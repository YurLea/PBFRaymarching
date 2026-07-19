using UnityEngine;

[RequireComponent(typeof(Camera))]
[ExecuteInEditMode]
public class PBFRaymarch : MonoBehaviour
{
    [Header("Links")]
    public PBFSim sim;
    public PBFDensityMap densityMap;
    
    [Header("Shader")]
    [SerializeField] private Shader _shader;
    
    [Header("Raymarch params")]
    public float maxDistance = 50.0f;
    
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

    private void OnRenderImage(RenderTexture source, RenderTexture destination)
    {
        if (!RaymarchMaterial || sim == null || densityMap == null || densityMap.DensityTexture == null)
        {
            Graphics.Blit(source, destination);
            return;
        }
        
        SetAllParameters(source);
        
        // Fullscreen quad (vertex.z несёт индекс 0..3)
        RenderTexture.active = destination;
        GL.PushMatrix();
        GL.LoadOrtho();
        RaymarchMaterial.SetPass(0);

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

    private void SetAllParameters(RenderTexture source)
    {
        // "окружение" в текущей версии шейдера — это просто source
        _raymarchMat.SetTexture("_MainTex", source);

        // Матрицы луча
        _raymarchMat.SetMatrix("_CamFrustum", CamFrustum(Cam));
        _raymarchMat.SetMatrix("_CamToWorld", Cam.cameraToWorldMatrix);

        // Марч
        _raymarchMat.SetFloat("_MaxDistance", maxDistance);
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
