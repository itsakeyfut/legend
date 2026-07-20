// The per-draw constants, shared by every shader that draws geometry.
//
// This block must match gpu/pipeline.zig's PushConstants byte for byte. It lived
// in four shaders at once before this file existed, which meant four places to
// keep in step with a fifth in Zig -- and nothing but attention holding them
// together.

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
