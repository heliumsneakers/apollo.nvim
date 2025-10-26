// cosine_neon.h
#pragma once
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
    #include <arm_neon.h>
#elif defined(__AVX512F__) || defined(__AVX2__)
    #include <immintrin.h>
#endif
#include <stdint.h>

void f32_cosine_distance_simd(
    const float *x,
    const float *y,
    double      *result,
    const uint64_t size
);

void f32_dot_product_simd(
    const float *x,
    const float *y,
    double      *result,
    const uint64_t size
);

void norm_simd(float *v, uint32_t d);
