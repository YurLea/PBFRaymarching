using UnityEngine;
using UnityEngine.Rendering;

public class PBFDensityMap : MonoBehaviour
{
    [Header("Links")]
    public PBFSim sim;
    public ComputeShader densityCS;

    [Header("Density volume cfg")]
    public Vector3Int volumeResolution = new Vector3Int(80, 128, 80);
    public float densityStorageScale = 256.0f;

    [Header("Build")]
    public bool buildEveryFrame = true;
    public bool buildInLateUpdate = true;

    public RenderTexture DensityTexture => densityTexture;

    const int THREADS = 256;

    RenderTexture densityTexture;
    ComputeBuffer densityAccum;

    int totalCells;

    int K_Clear;
    int K_Splat;
    int K_Finalize;

    void OnEnable()
    {
        if (sim == null)
            sim = FindFirstObjectByType<PBFSim>();

        if (sim == null || densityCS == null)
        {
            enabled = false;
            return;
        }

        K_Clear = densityCS.FindKernel("ClearDensityVolume");
        K_Splat = densityCS.FindKernel("SplatParticlesToDensity");
        K_Finalize = densityCS.FindKernel("FinalizeDensityVolume");

        AllocateIfNeeded(force: true);
    }

    void OnDisable()
    {
        Release();
    }

    void Release()
    {
        if (densityTexture != null)
        {
            densityTexture.Release();

            if (Application.isPlaying)
                Destroy(densityTexture);
            else
                DestroyImmediate(densityTexture);

            densityTexture = null;
        }

        densityAccum?.Release();
        densityAccum = null;
    }

    void AllocateIfNeeded(bool force = false)
    {
        Vector3Int res = new Vector3Int(
            Mathf.Max(1, volumeResolution.x),
            Mathf.Max(1, volumeResolution.y),
            Mathf.Max(1, volumeResolution.z)
        );

        int newTotalCells = res.x * res.y * res.z;

        bool needRecreate =
            force ||
            densityTexture == null ||
            densityAccum == null ||
            totalCells != newTotalCells ||
            densityTexture.width != res.x ||
            densityTexture.height != res.y ||
            densityTexture.volumeDepth != res.z;

        if (!needRecreate)
            return;

        Release();

        totalCells = newTotalCells;

        densityAccum = new ComputeBuffer(
            totalCells,
            sizeof(uint),
            ComputeBufferType.Structured
        );

        densityTexture = new RenderTexture(
            res.x,
            res.y,
            0,
            RenderTextureFormat.ARGBHalf,
            RenderTextureReadWrite.Linear
        );

        densityTexture.dimension = TextureDimension.Tex3D;
        densityTexture.volumeDepth = res.z;
        densityTexture.enableRandomWrite = true;
        densityTexture.wrapMode = TextureWrapMode.Clamp;
        densityTexture.filterMode = FilterMode.Bilinear;
        densityTexture.Create();

        BindResources();
    }

    void BindResources()
    {
        if (sim == null)
            return;

        ComputeBuffer particles = sim.ParticlesBuffer;

        if (particles == null)
            return;

        int[] kernels =
        {
            K_Clear,
            K_Splat,
            K_Finalize
        };

        foreach (int k in kernels)
        {
            densityCS.SetBuffer(k, "Particles", particles);
            densityCS.SetBuffer(k, "DensityAccum", densityAccum);
            densityCS.SetTexture(k, "DensityMap", densityTexture);
        }
    }

    void SetParams()
    {
        Vector3 boundsMin = sim.boxMin;
        Vector3 boundsSize = sim.boxMax - sim.boxMin;

        Vector3Int res = new Vector3Int(
            Mathf.Max(1, volumeResolution.x),
            Mathf.Max(1, volumeResolution.y),
            Mathf.Max(1, volumeResolution.z)
        );

        Vector3 voxelSize = new Vector3(
            boundsSize.x / res.x,
            boundsSize.y / res.y,
            boundsSize.z / res.z
        );

        // ВАЖНО:
        // Строим density volume только по fluid-частицам.
        // В PBFSim fluid-частицы идут первыми: indices [0, sim.FluidCount).
        densityCS.SetInt("N", sim.FluidCount);

        densityCS.SetInt("volumeResolutionX", res.x);
        densityCS.SetInt("volumeResolutionY", res.y);
        densityCS.SetInt("volumeResolutionZ", res.z);

        densityCS.SetVector("boundsMin", new Vector4(boundsMin.x, boundsMin.y, boundsMin.z, 0));
        densityCS.SetVector("boundsSize", new Vector4(boundsSize.x, boundsSize.y, boundsSize.z, 0));
        densityCS.SetVector("voxelSize", new Vector4(voxelSize.x, voxelSize.y, voxelSize.z, 0));

        densityCS.SetFloat("h", sim.h);
        densityCS.SetFloat("particleMass", sim.particleMass);
        densityCS.SetFloat("densityStorageScale", Mathf.Max(1.0f, densityStorageScale));
    }

    void Update()
    {
        if (!buildInLateUpdate && buildEveryFrame)
            Build();
    }

    void LateUpdate()
    {
        if (buildInLateUpdate && buildEveryFrame)
            Build();
    }

    public void Build()
    {
        if (sim == null || densityCS == null)
            return;

        if (sim.ParticlesBuffer == null || sim.FluidCount <= 0)
            return;

        AllocateIfNeeded();
        BindResources();
        SetParams();

        int tgCells = Mathf.Max(1, (totalCells + THREADS - 1) / THREADS);
        int tgParticles = Mathf.Max(1, (sim.FluidCount + THREADS - 1) / THREADS);

        densityCS.Dispatch(K_Clear, tgCells, 1, 1);
        densityCS.Dispatch(K_Splat, tgParticles, 1, 1);
        densityCS.Dispatch(K_Finalize, tgCells, 1, 1);
    }
}

