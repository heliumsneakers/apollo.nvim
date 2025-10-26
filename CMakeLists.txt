# CMakeLists.txt — build libchunks across macOS, Linux, Windows

cmake_minimum_required(VERSION 3.16)
project(chunks LANGUAGES C)

# ---------------------------------------------------------------------
# Build settings
# ---------------------------------------------------------------------

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Paths
set(CHUNKS_SRC_DIR "${CMAKE_CURRENT_LIST_DIR}/C")
set(OUTPUT_LIB_DIR "${CMAKE_SOURCE_DIR}/lib")
file(MAKE_DIRECTORY ${OUTPUT_LIB_DIR})

# ---------------------------------------------------------------------
# Source files
# ---------------------------------------------------------------------

add_library(chunks SHARED
    ${CHUNKS_SRC_DIR}/cosine_simd.c
    ${CHUNKS_SRC_DIR}/chunks.c
)

target_include_directories(chunks PUBLIC
    ${CHUNKS_SRC_DIR}
)

# ---------------------------------------------------------------------
# Optimization and SIMD flags
# ---------------------------------------------------------------------

if (CMAKE_C_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(chunks PRIVATE -O3)

    if (CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64)$")
        # Default to AVX2 + FMA for modern CPUs
        target_compile_options(chunks PRIVATE -mavx2 -mfma)

        # Optional AVX-512 toggle: cmake -DUSE_AVX512=ON ..
        option(USE_AVX512 "Enable AVX-512 optimizations" OFF)
        if (USE_AVX512)
            message(STATUS "Building with AVX-512 support")
            target_compile_options(chunks PRIVATE -mavx512f -mavx512vl)
            target_compile_definitions(chunks PRIVATE USE_AVX512=1)
        endif()

    elseif (CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64|armv7|armv8)$")
        # NEON usually enabled by default on arm64
        message(STATUS "Building with ARM NEON optimizations")
        target_compile_definitions(chunks PRIVATE USE_NEON=1)
    else()
        message(WARNING "Unknown CPU architecture — building scalar fallback")
    endif()

elseif (CMAKE_C_COMPILER_ID MATCHES "MSVC")
    target_compile_options(chunks PRIVATE /O2)

    if (CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64)$")
        # MSVC AVX2 and optional AVX-512
        target_compile_options(chunks PRIVATE /arch:AVX2)
        option(USE_AVX512 "Enable AVX-512 optimizations" OFF)
        if (USE_AVX512)
            message(STATUS "Building with AVX-512 support (/arch:AVX512)")
            target_compile_options(chunks PRIVATE /arch:AVX512)
            target_compile_definitions(chunks PRIVATE USE_AVX512=1)
        endif()
    endif()
endif()

# ---------------------------------------------------------------------
# Output directories and naming
# ---------------------------------------------------------------------

set_target_properties(chunks PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${OUTPUT_LIB_DIR}
    LIBRARY_OUTPUT_DIRECTORY ${OUTPUT_LIB_DIR}
    ARCHIVE_OUTPUT_DIRECTORY ${OUTPUT_LIB_DIR}
)

# Platform-specific naming
if (APPLE)
    set_target_properties(chunks PROPERTIES PREFIX "" SUFFIX ".dylib")
elseif (WIN32)
    set_target_properties(chunks PROPERTIES PREFIX "" SUFFIX ".dll")
else()
    set_target_properties(chunks PROPERTIES PREFIX "lib" SUFFIX ".so")
endif()

# ---------------------------------------------------------------------
# Build summary
# ---------------------------------------------------------------------
message(STATUS "==== chunks build configuration ====")
message(STATUS "  Compiler: ${CMAKE_C_COMPILER_ID} ${CMAKE_C_COMPILER_VERSION}")
message(STATUS "  Processor: ${CMAKE_SYSTEM_PROCESSOR}")
message(STATUS "  SIMD source: cosine_simd.c")
message(STATUS "  Output: ${OUTPUT_LIB_DIR}")
message(STATUS "===================================")
