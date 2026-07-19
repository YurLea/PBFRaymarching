Shader "PeerPlay/PBF/RaymarchLikeFluid_Debug"
{
    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}
        _DensityMap ("Density Map (3D)", 3D) = "" {}

        _ScatteringCoefficients ("Extinction Coefficients (RGB)", Vector) = (1,1,1,0)
        _NormalEps ("Normal Epsilon (World units)", Float) = 0.005

        _IOR ("Index Of Refraction", Float) = 1.333

        _NumBounces ("Num Bounces (boundary events)", Range(1,8)) = 1
        _BounceDensityStepSize ("Bounce Density Step Size", Float) = 0.15
        
        _Radius ("Sphere Radius", Float) = 0.95
        _Position ("Sphere Pos", Vector) = (-3.0, 2.2, 3.0)
    }

    SubShader
    {
        Cull Off ZWrite Off ZTest Always

        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 3.0

            #include "UnityCG.cginc"

            sampler2D _MainTex;
            float4 _MainTex_TexelSize;

            sampler3D _DensityMap;

            float4x4 _CamFrustum;
            float4x4 _CamToWorld;

            float4 _BoundsMin;   // xyz
            float4 _BoundsSize;  // xyz
            float3 dirToSun;

            float _MaxDistance;
            float _DensityOffset;
            float _DensityMultiplier;
            float _StepSize;

            float4 _ScatteringCoefficients; // xyz used as extinction
            float _NormalEps;

            float _IOR;
            float _NumBounces;
            float _BounceDensityStepSize;

            static const float TinyNudge = 1e-3;
            static const float iorAir = 1.0;

            float _Radius;
            float3 _Position;

            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv     : TEXCOORD0;
            };

            struct v2f
            {
                float2 uv    : TEXCOORD0;
                float4 pos   : SV_POSITION;
                float3 rayWS : TEXCOORD1;
            };

            v2f vert(appdata v)
            {
                v2f o;

                half index = v.vertex.z;
                v.vertex.z = 0;

                o.pos = UnityObjectToClipPos(v.vertex);
                o.uv = v.uv;

                float3 rayVS = _CamFrustum[(int)index].xyz;
                rayVS /= max(1e-6, abs(rayVS.z));
                o.rayWS = mul(_CamToWorld, float4(rayVS, 0.0)).xyz;

                return o;
            }

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

            // ----------------- helpers (шахматка) -----------------

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

            // ----------------- Scene solids: Sphere + RectPlane -----------------

            // distance (SDF) до сферы (не обязателен, но оставляю по просьбе)
            float SphereDistance(float3 pWS, float3 centerWS, float R)
            {
                return length(pWS - centerWS) - R;
            }

            bool RaySphereHit(float3 ro, float3 rd, float3 center, float R, out float tHit)
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
            bool RayLitSphereHit(float3 ro, float3 rd, out float tHit, out float3 col)
            {
                // ---- hardcode: параметры сферы ----
                const float3 sphereCenterWS = _Position;
                const float  R = _Radius;
                const float3 sphereColor = float3(1.0, 0.25, 0.25);

                col = 0;
                if (!RaySphereHit(ro, rd, sphereCenterWS, R, tHit)) return false;

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

            // Plane rect: только t (для клипа трассировки)
            bool RayRectPlaneTHit(float3 posWS, float3 dirWS, out float tHit)
            {
                // ----- hardcode: параметры плоскости -----
                const float3 planeCenterWS = float3(10.0, -0.05, 5.0);
                const float3 n = float3(0.0, 1.0, 0.0);

                const float3 uAxis = float3(1.0, 0.0, 0.0);
                const float3 vAxis = float3(0.0, 0.0, 1.0);

                const float a = 30.0;
                const float b = 20.0;

                float3 rd = normalize(dirWS);
                float denom = dot(n, rd);
                if (abs(denom) < 1e-6) { tHit = 0; return false; }

                float t = dot(n, (planeCenterWS - posWS)) / denom;
                if (t <= 0.0) { tHit = 0; return false; }

                float3 hitWS = posWS + rd * t;

                float3 d = hitWS - planeCenterWS;
                float u = dot(d, uAxis);
                float v = dot(d, vAxis);

                if (abs(u) > a * 0.5 || abs(v) > b * 0.5) { tHit = 0; return false; }

                tHit = t;
                return true;
            }

            // Plane rect: color + t
            bool RayRectCheckerPlaneHit(float3 posWS, float3 dirWS, out float tHit, out float3 col)
            {
                // ----- hardcode: параметры плоскости -----
                const float3 planeCenterWS = float3(10.0, -0.05, 5.0);
                const float3 n = float3(0.0, 1.0, 0.0);

                const float3 uAxis = float3(1.0, 0.0, 0.0);
                const float3 vAxis = float3(0.0, 0.0, 1.0);

                const float a = 30.0;
                const float b = 20.0;

                const float tileA = 0.5;
                const float tileB = 0.5;

                // 4 базовых цвета
                const float3 colBL = float3(0.55, 0.86, 0.78);
                const float3 colBR = float3(0.90, 0.80, 0.54);
                const float3 colTL = float3(0.93, 0.62, 0.62);
                const float3 colTR = float3(0.62, 0.55, 0.92);

                col = 0;
                tHit = 0;

                float3 rd = normalize(dirWS);
                float denom = dot(n, rd);
                if (abs(denom) < 1e-6) return false;

                float t = dot(n, (planeCenterWS - posWS)) / denom;
                if (t <= 0.0) return false;

                float3 hitWS = posWS + rd * t;

                float3 d = hitWS - planeCenterWS;
                float u = dot(d, uAxis);
                float v = dot(d, vAxis);

                if (abs(u) > a * 0.5 || abs(v) > b * 0.5)
                    return false;

                float u01 = u + a * 0.5;
                float v01 = v + b * 0.5;

                // квадранты
                float qx = step(a * 0.5, u01);
                float qy = step(b * 0.5, v01);

                float3 bottom = lerp(colBL, colBR, qx);
                float3 top    = lerp(colTL, colTR, qx);
                float3 baseCol = lerp(bottom, top, qy);

                float cellU = floor(u01 / tileA);
                float cellV = floor(v01 / tileB);

                // рандом на тайл
                float2 cellId = float2(cellU, cellV);
                float r1 = Hash12(cellId + 13.37);
                float r2 = Hash12(cellId + 91.11);

                float brightness = lerp(0.66, 1.06, r1);
                float hueAngle = (r2 - 0.5) * 0.62;

                float3 variedBase = HueShiftYIQ(baseCol, hueAngle);
                variedBase *= brightness;
                variedBase = saturate(variedBase);

                float check = fmod(cellU + cellV, 2.0);

                float3 cDark  = variedBase * 0.68;
                float3 cLight = saturate(variedBase * 1.10 + 0.03);
                float3 c = lerp(cLight, cDark, check);

                // линии сетки
                float fu = frac(u01 / tileA);
                float fv = frac(v01 / tileB);
                float edge = min(min(fu, 1.0 - fu), min(fv, 1.0 - fv));

                const float gridWidth = 0.045;
                float lineMask = 1.0 - smoothstep(0.0, gridWidth, edge);
                c = lerp(c, saturate(c + 0.10), lineMask * 0.65);

                // разделители квадрантов
                const float seamW = 0.035;
                float seamU = 1.0 - smoothstep(0.0, seamW, abs(u));
                float seamV = 1.0 - smoothstep(0.0, seamW, abs(v));
                float seam = max(seamU, seamV);
                c = lerp(c, float3(0.95, 0.95, 0.95), seam * 0.75);

                // затемнение к краям
                float edgeU = (a * 0.5 - abs(u));
                float edgeV = (b * 0.5 - abs(v));
                float edgeMin = min(edgeU, edgeV);
                float edgeFade = smoothstep(0.0, 0.35, edgeMin);
                c *= lerp(0.75, 1.0, edgeFade);

                tHit = t;
                col = saturate(c);
                return true;
            }

            // Возвращает maxDist, ограниченный ближайшим solid (sphere/plane), если он ближе.
            float ClampMaxDistToSolids(float3 ro, float3 rd, float maxDist)
            {
                float tMin = maxDist;

                // sphere (distance only)
                {
                    const float3 sphereCenterWS = _Position;
                    const float  R = _Radius;
                    float tS;
                    if (RaySphereHit(ro, rd, sphereCenterWS, R, tS))
                        tMin = min(tMin, max(0.0, tS - TinyNudge));
                }

                // rect plane (distance only)
                {
                    float tP;
                    if (RayRectPlaneTHit(ro, rd, tP))
                        tMin = min(tMin, max(0.0, tP - TinyNudge));
                }

                return tMin;
            }

            // ----------------- optical depth along ray inside bounds -----------------

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

            float3 Transmittance(float opticalDepth)
            {
                float3 ext = max(_ScatteringCoefficients.xyz, 0.0);
                return exp(-opticalDepth * ext);
            }

            // ----------------- Fresnel / reflection / refraction -----------------

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

            struct LightResponse
            {
                float3 reflectDir;
                float3 refractDir;
                float  reflectWeight;
                float  refractWeight;
            };

            LightResponse CalculateReflectionAndRefraction(float3 inDir, float3 normal, float iorA, float iorB)
            {
                LightResponse r;
                r.reflectWeight = CalculateReflectance(inDir, normal, iorA, iorB);
                r.refractWeight = 1.0 - r.reflectWeight;
                r.reflectDir = normalize(ReflectDir(inDir, normal));
                r.refractDir = normalize(RefractDir(inDir, normal, iorA, iorB));
                return r;
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

            // ----------------- Sky + LightWithEnv -----------------

            float3 SampleSky(float3 dir)
            {
                const float3 colGround = float3(0.35, 0.3, 0.35) * 0.53;
                const float3 colSkyHorizon = float3(1, 1, 1);
                const float3 colSkyZenith = float3(0.08, 0.37, 0.73);

                float sun = pow(max(0.0, dot(dir, dirToSun)), 500.0) * 1.0;
                float skyGradientT = pow(smoothstep(0.0, 0.4, dir.y), 0.35);
                float groundToSkyT = smoothstep(-0.01, 0.0, dir.y);
                float3 skyGradient = lerp(colSkyHorizon, colSkyZenith, skyGradientT);

                return lerp(colGround, skyGradient, groundToSkyT) + sun * (groundToSkyT >= 1.0);
            }

            // NEW: выбираем ближайший объект (sphere/plane) по t
            float3 LightWithEnv(float3 dirWS, float3 posWS)
            {
                float3 rd = normalize(dirWS);

                float tBest = 1e20;
                float3 cBest = 0;
                bool hit = false;

                // sphere
                {
                    float tS; float3 cS;
                    if (RayLitSphereHit(posWS, rd, tS, cS) && tS < tBest)
                    {
                        tBest = tS; cBest = cS; hit = true;
                    }
                }

                // plane
                {
                    float tP; float3 cP;
                    if (RayRectCheckerPlaneHit(posWS, rd, tP, cP) && tP < tBest)
                    {
                        tBest = tP; cBest = cP; hit = true;
                    }
                }

                if (hit) return cBest;
                return SampleSky(rd);
            }

            // ----------------- Trace -----------------

            float3 TraceLikeFluid(float3 ro, float3 rd)
            {
                bool travellingThroughFluid = IsInsideFluid(ro);

                float3 T = 1.0;
                float3 col = 0.0;

                int bounces = (int)round(_NumBounces);
                bounces = clamp(bounces, 1, 16);

                [loop]
                for (int i = 0; i < 16; i++)
                {
                    if (i >= bounces) break;

                    bool searchForNextEntry = !travellingThroughFluid;

                    // NEW: ограничиваем поиск поверхности жидкость/воздух ближайшими solid'ами
                    float maxDstThisRay = ClampMaxDistToSolids(ro, rd, _MaxDistance);

                    SurfaceInfo s = FindNextSurface(ro, rd, searchForNextEntry, maxDstThisRay);
                    if (!s.foundSurface) break;

                    T *= Transmittance(s.densityAlongRay);

                    float3 n = CalculateNormalWorld(s.pos, rd);

                    float iorA = travellingThroughFluid ? _IOR : iorAir;
                    float iorB = travellingThroughFluid ? iorAir : _IOR;

                    LightResponse lr = CalculateReflectionAndRefraction(rd, n, iorA, iorB);

                    float densityStep = max(_BounceDensityStepSize * (i + 1), 1e-4);

                    float dRefr = CalculateDensityAlongRay(s.pos + lr.refractDir * TinyNudge, lr.refractDir, densityStep);
                    float dRefl = CalculateDensityAlongRay(s.pos + lr.reflectDir * TinyNudge, lr.reflectDir, densityStep);

                    bool traceRefr = (dRefr * lr.refractWeight) > (dRefl * lr.reflectWeight);

                    // NEW: LightWithEnv берём из той же точки, что и dRefr/dRefl (с нуджем)
                    if (traceRefr)
                        col += LightWithEnv(lr.reflectDir, s.pos + lr.reflectDir * TinyNudge) * T * Transmittance(dRefl) * lr.reflectWeight;
                    else
                        col += LightWithEnv(lr.refractDir, s.pos + lr.refractDir * TinyNudge) * T * Transmittance(dRefr) * lr.refractWeight;

                    float3 nextDir = traceRefr ? lr.refractDir : lr.reflectDir;
                    float  nextW   = traceRefr ? lr.refractWeight : lr.reflectWeight;

                    ro = s.pos + nextDir * TinyNudge;
                    rd = nextDir;
                    T *= nextW;

                    if (traceRefr) travellingThroughFluid = !travellingThroughFluid;

                    if (max(T.x, max(T.y, T.z)) < 1e-4) break;
                }

                float dRem = CalculateDensityAlongRay(ro, rd, max(_BounceDensityStepSize, 1e-4));
                col += LightWithEnv(rd, ro + rd * TinyNudge) * T * Transmittance(dRem);

                return col;
            }

            fixed4 frag(v2f i) : SV_Target
            {
                float3 ro = _WorldSpaceCameraPos;
                float3 rd = normalize(i.rayWS);

                float3 col = TraceLikeFluid(ro, rd);
                return fixed4(saturate(col), 1.0);
            }

            ENDCG
        }
    }
}