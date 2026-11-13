#include "UntunnelKernels.h"

#include <math.h>
#include <stdint.h>
#include <string.h>

typedef float lanes_t __attribute__((vector_size(UNTUNNEL_SCAN_STATES * sizeof(float))));
typedef uint32_t bits_t __attribute__((vector_size(UNTUNNEL_SCAN_STATES * sizeof(uint32_t))));

static inline lanes_t load(const float *source) {
    lanes_t value;
    memcpy(&value, source, sizeof value);
    return value;
}

static inline void store(float *destination, lanes_t value) {
    memcpy(destination, &value, sizeof value);
}

static inline lanes_t splat(float value) {
    return value - (lanes_t){0};
}

// The sum of the lanes, pairwise, so it stays vector arithmetic until the last two.
static inline float total(lanes_t value) {
    typedef float half_t __attribute__((vector_size(8 * sizeof(float))));
    typedef float quarter_t __attribute__((vector_size(4 * sizeof(float))));
    half_t eight = __builtin_shufflevector(value, value, 0, 1, 2, 3, 4, 5, 6, 7)
                   + __builtin_shufflevector(value, value, 8, 9, 10, 11, 12, 13, 14, 15);
    quarter_t four = __builtin_shufflevector(eight, eight, 0, 1, 2, 3)
                     + __builtin_shufflevector(eight, eight, 4, 5, 6, 7);
    return (four[0] + four[2]) + (four[1] + four[3]);
}

// 2^t for t in -126...127: t = n + f with |f| <= 1/2, a degree-six polynomial for 2^f fitted
// at Chebyshev nodes (2 * 10^-7 from exact in single precision), and 2^n written straight
// into an exponent field. Adding 1.5 * 2^23 rounds to an integer and leaves it in the low
// mantissa bits, which is where n is read from. A library call per 256 values costs more than
// this arithmetic.
static inline lanes_t power_of_two(lanes_t t) {
    const float rounding = 12582912.0f;
    const uint32_t rounding_mantissa = 0x400000, exponent_bias = 127;
    lanes_t shifted = t + rounding;
    lanes_t f = t - (shifted - rounding);

    lanes_t series = splat(1.5461444854736328e-4f);
    series = series * f + 1.3400427997112274e-3f;
    series = series * f + 9.618056938052177e-3f;
    series = series * f + 5.550327152013779e-2f;
    series = series * f + 2.4022650718688965e-1f;
    series = series * f + 6.931471824645996e-1f;
    series = series * f + 1.0f;

    bits_t scale = ((bits_t)shifted + (exponent_bias - rounding_mantissa)) << 23;
    return series * (lanes_t)scale;
}

static inline lanes_t exponential(lanes_t x) {
    const float log2_e = 1.44269504f;
    lanes_t t = x * log2_e;
    return power_of_two(
        __builtin_elementwise_min(__builtin_elementwise_max(t, splat(-126.0f)), splat(127.0f)));
}

void untunnel_exp(float *values, size_t count) {
    for (size_t index = 0; index < count; index += UNTUNNEL_SCAN_STATES) {
        store(values + index, exponential(load(values + index)));
    }
}

void untunnel_silu(float *values, size_t count) {
    for (size_t index = 0; index < count; index += UNTUNNEL_SCAN_STATES) {
        lanes_t x = load(values + index);
        store(values + index, x / (1.0f + exponential(-x)));
    }
}

void untunnel_scan_step(const float *restrict step, const float *restrict driven,
                        const float *restrict decay, const float *restrict mix,
                        float *restrict state, float *restrict sum, size_t channels) {
    const lanes_t drive = load(mix);
    const lanes_t read = load(mix + UNTUNNEL_SCAN_STATES);
    for (size_t channel = 0; channel < channels; channel++) {
        const size_t offset = channel * UNTUNNEL_SCAN_STATES;
        lanes_t t = __builtin_elementwise_max(load(decay + offset) * step[channel],
                                              splat(-126.0f));
        lanes_t next = power_of_two(t) * load(state + offset) + drive * driven[channel];
        store(state + offset, next);
        sum[channel] += total(next * read);
    }
}

void untunnel_prelu(float *restrict values, const float *restrict slope_below_unity,
                    size_t width, size_t rows) {
    for (size_t row = 0; row < rows; row++) {
        float *channels = values + row * width;
        for (size_t channel = 0; channel < width; channel++) {
            const float x = channels[channel];
            channels[channel] = x + slope_below_unity[channel] * (x < 0.0f ? x : 0.0f);
        }
    }
}

void untunnel_layer_norm(float *restrict values, const float *restrict scale,
                         const float *restrict shift, float epsilon, size_t width,
                         size_t rows) {
    for (size_t row = 0; row < rows; row++) {
        float *channels = values + row * width;
        lanes_t sum = splat(0.0f);
        for (size_t index = 0; index < width; index += UNTUNNEL_SCAN_STATES) {
            sum += load(channels + index);
        }
        const float mean = total(sum) / (float)width;

        lanes_t squares = splat(0.0f);
        for (size_t index = 0; index < width; index += UNTUNNEL_SCAN_STATES) {
            lanes_t centred = load(channels + index) - mean;
            squares += centred * centred;
        }
        const float gain = 1.0f / sqrtf(total(squares) / (float)width + epsilon);

        for (size_t index = 0; index < width; index += UNTUNNEL_SCAN_STATES) {
            lanes_t centred = load(channels + index) - mean;
            store(channels + index, centred * gain * load(scale + index) + load(shift + index));
        }
    }
}
