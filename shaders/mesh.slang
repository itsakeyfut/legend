// A lit, textured, indexed mesh.
//
// The shading is the software rasterizer's, moved into silicon -- with two
// things that came free: the normal is interpolated across the face rather than
// held constant over it, and the texture is filtered rather than point-sampled.

struct PushConstants {
    // The MVP, one column per float4. Sent this way so neither side has to
    // guess how the other stores a matrix.
    float4 mvp0;
    float4 mvp1;
    float4 mvp2;
    float4 mvp3;
    // xyz: the inverse-transpose columns. w: the tint, smuggled through the
    // channels the normal maths does not use, because 128 bytes is the limit.
    float4 normal0;
    float4 normal1;
    float4 normal2;
    // xyz is the light direction, w is unused.
    float4 lightDir;
};

[vk::push_constant]
ConstantBuffer<PushConstants> pc;

// Set 0, binding 0 -- matching TextureLayout. The number is the whole contract
// between this file and texture.zig; nothing checks it until validation runs.
[vk::binding(0, 0)]
Sampler2D albedo;

struct VertexInput {
    float3 position : POSITION;
    float2 uv : TEXCOORD0;
    float3 normal : NORMAL;
};

struct VertexOutput {
    float4 position : SV_Position;
    float2 uv : TEXCOORD0;
    float3 normal : NORMAL;
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput input) {
    float4 p = float4(input.position, 1.0);

    VertexOutput output;
    output.position = pc.mvp0 * p.x + pc.mvp1 * p.y + pc.mvp2 * p.z + pc.mvp3 * p.w;
    output.uv = input.uv;
    output.normal = pc.normal0.xyz * input.normal.x
                  + pc.normal1.xyz * input.normal.y
                  + pc.normal2.xyz * input.normal.z;
    return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput input) : SV_Target {
    float3 tint = float3(pc.normal0.w, pc.normal1.w, pc.normal2.w);

    // The image is an sRGB format, so the hardware has already converted it to
    // linear on the way in. Multiplying by light here is therefore correct, and
    // the swapchain converts back on the way out.
    float3 texel = albedo.Sample(input.uv).rgb;

    float3 n = normalize(input.normal);
    float lambert = max(0.0, dot(n, pc.lightDir.xyz));
    float intensity = 0.2 + 0.8 * lambert;

    return float4(texel * tint * intensity, 1.0);
}