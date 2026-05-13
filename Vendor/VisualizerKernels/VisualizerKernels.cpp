// VisualizerKernels — small C++ generator kernels invoked from Swift to feed
// vertex data into Metal scenes. The kernels are deliberately self-contained
// (no dependencies beyond <cmath>) so the library compiles cleanly across the
// SwiftPM build matrix and stays trivially testable.

#include "VisualizerKernels.h"
#include <cmath>
#include <algorithm>

namespace {
constexpr float kTwoPi = 6.28318530717958647692f;
}

extern "C" void vk_lissajous(float *out_xy,
                             uint32_t count,
                             float t,
                             float a,
                             float b,
                             float delta,
                             float rms) {
    if (!out_xy || count == 0) return;
    const float pulse = 0.85f + 0.15f * std::min(1.0f, rms * 6.0f);
    const float phase = t * 0.35f;
    for (uint32_t i = 0; i < count; ++i) {
        const float u = static_cast<float>(i) / static_cast<float>(count - 1);
        const float theta = u * kTwoPi;
        const float x = std::sin(a * theta + delta + phase);
        const float y = std::sin(b * theta + phase * 0.7f);
        out_xy[2*i + 0] = x * pulse;
        out_xy[2*i + 1] = y * pulse;
    }
}

extern "C" void vk_rose(float *out_xy,
                        uint32_t count,
                        float t,
                        int32_t petals,
                        float rms) {
    if (!out_xy || count == 0) return;
    const float k = static_cast<float>(petals <= 0 ? 1 : petals);
    const float rot = t * 0.25f;
    const float scale = 0.9f * (1.0f + std::min(0.8f, rms * 2.0f));
    for (uint32_t i = 0; i < count; ++i) {
        const float u = static_cast<float>(i) / static_cast<float>(count - 1);
        const float theta = u * kTwoPi;
        const float r = std::cos(k * theta) * scale;
        out_xy[2*i + 0] = r * std::cos(theta + rot);
        out_xy[2*i + 1] = r * std::sin(theta + rot);
    }
}

extern "C" const char *vk_build_id(void) {
    return "VisualizerKernels/1.0";
}
