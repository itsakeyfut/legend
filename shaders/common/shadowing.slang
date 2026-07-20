// Set 2 and the shadow lookup: what the main pass needs to know about the light.
//
// Only the shaders that shade need this. The depth-only passes write no colour
// and sample nothing, so they include push_constants.slang alone -- declaring a
// sampler they never use would put a binding in the SPIR-V that their pipeline
// layout does not have.

struct ShadowData {
    float4x4 lightVP;
    float4 lightDir;
};

[vk::binding(0, 2)]
Sampler2DShadow shadowMap;

[vk::binding(1, 2)]
ConstantBuffer<ShadowData> shadow;

/// The shadow map's size, needed to step one texel at a time. Matches
/// shadow.zig's resolution; a mismatch only softens or hardens the filter, so it
/// is not worth a uniform of its own yet.
static const float shadow_texel = 1.0 / 2048.0;

/// Is this point in shadow, and how much of it?
///
/// Nine lookups on a 3x3 grid, averaged. Each lookup is itself a comparison
/// filtered across four texels by the hardware, so the nine values are already
/// fractions -- the result is a continuous gradient rather than the ten steps
/// nine yes-or-no answers could produce.
///
/// The bias scales with how obliquely the light strikes the surface. A shadow
/// map texel covers a patch of the world, and the steeper the angle, the more
/// depth that patch spans -- so a face nearly edge-on to the light needs far
/// more slack than one facing it squarely.
float shadowFactor(float4 lightPos, float3 normal) {
    float3 proj = lightPos.xyz / lightPos.w;
    // Past the light's far plane there is no information; treat it as lit.
    if (proj.z > 1.0) return 1.0;

    // Clip space is -1..1 across; texture coordinates are 0..1, and Vulkan's
    // v axis runs the same way its clip y does, so no flip is needed.
    float2 uv = proj.xy * 0.5 + 0.5;

    float cosine = clamp(dot(normal, shadow.lightDir.xyz), 0.0, 1.0);
    float bias = max(0.006 * (1.0 - cosine), 0.0008);

    float lit = 0.0;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            float2 offset = float2(x, y) * shadow_texel;
            // The hardware compares and filters: this returns how much of the
            // 2x2 neighbourhood this point is in front of, not a yes or no.
            lit += shadowMap.SampleCmp(uv + offset, proj.z - bias);
        }
    }
    return lit / 9.0;
}
