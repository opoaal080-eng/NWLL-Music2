#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

[[ stitchable ]] half4 nightwellDockColorBlur(
    float2 position,
    SwiftUI::Layer layer,
    float2 globalOrigin,
    float dockTop,
    float fadeHeight,
    float maxRadius
) {
    const float globalY = position.y + globalOrigin.y;
    if (globalY <= dockTop) {
        return layer.sample(position);
    }

    // Zero first and second derivatives at either end avoid a visible seam as
    // the original pixels enter the dock. All distances are in display points.
    const float t = clamp((globalY - dockTop) / max(fadeHeight, 1.0f), 0.0f, 1.0f);
    const float amount = t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f);
    const float radius = maxRadius * amount;
    if (radius <= 0.01f) {
        return layer.sample(position);
    }

    // A fixed 7 x 7 Gaussian reaches three standard deviations on each axis.
    // Its furthest sample is exactly maxRadius points away on either axis,
    // matching SwiftUI's maxSampleOffset. No work grows with the blur radius.
    const float step = radius / 3.0f;
    // exp(-0.5 * x*x), x = -3...3. Multiplying the two one-dimensional
    // coefficients gives the same two-dimensional Gaussian without per-pixel
    // exponentials.
    constexpr float weights[7] = {
        0.0111089965f, 0.1353352832f, 0.6065306597f, 1.0f,
        0.6065306597f, 0.1353352832f, 0.0111089965f
    };
    float4 weightedColor = float4(0.0f);
    float totalWeight = 0.0f;
    for (int y = -3; y <= 3; ++y) {
        for (int x = -3; x <= 3; ++x) {
            const float2 offset = float2(x, y);
            const float weight = weights[x + 3] * weights[y + 3];
            // SwiftUI supplies premultiplied color. Accumulating all four
            // channels together preserves that representation through blur.
            weightedColor += float4(layer.sample(position + offset * step)) * weight;
            totalWeight += weight;
        }
    }
    return half4(weightedColor / totalWeight);
}
