// The shadow pass for skinned meshes: depth only, from the light, after the
// skeleton has moved the vertex.
//
// The static shadow shader cannot serve here -- a skinned vertex reaches its
// final position only once the bones it follows have been applied, and that
// needs the bone matrices the main skinning pass already has at set 1. Nothing
// else differs: same push constants, same absence of colour.

#include "push_constants.slang"

// Set 1, binding 0 -- the same bone matrices the main pass binds, so the
// silhouette that blocks the light is the posed one.
struct BoneBlock {
    float4x4 matrices[128];
}

[vk::binding(0, 1)]
ConstantBuffer<BoneBlock> bones;

struct VertexInput {
    float3 position : POSITION;
    uint4 joints : BLENDINDICES0;
    float4 weights : BLENDWEIGHT0;
};

struct VertexOutput {
    float4 position : SV_Position;
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    float4x4 skin = bones.matrices[input.joints.x] * input.weights.x
                  + bones.matrices[input.joints.y] * input.weights.y
                  + bones.matrices[input.joints.z] * input.weights.z
                  + bones.matrices[input.joints.w] * input.weights.w;

    float4 skinned = mul(skin, float4(input.position, 1.0));

    VertexOutput output;
    // mvp here is lightViewProjection * model: the light's clip space.
    output.position = pc.mvp0 * skinned.x + pc.mvp1 * skinned.y
                    + pc.mvp2 * skinned.z + pc.mvp3 * skinned.w;
    return output;
}

[shader("fragment")]
void fragmentMain(VertexOutput input) {
    // Depth is written by the fixed-function test; there is no colour to emit.
}
