// chunks.c
#include "chunks.h"
#include "cosine_neon.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// Bump‐allocator arena
typedef struct {
  uint8_t *base;
  size_t   sz;
} Arena;

// Chunk record
typedef struct {
  const char *id, *parent, *file, *ext, *text;
  uint32_t     start_ln, end_ln;
  uint32_t     dim;
  float       *emb;
} Chunk;

// Index
struct ChunkIndex {
  Arena      arena;
  uint32_t   N;
  Chunk     *chunks;
};

static const char* read_str(Arena *A, uint8_t **p){
  uint32_t L = *(uint32_t*)(*p); *p+=4;
  const char *s = (const char*)(*p);
  *p += L;
  return s;
}

ChunkIndex* ci_load(const char *fname){
  FILE *f = fopen(fname,"rb");
  if(!f) return NULL;
  fseek(f,0,SEEK_END);
  size_t filesize = ftell(f);
  fseek(f,0,SEEK_SET);

  uint8_t *buf = malloc(filesize);
  fread(buf,1,filesize,f);
  fclose(f);

  uint8_t *p = buf;
  uint32_t N = *(uint32_t*)p; p+=4;

  ChunkIndex *ci = calloc(1,sizeof*ci);
  ci->arena.base = buf;
  ci->arena.sz   = filesize;
  ci->N          = N;
  ci->chunks     = calloc(N,sizeof(Chunk));

  for(uint32_t i=0;i<N;i++){
    Chunk *c = &ci->chunks[i];
    c->id       = read_str(&ci->arena,&p);
    c->parent   = read_str(&ci->arena,&p);
    c->file     = read_str(&ci->arena,&p);
    c->ext      = read_str(&ci->arena,&p);
    c->start_ln = *(uint32_t*)p; p+=4;
    c->end_ln   = *(uint32_t*)p; p+=4;
    c->text     = read_str(&ci->arena,&p);
    c->dim      = *(uint32_t*)p; p+=4;
    c->emb      = (float*)p;
    norm_neon(c->emb, c->dim); 
    p += sizeof(float)*c->dim;
  }

  return ci;
}

void ci_free(ChunkIndex *ci){
  free(ci->arena.base);
  free(ci->chunks);
  free(ci);
}

// simple min‐heap top‐K
typedef struct { double score; uint32_t idx; } Pair;
static void sift_down(Pair *h, int K){
  int i=0;
  while(1){
    int c=2*i+1; if(c>=K)break;
    if(c+1<K && h[c+1].score < h[c].score) c++;
    if(h[c].score < h[i].score){
      Pair t=h[i]; h[i]=h[c]; h[c]=t;
      i=c;
    } else break;
  }
}

uint32_t ci_search(ChunkIndex *ci,
                   const float *q, uint32_t dim,
                   uint32_t K, uint32_t *out_i,
                   double   *out_s)
{
  Pair *heap = calloc(K, sizeof(Pair));
  uint32_t sz = 0;

  for (uint32_t i = 0; i < ci->N; i++) {
    Chunk *c = &ci->chunks[i];
    if (c->dim != dim) continue;

    double sc_val;
    f32_dot_product_neon(
      q,            
      c->emb,       
      &sc_val,      
      (uint64_t)dim 
    );
    // f32_cosine_distance_neon (
    //   q,
    //   c->emb,
    //   &sc_val,
    //   (uint64_t)dim
    // );

    if (sz < K) {
      heap[sz++] = (Pair){ sc_val, i };
      if (sz == K) {
        for (int p = (K - 2) / 2; p >= 0; p--) {
          sift_down(heap, K);
        }
      }
    }
    else if (sc_val > heap[0].score) {
      heap[0] = (Pair){ sc_val, i };
      sift_down(heap, K);
    }
  }

  for (uint32_t j = 0; j < sz; j++) {
    out_i[j] = heap[j].idx;
    out_s[j] = heap[j].score;
  }
  free(heap);
  return sz;
}

// getters
const char* ci_get_id     (ChunkIndex*ci,uint32_t i){return ci->chunks[i].id;}
const char* ci_get_parent (ChunkIndex*ci,uint32_t i){return ci->chunks[i].parent;}
const char* ci_get_file   (ChunkIndex*ci,uint32_t i){return ci->chunks[i].file;}
const char* ci_get_ext    (ChunkIndex*ci,uint32_t i){return ci->chunks[i].ext;}
uint32_t    ci_get_start  (ChunkIndex*ci,uint32_t i){return ci->chunks[i].start_ln;}
uint32_t    ci_get_end    (ChunkIndex*ci,uint32_t i){return ci->chunks[i].end_ln;}
const char* ci_get_text   (ChunkIndex*ci,uint32_t i){return ci->chunks[i].text;}
