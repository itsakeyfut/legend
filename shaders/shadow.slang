// The shadow pass: depth only, from the light's point of view.
//
// Nothing is shaded here. The vertex stage places each vertex in the light's
// clip space and the depth test does the rest -- what survives is, for every
// direction the light looks, the distance to the nearest surface. The fragment
// stage exists only because a graphics pipeline wants one; it writes nothing.
//
// The push constants are the main pass's struct, reused unchanged: mvp0..3 hold
// lightViewProjection * model, and the rest is ignored. One layout, one shape,
// no second contract to keep in sync.

struct PushConstants {
    float4 mvp0;
    float4 mvp1;
    float4 mvp2;
    float4 mvp3;
    float4 normal0;
    float4 normal1;
    float4 normal2;
    float4 lightDir;
};

[vk::push_constant]
ConstantBuffer<PushConstants> pc;

struct VertexInput {
    float3 position : POSITION;
    float2 uv : TEXCOORD0;
    float3 normal : NORMAL;
};

struct VertexOutput {
    float4 position : SV_Position;
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    float4 p = float4(input.position, 1.0);

    VertexOutput output;
    output.position = pc.mvp0 * p.x + pc.mvp1 * p.y + pc.mvp2 * p.z + pc.mvp3 * p.w;
    return output;
}

[shader("fragment")]
void fragmentMain(VertexOutput input) {
    // Depth is written by the fixed-function test; there is no colour to emit.
}