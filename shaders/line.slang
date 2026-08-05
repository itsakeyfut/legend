// Debug lines: a vertex buffer of coloured points drawn as a line list, with no
// lighting, no texture, no model transform. Each vertex already carries a world
// position and colour; the shader only projects the position into clip space
// and passes the colour through. This is the immediate-mode debug draw every
// engine has -- hitboxes, bounds, trajectories -- so it is deliberately plain.

struct LinePush {
    // The camera's view-projection, as four columns (row-major, matching the
    // engine's Mat4 and the -matrix-layout-row-major slangc flag).
    float4 vp0;
    float4 vp1;
    float4 vp2;
    float4 vp3;
};

[vk::push_constant]
ConstantBuffer<LinePush> pc;

struct VertexInput {
    float3 position : POSITION;
    float3 color : COLOR0;
};

struct VertexOutput {
    float4 position : SV_Position;
    float3 color : COLOR0;
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    float4 p = float4(input.position, 1.0);

    VertexOutput output;
    output.position = pc.vp0 * p.x + pc.vp1 * p.y + pc.vp2 * p.z + pc.vp3 * p.w;
    output.color = input.color;
    return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target {
    return float4(input.color, 1.0);
}
