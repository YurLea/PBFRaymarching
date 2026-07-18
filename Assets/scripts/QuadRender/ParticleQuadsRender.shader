Shader "Custom/PBF/ParticleQuadsSpeed"
{
    Properties
    {
        _Size("Size (world)", Float) = 0.2
        _MinSpeed("Min Speed", Float) = 0.0
        _MaxSpeed("Max Speed", Float) = 10.0
        _Alpha("Alpha", Range(0,1)) = 1.0
    }

    SubShader
    {
        Tags { "Queue"="Transparent" "RenderType"="Transparent" "IgnoreProjector"="True" }
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
                float density;
                float lambda;
                float pad0, pad1;
            };

            StructuredBuffer<ParticleData> _Particles;

            float _Size;
            float _MinSpeed;
            float _MaxSpeed;
            float _Alpha;

            float4 _CamRight; // xyz
            float4 _CamUp;    // xyz

            struct VOut
            {
                float4 posCS : SV_POSITION;
                float4 col   : COLOR0;
            };

            float3 SpeedToColor(float t)
            {
                t = saturate(t);

                float3 c0 = float3(0, 0, 1); // blue
                float3 c1 = float3(0, 1, 1); // cyan
                float3 c2 = float3(0, 1, 0); // green
                float3 c3 = float3(1, 1, 0); // yellow
                float3 c4 = float3(1, 0, 0); // red

                if (t < 0.25) return lerp(c0, c1, t / 0.25);
                if (t < 0.50) return lerp(c1, c2, (t - 0.25) / 0.25);
                if (t < 0.75) return lerp(c2, c3, (t - 0.50) / 0.25);
                return lerp(c3, c4, (t - 0.75) / 0.25);
            }

            VOut vert(uint vertexID : SV_VertexID, uint instanceID : SV_InstanceID)
            {
                VOut o;

                ParticleData p = _Particles[instanceID];

                // 6 verts (2 triangles) with uv corners:
                // (0,0)-(1,0)-(1,1) and (0,0)-(1,1)-(0,1)
                float2 uv;
                if (vertexID == 0) uv = float2(0,0);
                else if (vertexID == 1) uv = float2(1,0);
                else if (vertexID == 2) uv = float2(1,1);
                else if (vertexID == 3) uv = float2(0,0);
                else if (vertexID == 4) uv = float2(1,1);
                else uv = float2(0,1);

                float2 corner = uv * 2.0 - 1.0; // [-1..1]
                float3 worldPos = p.position.xyz
                                  + (_CamRight.xyz * corner.x + _CamUp.xyz * corner.y) * (_Size * 0.5);

                o.posCS = mul(UNITY_MATRIX_VP, float4(worldPos, 1.0));

                float speed = length(p.velocity.xyz);
                float t = (speed - _MinSpeed) / max(1e-6, (_MaxSpeed - _MinSpeed));
                float3 rgb = SpeedToColor(t);

                o.col = float4(rgb, _Alpha);
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
