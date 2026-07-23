using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using UnityEngine;

public class PBFSim : MonoBehaviour
{
    [Header("Compute")]
    public ComputeShader pbfCS;

    public const int THREADS = 256;
    public const int MAX_PER_CELL = 256;
    public const int MAX_NEIGHBORS = 64;

    const int PARTICLE_STRIDE = 96; // 24 floats * 4 bytes

    [Header("Sim")]
    public float dt = 0.016f;
    public int substeps = 4;
    public int solverIterations = 4;

    [Header("Fluid")]
    public float h = 0.4f;
    public float restDensity = 70.0f;
    public float particleMass = 1.0f;
    public float lambdaEps = 10.0f;

    public float corrK = 5e-5f;
    public float corrN = 4f;
    public float corrDeltaQ = 0.162f;

    public Vector3 gravity = new Vector3(0, -8, 0);
    public float xsphC = 0.0001f;

    [Header("Bounds")]
    public Vector3 boxMin = new Vector3(0, 0, 0);
    public Vector3 boxMax = new Vector3(8, 25, 5);
    public float particleRadius = 0.2f;

    [Tooltip("0 = не отскакивать от стен. Отрицательные значения дают bounce.")]
    public float damp = 0.0f;

    [Header("Fluid Initial Block")]
    public int Nx = 10;
    public int Ny = 30;
    public int Nz = 14;
    public float spacing = 0.25f;

    [Header("Rigid Sphere As Particles")]
    [Tooltip("До запуска — начальная позиция сферы. Во время Play Mode — текущая позиция центра сферы.")]
    public Vector3 spherePosition = new Vector3(4, 10, 2.5f);

    [Tooltip("Радиус сферы при генерации solid-частиц.")]
    public float sphereRadius = 1.0f;

    [Tooltip("Расстояние между частицами твердого тела. Обычно 0.7-1.2 * particleRadius.")]
    public float sphereParticleSpacing = 0.25f;

    [Tooltip("Масса одной solid-частицы. Чем больше, тем тяжелее сфера.")]
    public float solidParticleMass = 4.0f;

    [Range(0.0f, 1.0f)]
    public float shapeMatchingStiffness = 1.0f;

    [Header("Fluid-Solid Coupling")]
    [Tooltip("Множитель вклада solid particles в density estimation жидкости.")]
    public float solidDensityScale = 1.0f;

    [Tooltip("SOR-множитель только для contact constraints. PBF pressure delta им больше не масштабируется.")]
    public float contactSOR = 1.0f;

    [Tooltip("Количество предварительных contact-итераций перед основным solve.")]
    public int stabilizationIterations = 1;

    [Header("Timing")]
    public bool useUnityDeltaTime = false;

    public ComputeBuffer ParticlesBuffer => particlesBuffer;

    public int ParticleCount => totalParticleCount;
    public int FluidCount => fluidParticleCount;
    public int SolidCount => solidParticleCount;
    public int RigidStart => rigidStart;

    ComputeBuffer particlesBuffer;
    ComputeBuffer gridIndicesBuffer;
    ComputeBuffer gridCountersBuffer;
    ComputeBuffer neighborsBuffer;
    ComputeBuffer neighborCountersBuffer;

    ParticleData[] solidReadback;

    int fluidParticleCount;
    int solidParticleCount;
    int totalParticleCount;
    int rigidStart;

    Vector3 cellSize;
    Vector3Int gridRes;
    int gridTotalCells;

    int K_ClearGridCounters;
    int K_ApplyForcesPredict;
    int K_BuildGrid;
    int K_FindNeighbors;
    int K_ComputeLambda;
    int K_ComputeDeltaP;
    int K_SolveContactDeltas;
    int K_ApplyDeltaAndCollide;
    int K_ShapeMatchRigidSphere;
    int K_UpdateVelocityFinalize;
    int K_ApplyXSPHViscosity;

    [StructLayout(LayoutKind.Sequential)]
    struct ParticleData
    {
        public Vector4 position;
        public Vector4 predicted;
        public Vector4 velocity;
        public Vector4 delta;

        // Для rigid body:
        // rest.xyz — локальная rest-позиция частицы относительно центра масс rigid body.
        public Vector4 rest;

        public float density;
        public float lambda;
        public float invMass;
        public float type; // 0 = fluid, 1 = solid
    }

    static int CeilDiv(int a, int b)
    {
        return (a + b - 1) / b;
    }

    void Start()
    {
        if (pbfCS == null)
        {
            Debug.LogError("Assign ComputeShader PBF.compute to PBFSim.");
            enabled = false;
            return;
        }

        InitializeParticlesAndBuffers();
        FindKernels();
        BindAllKernels();
        SetCommonParams();

        // Сразу обновляем публичные runtime-поля после инициализации.
        UpdateSphereRuntimeFields();
    }

    void InitializeParticlesAndBuffers()
    {
        int actualStride = Marshal.SizeOf<ParticleData>();
        if (actualStride != PARTICLE_STRIDE)
        {
            Debug.LogError($"ParticleData stride mismatch. C# Marshal.SizeOf={actualStride}, expected={PARTICLE_STRIDE}. Shader expects 96 bytes.");
            enabled = false;
            return;
        }

        int safeNx = Mathf.Max(0, Nx);
        int safeNy = Mathf.Max(0, Ny);
        int safeNz = Mathf.Max(0, Nz);

        fluidParticleCount = safeNx * safeNy * safeNz;

        List<ParticleData> particles = new List<ParticleData>(fluidParticleCount + 1024);

        // -------------------------
        // Fluid particles
        // -------------------------

        Vector3 blockSize = new Vector3(
            Mathf.Max(0, safeNx - 1) * spacing,
            Mathf.Max(0, safeNy - 1) * spacing,
            Mathf.Max(0, safeNz - 1) * spacing
        );

        float sideMargin = particleRadius + 0.5f * h;

        Vector3 start = new Vector3(
            0.5f * (boxMin.x + boxMax.x - blockSize.x),
            boxMin.y + particleRadius + 0.1f,
            0.5f * (boxMin.z + boxMax.z - blockSize.z)
        );

        start.x = Mathf.Max(start.x, boxMin.x + sideMargin);
        start.z = Mathf.Max(start.z, boxMin.z + sideMargin);

        float maxFluidX = start.x + blockSize.x;
        float maxFluidY = start.y + blockSize.y;
        float maxFluidZ = start.z + blockSize.z;

        if (maxFluidX > boxMax.x - particleRadius ||
            maxFluidY > boxMax.y - particleRadius ||
            maxFluidZ > boxMax.z - particleRadius)
        {
            Debug.LogWarning(
                $"Fluid initial block may not fit inside box. " +
                $"Block max=({maxFluidX:F2}, {maxFluidY:F2}, {maxFluidZ:F2}), " +
                $"Box max allowed=({boxMax.x - particleRadius:F2}, {boxMax.y - particleRadius:F2}, {boxMax.z - particleRadius:F2})"
            );
        }

        for (int i = 0; i < fluidParticleCount; i++)
        {
            int x = i % safeNx;
            int y = (i / safeNx) % safeNy;
            int z = i / (safeNx * safeNy);

            float px = start.x + spacing * x;
            float py = start.y + spacing * y;
            float pz = start.z + spacing * z;

            px = Mathf.Clamp(px, boxMin.x + particleRadius, boxMax.x - particleRadius);
            py = Mathf.Clamp(py, boxMin.y + particleRadius, boxMax.y - particleRadius);
            pz = Mathf.Clamp(pz, boxMin.z + particleRadius, boxMax.z - particleRadius);

            particles.Add(new ParticleData
            {
                position = new Vector4(px, py, pz, 0),
                predicted = new Vector4(px, py, pz, 0),
                velocity = Vector4.zero,
                delta = Vector4.zero,
                rest = Vector4.zero,

                density = 0,
                lambda = 0,
                invMass = particleMass > 0.0f ? 1.0f / particleMass : 0.0f,
                type = 0.0f
            });
        }

        // -------------------------
        // Rigid sphere particles
        // -------------------------

        rigidStart = particles.Count;

        float r = Mathf.Max(0.001f, sphereRadius);
        float sp = Mathf.Max(0.001f, sphereParticleSpacing);

        List<Vector3> offsets = new List<Vector3>();

        for (float x = -r; x <= r + 1e-5f; x += sp)
        {
            for (float y = -r; y <= r + 1e-5f; y += sp)
            {
                for (float z = -r; z <= r + 1e-5f; z += sp)
                {
                    Vector3 local = new Vector3(x, y, z);

                    if (local.magnitude <= r)
                        offsets.Add(local);
                }
            }
        }

        if (offsets.Count == 0)
            offsets.Add(Vector3.zero);

        // Центрируем rest offsets относительно собственного COM.
        Vector3 restCom = Vector3.zero;
        for (int i = 0; i < offsets.Count; i++)
            restCom += offsets[i];

        restCom /= offsets.Count;

        for (int i = 0; i < offsets.Count; i++)
        {
            Vector3 rest = offsets[i] - restCom;
            Vector3 world = spherePosition + rest;

            world.x = Mathf.Clamp(world.x, boxMin.x + particleRadius, boxMax.x - particleRadius);
            world.y = Mathf.Clamp(world.y, boxMin.y + particleRadius, boxMax.y - particleRadius);
            world.z = Mathf.Clamp(world.z, boxMin.z + particleRadius, boxMax.z - particleRadius);

            particles.Add(new ParticleData
            {
                position = new Vector4(world.x, world.y, world.z, 0),
                predicted = new Vector4(world.x, world.y, world.z, 0),
                velocity = Vector4.zero,
                delta = Vector4.zero,
                rest = new Vector4(rest.x, rest.y, rest.z, 0),

                density = 0,
                lambda = 0,
                invMass = solidParticleMass > 0.0f ? 1.0f / solidParticleMass : 0.0f,
                type = 1.0f
            });
        }

        solidParticleCount = offsets.Count;
        totalParticleCount = particles.Count;

        solidReadback = solidParticleCount > 0 ? new ParticleData[solidParticleCount] : null;

        // -------------------------
        // Grid
        // -------------------------

        cellSize = new Vector3(h, h, h);

        gridRes = new Vector3Int(
            Mathf.Max(1, Mathf.CeilToInt((boxMax.x - boxMin.x) / cellSize.x)),
            Mathf.Max(1, Mathf.CeilToInt((boxMax.y - boxMin.y) / cellSize.y)),
            Mathf.Max(1, Mathf.CeilToInt((boxMax.z - boxMin.z) / cellSize.z))
        );

        gridTotalCells = gridRes.x * gridRes.y * gridRes.z;

        // -------------------------
        // Buffers
        // -------------------------

        particlesBuffer = new ComputeBuffer(
            totalParticleCount,
            PARTICLE_STRIDE,
            ComputeBufferType.Structured
        );

        particlesBuffer.SetData(particles);

        gridIndicesBuffer = new ComputeBuffer(
            gridTotalCells * MAX_PER_CELL,
            sizeof(uint),
            ComputeBufferType.Structured
        );

        gridCountersBuffer = new ComputeBuffer(
            gridTotalCells,
            sizeof(uint),
            ComputeBufferType.Structured
        );

        neighborsBuffer = new ComputeBuffer(
            totalParticleCount * MAX_NEIGHBORS,
            sizeof(uint),
            ComputeBufferType.Structured
        );

        neighborCountersBuffer = new ComputeBuffer(
            totalParticleCount,
            sizeof(uint),
            ComputeBufferType.Structured
        );

        Debug.Log(
            $"PBFSim initialized. Fluid={fluidParticleCount}, SolidSphere={solidParticleCount}, Total={totalParticleCount}, Grid={gridRes}, Stride={PARTICLE_STRIDE}"
        );
    }

    void FindKernels()
    {
        K_ClearGridCounters = pbfCS.FindKernel("ClearGridCounters");
        K_ApplyForcesPredict = pbfCS.FindKernel("ApplyForcesPredict");
        K_BuildGrid = pbfCS.FindKernel("BuildGrid");
        K_FindNeighbors = pbfCS.FindKernel("FindNeighbors");
        K_ComputeLambda = pbfCS.FindKernel("ComputeLambda");
        K_ComputeDeltaP = pbfCS.FindKernel("ComputeDeltaP");
        K_SolveContactDeltas = pbfCS.FindKernel("SolveContactDeltas");
        K_ApplyDeltaAndCollide = pbfCS.FindKernel("ApplyDeltaAndCollide");
        K_ShapeMatchRigidSphere = pbfCS.FindKernel("ShapeMatchRigidSphere");
        K_UpdateVelocityFinalize = pbfCS.FindKernel("UpdateVelocityFinalize");
        K_ApplyXSPHViscosity = pbfCS.FindKernel("ApplyXSPHViscosity");
    }

    void BindAllKernels()
    {
        int[] kernels =
        {
            K_ClearGridCounters,
            K_ApplyForcesPredict,
            K_BuildGrid,
            K_FindNeighbors,
            K_ComputeLambda,
            K_ComputeDeltaP,
            K_SolveContactDeltas,
            K_ApplyDeltaAndCollide,
            K_ShapeMatchRigidSphere,
            K_UpdateVelocityFinalize,
            K_ApplyXSPHViscosity
        };

        foreach (int k in kernels)
        {
            pbfCS.SetBuffer(k, "Particles", particlesBuffer);
            pbfCS.SetBuffer(k, "GridIndices", gridIndicesBuffer);
            pbfCS.SetBuffer(k, "GridCounters", gridCountersBuffer);
            pbfCS.SetBuffer(k, "Neighbors", neighborsBuffer);
            pbfCS.SetBuffer(k, "NeighborCounters", neighborCountersBuffer);
        }
    }

    void SetCommonParams()
    {
        pbfCS.SetInt("N", totalParticleCount);
        pbfCS.SetInt("fluidCount", fluidParticleCount);
        pbfCS.SetInt("rigidStart", rigidStart);
        pbfCS.SetInt("rigidCount", solidParticleCount);
        pbfCS.SetInt("gridTotalCells", gridTotalCells);

        pbfCS.SetFloat("h", h);
        pbfCS.SetFloat("restDensity", restDensity);
        pbfCS.SetFloat("particleMass", particleMass);

        pbfCS.SetFloat("lambdaEps", lambdaEps);
        pbfCS.SetFloat("corrK", corrK);
        pbfCS.SetFloat("corrN", corrN);
        pbfCS.SetFloat("corrDeltaQ", corrDeltaQ);

        pbfCS.SetFloat("xsphC", xsphC);
        pbfCS.SetFloat("particleRadius", particleRadius);
        pbfCS.SetFloat("damp", damp);

        pbfCS.SetFloat("solidDensityScale", solidDensityScale);
        pbfCS.SetFloat("shapeMatchingStiffness", shapeMatchingStiffness);
        pbfCS.SetFloat("contactSOR", contactSOR);

        pbfCS.SetVector("gravity", new Vector4(gravity.x, gravity.y, gravity.z, 0));
        pbfCS.SetVector("boxMin", new Vector4(boxMin.x, boxMin.y, boxMin.z, 0));
        pbfCS.SetVector("boxMax", new Vector4(boxMax.x, boxMax.y, boxMax.z, 0));

        pbfCS.SetVector("gridCellSize", new Vector4(cellSize.x, cellSize.y, cellSize.z, 0));
        pbfCS.SetInts("gridResolution", gridRes.x, gridRes.y, gridRes.z, 0);
    }

    void Update()
    {
        float frameDt = useUnityDeltaTime ? Time.deltaTime : dt;

        Step(frameDt);

        // После шага симуляции обновляем spherePosition текущим центром сферы.
        UpdateSphereRuntimeFields();
    }

    void UpdateSphereRuntimeFields()
    {
        if (particlesBuffer == null)
            return;

        if (solidParticleCount <= 0)
            return;

        if (solidReadback == null || solidReadback.Length != solidParticleCount)
            solidReadback = new ParticleData[solidParticleCount];

        particlesBuffer.GetData(
            solidReadback,
            0,
            rigidStart,
            solidParticleCount
        );

        Vector3 com = Vector3.zero;

        for (int i = 0; i < solidParticleCount; i++)
        {
            Vector4 p = solidReadback[i].position;
            com += new Vector3(p.x, p.y, p.z);
        }

        com /= solidParticleCount;

        spherePosition = com;
    }

    void RebuildNeighbors(int tgParticles, int tgCells)
    {
        pbfCS.Dispatch(K_ClearGridCounters, tgCells, 1, 1);
        pbfCS.Dispatch(K_BuildGrid, tgParticles, 1, 1);
        pbfCS.Dispatch(K_FindNeighbors, tgParticles, 1, 1);
    }

    void Step(float frameDt)
    {
        if (totalParticleCount <= 0) return;

        SetCommonParams();

        float stepDt = frameDt / Mathf.Max(1, substeps);
        pbfCS.SetFloat("dt", stepDt);

        int tgParticles = CeilDiv(totalParticleCount, THREADS);
        int tgCells = CeilDiv(gridTotalCells, THREADS);

        for (int s = 0; s < substeps; s++)
        {
            // 1. External forces + prediction.
            pbfCS.Dispatch(K_ApplyForcesPredict, tgParticles, 1, 1);

            // 2. Neighbor search for all particles: fluid + rigid sphere particles.
            RebuildNeighbors(tgParticles, tgCells);

            // 3. Pre-stabilization contacts.
            int stabIterations = Mathf.Max(0, stabilizationIterations);

            for (int st = 0; st < stabIterations; st++)
            {
                pbfCS.Dispatch(K_SolveContactDeltas, tgParticles, 1, 1);
                pbfCS.Dispatch(K_ApplyDeltaAndCollide, tgParticles, 1, 1);

                if (solidParticleCount > 0)
                    pbfCS.Dispatch(K_ShapeMatchRigidSphere, 1, 1, 1);
            }

            // Если pre-stabilization двигал частицы — обновляем neighbor list перед основным PBF solve.
            if (stabIterations > 0)
                RebuildNeighbors(tgParticles, tgCells);

            // 4. Main solver.
            for (int it = 0; it < solverIterations; it++)
            {
                // Fluid density constraint.
                pbfCS.Dispatch(K_ComputeLambda, tgParticles, 1, 1);

                // ВАЖНО:
                // ComputeDeltaP кладет PBF delta в p.delta.xyz.
                pbfCS.Dispatch(K_ComputeDeltaP, tgParticles, 1, 1);

                // SolveContactDeltas теперь ДОБАВЛЯЕТ contact delta к уже имеющейся PBF delta.
                pbfCS.Dispatch(K_SolveContactDeltas, tgParticles, 1, 1);

                // Применяем сумму: PBF pressure delta + fluid-solid contact delta.
                pbfCS.Dispatch(K_ApplyDeltaAndCollide, tgParticles, 1, 1);

                // Rigid shape matching constraint.
                if (solidParticleCount > 0)
                    pbfCS.Dispatch(K_ShapeMatchRigidSphere, 1, 1, 1);
            }

            // 5. Velocities from position changes.
            pbfCS.Dispatch(K_UpdateVelocityFinalize, tgParticles, 1, 1);

            // 6. XSPH only for fluid particles.
            if (xsphC > 0.0f)
                pbfCS.Dispatch(K_ApplyXSPHViscosity, tgParticles, 1, 1);
        }
    }

    void OnDestroy()
    {
        particlesBuffer?.Release();
        gridIndicesBuffer?.Release();
        gridCountersBuffer?.Release();
        neighborsBuffer?.Release();
        neighborCountersBuffer?.Release();

        particlesBuffer = null;
        gridIndicesBuffer = null;
        gridCountersBuffer = null;
        neighborsBuffer = null;
        neighborCountersBuffer = null;

        solidReadback = null;
    }
}


