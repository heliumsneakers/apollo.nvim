// cosine_neon.c
#include <stdint.h>
#include <math.h>
#include <arm_neon.h>

/* 
 *  Instead of my original implementation of the cosine distance function, I've decided to try doing a fast inverse square root
 *  implementation to normalize the Vector utilizing the Newtown-Raphson iteration method to gain more speed for a .01%-.02%
 *  error range. Instead of the Cosine Distance function we take the dot product since the vectors are normalized.
 *
 *  The math and SIMD in this file are heavily inspired by Quake3 Fast Inverse Square Root, and Casey Muratori's 
 *  "Simple Code High Performance". Details explaining the speedup can be found below.
 */

void f32_dot_product_neon(
    const float *x,
    const float *y,
    double      *result,
    const uint64_t size
) {
    // vector accumulator
    float32x4_t sum_v = vmovq_n_f32(0.0f);

    uint64_t i = 0;
    // main loop: 4 floats per iteration
    for (; i + 4 <= size; i += 4) {
        float32x4_t vx = vld1q_f32(x + i);
        float32x4_t vy = vld1q_f32(y + i);
        // sum_v += vx * vy
        sum_v = vmlaq_f32(sum_v, vx, vy);
    }

    // horizontal add
    float sum = vaddvq_f32(sum_v);

    // tail loop
    for (; i < size; i++) {
        sum += x[i] * y[i];
    }

    *result = (double)sum;
}

// normalize with vectorized sum‐of‐squares and reciprocal‐sqrt estimate
void norm_neon(float *v, uint32_t d) {

    // Vectorized sum-of-squares
    float32x4_t sum4 = vmovq_n_f32(0.0f);
    uint32_t i = 0;
    for (; i + 4 <= d; i += 4) {
        float32x4_t x = vld1q_f32(v + i);
        sum4 = vmlaq_f32(sum4, x, x);
    }
    float sum = vaddvq_f32(sum4);
    for (; i < d; i++) {
        sum += v[i] * v[i];
    }

    // reciprocal‐sqrt estimate + two Newton‐Raphson refinements
    // using NEON vrsqrteq/vrsqrtsq on a 4‐lane vector, then extracting lane 0
    float32x4_t s4 = vdupq_n_f32(sum);
    float32x4_t y  = vrsqrteq_f32(s4);
    // one iteration: y = y * (3 - sum*y*y) * 0.5
    y = vmulq_f32(y, vrsqrtsq_f32(vmulq_f32(s4, vmulq_f32(y, y)), y));
    // second iteration
    y = vmulq_f32(y, vrsqrtsq_f32(vmulq_f32(s4, vmulq_f32(y, y)), y));
    float inv_norm = vgetq_lane_f32(y, 0);

    // vectorized scaling by inv_norm
    float32x4_t scale4 = vdupq_n_f32(inv_norm);
    i = 0;
    for (; i + 4 <= d; i += 4) {
        float32x4_t x = vld1q_f32(v + i);
        vst1q_f32(v + i, vmulq_f32(x, scale4));
    }
    for (; i < d; i++) {
        v[i] *= inv_norm;
    }
}

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
