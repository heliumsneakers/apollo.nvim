// cosine_simd.c
#include "cosine_simd.h"
#include <math.h>
#include <stdint.h>

#if defined(__ARM_NEON) || defined(__ARM_NEON__)
    #include <arm_neon.h>
#elif defined(__AVX512F__)
    #include <immintrin.h>
#elif defined(__AVX2__)
    #include <immintrin.h>
#endif
/* 
 *  Instead of my original implementation of the cosine distance function, I've decided to try doing a fast inverse square root
 *  implementation to normalize the Vector utilizing the Newtown-Raphson iteration method to gain more speed for a .01%-.02%
 *  error range. Instead of the Cosine Distance function we take the dot product since the vectors are normalized.
 *
 *  The math and SIMD in this file are heavily inspired by Quake3 Fast Inverse Square Root, and Casey Muratori's 
 *  "Simple Code High Performance". Details explaining the speedup can be found below.
 */

#ifndef restrict
#define restrict __restrict
#endif


#if defined(__ARM_NEON) || defined(__ARM_NEON__)

void f32_dot_product_simd(const float *x, const float *y, double *result, uint64_t size) {
    float32x4_t sum_v = vmovq_n_f32(0.0f);
    uint64_t i = 0;
    for (; i + 4 <= size; i += 4) {
        float32x4_t vx = vld1q_f32(x + i);
        float32x4_t vy = vld1q_f32(y + i);
        sum_v = vmlaq_f32(sum_v, vx, vy);
    }
    float sum = vaddvq_f32(sum_v);
    for (; i < size; i++) sum += x[i] * y[i];
    *result = (double)sum;
}

void norm_simd(float *v, uint32_t d) {
    float32x4_t sum4 = vmovq_n_f32(0.0f);
    uint32_t i = 0;
    for (; i + 4 <= d; i += 4) {
        float32x4_t x = vld1q_f32(v + i);
        sum4 = vmlaq_f32(sum4, x, x);
    }
    float sum = vaddvq_f32(sum4);
    for (; i < d; i++) sum += v[i] * v[i];
    float32x4_t s4 = vdupq_n_f32(sum);
    float32x4_t y = vrsqrteq_f32(s4);
    y = vmulq_f32(y, vrsqrtsq_f32(vmulq_f32(s4, vmulq_f32(y, y)), y));
    y = vmulq_f32(y, vrsqrtsq_f32(vmulq_f32(s4, vmulq_f32(y, y)), y));
    float inv_norm = vgetq_lane_f32(y, 0);
    float32x4_t scale4 = vdupq_n_f32(inv_norm);
    for (i = 0; i + 4 <= d; i += 4) {
        float32x4_t x = vld1q_f32(v + i);
        vst1q_f32(v + i, vmulq_f32(x, scale4));
    }
    for (; i < d; i++) v[i] *= inv_norm;
}

#elif defined(__AVX512F__)

static inline float hsum512_ps(__m512 v) {
    __m256 lo = _mm512_castps512_ps256(v);
    __m256 hi = _mm512_extractf32x8_ps(v, 1);
    __m256 sum256 = _mm256_add_ps(lo, hi);
    __m128 lo128 = _mm256_castps256_ps128(sum256);
    __m128 hi128 = _mm256_extractf128_ps(sum256, 1);
    __m128 sum128 = _mm_add_ps(lo128, hi128);
    sum128 = _mm_hadd_ps(sum128, sum128);
    sum128 = _mm_hadd_ps(sum128, sum128);
    return _mm_cvtss_f32(sum128);
}

void f32_dot_product_simd(const float *x, const float *y, double *result, uint64_t size) {
    uint64_t i = 0;
    __m512 acc = _mm512_setzero_ps();
    for (; i + 16 <= size; i += 16) {
        __m512 vx = _mm512_loadu_ps(x + i);
        __m512 vy = _mm512_loadu_ps(y + i);
        acc = _mm512_fmadd_ps(vx, vy, acc);
    }
    float sum = hsum512_ps(acc);
    for (; i < size; i++) sum += x[i] * y[i];
    *result = (double)sum;
}

void norm_simd(float *v, uint32_t d) {
    __m512 acc = _mm512_setzero_ps();
    uint32_t i = 0;
    for (; i + 16 <= d; i += 16) {
        __m512 x = _mm512_loadu_ps(v + i);
        acc = _mm512_fmadd_ps(x, x, acc);
    }
    float sum = hsum512_ps(acc);
    for (; i < d; i++) sum += v[i] * v[i];
    if (sum == 0.0f) return;

    __m512 s = _mm512_set1_ps(sum);
    __m512 y = _mm512_rsqrt14_ps(s);
    const __m512 half = _mm512_set1_ps(0.5f);
    const __m512 three = _mm512_set1_ps(3.0f);
    __m512 y2 = _mm512_mul_ps(y, y);
    y = _mm512_mul_ps(y, _mm512_mul_ps(_mm512_sub_ps(three, _mm512_mul_ps(s, _mm512_mul_ps(y2, half))), half));
    y2 = _mm512_mul_ps(y, y);
    y = _mm512_mul_ps(y, _mm512_mul_ps(_mm512_sub_ps(three, _mm512_mul_ps(s, _mm512_mul_ps(y2, half))), half));
    float inv_norm = _mm_cvtss_f32(_mm256_castps256_ps128(_mm512_castps512_ps256(y)));

    __m512 scale = _mm512_set1_ps(inv_norm);
    i = 0;
    for (; i + 16 <= d; i += 16) {
        __m512 x = _mm512_loadu_ps(v + i);
        _mm512_storeu_ps(v + i, _mm512_mul_ps(x, scale));
    }
    for (; i < d; i++) v[i] *= inv_norm;
}


#elif defined(__AVX2__)

static inline float hsum256_ps(__m256 v) {
    __m128 lo = _mm256_castps256_ps128(v);
    __m128 hi = _mm256_extractf128_ps(v, 1);
    __m128 sum = _mm_add_ps(lo, hi);
    sum = _mm_hadd_ps(sum, sum);
    sum = _mm_hadd_ps(sum, sum);
    return _mm_cvtss_f32(sum);
}

void f32_dot_product_simd(const float *x, const float *y, double *result, uint64_t size) {
    uint64_t i = 0;
    __m256 acc = _mm256_setzero_ps();
    for (; i + 8 <= size; i += 8) {
        __m256 vx = _mm256_loadu_ps(x + i);
        __m256 vy = _mm256_loadu_ps(y + i);
        acc = _mm256_fmadd_ps(vx, vy, acc);
    }
    float sum = hsum256_ps(acc);
    for (; i < size; i++) sum += x[i] * y[i];
    *result = (double)sum;
}

void norm_simd(float *v, uint32_t d) {
    uint32_t i = 0;
    __m256 acc = _mm256_setzero_ps();
    for (; i + 8 <= d; i += 8) {
        __m256 x = _mm256_loadu_ps(v + i);
        acc = _mm256_fmadd_ps(x, x, acc);
    }
    float sum = hsum256_ps(acc);
    for (; i < d; i++) sum += v[i] * v[i];
    if (sum == 0.0f) return;

    __m256 s = _mm256_set1_ps(sum);
    __m256 y = _mm256_rsqrt_ps(s);
    const __m256 half = _mm256_set1_ps(0.5f);
    const __m256 three = _mm256_set1_ps(3.0f);
    __m256 y2 = _mm256_mul_ps(y, y);
    __m256 t = _mm256_sub_ps(three, _mm256_mul_ps(s, _mm256_mul_ps(y2, half)));
    y = _mm256_mul_ps(y, _mm256_mul_ps(t, half));
    y2 = _mm256_mul_ps(y, y);
    t = _mm256_sub_ps(three, _mm256_mul_ps(s, _mm256_mul_ps(y2, half)));
    y = _mm256_mul_ps(y, _mm256_mul_ps(t, half));
    float inv_norm = _mm_cvtss_f32(_mm256_castps256_ps128(y));

    __m256 scale = _mm256_set1_ps(inv_norm);
    i = 0;
    for (; i + 8 <= d; i += 8) {
        __m256 x = _mm256_loadu_ps(v + i);
        _mm256_storeu_ps(v + i, _mm256_mul_ps(x, scale));
    }
    for (; i < d; i++) v[i] *= inv_norm;
}


#else

void f32_dot_product_simd(const float *x, const float *y, double *result, uint64_t size) {
    double sum = 0.0;
    for (uint64_t i = 0; i < size; i++) sum += (double)x[i] * (double)y[i];
    *result = sum;
}

void norm_simd(float *v, uint32_t d) {
    float sum = 0.0f;
    for (uint32_t i = 0; i < d; i++) sum += v[i] * v[i];
    if (sum == 0.0f) return;
    float inv = 1.0f / sqrtf(sum);
    for (uint32_t i = 0; i < d; i++) v[i] *= inv;
}

#endif

/*  Why the above code is faster even though it has ~40 more ASM instructions:
 *      1) In the cosine distance function we have 3 vector accumulations per lane, comparative to the NEON intrinsics 
 *         approx reciprocal-sqrt -> single vmlaq per lane.
 *
 *      2) The big one calling sqrtf() TWICE :/ slowing the vector op speedups we gained anyways,
 *         this is of course also skipped using the approx reciprocal-sqrt and then just a simple scaling 
 *         of the vectors and getting the dot product. All adds and multiplys pretty much :) 
 *  */

// void f32_cosine_distance_neon(
//     const float *x,
//     const float *y,
//     double      *result,
//     const uint64_t size
// ) {
//     // vector accumulators
//     float32x4_t sum_xy_v = vmovq_n_f32(0.0f);
//     float32x4_t sum_xx_v = vmovq_n_f32(0.0f);
//     float32x4_t sum_yy_v = vmovq_n_f32(0.0f);
//
//     uint64_t i = 0;
//     // main loop, 4 floats per iteration
//     for (; i + 4 <= size; i += 4) {
//         float32x4_t vx = vld1q_f32(x + i);
//         float32x4_t vy = vld1q_f32(y + i);
//
//         // sum_xy_v += vx * vy
//         sum_xy_v = vmlaq_f32(sum_xy_v, vx, vy);
//         // sum_xx_v += vx * vx
//         sum_xx_v = vmlaq_f32(sum_xx_v, vx, vx);
//         // sum_yy_v += vy * vy
//         sum_yy_v = vmlaq_f32(sum_yy_v, vy, vy);
//     }
//
//     // horizontal add of vector accumulators
//     float sum_xy = vaddvq_f32(sum_xy_v);
//     float sum_xx = vaddvq_f32(sum_xx_v);
//     float sum_yy = vaddvq_f32(sum_yy_v);
//
//     // tail loop for remaining elements
//     for (; i < size; i++) {
//         float xi = x[i];
//         float yi = y[i];
//         sum_xy += xi * yi;
//         sum_xx += xi * xi;
//         sum_yy += yi * yi;
//     }
//
//     // final cosine-distance calculation
//     float denom = sqrtf(sum_xx) * sqrtf(sum_yy);
//     if (denom == 0.0f) {
//         *result = 0.0;
//     } else {
//         *result = (double)(sum_xy / denom);
//     }
// }
