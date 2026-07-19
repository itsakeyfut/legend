// Screen-space text: one quad per glyph, sampled from the font atlas.
//
// There is no vertex buffer. Six vertices make two triangles, and their corners
// come from the vertex index alone -- a glyph is entirely described by the push
// constants, so drawing one is a push and a draw with nothing bound but the
// atlas.
//
// Coordinates are pixels with the origin at the top left, which is how anyone
// placing an overlay thinks about them; the shader converts to clip space.

struct TextPush {
    // x, y, width, height -- in pixels.
    float4 rect;
    // u, v, and the span of each, in atlas texture coordinates.
    float4 uvRect;
    // The glyph's colour, alpha included.
    float4 color;
    // The framebuffer's width and height in pixels; zw unused.
    float4 screen;
};

[vk::push_constant]
ConstantBuffer<TextPush> pc;

// Set 0, binding 0 -- the font atlas, bound like any other material texture.
[vk::binding(0, 0)]
Sampler2D atlas;

struct VertexOutput {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
};

[shader("vertex")]
VertexOutput vertexMain(uint vertexIndex : SV_VertexID) {
    // Two triangles over the unit square. Winding does not matter: the text
    // pipeline culls nothing.
    const float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(1, 1),
        float2(0, 0), float2(1, 1), float2(0, 1),
    };
    float2 corner = corners[vertexIndex];

    float2 pixel = pc.rect.xy + corner * pc.rect.zw;

    VertexOutput output;
    // Pixels to clip space. Vulkan's y runs down the screen just as pixel rows
    // do, so both axes map the same way and neither is flipped.
    output.position = float4(
        pixel.x / pc.screen.x * 2.0 - 1.0,
        pixel.y / pc.screen.y * 2.0 - 1.0,
        0.0,
        1.0
    );
    output.uv = pc.uvRect.xy + corner * pc.uvRect.zw;
    return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target {
    // The atlas is white with the glyph in its alpha, so one atlas serves every
    // colour: the coverage scales the alpha and the colour comes from the push.
    float coverage = atlas.Sample(input.uv).a;
    return float4(pc.color.rgb, pc.color.a * coverage);
}
