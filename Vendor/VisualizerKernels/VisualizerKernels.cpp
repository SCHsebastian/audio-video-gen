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
    // Hard ceiling at 0.90 so even with audio-reactive pulse the curve plus the
    // line-thickness halo stays inside NDC [-1, 1].
    const float pulse = 0.78f + 0.12f * std::min(1.0f, rms * 6.0f);
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
    // Cap effective radius to 0.85 so the curve + glow halo stays inside the canvas.
    const float scale = std::min(0.85f, 0.65f * (1.0f + std::min(0.5f, rms * 1.5f)));
    for (uint32_t i = 0; i < count; ++i) {
        const float u = static_cast<float>(i) / static_cast<float>(count - 1);
        const float theta = u * kTwoPi;
        const float r = std::cos(k * theta) * scale;
        out_xy[2*i + 0] = r * std::cos(theta + rot);
        out_xy[2*i + 1] = r * std::sin(theta + rot);
    }
}

extern "C" void vk_catmull_rom(const float *in_xy,
                               uint32_t inCount,
                               float *out_xy,
                               uint32_t subdivs) {
    if (!in_xy || !out_xy || inCount < 4 || subdivs == 0) return;
    // Uniform Catmull-Rom over (inCount-3) spans, each emitting `subdivs` points,
    // plus one trailing point at the very end so the polyline closes cleanly.
    const uint32_t spans = inCount - 3;
    uint32_t w = 0;
    for (uint32_t k = 0; k < spans; ++k) {
        const float *P0 = in_xy + 2 * (k + 0);
        const float *P1 = in_xy + 2 * (k + 1);
        const float *P2 = in_xy + 2 * (k + 2);
        const float *P3 = in_xy + 2 * (k + 3);
        for (uint32_t j = 0; j < subdivs; ++j) {
            const float t = static_cast<float>(j) / static_cast<float>(subdivs);
            const float t2 = t * t;
            const float t3 = t2 * t;
            const float x = 0.5f * ((2.0f * P1[0])
                                   + (-P0[0] + P2[0]) * t
                                   + (2.0f * P0[0] - 5.0f * P1[0] + 4.0f * P2[0] - P3[0]) * t2
                                   + (-P0[0] + 3.0f * P1[0] - 3.0f * P2[0] + P3[0]) * t3);
            const float y = 0.5f * ((2.0f * P1[1])
                                   + (-P0[1] + P2[1]) * t
                                   + (2.0f * P0[1] - 5.0f * P1[1] + 4.0f * P2[1] - P3[1]) * t2
                                   + (-P0[1] + 3.0f * P1[1] - 3.0f * P2[1] + P3[1]) * t3);
            out_xy[2*w + 0] = x;
            out_xy[2*w + 1] = y;
            ++w;
        }
    }
    // Trailing endpoint = last P2 of the final span.
    const float *Plast = in_xy + 2 * (inCount - 2);
    out_xy[2*w + 0] = Plast[0];
    out_xy[2*w + 1] = Plast[1];
}

extern "C" void vk_bars_process(const float *in,
                                uint32_t inCount,
                                float *out,
                                uint32_t outCount,
                                float *state,
                                float *peaks,
                                float sampleRate,
                                float dt) {
    if (!in || !out || !state || !peaks || inCount == 0 || outCount == 0) return;

    // Time constants — strictly `1 - exp(-dt/tau)` so per-bar attack/release look
    // identical at 60/120/240 Hz refresh rates.
    constexpr float tau_atk = 0.020f;  // 20 ms — snappy rise
    constexpr float tau_rel = 0.300f;  // 300 ms — the Winamp linger
    const float a_atk = 1.0f - std::exp(-dt / tau_atk);
    const float a_rel = 1.0f - std::exp(-dt / tau_rel);

    // Log-frequency band edges. We carve [f_min, f_max] into outCount log slices
    // and pull the value from the linear FFT bins covering each slice.
    constexpr float f_min     = 40.0f;
    constexpr float f_max     = 16000.0f;
    constexpr float db_floor  = -70.0f;
    constexpr float db_ceil   = -10.0f;
    constexpr float db_range  = db_ceil - db_floor;
    constexpr float eps       = 1e-4f;
    constexpr float peak_hold = 0.50f;     // s; cap dwells before falling
    constexpr float peak_fall = 0.60f;     // /s; how fast the cap drifts down

    const float ratio = f_max / f_min;
    // Each input bin covers `nyquist / inCount` Hz. We need bin = f / hzPerBin.
    const float hzPerBin = (sampleRate * 0.5f) / static_cast<float>(inCount);
    const int32_t lastBin = static_cast<int32_t>(inCount) - 1;

    for (uint32_t k = 0; k < outCount; ++k) {
        const float u_lo = static_cast<float>(k)     / static_cast<float>(outCount);
        const float u_hi = static_cast<float>(k + 1) / static_cast<float>(outCount);
        const float f_lo = f_min * std::pow(ratio, u_lo);
        const float f_hi = f_min * std::pow(ratio, u_hi);
        const float i_lo = f_lo / hzPerBin;
        const float i_hi = f_hi / hzPerBin;

        // Pull the linear-magnitude value: interpolate when the slice is narrower
        // than one bin (low frequencies), take the max otherwise (high freq, wide
        // slice) so transient peaks aren't averaged into mush.
        float v_lin;
        if (i_hi - i_lo < 1.0f) {
            const float i_mid = 0.5f * (i_lo + i_hi);
            int32_t b0 = static_cast<int32_t>(std::floor(i_mid));
            if (b0 < 0) b0 = 0;
            if (b0 > lastBin) b0 = lastBin;
            int32_t b1 = b0 + 1;
            if (b1 > lastBin) b1 = lastBin;
            const float frac = i_mid - static_cast<float>(b0);
            v_lin = in[b0] * (1.0f - frac) + in[b1] * frac;
        } else {
            int32_t b0 = static_cast<int32_t>(std::floor(i_lo));
            int32_t b1 = static_cast<int32_t>(std::ceil(i_hi)) - 1;
            if (b0 < 0) b0 = 0;
            if (b0 > lastBin) b0 = lastBin;
            if (b1 < b0) b1 = b0;
            if (b1 > lastBin) b1 = lastBin;
            float m = in[b0];
            for (int32_t j = b0 + 1; j <= b1; ++j) {
                if (in[j] > m) m = in[j];
            }
            v_lin = m;
        }

        // dB conversion + perceptual +3 dB/oct compensation (centred on 1 kHz).
        // Pink-noise programme material slopes ≈ -3 dB/oct; without this lift
        // treble bars permanently hug the floor.
        const float f_center = std::sqrt(f_lo * f_hi);
        float db = 20.0f * std::log10(v_lin > eps ? v_lin : eps);
        db += 3.0f * std::log2(f_center / 1000.0f);
        float v01 = (db - db_floor) / db_range;
        if (v01 < 0.0f) v01 = 0.0f;
        if (v01 > 1.0f) v01 = 1.0f;

        // Asymmetric attack/release — fast up, slow down.
        float s = state[k];
        const float coef = (v01 > s) ? a_atk : a_rel;
        s += (v01 - s) * coef;
        state[k] = s;
        out[k] = s;

        // Peak cap: snap to the new high, hold, then fall at a constant rate.
        // Never below the live bar value — the cap tracks the bar if it catches.
        float p = peaks[k];
        float hold = state[outCount + k];
        if (v01 >= p) {
            p = v01;
            hold = peak_hold;
        } else if (hold > 0.0f) {
            hold -= dt;
        } else {
            p -= peak_fall * dt;
            if (p < s) p = s;
            if (p < 0.0f) p = 0.0f;
        }
        peaks[k] = p;
        state[outCount + k] = hold;
    }
}

extern "C" void vk_scope_prepare(const float *in,
                                 uint32_t inCount,
                                 float *out,
                                 uint32_t outCount,
                                 float gain) {
    if (!in || !out || inCount == 0 || outCount == 0) return;

    // 1) DC removal — subtract the per-window mean so the trace stays centred
    //    even when the source has bias.
    double sum = 0.0;
    for (uint32_t i = 0; i < inCount; ++i) sum += in[i];
    const float mean = static_cast<float>(sum / static_cast<double>(inCount));

    // 2) Schmitt-trigger zero-crossing search: positive slope, ±hysteresis
    //    deadband around 0 so noise riding on the signal can't re-trigger.
    //    Search window is [inCount/4, inCount - outCount] so we always have
    //    at least `outCount` samples after the trigger.
    constexpr float hysteresis = 0.02f;
    const uint32_t leading = inCount / 4u;
    const uint32_t searchEnd = (outCount < inCount) ? (inCount - outCount) : leading;
    uint32_t trigger = leading;
    bool armed = false;   // becomes true once we've seen the signal dip below -h
    for (uint32_t i = leading; i < searchEnd; ++i) {
        const float v = in[i] - mean;
        if (!armed) {
            if (v < -hysteresis) armed = true;
        } else {
            if (v >= hysteresis) {  // positive-side crossing past the deadband
                trigger = i;
                break;
            }
        }
    }

    // 3) Copy the slice [trigger, trigger+outCount) into `out`, DC-removed,
    //    gain-applied, soft-limited so the trace never escapes [-1, 1].
    for (uint32_t i = 0; i < outCount; ++i) {
        const uint32_t src = trigger + i;
        const float x = (src < inCount ? in[src] : in[inCount - 1]) - mean;
        const float y = std::tanh(x * gain);
        out[i] = y;
    }
}

extern "C" const char *vk_build_id(void) {
    return "VisualizerKernels/2.0";
}
