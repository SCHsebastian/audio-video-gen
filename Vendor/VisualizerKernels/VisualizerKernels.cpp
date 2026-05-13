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

extern "C" void vk_bars_process(const float *in,
                                float *out,
                                float *state,
                                uint32_t count,
                                float dt,
                                float beat) {
    if (!in || !out || !state || count == 0) return;
    // Attack: react fast to rising bands. Release: decay slowly so peaks linger.
    // Time constants chosen for ~60 fps; behavior is dt-aware so the scene still
    // looks right under the speed slider.
    const float attack_tau  = 0.060f;  // 60 ms — slightly softer rise
    const float release_tau = 0.380f;  // 380 ms — bars linger, easier to read
    const float a_atk = 1.0f - std::exp(-dt / std::max(1e-4f, attack_tau));
    const float a_rel = 1.0f - std::exp(-dt / std::max(1e-4f, release_tau));

    const float beatLift = std::min(1.0f, std::max(0.0f, beat)) * 0.18f;

    for (uint32_t i = 0; i < count; ++i) {
        // Perceptual scaling — emphasise lows a touch, compress highs.
        // (gentle gamma; spectrum is already in [0, 1] from the analyzer.)
        float v = std::pow(std::max(0.0f, in[i]), 0.7f) + beatLift;
        v = std::min(1.0f, v);

        float s = state[i];
        float coef = (v > s) ? a_atk : a_rel;
        s = s + (v - s) * coef;
        state[i] = s;
        out[i] = s;
    }
}

extern "C" void vk_scope_envelope(const float *in,
                                  float *out,
                                  uint32_t count,
                                  float gain) {
    if (!in || !out || count == 0) return;

    // First pass: 3-tap low-pass with reflected edges.
    // (Separate from output write so we can also DC-remove in one sweep.)
    const float w0 = 0.25f, w1 = 0.5f, w2 = 0.25f;

    // Compute DC over the window for a one-shot high-pass.
    double dc = 0.0;
    for (uint32_t i = 0; i < count; ++i) dc += in[i];
    const float meanv = static_cast<float>(dc / static_cast<double>(count));

    for (uint32_t i = 0; i < count; ++i) {
        float prev = in[i == 0 ? 0 : i - 1] - meanv;
        float cur  = in[i] - meanv;
        float next = in[i + 1 >= count ? count - 1 : i + 1] - meanv;
        float smoothed = w0 * prev + w1 * cur + w2 * next;
        // Soft saturation — keeps loud transients on screen without clipping.
        float x = smoothed * gain * 1.3f;
        out[i] = std::tanh(x);
    }
}

extern "C" const char *vk_build_id(void) {
    return "VisualizerKernels/1.1";
}
