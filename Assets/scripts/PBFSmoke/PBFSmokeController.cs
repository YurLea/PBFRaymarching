using System.Collections;
using System.Runtime.InteropServices;
using UnityEngine;
using UnityEngine.Rendering;

public class PBFSmoke : MonoBehaviour
{
    [Header("Compute")]
    public ComputeShader cs;

    [Header("Fluid resolution (~10k)")]
    [Range(16, 40)] public int dim = 22; // 22^3 = 10648

    [Header("Solver")]
    [Range(1, 12)] public int solverIters = 5;
    public float dt = 1f / 60f;

    [Header("PBF params")]
    public float hMul = 1.8f;         // h = hMul * spacing
    public float eps = 1e-6f;
    public float scorrK = 0.01f;
    public float scorrN = 4f;
    public float velDamping = 0.999f;

    [Header("Box 1x1x1")]
    public Vector3 boxMin = Vector3.zero;
    public Vector3 boxMax = Vector3.one;

    [Header("Forces")]
    public Vector3 gravity = new Vector3(0, -9.81f, 0);
    [Range(0f, 1f)] public float alphaG = 0.0f; // часто 0 для carrier air
    public Vector3 sourceCenter = new Vector3(0.5f, 0.12f, 0.5f);
    public float sourceRadius = 0.12f;
    public float jetAccel = 40f;

    [Header("Smoke markers")]
    public int smokeMax = 65536;
    public int spawnPerFrame = 256;
    public float smokeLife = 6f;
    public float smokeSpawnRadius = 0.06f;

    // === API для твоего PBFQuadRenderer ===
    public ComputeBuffer ParticlesBuffer => smokeBuf;  // ВАЖНО: это SMOKE buffer
    public int ParticleCount => smokeMax;

    // Debug (если захочешь рисовать fluid отдельно)
    public ComputeBuffer FluidBuffer => fluidBuf;
    public int FluidCount => nFluid;

    // Grid
    const uint MAX_PER_CELL = 64;

    // Kernels
    int K0, K1, K2pred, K2x, K3, K4, K5, K6, K7emit, K8adv, K9rho;

    // Buffers
    ComputeBuffer fluidBuf;
    ComputeBuffer deltaBuf;
    ComputeBuffer cellCountBuf;
    ComputeBuffer cellParticlesBuf;
    ComputeBuffer smokeBuf;
    ComputeBuffer smokeWriteBuf;
    ComputeBuffer rhoOutBuf;

    int nFluid;

    int gridResX, gridResY, gridResZ;
    int numCells;

    float spacing;
    float h;
    float r;
    float poly6Const;
    float spikyGradConst;
    float scorrDQ;
    float scorrWQ;
    float rho0 = 0f;

    bool ready = false;
    uint frameIndex = 1;

    [StructLayout(LayoutKind.Sequential)]
    struct FluidParticle
    {
        public Vector4 x;
        public Vector4 v;
        public Vector4 xPred;
        public float lambda;
        public float rho;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct SmokeParticle
    {
        public Vector4 x;
        public Vector4 v;
        public float life;
        public float pad0;
        public Vector2 pad1;
    }

    void OnDestroy()
    {
        ReleaseAll();
    }

    void OnDisable()
    {
        ReleaseAll();
    }

    void ReleaseAll()
    {
        fluidBuf?.Release(); fluidBuf = null;
        deltaBuf?.Release(); deltaBuf = null;
        cellCountBuf?.Release(); cellCountBuf = null;
        cellParticlesBuf?.Release(); cellParticlesBuf = null;
        smokeBuf?.Release(); smokeBuf = null;
        smokeWriteBuf?.Release(); smokeWriteBuf = null;
        rhoOutBuf?.Release(); rhoOutBuf = null;
        ready = false;
    }

    IEnumerator Start()
    {
        if (!cs) yield break;

        FindKernels();
        AllocateAndInit();

        // Compute rest density rho0 once from initial lattice
        yield return ComputeRestDensity();

        ready = true;
    }

    void FixedUpdate()
    {
        if (!ready || !Application.isPlaying) return;

        frameIndex++;

        SetCommonParams(dt);

        // 1) forces + predict
        cs.Dispatch(K0, Groups(nFluid), 1, 1);

        // 2) build grid on xPred
        cs.Dispatch(K1, Groups(numCells), 1, 1);
        cs.Dispatch(K2pred, Groups(nFluid), 1, 1);

        // 3) PBF iterations
        for (int it = 0; it < solverIters; it++)
        {
            cs.Dispatch(K3, Groups(nFluid), 1, 1);
            cs.Dispatch(K4, Groups(nFluid), 1, 1);
            cs.Dispatch(K5, Groups(nFluid), 1, 1);
        }

        // 4) update velocity + commit x
        cs.Dispatch(K6, Groups(nFluid), 1, 1);

        // 5) rebuild grid on final x (for smoke velocity sampling)
        cs.Dispatch(K1, Groups(numCells), 1, 1);
        cs.Dispatch(K2x, Groups(nFluid), 1, 1);

        // 6) emit smoke (ring buffer)
        SetSmokeParams();
        cs.Dispatch(K7emit, Groups(spawnPerFrame), 1, 1);

        // 7) advect smoke
        cs.Dispatch(K8adv, Groups(smokeMax), 1, 1);
    }

    void FindKernels()
    {
        K0 = cs.FindKernel("K0_ApplyForcesPredict");
        K1 = cs.FindKernel("K1_ClearGrid");
        K2pred = cs.FindKernel("K2_BuildGrid_Pred");
        K2x = cs.FindKernel("K2b_BuildGrid_X");
        K3 = cs.FindKernel("K3_ComputeLambda");
        K4 = cs.FindKernel("K4_ComputeDeltaPos");
        K5 = cs.FindKernel("K5_ApplyDeltaPosProject");
        K6 = cs.FindKernel("K6_UpdateVelocity");
        K7emit = cs.FindKernel("K7_EmitSmoke");
        K8adv = cs.FindKernel("K8_AdvectSmoke");
        K9rho = cs.FindKernel("K9_DensityOnly");
    }

    void AllocateAndInit()
    {
        nFluid = dim * dim * dim;

        spacing = (boxMax.x - boxMin.x) / dim;
        h = hMul * spacing;
        r = 0.49f * spacing;

        gridResX = Mathf.CeilToInt((boxMax.x - boxMin.x) / h);
        gridResY = Mathf.CeilToInt((boxMax.y - boxMin.y) / h);
        gridResZ = Mathf.CeilToInt((boxMax.z - boxMin.z) / h);
        numCells = gridResX * gridResY * gridResZ;

        // kernel constants
        poly6Const = 315f / (64f * Mathf.PI * Mathf.Pow(h, 9f));
        spikyGradConst = -45f / (Mathf.PI * Mathf.Pow(h, 6f));

        scorrDQ = 0.3f * h;
        float h2 = h * h;
        float dq2 = scorrDQ * scorrDQ;
        float x = h2 - dq2;
        scorrWQ = (dq2 < h2) ? poly6Const * x * x * x : 1f;

        // Buffers
        fluidBuf = new ComputeBuffer(nFluid, Marshal.SizeOf<FluidParticle>(), ComputeBufferType.Structured);
        deltaBuf = new ComputeBuffer(nFluid, sizeof(float) * 4, ComputeBufferType.Structured);

        cellCountBuf = new ComputeBuffer(numCells, sizeof(uint), ComputeBufferType.Structured);
        cellParticlesBuf = new ComputeBuffer(numCells * (int)MAX_PER_CELL, sizeof(uint), ComputeBufferType.Structured);

        smokeBuf = new ComputeBuffer(smokeMax, Marshal.SizeOf<SmokeParticle>(), ComputeBufferType.Structured);
        smokeWriteBuf = new ComputeBuffer(1, sizeof(uint), ComputeBufferType.Structured);

        rhoOutBuf = new ComputeBuffer(nFluid, sizeof(float), ComputeBufferType.Structured);

        // Init fluid lattice
        var fluid = new FluidParticle[nFluid];
        int idx = 0;
        for (int z = 0; z < dim; z++)
        for (int y = 0; y < dim; y++)
        for (int x3 = 0; x3 < dim; x3++)
        {
            Vector3 pos = new Vector3((x3 + 0.5f) / dim, (y + 0.5f) / dim, (z + 0.5f) / dim);
            fluid[idx] = new FluidParticle
            {
                x = new Vector4(pos.x, pos.y, pos.z, 0),
                v = Vector4.zero,
                xPred = new Vector4(pos.x, pos.y, pos.z, 0),
                lambda = 0,
                rho = 0
            };
            idx++;
        }
        fluidBuf.SetData(fluid);

        // Init smoke as dead
        var smoke = new SmokeParticle[smokeMax];
        for (int i = 0; i < smokeMax; i++)
            smoke[i] = new SmokeParticle { x = Vector4.zero, v = Vector4.zero, life = -1 };
        smokeBuf.SetData(smoke);
        smokeWriteBuf.SetData(new uint[] { 0 });

        BindAllBuffers();

        // Static-ish params
        cs.SetInt("_NumCells", numCells);
        cs.SetInts("_GridRes", gridResX, gridResY, gridResZ);
        cs.SetInt("_MaxPerCell", (int)MAX_PER_CELL);

        cs.SetVector("_BoxMin", boxMin);
        cs.SetVector("_BoxMax", boxMax);

        cs.SetFloat("_H", h);
        cs.SetFloat("_H2", h * h);
        cs.SetFloat("_R", r);

        cs.SetFloat("_Poly6Const", poly6Const);
        cs.SetFloat("_SpikyGradConst", spikyGradConst);

        cs.SetFloat("_ScorrK", scorrK);
        cs.SetFloat("_ScorrN", scorrN);
        cs.SetFloat("_ScorrDQ", scorrDQ);
        cs.SetFloat("_ScorrWQ", scorrWQ);

        cs.SetFloat("_Eps", eps);
    }

    void BindAllBuffers()
    {
        int[] kernels = { K0, K2pred, K2x, K3, K4, K5, K6, K9rho, K8adv };
        foreach (var k in kernels)
        {
            cs.SetBuffer(k, "_Fluid", fluidBuf);
            cs.SetBuffer(k, "_CellCount", cellCountBuf);
            cs.SetBuffer(k, "_CellParticles", cellParticlesBuf);
        }

        cs.SetBuffer(K4, "_DeltaPos", deltaBuf);
        cs.SetBuffer(K5, "_DeltaPos", deltaBuf);

        cs.SetBuffer(K1, "_CellCount", cellCountBuf);

        cs.SetBuffer(K7emit, "_Smoke", smokeBuf);
        cs.SetBuffer(K7emit, "_SmokeWrite", smokeWriteBuf);
        cs.SetBuffer(K8adv, "_Smoke", smokeBuf);

        cs.SetBuffer(K9rho, "_RhoOut", rhoOutBuf);
    }

    IEnumerator ComputeRestDensity()
    {
        // Build grid from x (initial), compute rho into rhoOutBuf, readback -> rho0.
        cs.SetInt("_NumParticles", nFluid);
        cs.SetFloat("_Dt", dt);
        cs.SetFloat("_M", 1f);
        cs.SetFloat("_Rho0", 1f);

        cs.Dispatch(K1, Groups(numCells), 1, 1);
        cs.Dispatch(K2x, Groups(nFluid), 1, 1);
        cs.Dispatch(K9rho, Groups(nFluid), 1, 1);

        var req = AsyncGPUReadback.Request(rhoOutBuf);
        while (!req.done) yield return null;
        if (req.hasError)
        {
            Debug.LogError("AsyncGPUReadback error while computing rest density.");
            yield break;
        }

        var data = req.GetData<float>();

        float sum = 0f;
        int count = 0;
        for (int i = 0; i < nFluid; i++)
        {
            int z = i / (dim * dim);
            int rem = i - z * dim * dim;
            int y = rem / dim;
            int x = rem - y * dim;

            float px = (x + 0.5f) / dim;
            float py = (y + 0.5f) / dim;
            float pz = (z + 0.5f) / dim;

            if (px < h || px > 1f - h) continue;
            if (py < h || py > 1f - h) continue;
            if (pz < h || pz > 1f - h) continue;

            sum += data[i];
            count++;
        }

        rho0 = (count > 0) ? (sum / count) : 1f;
        Debug.Log($"PBF rest density rho0 = {rho0:F6}");

        cs.SetFloat("_Rho0", rho0);
        cs.SetFloat("_M", 1f);
    }

    void SetCommonParams(float dtNow)
    {
        cs.SetInt("_NumParticles", nFluid);
        cs.SetFloat("_Dt", dtNow);
        cs.SetFloat("_Rho0", rho0);
        cs.SetFloat("_M", 1f);

        cs.SetFloat("_AlphaG", alphaG);
        cs.SetVector("_Gravity", gravity);

        cs.SetVector("_SourceCenter", sourceCenter);
        cs.SetFloat("_SourceRadius", sourceRadius);
        cs.SetFloat("_JetAccel", jetAccel);

        cs.SetFloat("_VelDamping", velDamping);
        cs.SetInt("_FrameIndex", (int)frameIndex);
    }

    void SetSmokeParams()
    {
        cs.SetInt("_SmokeMax", smokeMax);
        cs.SetInt("_SpawnPerFrame", spawnPerFrame);
        cs.SetFloat("_SmokeLife", smokeLife);
        cs.SetFloat("_SmokeSpawnRadius", smokeSpawnRadius);
        cs.SetInt("_FrameIndex", (int)frameIndex);
    }

    static int Groups(int n) => Mathf.CeilToInt(n / 256f);
}
