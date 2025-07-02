# CMakeLists.txt — build libchunks across macOS, Linux, Windows

cmake_minimum_required(VERSION 3.16)
project(chunks
    LANGUAGES C
)

# Use C11
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
# Position-independent code for shared libs
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Source directory
set(CHUNKS_SRC_DIR "${CMAKE_CURRENT_LIST_DIR}/C")

# Ensure output directory exists
set(OUTPUT_LIB_DIR "${CMAKE_SOURCE_DIR}/lib")
file(MAKE_DIRECTORY ${OUTPUT_LIB_DIR})

# Our shared library target
add_library(chunks SHARED
    ${CHUNKS_SRC_DIR}/cosine_neon.c
    ${CHUNKS_SRC_DIR}/chunks.c
)

# Public headers
target_include_directories(chunks PUBLIC
    ${CHUNKS_SRC_DIR}
)

# Optimization flags
if (CMAKE_C_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(chunks PRIVATE -O3 -march=native)
elseif (CMAKE_C_COMPILER_ID MATCHES "MSVC")
    target_compile_options(chunks PRIVATE /O2)
endif()

# Place all output artifacts in lib/ at project root
set_target_properties(chunks PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${OUTPUT_LIB_DIR}   # for Windows DLLs
    LIBRARY_OUTPUT_DIRECTORY ${OUTPUT_LIB_DIR}   # for .so/.dylib
    ARCHIVE_OUTPUT_DIRECTORY ${OUTPUT_LIB_DIR}   # for static archives, if any
)

# Platform-specific naming conventions
if (APPLE)
    set_target_properties(chunks PROPERTIES
        PREFIX ""
        SUFFIX ".dylib"
    )
elseif (WIN32)
    set_target_properties(chunks PROPERTIES
        PREFIX ""
        SUFFIX ".dll"
    )
else()
    set_target_properties(chunks PROPERTIES
        PREFIX "lib"
        SUFFIX ".so"
    )
endif()
