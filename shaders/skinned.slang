// A lit, textured, skinned mesh, shadowed by the light's depth map.
//
// The same shading as mesh.slang, with one thing added before the MVP: each
// vertex is deformed by the bones it follows. The vertex carries four joint
// indices and four weights; this blends those joints' skinning matrices and
// applies the result, so the vertex tracks the posed skeleton. At bind pose the
// skinning matrices are identity, so this reduces to the static path.

struct PushConstants {
    // The MVP, one column per float4.
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

// Set 1, binding 0 -- the bone matrices, matching BoneLayout. One matrix per
// joint; a vertex references up to four by index.
struct BoneBlock {
    float4x4 matrices[128];
}

[vk::binding(0, 1)]
ConstantBuffer<BoneBlock> bones;

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
    uint4 joints : BLENDINDICES0;
    float4 weights : BLENDWEIGHT0;
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
    // Blend the four joints' skinning matrices by weight. The sum of weights is
    // 1 for a skinned vertex; a static vertex has weights {1,0,0,0} and joint 0
    // set to identity, so this leaves it where it was.
    float4x4 skin = bones.matrices[input.joints.x] * input.weights.x
                  + bones.matrices[input.joints.y] * input.weights.y
                  + bones.matrices[input.joints.z] * input.weights.z
                  + bones.matrices[input.joints.w] * input.weights.w;

    // Deform in model space, then project.
    float4 skinned = mul(skin, float4(input.position, 1.0));

    VertexOutput output;
    output.position = pc.mvp0 * skinned.x + pc.mvp1 * skinned.y
                    + pc.mvp2 * skinned.z + pc.mvp3 * skinned.w;
    output.uv = input.uv;

    // World space of the *deformed* vertex: the light sees the posed model.
    float3 world = pc.model0.xyz * skinned.x + pc.model1.xyz * skinned.y
                 + pc.model2.xyz * skinned.z + pc.model3.xyz * skinned.w;
    output.lightPos = mul(shadow.lightVP, float4(world, 1.0));

    // The normal is deformed by the skinning matrix's rotation part too, so lit
    // surfaces follow the pose. Using the upper 3x3 is an approximation (correct
    // only for rigid bones), but standard and visually right for skeletal work.
    float3x3 skin3 = float3x3(skin);
    float3 sn = mul(skin3, input.normal);
    output.normal = pc.model0.xyz * sn.x
                  + pc.model1.xyz * sn.y
                  + pc.model2.xyz * sn.z;
    return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target {
    float3 tint = float3(pc.model0.w, pc.model1.w, pc.model2.w);
    float3 texel = albedo.Sample(input.uv).rgb;
    float3 n = normalize(input.normal);
    float lambert = max(0.0, dot(n, shadow.lightDir.xyz));
    // Ambient stays out of the shadow term, so shadowed surfaces darken rather
    // than turn black.
    float intensity = 0.2 + 0.8 * lambert * shadowFactor(input.lightPos);
    return float4(texel * tint * intensity, 1.0);
}
