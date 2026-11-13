#ifndef UNTUNNEL_KERNELS_H
#define UNTUNNEL_KERNELS_H

#include <stdbool.h>
#include <stddef.h>

/// The inner loops of the real-time model. Every `count` is a multiple of sixteen, and no
/// function allocates, which is why the matrix product is here: the system's allocates a
/// buffer on every call.

/// The lanes of one channel's state, and the width every loop here works at.
enum { UNTUNNEL_SCAN_STATES = 16 };

/// `exp(x)` in place, with `x` clamped to what a normal single-precision result can hold.
/// The relative error stays under `4e-7 + 1e-7 * |x|`.
void untunnel_exp(float *values, size_t count);

/// `x * sigmoid(x)` in place.
void untunnel_silu(float *values, size_t count);

/// One step of the selective-scan recurrence for one sequence of `channels` channels:
///
///     h[c][s] = 2^(step[c] * decay[c][s]) * h[c][s] + driven[c] * drive[s]
///     sum[c] += h[c] . read
///
/// `decay` is the decay rate times `log2(e)` and never positive, and `step` never negative.
/// `decay` and `state` hold sixteen lanes per channel; `mix` is `drive` then `read`.
void untunnel_scan_step(const float *step, const float *driven, const float *decay,
                        const float *mix, float *state, float *sum, size_t channels);

/// Layer normalisation in place over rows of `width` values, a multiple of sixteen: each row
/// loses its mean, is divided by `sqrt(biased variance + epsilon)`, then scaled and shifted
/// per channel.
void untunnel_layer_norm(float *values, const float *scale, const float *shift, float epsilon,
                         size_t width, size_t rows);

/// `x + slope_below_unity * min(x, 0)` in place over rows of `width` values, which is PReLU
/// with `slope_below_unity = slope - 1` per channel.
void untunnel_prelu(float *values, const float *slope_below_unity, size_t width, size_t rows);

/// `out[rows][columns] = a[rows][depth] . b[depth][columns]`, added to what `out` holds when
/// `accumulate`. Rows of `a` start `a_stride` values apart and rows of `out` `out_stride`
/// apart, so either may be a window into wider rows; `b` is contiguous.
///
/// Every output is summed over `depth` in order with fused multiply-adds, so the result does
/// not depend on which of the two implementations ran. Where the processor has a matrix unit
/// the product runs on it. A cluster of cores shares one unit, so calls from several threads
/// at once take turns: call it from one thread per frame.
void untunnel_matmul(const float *a, size_t a_stride, const float *b, size_t columns,
                     float *out, size_t out_stride, size_t rows, size_t depth, bool accumulate);

/// The same product on ordinary vector registers, which any thread may run at any time.
void untunnel_matmul_portable(const float *a, size_t a_stride, const float *b, size_t columns,
                              float *out, size_t out_stride, size_t rows, size_t depth,
                              bool accumulate);

/// Whether `untunnel_matmul` runs on a matrix unit on this machine.
bool untunnel_has_matrix_unit(void);

#endif
