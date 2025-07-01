#include <stdint.h>
#include <math.h>
#include <arm_neon.h>

void f32_cosine_distance_neon(
    const float *x,
    const float *y,
    double      *result,
    const uint64_t size
) {
    // Vector accumulators
    float32x4_t sum_xy_v = vmovq_n_f32(0.0f);
    float32x4_t sum_xx_v = vmovq_n_f32(0.0f);
    float32x4_t sum_yy_v = vmovq_n_f32(0.0f);

    uint64_t i = 0;
    // Main loop: 4 floats per iteration
    for (; i + 4 <= size; i += 4) {
        float32x4_t vx = vld1q_f32(x + i);
        float32x4_t vy = vld1q_f32(y + i);

        // sum_xy_v += vx * vy
        sum_xy_v = vmlaq_f32(sum_xy_v, vx, vy);
        // sum_xx_v += vx * vx
        sum_xx_v = vmlaq_f32(sum_xx_v, vx, vx);
        // sum_yy_v += vy * vy
        sum_yy_v = vmlaq_f32(sum_yy_v, vy, vy);
    }

    // Horizontal add of vector accumulators
    float sum_xy = vaddvq_f32(sum_xy_v);
    float sum_xx = vaddvq_f32(sum_xx_v);
    float sum_yy = vaddvq_f32(sum_yy_v);

    // Tail loop for remaining elements
    for (; i < size; i++) {
        float xi = x[i];
        float yi = y[i];
        sum_xy += xi * yi;
        sum_xx += xi * xi;
        sum_yy += yi * yi;
    }

    // Final cosine-distance calculation
    float denom = sqrtf(sum_xx) * sqrtf(sum_yy);
    if (denom == 0.0f) {
        *result = 0.0;
    } else {
        *result = (double)(sum_xy / denom);
    }
}

void f32_dot_product_neon(
    const float *x,
    const float *y,
    double      *result,
    const uint64_t size
) {
    // Vector accumulator
    float32x4_t sum_v = vmovq_n_f32(0.0f);

    uint64_t i = 0;
    // Main loop: 4 floats per iteration
    for (; i + 4 <= size; i += 4) {
        float32x4_t vx = vld1q_f32(x + i);
        float32x4_t vy = vld1q_f32(y + i);
        // sum_v += vx * vy
        sum_v = vmlaq_f32(sum_v, vx, vy);
    }

    // Horizontal add
    float sum = vaddvq_f32(sum_v);

    // Tail loop
    for (; i < size; i++) {
        sum += x[i] * y[i];
    }

    *result = (double)sum;
}
