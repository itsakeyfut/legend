// A lit, textured, indexed mesh, shadowed by the light's depth map.
//
// The vertex stage now carries a world-space position into light clip space as
// well as into the camera's; the fragment stage compares that against the depth
// the shadow pass recorded. Further from the light than what got there first
// means something is in the way.

#include "common/push_constants.slang"
#include "common/shadowing.slang"

// Set 0, binding 0 -- the material texture, matching TextureLayout.
[vk::binding(0, 0)]
Sampler2D albedo;

struct VertexInput {
    float3 position : POSITION;
    float2 uv : TEXCOORD0;
    float3 normal : NORMAL;
};

struct VertexOutput {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
    float3 normal : NORMAL;
    float4 lightPos : TEXCOORD1;
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    float4 p = float4(input.position, 1.0);

    VertexOutput output;
    output.position = pc.mvp0 * p.x + pc.mvp1 * p.y + pc.mvp2 * p.z + pc.mvp3 * p.w;

    // World space, for the light to look at. Only xyz is wanted, which is also
    // why the tint in the w channels does no harm.
    float3 world = pc.model0.xyz * p.x + pc.model1.xyz * p.y
                 + pc.model2.xyz * p.z + pc.model3.xyz;
    output.lightPos = mul(shadow.lightVP, float4(world, 1.0));

    output.uv = input.uv;
    // The model matrix's upper 3x3 stands in for the inverse transpose: exact
    // for rotation and uniform scale, which is what the scenes here use.
    output.normal = pc.model0.xyz * input.normal.x
                  + pc.model1.xyz * input.normal.y
                  + pc.model2.xyz * input.normal.z;
    return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target {
    float3 tint = float3(pc.model0.w, pc.model1.w, pc.model2.w);

    // The image is an sRGB format, so the hardware has already converted it to
    // linear on the way in. Multiplying by light here is therefore correct, and
    // the swapchain converts back on the way out.
    float3 texel = albedo.Sample(input.uv).rgb;

    float3 n = normalize(input.normal);
    float lambert = max(0.0, dot(n, shadow.lightDir.xyz));
    // Ambient stays out of the shadow term, so shadowed surfaces darken rather
    // than turn black.
    float intensity = 0.2 + 0.8 * lambert * shadowFactor(input.lightPos, n);

    return float4(texel * tint * intensity, 1.0);
}
