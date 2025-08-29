// src/gvfs_metal.h
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct gvfs_ctx gvfs_ctx;

typedef struct {
    uint32_t found;      // 0/1
    uint32_t selector;   // big-endian display (like cast)
    uint32_t suffix_len; // <= 32
    char     suffix[32]; // raw chars, not 0-terminated if full
} gvfs_result;

// Create a GPU context and load the metallib + kernel.
// metallib_path may be NULL to load "default.metallib" next to the executable.
gvfs_ctx* gvfs_create(const char* metallib_path, const char* kernel_name);

// Free GPU resources.
void gvfs_destroy(gvfs_ctx* ctx);

// Compute sum_{k=1..max_suffix_len} alphabet_len^k
uint64_t gvfs_total_space(uint32_t alphabet_len, uint32_t max_suffix_len);

// Run a single batch on the GPU.
// Returns 0 on success, nonzero on failure (no device, bad metallib, etc).
int gvfs_search_batch(
    gvfs_ctx* ctx,
    const char* prefix, uint32_t prefix_len,
    const char* args,   uint32_t args_len,
    const char* alphabet, uint32_t alphabet_len,
    uint32_t must_be_one, uint32_t must_be_zero,
    uint32_t max_suffix_len,
    uint64_t start_index, uint64_t batch_count,
    gvfs_result* out
);

#ifdef __cplusplus
}
#endif
