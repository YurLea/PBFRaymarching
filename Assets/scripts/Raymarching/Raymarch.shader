Shader "PeerPlay/PBF/RaymarchLikeFluid_NoEnv"
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

                // вне bounds считаем нулевую плотность
                if (any(uvw < 0.0) || any(uvw > 1.0))
                    return 0.0;

                // можно слегка “убить” края, как во 2-м шейдере, чтобы не ловить артефакты
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

            // optical depth along ray inside bounds (как во 2-м шейдере)
            float CalculateDensityAlongRay(float3 roWorld, float3 rdWorld, float stepSize)
            {
                if (dot(rdWorld, rdWorld) < 0.9) return 0.0;

                float3 bmin = _BoundsMin.xyz;
                float3 bmax = _BoundsMin.xyz + _BoundsSize.xyz;

                float2 hit = RayBox(bmin, bmax, roWorld, rdWorld);
                if (hit.y <= 0.0)
                    return 0.0;

                float step = max(stepSize, 1e-4);

                float dstToBox = hit.x;
                float dstThrough = min(hit.y, _MaxDistance);

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
                float3 ext = max(_ScatteringCoefficients.xyz, 0.0); // используем как extinctionCoeff
                return exp(-opticalDepth * ext);
            }

            // -------- Fresnel / reflection / refraction (как во 2-м шейдере) --------

            float CalculateReflectance(float3 inDir, float3 normal, float iorA, float iorB)
            {
                float refractRatio = iorA / iorB;
                float cosAngleIn = -dot(inDir, normal);
                float sinSqrAngleOfRefraction = refractRatio * refractRatio * (1.0 - cosAngleIn * cosAngleIn);
                if (sinSqrAngleOfRefraction >= 1.0) return 1.0; // TIR

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
                if (sinSqrAngleOfRefraction > 1.0) return float3(0,0,0); // TIR

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
                r.refractDir = normalize(RefractDir(inDir, normal, iorA, iorB)); // может стать (0,0,0) при TIR
                return r;
            }

            // -------- Surface stepping (FindNextSurface как во 2-м шейдере) --------

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
                float dstThrough = min(hit.y, maxDst);

                float stepSize = max(_StepSize, 1e-4);

                // стартуем чуть внутри bounds
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
                        // ищем вход: снаружи -> внутри
                        found = insideFluid && hasExittedFluid;
                    }
                    else
                    {
                        // ищем выход: внутри -> снаружи (или конец)
                        found = hasEnteredFluid && (!insideFluid || isLastStep);
                    }

                    if (found)
                    {
                        info.pos = lastPosInFluid;   // точка внутри, рядом с поверхностью
                        info.foundSurface = true;
                        return info;
                    }

                    t += stepSize;
                }

                return info;
            }

            // -------- "No environment": sample _MainTex by ray direction --------
            float2 UVFromWorldDir(float3 dirWS)
            {
                float3 dirVS = mul(UNITY_MATRIX_V, float4(dirWS, 0)).xyz;

                // за камерой - невалидно
                if (-dirVS.z < 1e-5)
                    return float2(0.5, 0.5);

                // приводим к плоскости z=-1, чтобы стабильнее проектировалось
                float t = 1.0 / max(1e-5, -dirVS.z);
                float3 pVS = dirVS * t; // z = -1

                float4 clip = mul(UNITY_MATRIX_P, float4(pVS, 1));
                float2 uv = clip.xy / max(1e-5, clip.w) * 0.5 + 0.5;
                return uv;
            }

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

            float3 LightNoEnv(float3 dirWS)
            {
                //float2 uv = UVFromWorldDir(dirWS);
                //uv = clamp(uv, 0.001, 0.999);
                //return tex2D(_MainTex, uv).rgb;
                return SampleSky(dirWS);
            }

            float3 TraceLikeFluid(float3 ro, float3 rd)
            {
                bool travellingThroughFluid = IsInsideFluid(ro);

                float3 T = 1.0;     // accumulated transmittance
                float3 col = 0.0;   // accumulated light

                int bounces = (int)round(_NumBounces);
                bounces = clamp(bounces, 1, 16);

                [loop]
                for (int i = 0; i < 16; i++)
                {
                    if (i >= bounces) break;

                    bool searchForNextEntry = !travellingThroughFluid;

                    SurfaceInfo s = FindNextSurface(ro, rd, searchForNextEntry, _MaxDistance);
                    if (!s.foundSurface) break;

                    // поглощение до поверхности
                    T *= Transmittance(s.densityAlongRay);

                    float3 n = CalculateNormalWorld(s.pos, rd);

                    // IOR
                    float iorA = travellingThroughFluid ? _IOR : iorAir;
                    float iorB = travellingThroughFluid ? iorAir : _IOR;

                    LightResponse lr = CalculateReflectionAndRefraction(rd, n, iorA, iorB);

                    float densityStep = max(_BounceDensityStepSize * (i + 1), 1e-4);
                    float dRefr = CalculateDensityAlongRay(s.pos + lr.refractDir * TinyNudge, lr.refractDir, densityStep);
                    float dRefl = CalculateDensityAlongRay(s.pos + lr.reflectDir * TinyNudge, lr.reflectDir, densityStep);

                    bool traceRefr = (dRefr * lr.refractWeight) > (dRefl * lr.reflectWeight);

                    // "менее интересный" путь добавляем сразу
                    if (traceRefr)
                        col += LightNoEnv(lr.reflectDir) * T * Transmittance(dRefl) * lr.reflectWeight;
                    else
                        col += LightNoEnv(lr.refractDir) * T * Transmittance(dRefr) * lr.refractWeight;

                    // продолжаем "более интересный" путь
                    float3 nextDir = traceRefr ? lr.refractDir : lr.reflectDir;
                    float  nextW   = traceRefr ? lr.refractWeight : lr.reflectWeight;

                    ro = s.pos + nextDir * TinyNudge;
                    rd = nextDir;
                    T *= nextW;

                    // если преломились — сменили среду
                    if (traceRefr) travellingThroughFluid = !travellingThroughFluid;

                    // если T почти ноль — можно выйти
                    if (max(T.x, max(T.y, T.z)) < 1e-4) break;
                }

                // остаток пути (как в конце второго шейдера)
                float dRem = CalculateDensityAlongRay(ro, rd, max(_BounceDensityStepSize, 1e-4));
                col += LightNoEnv(rd) * T * Transmittance(dRem);

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