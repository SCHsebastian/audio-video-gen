#ifndef VISUALIZER_KERNELS_H
#define VISUALIZER_KERNELS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Fill `out_xy` (length = `count`*2) with a Lissajous curve in [-1, 1]^2.
/// `t` is animation time in seconds. `a`, `b` are angular frequencies, `delta` is the
/// phase difference. The kernel applies a small audio-reactive radial pulse via `rms`.
void vk_lissajous(float *out_xy,
                  uint32_t count,
                  float t,
                  float a,
                  float b,
                  float delta,
                  float rms);

/// Fill `out_xy` (length = `count`*2) with a polar rose curve r = cos(petals * theta)
/// scaled by `1 + rms`. `t` rotates the figure slowly.
void vk_rose(float *out_xy,
             uint32_t count,
             float t,
             int32_t petals,
             float rms);

/// Catmull-Rom subdivision of an XY polyline. Given `inCount` 2D control points in
/// `in_xy` (length = inCount*2), produces `(inCount-3)*subdivs + 1` evenly-spaced
/// curve samples in `out_xy` (length must be `(inCount-3)*subdivs + 1` pairs).
/// Used by Lissajous to smooth the parametric trace into a continuous "phosphor"
/// curve before per-pixel SDF rendering.
void vk_catmull_rom(const float *in_xy,
                    uint32_t inCount,
                    float *out_xy,
                    uint32_t subdivs);

/// Canonical bars-spectrum kernel.
///
/// Input: `in[inCount]` is a linear-frequency FFT magnitude band array (typically
/// 64 bands covering [0, sampleRate/2]).
///
/// Output: `out[outCount]` are normalized bar heights in [0, 1] (post log-frequency
/// rebinning, dB scaling, perceptual +3 dB/oct slope, and asymmetric attack/release
/// smoothing). `peaks[outCount]` are the floating peak-cap positions.
///
/// `state` is caller-owned scratch of length `2*outCount` (initialise to zero):
/// the first `outCount` floats hold the per-bar smoothing state, the next
/// `outCount` hold the per-bar peak-hold timers.
///
/// `dt` is the frame interval in seconds. `sampleRate` is the audio sample rate
/// (Hz, e.g. 48000).
void vk_bars_process(const float *in,
                     uint32_t inCount,
                     float *out,
                     uint32_t outCount,
                     float *state,
                     float *peaks,
                     float sampleRate,
                     float dt);

/// Canonical oscilloscope pre-processor.
///
/// `in[inCount]` is a window of PCM samples in [-1, 1]; typically 1024.
/// `out[outCount]` receives `outCount` samples (typically 512) sliced from `in`
/// starting at the first positive-going zero-crossing past `inCount/4` (Schmitt
/// trigger with `±hysteresis` deadband). DC is removed before the slice so the
/// trace doesn't drift vertically. `gain` is multiplied in after triggering.
///
/// The trigger-sync is what makes a sustained tone hold still on the display
/// instead of jittering like jelly.
void vk_scope_prepare(const float *in,
                      uint32_t inCount,
                      float *out,
                      uint32_t outCount,
                      float gain);

/// Returns the build identifier of the kernels library. Used as a smoke-test that
/// the C++ target is linked in. Caller must NOT free the returned pointer.
const char *vk_build_id(void);

#ifdef __cplusplus
}
#endif

#endif
