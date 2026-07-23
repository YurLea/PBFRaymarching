Shader "Custom/PBF/ParticleQuadsSpeed"
{
    Properties
    {
        _FluidSize("Fluid Quad Size", Float) = 0.1
        _SolidSize("Solid Quad Size", Float) = 0.16

        _MinSpeed("Min Speed", Float) = 0.0
        _MaxSpeed("Max Speed", Float) = 10.0

        _FluidAlpha("Fluid Alpha", Range(0,1)) = 1.0
        _SolidAlpha("Solid Alpha", Range(0,1)) = 1.0
    }

    SubShader
    {
        Tags
        {
            "Queue"="Transparent"
            "RenderType"="Transparent"
            "IgnoreProjector"="True"
        }

        LOD 100

        Pass
        {
            ZWrite Off
            Cull Off
            Blend SrcAlpha OneMinusSrcAlpha

            HLSLPROGRAM

            #pragma target 4.5
            #pragma vertex vert
            #pragma fragment frag

            #include "UnityCG.cginc"

            struct ParticleData
            {
                float4 position;
                float4 predicted;
                float4 velocity;
                float4 delta;

                float4 rest;

                float density;
                float lambda;
                float invMass;
                float type; // 0 = fluid, 1 = solid
            };

            StructuredBuffer<ParticleData> _Particles;

            float _FluidSize;
            float _SolidSize;

            float _MinSpeed;
            float _MaxSpeed;

            float _FluidAlpha;
            float _SolidAlpha;

            float4 _CamRight;
            float4 _CamUp;

            struct VOut
            {
                float4 posCS : SV_POSITION;
                float4 col   : COLOR0;
            };

            float3 SpeedToColor(float t)
            {
                t = saturate(t);

                float3 c0 = float3(0, 0, 1);
                float3 c1 = float3(0, 1, 1);
                float3 c2 = float3(0, 1, 0);
                float3 c3 = float3(1, 1, 0);
                float3 c4 = float3(1, 0, 0);

                if (t < 0.25) return lerp(c0, c1, t / 0.25);
                if (t < 0.50) return lerp(c1, c2, (t - 0.25) / 0.25);
                if (t < 0.75) return lerp(c2, c3, (t - 0.50) / 0.25);

                return lerp(c3, c4, (t - 0.75) / 0.25);
            }

            float2 QuadUV(uint vertexID)
            {
                if (vertexID == 0) return float2(0, 0);
                if (vertexID == 1) return float2(1, 0);
                if (vertexID == 2) return float2(1, 1);
                if (vertexID == 3) return float2(0, 0);
                if (vertexID == 4) return float2(1, 1);
                return float2(0, 1);
            }

            VOut vert(uint vertexID : SV_VertexID, uint instanceID : SV_InstanceID)
            {
                VOut o;

                ParticleData p = _Particles[instanceID];

                bool isSolid = p.type >= 0.5;

                float size = isSolid ? _SolidSize : _FluidSize;

                float2 uv = QuadUV(vertexID);
                float2 corner = uv * 2.0 - 1.0;

                float3 worldPos =
                    p.position.xyz +
                    (_CamRight.xyz * corner.x + _CamUp.xyz * corner.y) * (size * 0.5);

                o.posCS = mul(UNITY_MATRIX_VP, float4(worldPos, 1.0));

                if (isSolid)
                {
                    // Сфера из solid particles рисуется черными квадами.
                    o.col = float4(0, 0, 0, _SolidAlpha);
                }
                else
                {
                    float speed = length(p.velocity.xyz);
                    float t = (speed - _MinSpeed) / max(1e-6, _MaxSpeed - _MinSpeed);
                    float3 rgb = SpeedToColor(t);

                    o.col = float4(rgb, _FluidAlpha);
                }

                return o;
            }

            fixed4 frag(VOut i) : SV_Target
            {
                return i.col;
            }

            ENDHLSL
        }
    }
}

