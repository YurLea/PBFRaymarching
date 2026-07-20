using UnityEngine;

[RequireComponent(typeof(Camera))]   // Скрипт должен висеть на камере (нужны матрицы/OnRenderImage)
[ExecuteInEditMode]                  // Чтобы работало в редакторе без Play Mode
public class PBFRaymarch : MonoBehaviour
{
    [Header("Links")]
    public PBFSim sim;                        // Ссылка на симуляцию (если нужно брать какие-то данные)
    public PBFDensityMap densityMap;          // 3D плотность, по которой будем raymarch-ить

    [Header("Shader")]
    [SerializeField] private Shader _shader;  // Шейдер пост-эффекта (raymarch)

    [Header("Raymarch params")]
    public float maxDistance = 50.0f;         // Максимальная длина луча в мире
    
    [Header("Light")]
    public Light sun; // Directional Light из сцены
    public float sunIntensity;

    [Header("Plane")] 
    public Vector3 planeCenter;
    public float planeWidth;
    public float planeHeight;
    public float planeTileWidth;
    public float planeTileHeight;
    public Color planeCol1;
    public Color planeCol2;
    public Color planeCol3;
    public Color planeCol4;
    public float edgeDarkness;
    public float Brightness;
    public float hue;

    [Header("Plane")] 
    public Vector3 spherePosition;
    public float sphereRadius;

    private Camera _cam;
    private Material _raymarchMat;

    /// <summary>
    /// Ленивое кеширование камеры (чтобы не дергать GetComponent каждый кадр).
    /// </summary>
    public Camera Cam
    {
        get
        {
            if (!_cam) _cam = GetComponent<Camera>();
            return _cam;
        }
    }

    /// <summary>
    /// Ленивое создание материала из шейдера.
    /// HideAndDontSave — чтобы не сохранялся в сцену и не "засорял" проект.
    /// </summary>
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

    /// <summary>
    /// Чистим материал при выключении/удалении компонента, чтобы не было утечек.
    /// </summary>
    void OnDisable()
    {
        if (_raymarchMat)
        {
            if (Application.isPlaying) Destroy(_raymarchMat);
            else DestroyImmediate(_raymarchMat);
        }
    }

    /// <summary>
    /// Пост-эффект: Unity вызывает после рендера камеры.
    /// source — картинка, которую камера уже отрендерила.
    /// destination — куда нужно записать итог.
    /// </summary>
    private void OnRenderImage(RenderTexture source, RenderTexture destination)
    {
        // Если чего-то нет — просто копируем исходник без эффекта.
        if (!RaymarchMaterial || sim == null || densityMap == null || densityMap.DensityTexture == null)
        {
            Graphics.Blit(source, destination);
            return;
        }

        // Передаем в материал текстуры/матрицы/параметры, которые нужны шейдеру.
        SetAllParameters(source);

        // Рисуем Fullscreen Quad вручную через GL.
        // Важный трюк: vertex.z используем как "индекс угла" (0..3),
        // чтобы в вершинном шейдере взять нужный вектор из _CamFrustum.
        RenderTexture.active = destination;
        GL.PushMatrix();
        GL.LoadOrtho();               // Переходим в орто 0..1 экранные координаты
        RaymarchMaterial.SetPass(0);  // Активируем первый Pass шейдера

        GL.Begin(GL.QUADS);

        // BL (bottom-left). index = 3
        GL.MultiTexCoord2(0, 0.0f, 0.0f);
        GL.Vertex3(0.0f, 0.0f, 3.0f);

        // BR. index = 2
        GL.MultiTexCoord2(0, 1.0f, 0.0f);
        GL.Vertex3(1.0f, 0.0f, 2.0f);

        // TR. index = 1
        GL.MultiTexCoord2(0, 1.0f, 1.0f);
        GL.Vertex3(1.0f, 1.0f, 1.0f);

        // TL. index = 0
        GL.MultiTexCoord2(0, 0.0f, 1.0f);
        GL.Vertex3(0.0f, 1.0f, 0.0f);

        GL.End();
        GL.PopMatrix();
    }

    /// <summary>
    /// В одном месте задаем все параметры материала:
    /// - "фон" (то, что уже отрендерено камерой)
    /// - матрицы, чтобы в шейдере восстановить мировые лучи
    /// - параметры raymarch-а
    /// </summary>
    private void SetAllParameters(RenderTexture source)
    {
        // Фон/окружение: текущий кадр камеры.
        _raymarchMat.SetTexture("_MainTex", source);

        // ВАЖНО: у шейдера есть _DensityMap, его тоже обычно надо передать:
        _raymarchMat.SetTexture("_DensityMap", densityMap.DensityTexture);

        // Матрица "лучей по углам" (в пространстве камеры).
        _raymarchMat.SetMatrix("_CamFrustum", CamFrustum(Cam));

        // Матрица из camera space в world space — чтобы превратить луч в мировой.
        _raymarchMat.SetMatrix("_CamToWorld", Cam.cameraToWorldMatrix);

        // Параметры марча
        _raymarchMat.SetFloat("_MaxDistance", maxDistance);
        
        // Паарметры освещения
        Vector3 dirToSunWS = -sun.transform.forward;          // world-space
        _raymarchMat.SetVector("dirToSun", new Vector4(dirToSunWS.x, dirToSunWS.y, dirToSunWS.z, 0));
        _raymarchMat.SetFloat("sunIntensity", sunIntensity);
        
        // Параметры пола
        _raymarchMat.SetVector("planeCenter", planeCenter);
        _raymarchMat.SetFloat("planeWidth", planeWidth);
        _raymarchMat.SetFloat("planeHeight", planeHeight);
        _raymarchMat.SetFloat("planeTileWidth", planeTileWidth);
        _raymarchMat.SetFloat("planeTileHeight", planeTileHeight);
        _raymarchMat.SetColor("planeCol1", planeCol1);    
        _raymarchMat.SetColor("planeCol2", planeCol2);    
        _raymarchMat.SetColor("planeCol3", planeCol3);    
        _raymarchMat.SetColor("planeCol4", planeCol4);    
        _raymarchMat.SetFloat("edgeDarkness", edgeDarkness);
        _raymarchMat.SetFloat("Brightness", Brightness);
        _raymarchMat.SetFloat("hue", hue);
        
        // Параметры тестовой сферы
        _raymarchMat.SetVector("spherePosition", spherePosition);
        _raymarchMat.SetFloat("sphereRadius", sphereRadius);
    }

    /// <summary>
    /// Собираем 4 вектора направления на углы frustum-а в camera space:
    /// TL, TR, BR, BL (в таком порядке кладем в строки матрицы).
    ///
    /// Дальше в вершинном шейдере по индексу 0..3 берем нужную строку.
    /// </summary>
    private Matrix4x4 CamFrustum(Camera cam)
    {
        var frustum = Matrix4x4.identity;

        // tan(fov/2) дает "высоту" на расстоянии 1 от камеры (в camera space)
        float fov = Mathf.Tan((cam.fieldOfView * 0.5f) * Mathf.Deg2Rad);

        Vector3 goUp = Vector3.up * fov;
        Vector3 goRight = Vector3.right * fov * cam.aspect;

        // В Unity camera forward — это +Z, но для view space часто используют -forward для направления "в экран".
        // Тут берется -forward, чтобы лучи смотрели вперед из камеры.
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