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

/// Post-process a raw spectrum into displayed bar heights with perceptual scaling,
/// attack-fast / release-slow smoothing and a per-bar peak-decay envelope.
/// `state` is caller-owned scratch of length `count` and persists across calls
/// (initialise to zero). `beat` adds a brief overall lift on transients.
/// `in`/`out` have length `count`. `dt` is the frame interval in seconds.
void vk_bars_process(const float *in,
                     float *out,
                     float *state,
                     uint32_t count,
                     float dt,
                     float beat);

/// Smooth and shape an oscilloscope tail into a glow-friendly envelope.
/// Applies a small 3-tap low-pass, a soft non-linear gain (tanh-style) and a
/// gentle high-pass to remove DC, then writes `count` samples in `out`.
/// `gain` is the input amplitude scale (use 1.0 to start). In/out may not alias.
void vk_scope_envelope(const float *in,
                       float *out,
                       uint32_t count,
                       float gain);

/// Returns the build identifier of the kernels library. Used as a smoke-test that
/// the C++ target is linked in. Caller must NOT free the returned pointer.
const char *vk_build_id(void);

#ifdef __cplusplus
}
#endif

#endif
