// The classic first triangle. The vertices are not in a buffer yet -- they are
// baked into the shader and picked out by vertex index, which lets the whole
// vertex-buffer / memory-allocation machinery wait for the next step.

struct VertexOutput {
    float4 position : SV_Position;
    float3 color : COLOR;
};

static const float2 positions[3] = {
    float2(0.0, -0.5),
    float2(0.5, 0.5),
    float2(-0.5, 0.5),
};

static const float3 colors[3] = {
    float3(1.0, 0.2, 0.2),
    float3(0.2, 1.0, 0.2),
    float3(0.2, 0.4, 1.0),
};

[shader("vertex")]
VertexOutput vertexMain(uint index: SV_VertexID) {
    VertexOutput out;
    out.position = float4(positions[index], 0.0, 1.0);
    out.color = colors[index];
    return out;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput in) : SV_Target {
    // Interpolated across the triangle by the rasterizer -- the same barycentric
    // interpolation the software renderer did by hand, now in silicon.
    return float4(in.color, 1.0);
}