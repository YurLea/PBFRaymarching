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
    [Header("Color")]
    // добавьте в параметры
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

        // Передача данных как в вашей заготовке + нужные параметры/текстура/границы
        mat.SetMatrix("_CamFrustum", CamFrustum(Cam));
        mat.SetMatrix("_CamToWorld", Cam.cameraToWorldMatrix);

        mat.SetFloat("_MaxDistance", maxDistance);
        mat.SetFloat("_DensityOffset", densityOffset);
        mat.SetFloat("_DensityMultiplier", densityMultiplier);
        mat.SetFloat("_StepSize", stepSize);

        Vector3 bmin = sim.boxMin;
        Vector3 bsize = sim.boxMax - sim.boxMin;
        mat.SetVector("_BoundsMin", new Vector4(bmin.x, bmin.y, bmin.z, 0));
        mat.SetVector("_BoundsSize", new Vector4(bsize.x, bsize.y, bsize.z, 0));

        mat.SetTexture("_DensityMap", densityMap.DensityTexture);
        
        mat.SetVector("_ScatteringCoefficients",
            new Vector4(scatteringCoefficients.x, scatteringCoefficients.y, scatteringCoefficients.z, 0));
        
        Light sun = directionalLight != null ? directionalLight : RenderSettings.sun;

        // dirToSun: направление ОТ точки в сцене К солнцу.
        // Для Directional Light в Unity лучи света идут вдоль -forward,
        // значит "к солнцу" = forward.
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

        mat.SetVector("_ScatteringCoefficients",
            new Vector4(scatteringCoefficients.x, scatteringCoefficients.y, scatteringCoefficients.z, 0));

        mat.SetVector("_LightColor", new Vector4(lightColor.x, lightColor.y, lightColor.z, 0));

        // Fullscreen quad как в вашей заготовке (vertex.z несёт индекс 0..3)
        RenderTexture.active = destination;
        GL.PushMatrix();
        GL.LoadOrtho();
        mat.SetPass(0);

        GL.Begin(GL.QUADS);

        // BL (index 3 in your original, but we keep your exact mapping)
        GL.MultiTexCoord2(0, 0.0f, 0.0f);
        GL.Vertex3(0.0f, 0.0f, 3.0f);

        // BR
        GL.MultiTexCoord2(0, 1.0f, 0.0f);
        GL.Vertex3(1.0f, 0.0f, 2.0f);

        // TR
        GL.MultiTexCoord2(0, 1.0f, 1.0f);
        GL.Vertex3(1.0f, 1.0f, 1.0f);

        // TL
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
