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

            float3 planeCenter;
            float planeWidth;
            float planeHeight;
            float planeTileWidth;
            float planeTileHeight;
            float3 planeCol1;
            float3 planeCol2;
            float3 planeCol3;
            float3 planeCol4;
            float edgeDarkness;
            float Brightness;
            float hue;

            float sphereRadius;
            float3 spherePosition;

            float shadowSoftness;
            float shadowIntensity;

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

            // ----------------- Helper tile functions -----------------

            float Hash12(float2 p)
            {
                return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453123);
            }

            float3 HueShiftYIQ(float3 rgb, float angle)
            {
                const float3 toY  = float3(0.299, 0.587, 0.114);
                const float3 toI  = float3(0.596, -0.274, -0.322);
                const float3 toQ  = float3(0.211, -0.523, 0.312);

                float  Y = dot(rgb, toY);
                float  I = dot(rgb, toI);
                float  Q = dot(rgb, toQ);

                float ca = cos(angle);
                float sa = sin(angle);

                float I2 = I * ca - Q * sa;
                float Q2 = I * sa + Q * ca;

                float3 outRgb;
                outRgb.r = Y + 0.956 * I2 + 0.621 * Q2;
                outRgb.g = Y - 0.272 * I2 - 0.647 * Q2;
                outRgb.b = Y - 1.107 * I2 + 1.705 * Q2;
                return outRgb;
            }

            // ----------------- Obstale tracing + their color and shading -----------------
            float ObstacleUnion(float d1, float d2)
            {
                return min(d1, d2);
            }

            // 1) Чистая геометрия: пересечение луча с прямоугольником на плоскости.
            // Возвращает true/false + tHit и локальные координаты на плоскости (u,v) и (u01,v01).
            // u,v   : координаты относительно center (в системе осей uAxis/vAxis), ноль в центре
            // u01,v01: сдвинутые в диапазон [0..a] / [0..b] (удобно для тайлинга)
            bool RayRectPlaneIntersect(
                float3 ro, float3 rd,
                float3 planeCenterWS, float3 n,
                float  a, float  b,
                out float tHit,
                out float u, out float v,
                out float u01, out float v01)
            {
                tHit = 0;
                u = v = 0;
                u01 = v01 = 0;

                const float3 uAxis = float3(1.0, 0.0, 0.0);
                const float3 vAxis = float3(0.0, 0.0, 1.0);

                // 1) пересечение луча с плоскостью
                float denom = dot(n, rd);
                if (abs(denom) < 1e-6) return false;          // почти параллельно плоскости

                float t = dot(n, (planeCenterWS - ro)) / denom;
                if (t <= 0.0) return false;                   // направление луча вверх, а плоскость внизу или наоборот

                float3 hitWS = ro + rd * t;

                // 2) перевод попадания в координаты прямоугольника (u/v)
                float3 d = hitWS - planeCenterWS;
                u = dot(d, uAxis);
                v = dot(d, vAxis);

                // 3) проверка попадания внутрь прямоугольника размеров a x b
                if (abs(u) > a * 0.5 || abs(v) > b * 0.5)
                    return false;

                // 4) координаты в "положительном" диапазоне (0..a, 0..b)
                u01 = u + a * 0.5;
                v01 = v + b * 0.5;

                tHit = t;
                return true;
            }

            bool RaySphereIntersect(float3 ro, float3 rd, float3 center, float R, out float tHit)
            {
                float3 oc = ro - center;
                float b = dot(oc, rd);
                float c = dot(oc, oc) - R * R;
                float h = b * b - c;
                if (h < 0.0) { tHit = 0.0; return false; }

                float s = sqrt(h);
                float t = -b - s;
                if (t <= 0.0) t = -b + s;

                tHit = t;
                return t > 0.0;
            }

            // Sphere: hit + shaded color + t
            bool testSphere(float3 ro, float3 rd, out float tHit, out float3 col)
            {
                // ---- hardcode: параметры сферы ----
                const float3 sphereCenterWS = spherePosition;
                const float  R = sphereRadius;
                const float3 sphereColor = float3(1.0, 0.25, 0.25);

                col = 0;
                if (!RaySphereIntersect(ro, rd, sphereCenterWS, R, tHit)) return false;

                float3 hitWS = ro + rd * tHit;

                float3 N = normalize(hitWS - sphereCenterWS);
                if (dot(N, rd) > 0.0) N = -N;

                float3 L = normalize(dirToSun);
                float ndotl = saturate(dot(N, L));

                const float ambient = 0.18;
                col = sphereColor * (ambient + (1.0 - ambient) * ndotl);

                float3 V = normalize(-rd);
                float3 H = normalize(L + V);
                float spec = pow(saturate(dot(N, H)), 64.0) * 0.25;
                col += spec;

                col = saturate(col);
                return true;
            }

            // visibility: 1 = светло, 0 = тень
            float SphereSoftShadowApprox(float3 pos, float3 dirToSun, float3 center, float R, float softnessWS)
            {
                float3 rd = normalize(dirToSun);

                // сфера должна быть "впереди" по направлению к солнцу
                if (dot(center - pos, rd) <= 0.0)
                    return 1.0;

                float3 oc = pos - center;

                // параметр ближайшей точки на луче до центра (со знаком, но для расстояния достаточно b)
                float b = dot(oc, rd);

                // min distance^2 от центра до прямой луча
                float d2 = dot(oc, oc) - b * b;
                d2 = max(d2, 0.0);
                float d = sqrt(d2);

                // edge < 0  => луч проходит "внутри" сферы (умбра)
                // edge ~ 0  => касание (граница тени)
                float edge = d - R * 0.7;

                float s = max(softnessWS, 1e-6);

                // 0 в тени, 1 на свету, плавный переход в зоне [0..s] за границей
                return shadowIntensity * smoothstep(0.0, s, edge);
            }

            // 2) Обертка "plane rect: color + hitInfo":
            // - задает (или принимает извне) параметры плоскости/прямоугольника
            // - вызывает чистую геометрию (RayRectPlaneIntersect)
            // - если есть хит, рассчитывает процедурный цвет (checker + квадранты + линии)
            bool Floor(float3 ro, float3 rd, out float tHit, out float3 col)
            {
                // ----- hardcode: параметры плоскости -----
                const float3 planeCenterWS = planeCenter;
                const float3 n = float3(0.0, 1.0, 0.0);

                const float a = planeWidth;
                const float b = planeHeight;

                const float tileA = planeTileWidth;
                const float tileB = planeTileHeight;

                // 4 базовых цвета
                const float3 colBL = planeCol1;
                const float3 colBR = planeCol2;
                const float3 colTL = planeCol3;
                const float3 colTR = planeCol4;

                col = 0;
                tHit = 0;

                // Сначала — только геометрия (есть/нет пересечения и где именно попали)
                float u, v, u01, v01;
                if (!RayRectPlaneIntersect(ro, rd, planeCenterWS, n, a, b,
                                           tHit, u, v, u01, v01))
                    return false;

                // Дальше — только раскраска (зависит от u/v/u01/v01)
                float qx = step(a * 0.5, u01);
                float qy = step(b * 0.5, v01);

                float3 bottom  = lerp(colBL, colBR, qx);
                float3 top     = lerp(colTL, colTR, qx);
                float3 baseCol = lerp(bottom, top, qy);

                float cellU = floor(u01 / tileA);
                float cellV = floor(v01 / tileB);

                // рандом на тайл
                float2 cellId = float2(cellU, cellV);
                float r1 = Hash12(cellId + 13.37);
                float r2 = Hash12(cellId + 91.11);

                float brightness = lerp(Brightness, 1.06, r1);
                float hueAngle   = (r2 - 0.5) * hue;

                float3 variedBase = HueShiftYIQ(baseCol, hueAngle);
                variedBase *= brightness;
                variedBase = saturate(variedBase);

                // checker (через четность клетки)
                float check = fmod(cellU + cellV, 2.0);

                float3 cDark  = variedBase * 0.68;
                float3 cLight = saturate(variedBase * 1.10 + 0.03);
                float3 c      = lerp(cLight, cDark, check);

                // линии сетки
                float fu = frac(u01 / tileA);
                float fv = frac(v01 / tileB);
                float edge = min(min(fu, 1.0 - fu), min(fv, 1.0 - fv));

                const float gridWidth = 0.045;
                float lineMask = 1.0 - smoothstep(0.0, gridWidth, edge);
                c = lerp(c, saturate(c + 0.10), lineMask * 0.65);

                // разделители квадрантов (по u=0 и v=0)
                const float seamW = 0.035;
                float seamU = 1.0 - smoothstep(0.0, seamW, abs(u));
                float seamV = 1.0 - smoothstep(0.0, seamW, abs(v));
                float seam  = max(seamU, seamV);
                c = lerp(c, float3(0.95, 0.95, 0.95), seam * 0.75);

                // затемнение к краям прямоугольника
                float edgeU = (a * 0.5 - abs(u));
                float edgeV = (b * 0.5 - abs(v));
                float edgeMin = min(edgeU, edgeV);
                float edgeFade = smoothstep(0.0, 0.35, edgeMin);
                c *= lerp(edgeDarkness, 1.0, edgeFade);

                col = saturate(c);
                
                //тень тестовой сферы
                float3 hitPlane = ro + rd * tHit;
                col *= lerp(0.15, 1.0, SphereSoftShadowApprox(hitPlane, dirToSun, spherePosition, sphereRadius, shadowSoftness));
                
                return true;
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
                float nearestDistance = 1e20;
                float3 nearestColor = 0;
                bool hit = false;

                // test sphere
                float dist; float3 col;
                if (testSphere(ro, rd, dist, col) && ObstacleUnion(dist, nearestDistance) < nearestDistance)
                {
                    nearestDistance = dist; nearestColor = col; hit = true;
                }

                // floor
                if (Floor(ro, rd, dist, col) && ObstacleUnion(dist, nearestDistance) < nearestDistance)
                {
                    nearestDistance = dist; nearestColor = col; hit = true;
                }

                if (hit) return nearestColor;
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
