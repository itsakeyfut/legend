// A lit, textured, indexed mesh, shadowed by the light's depth map.
//
// The vertex stage now carries a world-space position into light clip space as
// well as into the camera's; the fragment stage compares that against the depth
// the shadow pass recorded. Further from the light than what got there first
// means something is in the way.

struct PushConstants {
    // The MVP, one column per float4. Sent this way so neither side has to
    // guess how the other stores a matrix.
    float4 mvp0;
    float4 mvp1;
    float4 mvp2;
    float4 mvp3;
    // The model matrix's columns. Their w channels are zero for an affine
    // transform, so the tint travels there.
    float4 model0;
    float4 model1;
    float4 model2;
    float4 model3;
};

[vk::push_constant]
ConstantBuffer<PushConstants> pc;

// Set 0, binding 0 -- the material texture, matching TextureLayout.
[vk::binding(0, 0)]
Sampler2D albedo;

// Set 2 -- what the whole frame shares about the light.
struct ShadowData {
    float4x4 lightVP;
    float4 lightDir;
};

[vk::binding(0, 2)]
Sampler2D shadowMap;

[vk::binding(1, 2)]
ConstantBuffer<ShadowData> shadow;

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

/// Is this point further from the light than whatever the shadow pass saw
/// first? The bias keeps a surface from shadowing itself: its own recorded
/// depth and its interpolated depth here differ by a fraction of a texel.
float shadowFactor(float4 lightPos) {
    float3 proj = lightPos.xyz / lightPos.w;
    // Past the light's far plane there is no information; treat it as lit.
    if (proj.z > 1.0) return 1.0;

    // Clip space is -1..1 across; texture coordinates are 0..1, and Vulkan's
    // v axis runs the same way its clip y does, so no flip is needed.
    float2 uv = proj.xy * 0.5 + 0.5;
    float closest = shadowMap.Sample(uv).r;

    const float bias = 0.0025;
    return (proj.z - bias > closest) ? 0.0 : 1.0;
}

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
    float intensity = 0.2 + 0.8 * lambert * shadowFactor(input.lightPos);

    return float4(texel * tint * intensity, 1.0);
}
