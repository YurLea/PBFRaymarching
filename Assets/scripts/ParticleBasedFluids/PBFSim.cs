using System;
using System.Runtime.InteropServices;
using UnityEngine;

public class PBFSim : MonoBehaviour
{
    [Header("Compute")]
    public ComputeShader pbfCS;

    // === Константы как у вас ===
    public const int THREADS = 256;
    public const int MAX_PER_CELL = 256;
    public const int MAX_NEIGHBORS = 64;

    [Header("Sim")]
    public float dt = 0.016f;
    public int substeps = 4;
    public int solverIterations = 4;

    public float h = 0.4f;
    public float restDensity = 70.0f;
    public float particleMass = 1.0f;
    public float lambdaEps = 10.0f;

    public float corrK = 5e-5f;
    public float corrN = 4f;
    public float corrDeltaQ = 0.162f;

    public Vector3 gravity = new Vector3(0, -8, 0);
    public float xsphC = 0.0001f;

    public Vector3 boxMin = new Vector3(0, 0, 0);
    public Vector3 boxMax = new Vector3(8, 25, 5);
    public float particleRadius = 0.2f;
    public float damp = -0.5f;

    public int Nx = 10, Ny = 30, Nz = 14;
    public float spacing = 0.25f;

    [Header("Timing")]
    public bool useUnityDeltaTime = false; // если false — всегда используем dt как в sim

    [Header("Sphere")] 
    public Vector3 spherePosition;
    public float sphereRadius;

    // === Доступ наружу (для рендера, если захотите) ===
    public ComputeBuffer ParticlesBuffer => particlesBuffer;
    public int ParticleCount => N;

    // === GPU buffers ===
    ComputeBuffer particlesBuffer;
    ComputeBuffer gridIndicesBuffer;
    ComputeBuffer gridCountersBuffer;
    ComputeBuffer neighborsBuffer;
    ComputeBuffer neighborCountersBuffer;

    // === derived ===
    int N;
    Vector3 cellSize;
    Vector3Int gridRes;
    int gridTotalCells;

    // kernels
    int K_ClearGridCounters;
    int K_ApplyForcesPredict;
    int K_BuildGrid;
    int K_FindNeighbors;
    int K_ComputeLambda;
    int K_ComputeDeltaP;
    int K_ApplyDeltaAndCollide;
    int K_UpdateVelocityFinalize;
    int K_ApplyXSPHViscosity;

    [StructLayout(LayoutKind.Sequential)]
    struct ParticleData
    {
        public Vector4 position;
        public Vector4 predicted;
        public Vector4 velocity;
        public Vector4 delta;
        public float density;
        public float lambda;
        public float pad0;
        public float pad1;
    }

    static int CeilDiv(int a, int b) => (a + b - 1) / b;

    void Start()
    {
        if (pbfCS == null)
        {
            Debug.LogError("Assign ComputeShader (PBF.compute) to PBFSolver.");
            enabled = false;
            return;
        }

        // Derived values (как у вас в createPBFSolver)
        N = Nx * Ny * Nz;

        cellSize = new Vector3(h, h, h);
        gridRes = new Vector3Int(
            Mathf.CeilToInt((boxMax.x - boxMin.x) / cellSize.x),
            Mathf.CeilToInt((boxMax.y - boxMin.y) / cellSize.y),
            Mathf.CeilToInt((boxMax.z - boxMin.z) / cellSize.z)
        );
        gridTotalCells = gridRes.x * gridRes.y * gridRes.z;

        // Buffers
        particlesBuffer = new ComputeBuffer(N, Marshal.SizeOf<ParticleData>(), ComputeBufferType.Structured);

        gridIndicesBuffer = new ComputeBuffer(gridTotalCells * MAX_PER_CELL, sizeof(uint), ComputeBufferType.Structured);
        gridCountersBuffer = new ComputeBuffer(gridTotalCells, sizeof(uint), ComputeBufferType.Structured);

        neighborsBuffer = new ComputeBuffer(N * MAX_NEIGHBORS, sizeof(uint), ComputeBufferType.Structured);
        neighborCountersBuffer = new ComputeBuffer(N, sizeof(uint), ComputeBufferType.Structured);

        // Init particles (строго как в JS)
        var particles = new ParticleData[N];

        Vector3 start = boxMin + new Vector3(particleRadius + boxMax.x / 2, particleRadius + 0.1f, particleRadius + 0.1f);

        for (int i = 0; i < N; i++)
        {
            int x = i % Nx;
            int y = (i / Nx) % Ny;
            int z = i / (Nx * Ny);

            float px = start.x + spacing * x;
            float py = start.y + spacing * y;
            float pz = start.z + spacing * z;

            particles[i] = new ParticleData
            {
                position = new Vector4(px, py, pz, 0),
                predicted = new Vector4(px, py, pz, 0),
                velocity = Vector4.zero,
                delta = Vector4.zero,
                density = 0,
                lambda = 0,
                pad0 = 0,
                pad1 = 0
            };
        }

        particlesBuffer.SetData(particles);

        // Kernels
        K_ClearGridCounters = pbfCS.FindKernel("ClearGridCounters");
        K_ApplyForcesPredict = pbfCS.FindKernel("ApplyForcesPredict");
        K_BuildGrid = pbfCS.FindKernel("BuildGrid");
        K_FindNeighbors = pbfCS.FindKernel("FindNeighbors");
        K_ComputeLambda = pbfCS.FindKernel("ComputeLambda");
        K_ComputeDeltaP = pbfCS.FindKernel("ComputeDeltaP");
        K_ApplyDeltaAndCollide = pbfCS.FindKernel("ApplyDeltaAndCollide");
        K_UpdateVelocityFinalize = pbfCS.FindKernel("UpdateVelocityFinalize");
        K_ApplyXSPHViscosity = pbfCS.FindKernel("ApplyXSPHViscosity");

        // Bind buffers to all kernels (один раз)
        BindAllKernels();

        // Set static-ish params
        SetCommonParams();
    }

    void BindAllKernels()
    {
        int[] kernels =
        {
            K_ClearGridCounters, K_ApplyForcesPredict, K_BuildGrid, K_FindNeighbors,
            K_ComputeLambda, K_ComputeDeltaP, K_ApplyDeltaAndCollide, K_UpdateVelocityFinalize,
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
        pbfCS.SetInt("N", N);
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

        pbfCS.SetVector("gravity", new Vector4(gravity.x, gravity.y, gravity.z, 0));
        pbfCS.SetVector("boxMin", new Vector4(boxMin.x, boxMin.y, boxMin.z, 0));
        pbfCS.SetVector("boxMax", new Vector4(boxMax.x, boxMax.y, boxMax.z, 0));

        pbfCS.SetVector("gridCellSize", new Vector4(cellSize.x, cellSize.y, cellSize.z, 0));
        pbfCS.SetInts("gridResolution", gridRes.x, gridRes.y, gridRes.z, 0);
        
        pbfCS.SetVector("spherePosition", spherePosition);
        pbfCS.SetFloat("sphereRadius", sphereRadius);
    }

    void Update()
    {
        float frameDt = useUnityDeltaTime ? Time.deltaTime : dt;
        Step(frameDt);
    }

    void Step(float frameDt)
    {
        if (N <= 0) return;
        SetCommonParams();

        float stepDt = frameDt / Mathf.Max(1, substeps);
        pbfCS.SetFloat("dt", stepDt);

        int tgParticles = CeilDiv(N, THREADS);
        int tgCells = CeilDiv(gridTotalCells, THREADS);

        for (int s = 0; s < substeps; s++)
        {
            pbfCS.Dispatch(K_ApplyForcesPredict, tgParticles, 1, 1);

            pbfCS.Dispatch(K_ClearGridCounters, tgCells, 1, 1);
            pbfCS.Dispatch(K_BuildGrid, tgParticles, 1, 1);
            pbfCS.Dispatch(K_FindNeighbors, tgParticles, 1, 1);

            for (int it = 0; it < solverIterations; it++)
            {
                pbfCS.Dispatch(K_ComputeLambda, tgParticles, 1, 1);
                pbfCS.Dispatch(K_ComputeDeltaP, tgParticles, 1, 1);
                pbfCS.Dispatch(K_ApplyDeltaAndCollide, tgParticles, 1, 1);
            }

            pbfCS.Dispatch(K_UpdateVelocityFinalize, tgParticles, 1, 1);

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
    }
}
