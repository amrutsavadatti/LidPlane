#include <metal_stdlib>
using namespace metal;

struct Vertex { float4 position [[position]]; float2 uv; };
struct Parameters { float delta; float aspect; float blur; float padding; };

vertex Vertex planeVertex(uint id [[vertex_id]]) {
    float2 positions[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
    Vertex out;
    out.position = float4(positions[id], 0, 1);
    out.uv = float2(positions[id].x * .5 + .5, .5 - positions[id].y * .5);
    return out;
}

// Bounded screen-space projection. The bottom edge is the hinge; signed delta
// works in either direction. Every path produces a screenshot sample, which
// is important because an opaque full-screen overlay must never turn a failed
// geometric intersection into a black display.
fragment float4 planeFragment(Vertex in [[stage_in]],
                              texture2d<float> screenshot [[texture(0)]],
                              constant Parameters &p [[buffer(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float signedTurn = clamp(p.delta / 90.0, -1.0, 1.0);
    float amount = abs(signedTurn);
    float direction = sign(signedTurn);
    float hinge = 1.0 - in.uv.y;
    float bend = amount * 0.72;
    float verticalScale = max(0.34, cos(bend));
    float2 sampleUV = in.uv - float2(0.0, hinge * (1.0 - verticalScale) * 0.42);
    sampleUV.y = 1.0 - (1.0 - sampleUV.y) / verticalScale;
    sampleUV.x += direction * hinge * amount * 0.10;
    sampleUV = clamp(sampleUV, 0.0, 1.0);

    float radius = amount * p.blur * mix(.15, 1.0, hinge);
    float2 step = radius / float2(screenshot.get_width(), screenshot.get_height());
    float3 color = screenshot.sample(s, sampleUV).rgb * 4.0;
    color += screenshot.sample(s, clamp(sampleUV + float2(step.x,0), 0.0, 1.0)).rgb * 2.0;
    color += screenshot.sample(s, clamp(sampleUV - float2(step.x,0), 0.0, 1.0)).rgb * 2.0;
    color += screenshot.sample(s, clamp(sampleUV + float2(0,step.y), 0.0, 1.0)).rgb * 2.0;
    color += screenshot.sample(s, clamp(sampleUV - float2(0,step.y), 0.0, 1.0)).rgb * 2.0;
    color += screenshot.sample(s, clamp(sampleUV + step, 0.0, 1.0)).rgb;
    color += screenshot.sample(s, clamp(sampleUV - step, 0.0, 1.0)).rgb;
    color += screenshot.sample(s, clamp(sampleUV + float2(step.x,-step.y), 0.0, 1.0)).rgb;
    color += screenshot.sample(s, clamp(sampleUV + float2(-step.x,step.y), 0.0, 1.0)).rgb;
    color /= 16.0;
    color *= 1.0 - amount * 0.12 * hinge;
    return float4(color, 1);
}
