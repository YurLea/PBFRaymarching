using UnityEngine;

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

    [Header("Refraction")]
    public float indexOfRefraction = 1.333f;   // вода ~1.333
    public float refractionStrength = 1.0f;    // 0..1 (можно >1 для усиления)

    [Header("Color")]
    public Vector3 scatteringCoefficients = new Vector3(1f, 1f, 1f);

    [Header("Lighting")]
    public Light directionalLight;                 // если null, возьмём RenderSettings.sun
    public float lightMarchStepSize = 0.15f;       // шаг марча по лучу к солнцу

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
        // Нужна depth texture для screen-space refraction
        Cam.depthTextureMode |= DepthTextureMode.Depth;
    }

    void OnDisable()
    {
        if (_raymarchMat)
        {
            if (Application.isPlaying) Destroy(_raymarchMat);
            else DestroyImmediate(_raymarchMat);
        }
    }

    // ВАЖНО: гарантируем, что density volume построена до рендера камеры
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

        // фон (source) нужен для рефракции
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

        // Volume texture
        mat.SetTexture("_DensityMap", densityMap.DensityTexture);

        // Scattering
        mat.SetVector("_ScatteringCoefficients",
            new Vector4(scatteringCoefficients.x, scatteringCoefficients.y, scatteringCoefficients.z, 0));

        // Refraction params
        mat.SetFloat("_IOR", indexOfRefraction);
        mat.SetFloat("_RefractionStrength", refractionStrength);

        // Light
        Light sun = directionalLight != null ? directionalLight : RenderSettings.sun;

        Vector3 dirToSun = sun != null ? -sun.transform.forward : Vector3.up;
        dirToSun.Normalize();

        Vector3 lightColor = Vector3.one;
        if (sun != null)
        {
            Color c = sun.color * sun.intensity;
            lightColor = new Vector3(c.r, c.g, c.b);
        }

        mat.SetVector("_DirToSun", new Vector4(dirToSun.x, dirToSun.y, dirToSun.z, 0));
        mat.SetFloat("_LightMarchStepSize", lightMarchStepSize);
        mat.SetVector("_LightColor", new Vector4(lightColor.x, lightColor.y, lightColor.z, 0));

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
