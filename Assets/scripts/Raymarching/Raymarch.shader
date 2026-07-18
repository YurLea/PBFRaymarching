Shader "PeerPlay/PBF/RaymarchDensityDebug"
{
    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}
        _DensityMap ("Density Map (3D)", 3D) = "" {}
        _ScatteringCoefficients ("Scattering Coefficients (RGB)", Vector) = (1,1,1,0)
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

            float4 _ScatteringCoefficients; // xyz used

            struct appdata
            {
                float4 vertex : POSITION;  // z contains corner index 0..3
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

            // Возвращаем RGB (totalLight), как на вашем скрине
            float3 RayMarchFluid(float3 roWorld, float3 rdWorld)
            {
                float3 bmin = _BoundsMin.xyz;
                float3 bmax = _BoundsMin.xyz + _BoundsSize.xyz;

                float2 hit = RayBox(bmin, bmax, roWorld, rdWorld);

                const float TinyNudge = 1e-3;
                if (hit.y <= 0.0)
                    return 0.0.xxx;

                float stepSize = max(_StepSize, 1e-4);

                float dstToBox = hit.x;
                float dstThrough = min(hit.y, _MaxDistance);

                float t = TinyNudge;
                float tEnd = max(0.0, dstThrough - TinyNudge * 2.0);

                float densityAlongViewRay = 0.0;
                float3 totalLight = 0.0.xxx;

                float3 scatteringCoefficients = max(_ScatteringCoefficients.xyz, 0.0.xxx);

                [loop]
                for (int i = 0; i < 4096; i++)
                {
                    if (t >= tEnd) break;

                    float3 samplePos = roWorld + rdWorld * (dstToBox + t);

                    float raw = SampleDensityWorld(samplePos);
                    float dens = max(0.0, raw - _DensityOffset);

                    float densityAlongStep = dens * _DensityMultiplier * stepSize;
                    densityAlongViewRay += densityAlongStep;

                    // --- код как на вашем скрине ---
                    float3 inScatteredLight = float3(1, 1, 1) * densityAlongStep * scatteringCoefficients;
                    float3 viewRayTransmittance = exp(-densityAlongViewRay * scatteringCoefficients);
                    totalLight += inScatteredLight * viewRayTransmittance;

                    t += stepSize;
                }

                return totalLight;
            }

            fixed4 frag(v2f i) : SV_Target
            {
                float3 ro = _WorldSpaceCameraPos;
                float3 rd = normalize(i.rayWS);

                float3 col = RayMarchFluid(ro, rd);

                // debug clamp
                col = saturate(col);
                return fixed4(col, 1.0);
            }
            ENDCG
        }
    }
}