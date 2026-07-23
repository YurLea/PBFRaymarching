using UnityEngine;

[ExecuteAlways]
public class SmokeQuadRenderer : MonoBehaviour
{
    [Header("References")]
    public PBFSmoke sim;
    public Material material;

    [Header("Quad size (world units)")]
    public float size = 0.03f;

    [Header("Speed -> Color mapping")]
    public float minSpeed = 0.0f;
    public float maxSpeed = 6.0f;

    [Header("Smoke fade")]
    public float lifeFadeSeconds = 1.0f;

    [Header("Rendering")]
    public bool drawInSceneView = true;

    void OnDisable()
    {
        if (material != null)
            material.SetBuffer("_Particles", (ComputeBuffer)null);
    }

    void OnRenderObject()
    {
        if (sim == null || material == null) return;
        if (!drawInSceneView && (Camera.current != null) && Camera.current.cameraType == CameraType.SceneView) return;

        var buf = sim.ParticlesBuffer; // smoke buffer
        int n = sim.ParticleCount;     // smokeMax
        if (buf == null || n <= 0) return;

        Camera cam = Camera.current;
        if (cam == null) return;

        material.SetBuffer("_Particles", buf);
        material.SetFloat("_Size", size);
        material.SetFloat("_MinSpeed", minSpeed);
        material.SetFloat("_MaxSpeed", Mathf.Max(minSpeed + 1e-5f, maxSpeed));
        material.SetFloat("_LifeFade", Mathf.Max(1e-5f, lifeFadeSeconds));

        Vector3 right = cam.transform.right;
        Vector3 up = cam.transform.up;
        material.SetVector("_CamRight", new Vector4(right.x, right.y, right.z, 0));
        material.SetVector("_CamUp", new Vector4(up.x, up.y, up.z, 0));

        material.SetPass(0);
        Graphics.DrawProceduralNow(MeshTopology.Triangles, 6, n);
    }
}
