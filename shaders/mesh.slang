// A lit, indexed mesh. This is the software rasterizer's shading moved into
// silicon -- with one upgrade: the normal is interpolated across the face
// instead of being constant over it, so shading is smooth rather than flat, and
// costs nothing extra for it.

struct PushConstants {
    // The MVP, one column per float4. Sent this way so neither side has to
    // guess how the other stores a matrix.
    float4 mvp0;
    float4 mvp1;
    float4 mvp2;
    float4 mvp3;
    // The inverse-transpose, three columns; w unused.
    float4 normal0;
    float4 normal1;
    float4 normal2;
    // xyz is the light direction, w is padding.
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
    float3 n = normalize(input.normal);
    float lambert = max(0.0, dot(n, pc.lightDir.xyz));
    float intensity = 0.2 + 0.8 * lambert;

    // No texture yet. The UVs stand in as colour, so it is obvious at a glance
    // whether they survived the trip through the vertex buffer.
    float3 albedo = float3(input.uv, 0.6);
    return float4(albedo * intensity, 1.0);
}