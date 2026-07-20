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
            static const float iorAir = 1.0;

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

            float4 _BoundsMin;   // xyz
            float4 _BoundsSize;  // xyz

            float _DensityMultiplier;
            float _StepSize;
            float _DensityOffset;

            float4 _ScatteringCoefficients; // xyz used as extinction

            float _BounceDensityStepSize;
            float _IOR;

            float _NormalEps;

            float waterShadowIntensity;

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

            // ----------------- Calculation funstions -----------------

            float2 RayBox(float3 bmin, float3 bmax, float3 ro, float3 rd)
            {
                float3 inv = 1.0 / rd;
                float3 t0 = (bmin - ro) * inv;
                float3 t1 = (bmax - ro) * inv;

                float3 tmin3 = min(t0, t1);
                float3 tmax3 = max(t0, t1);

                float tmin = max(max(tmin3.x, tmin3.y), tmin3.z);
                float tmax = min(min(tmax3.x, tmax3.y), tmax3.z);

                if (tmax < max(tmin, 0.0))
                    return float2(0.0, 0.0);

                float dstToBox = max(tmin, 0.0);
                float dstThroughBox = max(0.0, tmax - dstToBox);
                return float2(dstToBox, dstThroughBox);
            }

            float SampleDensityWorld(float3 pWorld)
            {
                float3 bmin = _BoundsMin.xyz;
                float3 bsize = _BoundsSize.xyz;

                float3 uvw = (pWorld - bmin) / bsize;

                if (any(uvw < 0.0) || any(uvw > 1.0))
                    return 0.0;

                const float eps = 1e-4;
                if (any(uvw <= eps) || any(uvw >= 1.0 - eps))
                    return 0.0;

                return tex3D(_DensityMap, uvw).r;
            }

            float DensityField(float3 pWorld)
            {
                // <0 снаружи, >0 внутри жидкости
                return SampleDensityWorld(pWorld) - _DensityOffset;
            }

            bool IsInsideBounds(float3 pWorld)
            {
                float3 bmin = _BoundsMin.xyz;
                float3 bmax = _BoundsMin.xyz + _BoundsSize.xyz;
                return all(pWorld >= bmin) && all(pWorld <= bmax);
            }

            bool IsInsideFluid(float3 pWorld)
            {
                return IsInsideBounds(pWorld) && (DensityField(pWorld) > 0.0);
            }

            float3 CalculateNormalWorld(float3 pWorld, float3 viewDir)
            {
                float eps = max(_NormalEps, 1e-4);

                float3 bmin = _BoundsMin.xyz;
                float3 bmax = _BoundsMin.xyz + _BoundsSize.xyz;
                pWorld = clamp(pWorld, bmin + eps, bmax - eps);

                float3 ex = float3(eps, 0,   0);
                float3 ey = float3(0,   eps, 0);
                float3 ez = float3(0,   0,   eps);

                float dx = DensityField(pWorld + ex) - DensityField(pWorld - ex);
                float dy = DensityField(pWorld + ey) - DensityField(pWorld - ey);
                float dz = DensityField(pWorld + ez) - DensityField(pWorld - ez);

                float3 grad = float3(dx, dy, dz);
                float len2 = dot(grad, grad);
                float3 n = (len2 > 1e-12) ? (-grad * rsqrt(len2)) : float3(0, 1, 0);

                // faceforward
                if (dot(n, viewDir) > 0) n = -n;
                return n;
            }

            // ----------------- Surface stepping -----------------

            struct SurfaceInfo
            {
                float3 pos;
                float  densityAlongRay;
                bool   foundSurface;
            };

            SurfaceInfo FindNextSurface(float3 origin, float3 rayDir, bool findNextFluidEntryPoint, float maxDst)
            {
                SurfaceInfo info = (SurfaceInfo)0;
                if (dot(rayDir, rayDir) < 0.5) return info;

                float3 bmin = _BoundsMin.xyz;
                float3 bmax = _BoundsMin.xyz + _BoundsSize.xyz;

                float2 hit = RayBox(bmin, bmax, origin, rayDir);
                if (hit.y <= 0.0) return info;

                float dstToBox = hit.x;

                // FIX: maxDst — дистанция от origin по лучу
                float dstThrough = min(hit.y, maxDst - dstToBox);
                if (dstThrough <= 0.0) return info;

                float stepSize = max(_StepSize, 1e-4);

                float t = TinyNudge;
                float tEnd = max(0.0, dstThrough - TinyNudge * 2.0);

                bool hasExittedFluid = !IsInsideFluid(origin);
                bool hasEnteredFluid = false;
                float3 lastPosInFluid = origin + rayDir * (dstToBox + t);

                [loop]
                for (int i = 0; i < 4096; i++)
                {
                    if (t >= tEnd) break;

                    bool isLastStep = (t + stepSize) >= tEnd;
                    float3 samplePos = origin + rayDir * (dstToBox + t);

                    float f = DensityField(samplePos);
                    float dens = max(0.0, f);
                    float thickness = dens * _DensityMultiplier * stepSize;
                    bool insideFluid = thickness > 0.0;

                    if (insideFluid)
                    {
                        hasEnteredFluid = true;
                        lastPosInFluid = samplePos;
                        info.densityAlongRay += thickness;
                    }
                    else
                    {
                        hasExittedFluid = true;
                    }

                    bool found = false;
                    if (findNextFluidEntryPoint)
                    {
                        found = insideFluid && hasExittedFluid;
                    }
                    else
                    {
                        found = hasEnteredFluid && (!insideFluid || isLastStep);
                    }

                    if (found)
                    {
                        info.pos = lastPosInFluid;
                        info.foundSurface = true;
                        return info;
                    }

                    t += stepSize;
                }

                return info;
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

                const float ambient = 0.06;
                col = sphereColor * (ambient + (1.0 - ambient) * ndotl);

                float3 V = normalize(-rd);
                float3 H = normalize(L + V);
                float spec = pow(saturate(dot(N, H)), 64.0) * 0.25;
                col += spec;

                col = saturate(col);
                return true;
            }

            // Возвращает maxDist, ограниченный ближайшим solid (sphere/plane), если он ближе.
            float ClampMaxDistToSolids(float3 ro, float3 rd, float maxDist)
            {
                float tMin = maxDist;

                // sphere (distance only)
                {
                    const float3 sphereCenterWS = spherePosition;
                    const float  R = sphereRadius;
                    float tS;
                    if (RaySphereIntersect(ro, rd, sphereCenterWS, R, tS))
                        tMin = min(tMin, max(0.0, tS - TinyNudge));
                }

                // rect plane (distance only)
                {
                    float tP;
                    float u, v, u01, v01;
                    if (RayRectPlaneIntersect(ro, rd, planeCenter, float3(0.0, 1.0, 0.0), planeWidth, planeHeight,
                                           tP, u, v, u01, v01))
                        tMin = min(tMin, max(0.0, tP - TinyNudge));
                }

                return tMin;
            }

            // ----------------- Calculation funstions -----------------

            float CalculateDensityAlongRay(float3 roWorld, float3 rdWorld, float stepSize)
            {
                if (dot(rdWorld, rdWorld) < 0.9) return 0.0;

                // NEW: ограничиваем луч ближайшим solid, чтобы volume не считался "за" сферой/плоскостью
                float maxRayDist = ClampMaxDistToSolids(roWorld, rdWorld, _MaxDistance);

                float3 bmin = _BoundsMin.xyz;
                float3 bmax = _BoundsMin.xyz + _BoundsSize.xyz;

                float2 hit = RayBox(bmin, bmax, roWorld, rdWorld);
                if (hit.y <= 0.0)
                    return 0.0;

                float step = max(stepSize, 1e-4);

                float dstToBox = hit.x;

                // FIX: max distance по лучу
                float dstThrough = min(hit.y, maxRayDist - dstToBox);
                if (dstThrough <= 0.0)
                    return 0.0;

                float t = TinyNudge;
                float tEnd = max(0.0, dstThrough - TinyNudge * 2.0);

                float accum = 0.0;

                [loop]
                for (int i = 0; i < 1024; i++)
                {
                    if (t >= tEnd) break;

                    float3 p = roWorld + rdWorld * (dstToBox + t);

                    float f = DensityField(p);
                    float dens = max(0.0, f);

                    accum += dens * _DensityMultiplier * step;
                    t += step;
                }

                return accum;
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
                return smoothstep(0.0, s, edge);
            }

            float3 WaterShadowTransmittance(float3 p, float3 dirToSun)
            {
                float3 rd = normalize(dirToSun);

                // пересекаем shadow-ray с AABB объёма (где вообще есть densityMap)
                float3 bmin = _BoundsMin.xyz;
                float3 bmax = _BoundsMin.xyz + _BoundsSize.xyz;

                float2 hit = RayBox(bmin, bmax, p, rd);
                if (hit.y <= 0.0)
                    return 1.0; // луч не проходит через bounds => воды на пути нет

                float tEnter = hit.x;
                float tExit  = hit.x + hit.y;

                float step = max(_BounceDensityStepSize, 1e-4);

                float opticalDepth = 0.0;

                // маленький сдвиг чтобы не словить самопересечения/границу
                float t = tEnter + TinyNudge;

                [loop]
                for (int i = 0; i < 2048; i++)
                {
                    if (t >= tExit) break;

                    float3 x = p + rd * t;

                    // density field уже включает _DensityOffset; берём только "внутри жидкости"
                    float dens = max(0.0, DensityField(x));

                    // накапливаем оптическую толщу
                    opticalDepth += dens * _DensityMultiplier * step;

                    t += step;
                }

                // затухание (ВАЖНО: минус!)
                float3 ext = max(_ScatteringCoefficients.xyz, 0.0);
                return exp(-opticalDepth * ext * waterShadowIntensity);
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
                float sphereHit;
                col *= lerp(0.1, 1.0, SphereSoftShadowApprox(hitPlane, dirToSun, spherePosition, sphereRadius, shadowSoftness));
                if (RaySphereIntersect(hitPlane, dirToSun, spherePosition, sphereRadius, sphereHit))
                {
                    col *= pow(0.99, shadowIntensity);
                }

                // тень от воды
                float3 T = WaterShadowTransmittance(hitPlane, dirToSun);

                // shadowIntensity: 0..1 (0 = без тени, 1 = полная)
                float3 shadowMul = lerp(1.0, T, shadowIntensity);

                // если нужен “пол” (ambient), чтобы не уходить в полный чёрный:
                shadowMul = max(shadowMul, 0.1);

                col *= shadowMul;
                
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

            // ----------------- Physics: Fresnel / reflection / refraction / transmittance ------------------------------

            struct LightResponse
            {
                float3 reflectDir;
                float3 refractDir;
                float  reflectWeight;
                float  refractWeight;
            };
            
            float CalculateReflectance(float3 inDir, float3 normal, float iorA, float iorB)
            {
                float refractRatio = iorA / iorB;
                float cosAngleIn = -dot(inDir, normal);
                float sinSqrAngleOfRefraction = refractRatio * refractRatio * (1.0 - cosAngleIn * cosAngleIn);
                if (sinSqrAngleOfRefraction >= 1.0) return 1.0;

                float cosAngleOfRefraction = sqrt(1.0 - sinSqrAngleOfRefraction);

                float rPerp = (iorA * cosAngleIn - iorB * cosAngleOfRefraction) / (iorA * cosAngleIn + iorB * cosAngleOfRefraction);
                rPerp *= rPerp;

                float rPar = (iorB * cosAngleIn - iorA * cosAngleOfRefraction) / (iorB * cosAngleIn + iorA * cosAngleOfRefraction);
                rPar *= rPar;

                return (rPerp + rPar) * 0.5;
            }

            float3 ReflectDir(float3 inDir, float3 normal)
            {
                return inDir - 2.0 * dot(inDir, normal) * normal;
            }

            float3 RefractDir(float3 inDir, float3 normal, float iorA, float iorB)
            {
                float refractRatio = iorA / iorB;
                float cosAngleIn = -dot(inDir, normal);
                float sinSqrAngleOfRefraction = refractRatio * refractRatio * (1.0 - cosAngleIn * cosAngleIn);
                if (sinSqrAngleOfRefraction > 1.0) return float3(0,0,0);

                return refractRatio * inDir + (refractRatio * cosAngleIn - sqrt(1.0 - sinSqrAngleOfRefraction)) * normal;
            }

            LightResponse CalculateReflectionAndRefraction(float3 inDir, float3 normal, float iorA, float iorB)
            {
                LightResponse r;
                r.reflectWeight = CalculateReflectance(inDir, normal, iorA, iorB);
                r.refractWeight = 1.0 - r.reflectWeight;
                r.reflectDir = normalize(ReflectDir(inDir, normal));
                r.refractDir = normalize(RefractDir(inDir, normal, iorA, iorB));
                return r;
            }

            float3 Transmittance(float opticalDepth)
            {
                float3 ext = max(_ScatteringCoefficients.xyz, 0.0);
                return exp(-opticalDepth * ext);
            }

            // ----------------- RaymarchFLuid -----------------

            float3 RaymarchFluid(float3 ro, float3 rd)
            {
                bool travellingThroughFluid = IsInsideFluid(ro);
                
                float3 col = 0.0;

                bool searchForNextEntry = !travellingThroughFluid;

                // NEW: ограничиваем поиск поверхности жидкость/воздух ближайшими solid'ами
                float maxDstThisRay = ClampMaxDistToSolids(ro, rd, _MaxDistance);

                SurfaceInfo s = FindNextSurface(ro, rd, searchForNextEntry, maxDstThisRay);
                
                if (s.foundSurface)
                {
                    float3 n = CalculateNormalWorld(s.pos, rd);

                    float iorA = travellingThroughFluid ? _IOR : iorAir;
                    float iorB = travellingThroughFluid ? iorAir : _IOR;

                    LightResponse lr = CalculateReflectionAndRefraction(rd, n, iorA, iorB);

                    float densityStep = max(_BounceDensityStepSize, 1e-4);

                    float dRefr = CalculateDensityAlongRay(s.pos + lr.refractDir * TinyNudge, lr.refractDir, densityStep);
                    float dRefl = CalculateDensityAlongRay(s.pos + lr.reflectDir * TinyNudge, lr.reflectDir, densityStep);

                    bool traceRefr = (dRefr * lr.refractWeight) > (dRefl * lr.reflectWeight);

                    // NEW: LightWithEnv берём из той же точки, что и dRefr/dRefl (с нуджем)
                    if (traceRefr)
                        col += LightWithEnv(lr.refractDir, s.pos + lr.refractDir * TinyNudge) * Transmittance(dRefr) * lr.refractWeight;
                    else
                        col += LightWithEnv(lr.reflectDir, s.pos + lr.reflectDir * TinyNudge) * Transmittance(dRefl) * lr.reflectWeight;

                    float3 nextDir = traceRefr ? lr.refractDir : lr.reflectDir;

                    ro = s.pos + nextDir * TinyNudge;
                    rd = nextDir;
                }
                
                float dRem = CalculateDensityAlongRay(ro, rd, max(_BounceDensityStepSize, 1e-4));
                col += LightWithEnv(rd, ro + rd * TinyNudge) * Transmittance(dRem);
                
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
