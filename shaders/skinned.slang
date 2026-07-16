// A lit, textured, skinned mesh.
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
    // xyz: the inverse-transpose columns. w: the tint.
    float4 normal0;
    float4 normal1;
    float4 normal2;
    // xyz is the light direction, w is unused.
    float4 lightDir;
};

[vk::push_constant]
ConstantBuffer<PushConstants> pc;

// Set 0, binding 0 -- the material texture, matching TextureLayout
[vk::binding(0, 0)]
Sampler2D albedo;

// Set 1, binding 0 -- the bone matrices, matching BoneLayout. One matrix per
// joint; a vertex references up to four by index.
struct BoneBlock {
    float4x4 matrices[128];
}

[vk::binding(0, 1)]
ConstantBuffer<BoneBlock> bones;

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
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    // Blend the four joint's skinning matrices by weight. The sum of weights is
    // 1 for a skinned vertex; a static vertex has weights {1,0,0,0} and joint 0
    // set to identity, so this leaves it where it was.
    float4x4 skin = bones.matrices[input.joints.x] * input.weights.x
                  + bones.matrices[input.joints.y] * input.weights.y
                  + bones.matrices[input.joints.z] * input.weights.z
                  + bones.matrices[input.joints.w] * input.weights.w;

    // Deform in model space, then project
    float4 skinned = mul(skin, float4(input.position, 1.0));

    VertexOutput output;
    output.position = pc.mvp0 * skinned.x + pc.mvp1 * skinned.y
                    + pc.mvp2 * skinned.z + pc.mvp3 * skinned.w;
    output.uv = input.uv;

    // The normal is deformed by the skinning matrix's rotation part too, so lit
    // surfaces follow the pose. Using the upper 3x3 is an approximation (correct
    // only for rigid bones), but standard and visually right for skeletal work.
    float3x3 skin3 = float3x3(skin);
    float3 sn = mul(skin3, input.normal);
    output.normal = pc.normal0.xyz * sn.x
                  + pc.normal1.xyz * sn.y
                  + pc.normal2.xyz * sn.z;
    return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target {
    float3 tint = float3(pc.normal0.w, pc.normal1.w, pc.normal2.w);
    float3 texel = albedo.Sample(input.uv).rgb;
    float3 n = normalize(input.normal);
    float lambert = max(0.0, dot(n, pc.lightDir.xyz));
    float intensity = 0.2 + 0.8 * lambert;
    return float4(texel * tint * intensity, 1.0);
}
