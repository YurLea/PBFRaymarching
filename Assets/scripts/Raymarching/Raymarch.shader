Shader "PeerPlay/PBF/RaymarchDensityDebug"
{
    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}
        _DensityMap ("Density Map (3D)", 3D) = "" {}
        _ScatteringCoefficients ("Scattering Coefficients (RGB)", Vector) = (1,1,1,0)
        _DirToSun ("Dir To Sun (WS)", Vector) = (0,1,0,0)
        _LightColor ("Light Color (RGB)", Vector) = (1,1,1,0)
        _LightMarchStepSize ("Light March Step Size", Float) = 0.15
        _NormalEps ("Normal Epsilon (World units)", Float) = 0.005
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
            sampler3D _DensityMap;

            float4x4 _CamFrustum;
            float4x4 _CamToWorld;

            float4 _BoundsMin;   // xyz
            float4 _BoundsSize;  // xyz

            float _MaxDistance;
            float _DensityOffset;
            float _DensityMultiplier;
            float _StepSize;

            float4 _ScatteringCoefficients; // xyz
            float4 _DirToSun;               // xyz
            float4 _LightColor;             // xyz
            float  _LightMarchStepSize;

            float _NormalEps;

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

                if (uvw.x < 0 || uvw.y < 0 || uvw.z < 0 || uvw.x > 1 || uvw.y > 1 || uvw.z > 1)
                    return 0.0;

                return tex3D(_DensityMap, uvw).r;
            }

            float CalculateDensityAlongRay(float3 roWorld, float3 rdWorld, float stepSize)
            {
                float3 bmin = _BoundsMin.xyz;
                float3 bmax = _BoundsMin.xyz + _BoundsSize.xyz;

                float2 hit = RayBox(bmin, bmax, roWorld, rdWorld);
                const float TinyNudge = 1e-3;

                if (hit.y <= 0.0)
                    return 0.0;

                float step = max(stepSize, 1e-4);

                float dstToBox = hit.x;
                float dstThrough = hit.y;

                float t = TinyNudge;
                float tEnd = max(0.0, dstThrough - TinyNudge * 2.0);

                float accum = 0.0;

                [loop]
                for (int i = 0; i < 512; i++)
                {
                    if (t >= tEnd) break;

                    float3 p = roWorld + rdWorld * (dstToBox + t);

                    float raw = SampleDensityWorld(p);
                    float dens = max(0.0, raw - _DensityOffset);

                    accum += dens * _DensityMultiplier * step;
                    t += step;
                }

                return accum;
            }

            float DensityField(float3 pWorld)
            {
                // "поле" вокруг изо-поверхности: <0 снаружи, >0 внутри
                // (это не SDF, но для нормали градиента подходит)
                return SampleDensityWorld(pWorld) - _DensityOffset;
            }

            float3 CalculateNormalWorld(float3 pWorld, float3 viewDir)
            {
                float eps = max(_NormalEps, 1e-4);

                // чтобы при вычислении градиента не вылезать за bounds (иначе градиент ломается на краях/тонких местах)
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

                // устойчивое нормирование (без NaN)
                float len2 = dot(grad, grad);
                float3 n = (len2 > 1e-12) ? (-grad * rsqrt(len2)) : float3(0, 1, 0);

                // faceforward: чтобы нормаль всегда “смотрела” на камеру (важно для Fresnel/reflect/refract и убирает флипы)
                if (dot(n, viewDir) > 0) n = -n;

                return n;
            }

            bool RaymarchSurfaceHit(float3 roWorld, float3 rdWorld, out float3 hitPos)
            {
                float3 bmin = _BoundsMin.xyz;
                float3 bmax = _BoundsMin.xyz + _BoundsSize.xyz;

                float2 hit = RayBox(bmin, bmax, roWorld, rdWorld);
                if (hit.y <= 0.0) { hitPos = 0; return false; }

                float stepSize = max(_StepSize, 1e-4);

                float dstToBox = hit.x;
                float dstThrough = min(hit.y, _MaxDistance);

                const float TinyNudge = 1e-3;
                float t = TinyNudge;
                float tEnd = max(0.0, dstThrough - TinyNudge * 2.0);

                // значение поля в предыдущей точке
                float3 p0 = roWorld + rdWorld * (dstToBox + t);
                float f0 = DensityField(p0);

                [loop]
                for (int i = 0; i < 4096; i++)
                {
                    t += stepSize;
                    if (t >= tEnd) break;

                    float3 p1 = roWorld + rdWorld * (dstToBox + t);
                    float f1 = DensityField(p1);

                    if (f0 <= 0.0 && f1 > 0.0)
                    {
                        // сначала грубо (линейно)
                        float a = saturate(f0 / (f0 - f1));
                        float3 pa = lerp(p0, p1, a);

                        // потом 4-6 итераций бинарного поиска для стабильности
                        float3 lo = p0; float flo = f0;
                        float3 hi = p1; float fhi = f1;

                        [unroll]
                        for (int j = 0; j < 5; j++)
                        {
                            float3 mid = 0.5 * (lo + hi);
                            float fmid = DensityField(mid);

                            if (fmid > 0.0) { hi = mid; fhi = fmid; }
                            else           { lo = mid; flo = fmid; }
                        }

                        hitPos = hi; // точка уже на “внутренней” стороне порога
                        return true;
                    }

                    p0 = p1;
                    f0 = f1;
                }

                hitPos = 0;
                return false;
            }

            float3 RayMarchFluid(float3 roWorld, float3 rdWorld)
            {
                float3 bmin = _BoundsMin.xyz;
                float3 bmax = _BoundsMin.xyz + _BoundsSize.xyz;

                float2 hit = RayBox(bmin, bmax, roWorld, rdWorld);

                const float TinyNudge = 1e-3;
                if (hit.y <= 0.0)
                    return float3(0,0,0);

                float stepSize = max(_StepSize, 1e-4);

                float dstToBox = hit.x;
                float dstThrough = min(hit.y, _MaxDistance);

                float t = TinyNudge;
                float tEnd = max(0.0, dstThrough - TinyNudge * 2.0);

                float densityAlongViewRay = 0.0;
                float3 totalLight = float3(0,0,0);

                float3 scattering = max(_ScatteringCoefficients.xyz, float3(0,0,0));
                float3 dirToSun = normalize(_DirToSun.xyz);
                float3 lightColor = max(_LightColor.xyz, float3(0,0,0));
                float lightStep = max(_LightMarchStepSize, 1e-4);

                [loop]
                for (int i = 0; i < 4096; i++)
                {
                    if (t >= tEnd) break;

                    float3 samplePos = roWorld + rdWorld * (dstToBox + t);

                    float raw = SampleDensityWorld(samplePos);
                    float dens = max(0.0, raw - _DensityOffset);

                    float densityAlongStep = dens * _DensityMultiplier * stepSize;
                    densityAlongViewRay += densityAlongStep;

                    float densityAlongSunRay = CalculateDensityAlongRay(samplePos, dirToSun, lightStep);

                    float3 transmittedSunLight = exp(-densityAlongSunRay * scattering);
                    float3 inScatteredLight = transmittedSunLight * densityAlongStep * scattering * lightColor;

                    float3 viewRayTransmittance = exp(-densityAlongViewRay * scattering);
                    totalLight += inScatteredLight * viewRayTransmittance;

                    t += stepSize;
                }

                return totalLight;
            }

            fixed4 frag(v2f i) : SV_Target
            {
                float3 ro = _WorldSpaceCameraPos;
                float3 rd = normalize(i.rayWS);

                float3 hitPos;
                if (RaymarchSurfaceHit(ro, rd, hitPos))
                {
                    float3 n = CalculateNormalWorld(hitPos, rd);
                    return float4(saturate(n * 0.5 + 0.5), 1);
                }

                return float4(0,0,0,1);
            }
            //fixed4 frag(v2f i) : SV_Target
            //{
            //    float3 ro = _WorldSpaceCameraPos;
            //    float3 rd = normalize(i.rayWS);

            //    float3 col = RayMarchFluid(ro, rd);
            //    col = saturate(col);
            //    return fixed4(col, 1.0);
            //}
            ENDCG
        }
    }
}