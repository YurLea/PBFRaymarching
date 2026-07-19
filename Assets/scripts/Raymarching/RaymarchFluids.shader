Shader "Custom/PBF/RaymarchFluid"
{
    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}          // Фон (цвет из камеры)
        _DensityMap ("Density Map (3D)", 3D) = "" {}   // 3D текстура плотности (объем)
    }

    SubShader
    {
        // Для пост-эффекта:
        Cull Off       // двусторонний (нам не важны "фейсы" квадрата)
        ZWrite Off     // не пишем глубину
        ZTest Always   // рисуем всегда поверх

        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 3.0

            #include "UnityCG.cginc"

            // Входные ресурсы
            sampler2D _MainTex;
            float4 _MainTex_TexelSize; // иногда полезно для пост-эффектов (шаг пикселя), пока не используется

            sampler3D _DensityMap;     // 3D volume, по нему обычно марчат

            // Матрицы для реконструкции лучей
            float4x4 _CamFrustum;      // 4 направления на углы frustum-а (в camera space), лежат по строкам
            float4x4 _CamToWorld;      // camera space -> world space

            float _MaxDistance;        // максимальная дальность марча
            static const float TinyNudge = 1e-3;

            float3 dirToSun;
            float sunIntensity;

            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv     : TEXCOORD0;
            };

            struct v2f
            {
                float2 uv  : TEXCOORD0;
                float4 pos : SV_POSITION;

                // "Сырой" луч, который прокинем во фрагментный шейдер
                float3 ray : TEXCOORD1;
            };

            v2f vert(appdata v)
            {
                v2f o;

                // Мы запихнули индекс угла (0..3) в vertex.z на CPU (через GL.Vertex3(..., z=index))
                half index = v.vertex.z;

                // z обнуляем, чтобы quad реально был плоским в clip space
                v.vertex.z = 0;

                // Стандартная трансформация вершины (мы рисуем ortho quad)
                o.pos = UnityObjectToClipPos(v.vertex);
                o.uv = v.uv;

                // Берем направление на нужный угол frustum-а (camera space)
                o.ray = _CamFrustum[(int)index].xyz;

                // Нормализация по z:
                // приводим лучи к "глубине 1", чтобы интерполяция по экрану была корректной
                o.ray /= abs(o.ray.z);

                // Переводим направление из camera space в world space
                // (по смыслу это вектор, но тут mul с матрицей — распространенный прием в таких шейдерах)
                o.ray = mul(_CamToWorld, o.ray);

                return o;
            }

            // ----------------- Sky + LightWithEnv -----------------

            float3 SampleSky(float3 dir)
            {
                const float3 colGround = float3(0.35, 0.3, 0.35) * 0.53;
                const float3 colSkyHorizon = float3(1, 1, 1);
                const float3 colSkyZenith = float3(0.08, 0.37, 0.73);

                float sun = pow(max(0.0, dot(dir, dirToSun)), 500.0) * sunIntensity;
                float skyGradientT = pow(smoothstep(0.0, 0.4, dir.y), 0.35);
                float groundToSkyT = smoothstep(-0.01, 0.0, dir.y);
                float3 skyGradient = lerp(colSkyHorizon, colSkyZenith, skyGradientT);

                return lerp(colGround, skyGradient, groundToSkyT) + sun * (groundToSkyT >= 1.0);
            }

            float3 LightWithEnv(float3 rd, float3 ro)
            {
                return SampleSky(rd);
            }

            // ----------------- RaymarchFLuid -----------------

            float3 RaymarchFluid(float3 ro, float3 rd)
            {
                float3 col = 0;
                col += LightWithEnv(rd, ro + rd * TinyNudge);

                return col;
            }

            fixed4 frag(v2f i) : SV_Target
            {
                // Ray Origin (мировая позиция камеры)
                float3 ro = _WorldSpaceCameraPos;

                // Ray Direction (нормализуем интерполированный луч)
                float3 rd = normalize(i.ray);

                // Сейчас шейдер просто красит картинку направлением луча (для отладки).
                // Здесь дальше обычно делается raymarch:
                //  - идем по t от 0 до _MaxDistance
                //  - в точке p = ro + rd*t семплим _DensityMap (нужно привести p в UVW volume'а)
                //  - накапливаем плотность/цвет/прозрачность (front-to-back)
                //  - смешиваем с _MainTex как фоном
                float3 col = RaymarchFluid(ro, rd);
                return fixed4(saturate(col), 1.0);
            }
            ENDCG
        }
    }
}
