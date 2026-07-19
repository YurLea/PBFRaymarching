using UnityEngine;
using UnityEngine.Experimental.GlobalIllumination;

[RequireComponent(typeof(Camera))]
[ExecuteInEditMode]
public class PBFRaymarchCamera : MonoBehaviour
{
    [Header("Links")]
    public PBFSim sim;
    public PBFDensityMap densityMap;

    [Header("Shader")]
    [SerializeField] private Shader _shader;

    [Header("Raymarch params")]
    public float maxDistance = 50.0f;
    public float densityOffset = 25.0f;
    public float densityMultiplier = 0.0045f;
    public float stepSize = 0.03f;

    [Header("Medium / Extinction")]
    public Vector3 scatteringCoefficients = new Vector3(1f, 1f, 1f); // в новом шейдере это extinctionCoeff
    public float normalEps = 0.005f;

    [Header("IOR")]
    public float indexOfRefraction = 1.333f; // вода ~1.333

    [Header("Boundary tracing (like Fluid/Raymarching)")]
    [Range(1, 16)] public int numBounces = 4;
    public float bounceDensityStepSize = 0.15f;

    [Header("Light")]
    public Light sun; // перетащи сюда Directional Light из сцены


    private Camera _cam;
    private Material _raymarchMat;

    public Camera Cam
    {
        get
        {
            if (!_cam) _cam = GetComponent<Camera>();
            return _cam;
        }
    }

    public Material RaymarchMaterial
    {
        get
        {
            if (!_raymarchMat && _shader)
            {
                _raymarchMat = new Material(_shader);
                _raymarchMat.hideFlags = HideFlags.HideAndDontSave;
            }
            return _raymarchMat;
        }
    }

    private void OnEnable()
    {
        // Новый шейдер НЕ использует depth texture (нет screen-space refraction)
        // Cam.depthTextureMode |= DepthTextureMode.Depth;
    }

    void OnDisable()
    {
        if (_raymarchMat)
        {
            if (Application.isPlaying) Destroy(_raymarchMat);
            else DestroyImmediate(_raymarchMat);
        }
    }

    // гарантируем, что density volume построена до рендера камеры
    void OnPreRender()
    {
        if (densityMap != null)
            densityMap.Build();
    }

    private void OnRenderImage(RenderTexture source, RenderTexture destination)
    {
        var mat = RaymarchMaterial;
        if (!mat || sim == null || densityMap == null || densityMap.DensityTexture == null)
        {
            Graphics.Blit(source, destination);
            return;
        }

        // "окружение" в текущей версии шейдера — это просто source
        mat.SetTexture("_MainTex", source);

        // Матрицы луча
        mat.SetMatrix("_CamFrustum", CamFrustum(Cam));
        mat.SetMatrix("_CamToWorld", Cam.cameraToWorldMatrix);

        // Марч
        mat.SetFloat("_MaxDistance", maxDistance);
        mat.SetFloat("_DensityOffset", densityOffset);
        mat.SetFloat("_DensityMultiplier", densityMultiplier);
        mat.SetFloat("_StepSize", stepSize);

        // Bounds
        Vector3 bmin = sim.boxMin;
        Vector3 bsize = sim.boxMax - sim.boxMin;
        mat.SetVector("_BoundsMin", new Vector4(bmin.x, bmin.y, bmin.z, 0));
        mat.SetVector("_BoundsSize", new Vector4(bsize.x, bsize.y, bsize.z, 0));
        
        
        Vector3 dirToSunWS = -sun.transform.forward;          // world-space
        mat.SetVector("dirToSun", new Vector4(dirToSunWS.x, dirToSunWS.y, dirToSunWS.z, 0));
        
        
        // Volume texture
        mat.SetTexture("_DensityMap", densityMap.DensityTexture);

        // Extinction (в шейдере используется как extinctionCoeff через Transmittance())
        mat.SetVector("_ScatteringCoefficients",
            new Vector4(scatteringCoefficients.x, scatteringCoefficients.y, scatteringCoefficients.z, 0));

        // Normal epsilon
        mat.SetFloat("_NormalEps", normalEps);

        // IOR
        mat.SetFloat("_IOR", indexOfRefraction);

        // New: bounces like Fluid/Raymarching
        mat.SetFloat("_NumBounces", Mathf.Clamp(numBounces, 1, 16));
        mat.SetFloat("_BounceDensityStepSize", Mathf.Max(1e-4f, bounceDensityStepSize));

        // Fullscreen quad (vertex.z несёт индекс 0..3)
        RenderTexture.active = destination;
        GL.PushMatrix();
        GL.LoadOrtho();
        mat.SetPass(0);

        GL.Begin(GL.QUADS);

        // BL (index 3)
        GL.MultiTexCoord2(0, 0.0f, 0.0f);
        GL.Vertex3(0.0f, 0.0f, 3.0f);

        // BR (index 2)
        GL.MultiTexCoord2(0, 1.0f, 0.0f);
        GL.Vertex3(1.0f, 0.0f, 2.0f);

        // TR (index 1)
        GL.MultiTexCoord2(0, 1.0f, 1.0f);
        GL.Vertex3(1.0f, 1.0f, 1.0f);

        // TL (index 0)
        GL.MultiTexCoord2(0, 0.0f, 1.0f);
        GL.Vertex3(0.0f, 1.0f, 0.0f);

        GL.End();
        GL.PopMatrix();
    }

    private Matrix4x4 CamFrustum(Camera cam)
    {
        var frustum = Matrix4x4.identity;
        float fov = Mathf.Tan((cam.fieldOfView * 0.5f) * Mathf.Deg2Rad);

        Vector3 goUp = Vector3.up * fov;
        Vector3 goRight = Vector3.right * fov * cam.aspect;

        Vector3 TL = (-Vector3.forward - goRight + goUp);
        Vector3 TR = (-Vector3.forward + goRight + goUp);
        Vector3 BR = (-Vector3.forward + goRight - goUp);
        Vector3 BL = (-Vector3.forward - goRight - goUp);

        frustum.SetRow(0, TL);
        frustum.SetRow(1, TR);
        frustum.SetRow(2, BR);
        frustum.SetRow(3, BL);

        return frustum;
    }
}
