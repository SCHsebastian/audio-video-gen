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

/// Returns the build identifier of the kernels library. Used as a smoke-test that
/// the C++ target is linked in. Caller must NOT free the returned pointer.
const char *vk_build_id(void);

#ifdef __cplusplus
}
#endif

#endif
