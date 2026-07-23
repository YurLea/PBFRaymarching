Shader "Custom/PBF/SmokeParticleQuadsSpeed"
{
    Properties
    {
        _Size("Size (world)", Float) = 0.03
        _MinSpeed("Min Speed", Float) = 0.0
        _MaxSpeed("Max Speed", Float) = 6.0
        _Alpha("Alpha", Range(0,1)) = 0.8
        _LifeFade("Life Fade Seconds", Float) = 1.0
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

            struct SmokeParticleData
            {
                float4 x;      // position
                float4 v;      // velocity
                float  life;   // <=0 dead
                float  pad0;
                float2 pad1;
            };

            StructuredBuffer<SmokeParticleData> _Particles;

            float _Size;
            float _MinSpeed;
            float _MaxSpeed;
            float _Alpha;
            float _LifeFade;

            float4 _CamRight; // xyz
            float4 _CamUp;    // xyz

            struct VOut
            {
                float4 posCS : SV_POSITION;
                float4 col   : COLOR0;
                float2 uv    : TEXCOORD0;
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

            VOut vert(uint vertexID : SV_VertexID, uint instanceID : SV_InstanceID)
            {
                VOut o;

                SmokeParticleData p = _Particles[instanceID];

                float2 uv;
                if (vertexID == 0) uv = float2(0,0);
                else if (vertexID == 1) uv = float2(1,0);
                else if (vertexID == 2) uv = float2(1,1);
                else if (vertexID == 3) uv = float2(0,0);
                else if (vertexID == 4) uv = float2(1,1);
                else uv = float2(0,1);

                o.uv = uv;

                float2 corner = uv * 2.0 - 1.0;
                float3 worldPos = p.x.xyz
                                  + (_CamRight.xyz * corner.x + _CamUp.xyz * corner.y) * (_Size * 0.5);

                o.posCS = mul(UNITY_MATRIX_VP, float4(worldPos, 1.0));

                float speed = length(p.v.xyz);
                float t = (speed - _MinSpeed) / max(1e-6, (_MaxSpeed - _MinSpeed));
                float3 rgb = SpeedToColor(t);

                // life-based alpha
                float aLife = saturate(p.life / max(1e-5, _LifeFade));
                o.col = float4(rgb, _Alpha * aLife);

                return o;
            }

            fixed4 frag(VOut i) : SV_Target
            {
                // Soft round sprite alpha (smoke-ish)
                float2 d = i.uv * 2.0 - 1.0;
                float r2 = dot(d, d);
                float soft = exp(-r2 * 2.5); // tweak
                float a = i.col.a * soft;

                // cull dead / almost invisible
                clip(a - 1e-3);

                return float4(i.col.rgb, a);
            }
            ENDHLSL
        }
    }
}
