#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Shaders for sung keywords in the lyrics view. `kind` matches LyricEffect's raw value:
// 0 fire, 1 cold, 2 rain, 3 star, 4 heart, 5 light.

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1));
    float d = hash21(i + float2(1, 1));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Recolours the glyphs of one word. `bounds` is the word's rect (x, y, width, height).
[[ stitchable ]] half4 lyricGlyph(float2 position, half4 color, float4 bounds, float time, float kind, float strength) {
    if (color.a <= 0.001h) { return color; }
    float alpha = float(color.a);
    float3 base = float3(color.rgb) / alpha;
    float2 uv = (position - bounds.xy) / max(bounds.zw, float2(1.0));
    float3 tint = base;

    if (kind < 0.5) {
        // Fire: white-yellow at the foot of the letters, red at the tips, flickering upward.
        float flicker = valueNoise(float2(position.x * 0.11, position.y * 0.09 + time * 3.4));
        float heat = clamp(uv.y * 1.2 - 0.1 + (flicker - 0.5) * 0.9, 0.0, 1.0);
        tint = mix(float3(1.0, 0.22, 0.04), float3(1.0, 0.93, 0.55), heat);
        tint *= 1.0 + 0.25 * flicker;
    } else if (kind < 1.5) {
        // Cold: pale ice with small glints.
        float glint = pow(valueNoise(position * 0.45 + float2(time * 0.8, -time * 0.5)), 7.0);
        tint = mix(float3(0.62, 0.84, 1.0), float3(1.0), clamp(glint * 3.0 + (1.0 - uv.y) * 0.35, 0.0, 1.0));
    } else if (kind < 2.5) {
        // Rain: cool blue with streaks running down the letters.
        float streak = 0.5 + 0.5 * sin(position.y * 0.32 - time * 7.0 + position.x * 0.9);
        tint = mix(float3(0.45, 0.68, 1.0), float3(0.85, 0.94, 1.0), streak * streak);
    } else if (kind < 3.5) {
        // Star: warm white that twinkles.
        float twinkle = pow(valueNoise(position * 0.33 + time * 1.6), 6.0);
        tint = mix(float3(1.0, 0.95, 0.74), float3(1.0), twinkle * 2.0) * (1.0 + twinkle * 1.5);
    } else if (kind < 4.5) {
        // Heart: pink, beating twice per cycle.
        float cycle = fract(time * 1.1);
        float beat = exp(-cycle * 9.0) + 0.6 * exp(-abs(cycle - 0.28) * 14.0);
        tint = mix(float3(1.0, 0.36, 0.55), float3(1.0, 0.78, 0.84), clamp(beat, 0.0, 1.0));
    } else {
        // Light: gold with a bright band sweeping across.
        float sweep = fract(time * 0.55) * 1.6 - 0.3;
        float band = smoothstep(0.22, 0.0, abs(uv.x - sweep));
        tint = mix(float3(1.0, 0.82, 0.42), float3(1.0, 0.98, 0.9), band);
    }

    float3 result = mix(base, tint, clamp(strength, 0.0, 1.0));
    return half4(half3(result * alpha), color.a);
}

// Heat shimmer for fire words: the tips of the letters waver more than the feet.
[[ stitchable ]] float2 lyricHeat(float2 position, float4 bounds, float time, float strength) {
    float rise = 1.0 - clamp((position.y - bounds.y) / max(bounds.w, 1.0), 0.0, 1.0);
    float wobble = sin(position.y * 0.27 + time * 7.5) + 0.5 * sin(position.x * 0.19 - time * 5.0);
    return position + float2(wobble * 1.5 * rise, -rise * 0.6 * (0.5 + 0.5 * sin(time * 9.0 + position.x * 0.4))) * strength;
}
