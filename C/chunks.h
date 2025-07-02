// chunks.h
#pragma once
#include <stdint.h>


// Opaque handle
typedef struct ChunkIndex ChunkIndex;

// Load the entire chunks.bin into an arena and parse headers.
// Returns NULL on error.
ChunkIndex* ci_load(const char *filename);

// Free everything (arena + index array)
void ci_free(ChunkIndex *ci);

// Query top-K nearest neighbors by dot-product on unit vectors.
//   qemb: float32[dim]  (must be normalized already)
// Returns the number of hits (≤ K), and fills out_idxs[.] and out_scores[.]
uint32_t ci_search(
  ChunkIndex *ci,
  const float *qemb,
  uint32_t     dim,
  uint32_t     K,
  uint32_t    *out_idxs,
  double      *out_scores
);

// Metadata getters
const char* ci_get_id      (ChunkIndex*, uint32_t idx);
const char* ci_get_parent  (ChunkIndex*, uint32_t idx);
const char* ci_get_file    (ChunkIndex*, uint32_t idx);
const char* ci_get_ext     (ChunkIndex*, uint32_t idx);
uint32_t    ci_get_start   (ChunkIndex*, uint32_t idx);
uint32_t    ci_get_end     (ChunkIndex*, uint32_t idx);
const char* ci_get_text    (ChunkIndex*, uint32_t idx);
