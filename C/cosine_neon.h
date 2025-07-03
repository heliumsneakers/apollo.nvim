// cosine_neon.h
#pragma once
#include <arm_neon.h> 
#include <stdint.h>

void f32_cosine_distance_neon(
    const float *x,
    const float *y,
    double      *result,
    const uint64_t size
);

void f32_dot_product_neon(
    const float *x,
    const float *y,
    double      *result,
    const uint64_t size
);

void norm_neon(float *v, uint32_t d);
