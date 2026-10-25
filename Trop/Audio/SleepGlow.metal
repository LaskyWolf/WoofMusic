//
//  SleepGlow.metal
//  Trop
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

/// Height of one wavy edge of the sleep-timer glow at position `u` along it.
static float glowBoundary(float u, float offset, float edge, float depth, float outset,
                          float amp, float freq, float time, float speed, float phase) {
    return edge * depth - outset
        + amp * sin(u * freq + time * speed + phase + offset)
        + amp * 0.12 * sin(u * freq * 1.7 - time * speed * 0.6 + phase + offset);
}

/// The sleep-timer glow: three wavy layers (indigo, violet, a touch of teal)
/// hugging the left, top and right edges, joined by a smooth minimum so the
/// glow follows the rounded top corners. Drawn on the GPU, one pixel at a time.
[[ stitchable ]] half4 sleepGlow(float2 position, half4 color, float2 size, float time,
                                 float strength, float waveBoost, float outset,
                                 float scale, float waves) {
    const float3 colors[3] = { float3(48, 32, 165), float3(112, 86, 250), float3(86, 196, 220) };
    const float alphas[3] = { 0.95, 0.6, 0.3 };
    const float depths[3] = { 185, 132, 88 };
    const float amplitudes[3] = { 34, 38, 26 };
    const float frequencies[3] = { 0.012, 0.016, 0.02 };
    const float speeds[3] = { 0.7, -0.9, 1.1 };
    const float phases[3] = { 0, 1.7, 3.1 };

    if (strength <= 0.001) { return half4(0); }

    float k = 0.016 / scale;
    float skipMargin = log(3.0) / k;
    float4 acc = float4(0);

    for (int i = 0; i < 3; i++) {
        float edge = min(1.0, strength * (1.0 + float(i) * 0.04));
        float depth = depths[i] * scale;
        float fade = depth * edge + 1.0;
        float freq = frequencies[i] / scale;
        float amp = amplitudes[i] * scale * edge * waveBoost * waves;

        float v1 = position.x - glowBoundary(position.y, 0.0, edge, depth, outset, amp, freq, time, speeds[i], phases[i]);
        float v2 = (size.x - position.x) - glowBoundary(position.y, 1.9, edge, depth, outset, amp, freq, time, speeds[i], phases[i]);
        float v3 = (position.y - glowBoundary(position.x, 3.8, edge, depth, outset, amp, freq, time, speeds[i], phases[i]) * 0.85) / 0.85;
        if (min(v1, min(v2, v3)) > skipMargin) { continue; }

        float distance = -log(exp(-k * v1) + exp(-k * v2) + exp(-k * v3)) / k;
        float u = -distance / fade;
        if (u <= 0.0) { continue; }
        u = min(u, 1.0);
        float a = u * u * (3.0 - 2.0 * u) * alphas[i];
        acc = acc * (1.0 - a) + float4(colors[i] * a, a);
    }
    return half4(half3(acc.rgb / 255.0), half(acc.a));
}
