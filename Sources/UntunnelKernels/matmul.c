#include "UntunnelKernels.h"

#include <string.h>

typedef float lanes_t __attribute__((vector_size(UNTUNNEL_SCAN_STATES * sizeof(float))));

static inline lanes_t load(const float *source) {
    lanes_t value;
    memcpy(&value, source, sizeof value);
    return value;
}

static inline void store(float *destination, lanes_t value) {
    memcpy(destination, &value, sizeof value);
}

// As much of `b` as stays in the first-level cache while every row of `a` is run against it.
enum { DEPTH_BLOCK = 96 };

void untunnel_matmul_portable(const float *restrict a, size_t a_stride, const float *restrict b,
                              size_t columns, float *restrict out, size_t out_stride,
                              size_t rows, size_t depth, bool accumulate) {
    if (!accumulate) {
        for (size_t row = 0; row < rows; row++) {
            memset(out + row * out_stride, 0, columns * sizeof(float));
        }
    }
    const size_t whole = columns - columns % UNTUNNEL_SCAN_STATES;
    for (size_t first = 0; first < depth; first += DEPTH_BLOCK) {
        const size_t end = first + DEPTH_BLOCK < depth ? first + DEPTH_BLOCK : depth;
        for (size_t row = 0; row < rows; row++) {
            const float *input = a + row * a_stride;
            float *sums = out + row * out_stride;
            for (size_t column = 0; column < whole; column += UNTUNNEL_SCAN_STATES) {
                lanes_t sum = load(sums + column);
                for (size_t index = first; index < end; index++) {
                    sum += load(b + index * columns + column) * input[index];
                }
                store(sums + column, sum);
            }
            for (size_t column = whole; column < columns; column++) {
                float sum = sums[column];
                for (size_t index = first; index < end; index++) {
                    sum = __builtin_fmaf(b[index * columns + column], input[index], sum);
                }
                sums[column] = sum;
            }
        }
    }
}

#if defined(__aarch64__) && defined(__APPLE__)

#include <stdint.h>
#include <sys/sysctl.h>

// The declarations of <arm_sme.h> this file uses. The header itself cannot be included: the
// package compiles C with modules, and the header's module needs the whole file built for
// the extension, which takes a flag a package manifest may not carry.
typedef __SVBool_t svbool_t;
typedef __SVFloat32_t svfloat32_t;
#define MATRIX_INTRINSIC(builtin)                                                               \
    static inline __attribute__((always_inline, __clang_arm_builtin_alias(builtin)))
MATRIX_INTRINSIC(__builtin_sve_svwhilelt_b32_u64) svbool_t svwhilelt_b32_u64(uint64_t, uint64_t);
MATRIX_INTRINSIC(__builtin_sve_svdup_n_f32) svfloat32_t svdup_n_f32(float);
MATRIX_INTRINSIC(__builtin_sve_svld1_f32) svfloat32_t svld1_f32(svbool_t, const float *);
MATRIX_INTRINSIC(__builtin_sve_svzip1_f32) svfloat32_t svzip1_f32(svfloat32_t, svfloat32_t);
MATRIX_INTRINSIC(__builtin_sve_svzip2_f32) svfloat32_t svzip2_f32(svfloat32_t, svfloat32_t);
MATRIX_INTRINSIC(__builtin_sme_svzero_za) void svzero_za(void);
MATRIX_INTRINSIC(__builtin_sme_svld1_hor_za32)
void svld1_hor_za32(uint64_t, uint32_t, svbool_t, const void *);
MATRIX_INTRINSIC(__builtin_sme_svst1_hor_za32)
void svst1_hor_za32(uint64_t, uint32_t, svbool_t, void *);
MATRIX_INTRINSIC(__builtin_sme_svmopa_za32_f32_m)
void svmopa_za32_f32_m(uint64_t, svbool_t, svbool_t, svfloat32_t, svfloat32_t);

// The loop below is written for the sixteen lanes of a 512-bit vector, the only length the
// processors with a matrix unit have so far; another length takes the portable loop.
enum { MATRIX_LANES = 16 };

// One round of the perfect shuffle: sixteen vectors named `from0` to `from15` become `to0`
// to `to15`. Four rounds turn sixteen rows of sixteen values into their sixteen columns.
#define SHUFFLE(to, from)                                                                       \
    const svfloat32_t to##0 = svzip1_f32(from##0, from##8), to##1 = svzip2_f32(from##0, from##8), \
        to##2 = svzip1_f32(from##1, from##9), to##3 = svzip2_f32(from##1, from##9),             \
        to##4 = svzip1_f32(from##2, from##10), to##5 = svzip2_f32(from##2, from##10),           \
        to##6 = svzip1_f32(from##3, from##11), to##7 = svzip2_f32(from##3, from##11),           \
        to##8 = svzip1_f32(from##4, from##12), to##9 = svzip2_f32(from##4, from##12),           \
        to##10 = svzip1_f32(from##5, from##13), to##11 = svzip2_f32(from##5, from##13),         \
        to##12 = svzip1_f32(from##6, from##14), to##13 = svzip2_f32(from##6, from##14),         \
        to##14 = svzip1_f32(from##7, from##15), to##15 = svzip2_f32(from##7, from##15)

#define FOR_EACH_LANE(DO)                                                                       \
    DO(0) DO(1) DO(2) DO(3) DO(4) DO(5) DO(6) DO(7) DO(8) DO(9) DO(10) DO(11) DO(12) DO(13)     \
    DO(14) DO(15)

// The four tiles accumulate four vectors of output columns for one vector of rows. An outer
// product wants a column of `a`, which a row-major matrix does not hold in one place, so each
// sixteen-by-sixteen block of `a` is loaded by rows and shuffled into columns in registers;
// nothing is packed into memory first.
__attribute__((target("sme"), noinline))
static void matmul_streaming(const float *restrict a, size_t a_stride, const float *restrict b,
                             size_t columns, float *restrict out, size_t out_stride,
                             size_t rows, size_t depth, bool accumulate)
    __arm_streaming __arm_inout("za") {
    const size_t lanes = MATRIX_LANES;
    for (size_t first_row = 0; first_row < rows; first_row += lanes) {
        const svbool_t in_rows = svwhilelt_b32_u64(first_row, rows);
        const uint32_t row_count =
            (uint32_t)(rows - first_row < lanes ? rows - first_row : lanes);
        for (size_t column = 0; column < columns; column += 4 * lanes) {
            const svbool_t in_first = svwhilelt_b32_u64(column, columns);
            const svbool_t in_second = svwhilelt_b32_u64(column + lanes, columns);
            const svbool_t in_third = svwhilelt_b32_u64(column + 2 * lanes, columns);
            const svbool_t in_fourth = svwhilelt_b32_u64(column + 3 * lanes, columns);
            if (accumulate) {
                for (uint32_t row = 0; row < row_count; row++) {
                    const float *sums = out + (first_row + row) * out_stride + column;
                    svld1_hor_za32(0, row, in_first, sums);
                    svld1_hor_za32(1, row, in_second, sums + lanes);
                    svld1_hor_za32(2, row, in_third, sums + 2 * lanes);
                    svld1_hor_za32(3, row, in_fourth, sums + 3 * lanes);
                }
            } else {
                svzero_za();
            }
            for (size_t first = 0; first < depth; first += lanes) {
                const svbool_t in_depth = svwhilelt_b32_u64(first, depth);
                const uint32_t depth_count =
                    (uint32_t)(depth - first < lanes ? depth - first : lanes);
                const float *block = a + first_row * a_stride + first;
#define LOAD_ROW(i)                                                                             \
    const svfloat32_t row##i =                                                                  \
        i < row_count ? svld1_f32(in_depth, block + i * a_stride) : svdup_n_f32(0);
                FOR_EACH_LANE(LOAD_ROW)
                SHUFFLE(pair, row);
                SHUFFLE(quad, pair);
                SHUFFLE(octet, quad);
                SHUFFLE(inputs, octet);
#define ADD_OUTER_PRODUCT(i)                                                                    \
    if (i < depth_count) {                                                                      \
        const float *weights = b + (first + i) * columns + column;                              \
        svmopa_za32_f32_m(0, in_rows, in_first, inputs##i, svld1_f32(in_first, weights));       \
        svmopa_za32_f32_m(1, in_rows, in_second, inputs##i,                                     \
                          svld1_f32(in_second, weights + lanes));                               \
        svmopa_za32_f32_m(2, in_rows, in_third, inputs##i,                                      \
                          svld1_f32(in_third, weights + 2 * lanes));                            \
        svmopa_za32_f32_m(3, in_rows, in_fourth, inputs##i,                                     \
                          svld1_f32(in_fourth, weights + 3 * lanes));                           \
    }
                FOR_EACH_LANE(ADD_OUTER_PRODUCT)
            }
            for (uint32_t row = 0; row < row_count; row++) {
                float *sums = out + (first_row + row) * out_stride + column;
                svst1_hor_za32(0, row, in_first, sums);
                svst1_hor_za32(1, row, in_second, sums + lanes);
                svst1_hor_za32(2, row, in_third, sums + 2 * lanes);
                svst1_hor_za32(3, row, in_fourth, sums + 3 * lanes);
            }
        }
    }
}

__attribute__((target("sme"), noinline)) __arm_locally_streaming __arm_new("za")
static void matmul_with_matrix_unit(const float *a, size_t a_stride, const float *b,
                                    size_t columns, float *out, size_t out_stride,
                                    size_t rows, size_t depth, bool accumulate) {
    matmul_streaming(a, a_stride, b, columns, out, out_stride, rows, depth, accumulate);
}

static bool has_matrix_unit;

__attribute__((constructor))
static void find_matrix_unit(void) {
    int present = 0;
    int vector_bytes = 0;
    size_t size = sizeof present;
    has_matrix_unit =
        sysctlbyname("hw.optional.arm.FEAT_SME", &present, &size, NULL, 0) == 0 && present
        && sysctlbyname("hw.optional.arm.sme_max_svl_b", &vector_bytes, &size, NULL, 0) == 0
        && vector_bytes == MATRIX_LANES * sizeof(float);
}

bool untunnel_has_matrix_unit(void) {
    return has_matrix_unit;
}

void untunnel_matmul(const float *a, size_t a_stride, const float *b, size_t columns,
                     float *out, size_t out_stride, size_t rows, size_t depth,
                     bool accumulate) {
    if (has_matrix_unit) {
        matmul_with_matrix_unit(a, a_stride, b, columns, out, out_stride, rows, depth,
                                accumulate);
    } else {
        untunnel_matmul_portable(a, a_stride, b, columns, out, out_stride, rows, depth,
                                 accumulate);
    }
}

#else

bool untunnel_has_matrix_unit(void) {
    return false;
}

void untunnel_matmul(const float *a, size_t a_stride, const float *b, size_t columns,
                     float *out, size_t out_stride, size_t rows, size_t depth,
                     bool accumulate) {
    untunnel_matmul_portable(a, a_stride, b, columns, out, out_stride, rows, depth, accumulate);
}

#endif
