// src/gvfs_metal.m
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "gvfs_metal.h"

// Must match shader.metal
typedef struct {
    uint32_t must_be_one;
    uint32_t must_be_zero;
    uint32_t prefix_len;
    uint32_t args_len;
    uint32_t alphabet_len;
    uint32_t max_suffix_len;
    uint64_t start_index;
    uint64_t total_space;
} SearchIn;

typedef struct {
    _Atomic(uint32_t) found;
    uint32_t selector;
    uint32_t suffix_len;
    uint32_t _pad_;
    uint8_t  suffix[32];
} SearchOut;

struct gvfs_ctx {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLComputePipelineState> pso;
};

static id<MTLDevice> pickDevice(void) {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    if (d) return d;
    NSArray<id<MTLDevice>> *all = MTLCopyAllDevices();
    return all.count ? all.firstObject : nil;
}

// Try to load metallib from given path; if NULL, try "<executable_dir>/gvfs.metallib"
static id<MTLLibrary> loadMetallib(id<MTLDevice> dev, const char* cpath, NSError **err) {
    NSString *path = nil;
    if (cpath && cpath[0]) {
        path = [NSString stringWithUTF8String:cpath];
    } else {
        // default next to the executable
        NSString *exe = [NSString stringWithUTF8String:getprogname()];
        (void)exe;
        // Try current working directory
        path = @"gvfs.metallib";
    }
    return [dev newLibraryWithFile:path error:err];
}

uint64_t gvfs_total_space(uint32_t N, uint32_t L) {
    uint64_t total = 0, pow = N;
    for (uint32_t k = 1; k <= L; ++k) { total += pow; pow *= N; }
    return total;
}

gvfs_ctx* gvfs_create(const char* metallib_path, const char* kernel_name) {
    @autoreleasepool {
        id<MTLDevice> dev = pickDevice();
        if (!dev) return NULL;

        NSError *err = nil;
        id<MTLLibrary> lib = loadMetallib(dev, metallib_path, &err);
        if (!lib) return NULL;

        NSString *kname = kernel_name ? [NSString stringWithUTF8String:kernel_name] : @"vanity_selector";
        id<MTLFunction> fn = [lib newFunctionWithName:kname];
        if (!fn) return NULL;

        id<MTLComputePipelineState> pso = [dev newComputePipelineStateWithFunction:fn error:&err];
        if (!pso) return NULL;

        id<MTLCommandQueue> q = [dev newCommandQueue];
        if (!q) return NULL;

        gvfs_ctx *ctx = malloc(sizeof(gvfs_ctx));
        ctx->device = dev;
        ctx->queue  = q;
        ctx->pso    = pso;
        return ctx;
    }
}

void gvfs_destroy(gvfs_ctx* ctx) {
    if (!ctx) return;
    // ARC handles Obj-C objects, just free the holder.
    free(ctx);
}

int gvfs_search_batch(
    gvfs_ctx* ctx,
    const char* prefix, uint32_t prefix_len,
    const char* args,   uint32_t args_len,
    const char* alphabet, uint32_t alphabet_len,
    uint32_t must_be_one, uint32_t must_be_zero,
    uint32_t max_suffix_len,
    uint64_t start_index, uint64_t batch_count,
    gvfs_result* out_c
) {
    if (!ctx || !ctx->device || !ctx->pso || !ctx->queue) return -1;

    @autoreleasepool {
        id<MTLDevice> dev = ctx->device;

        id<MTLBuffer> bPrefix = [dev newBufferWithBytes:prefix length:prefix_len options:MTLResourceStorageModeShared];
        id<MTLBuffer> bArgs   = [dev newBufferWithBytes:args   length:args_len   options:MTLResourceStorageModeShared];
        id<MTLBuffer> bAlpha  = [dev newBufferWithBytes:alphabet length:alphabet_len options:MTLResourceStorageModeShared];

        id<MTLBuffer> bIn  = [dev newBufferWithLength:sizeof(SearchIn)  options:MTLResourceStorageModeShared];
        id<MTLBuffer> bOut = [dev newBufferWithLength:sizeof(SearchOut) options:MTLResourceStorageModeShared];

        SearchIn *in  = (SearchIn*)bIn.contents;
        SearchOut *out = (SearchOut*)bOut.contents;
        memset(out, 0, sizeof(*out));

        in->must_be_one   = must_be_one;
        in->must_be_zero  = must_be_zero;
        in->prefix_len    = prefix_len;
        in->args_len      = args_len;
        in->alphabet_len  = alphabet_len;
        in->max_suffix_len= max_suffix_len;
        in->start_index   = start_index;
        in->total_space   = batch_count;

        id<MTLCommandBuffer> cb = [ctx->queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:ctx->pso];
        [enc setBuffer:bPrefix offset:0 atIndex:0];
        [enc setBuffer:bArgs   offset:0 atIndex:1];
        [enc setBuffer:bAlpha  offset:0 atIndex:2];
        [enc setBuffer:bIn     offset:0 atIndex:3];
        [enc setBuffer:bOut    offset:0 atIndex:4];

        NSUInteger w = ctx->pso.threadExecutionWidth; // wave size (e.g., 32/64)
        if (w == 0) w = 64;
        NSUInteger tgCount = 256;                      // number of threadgroups
        MTLSize tg   = MTLSizeMake(w, 1, 1);
        MTLSize grid = MTLSizeMake(w * tgCount, 1, 1);

        [enc dispatchThreads:grid threadsPerThreadgroup:tg];
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];

        if (out) {
            out_c->found      = out->found;
            out_c->selector   = out->selector;
            out_c->suffix_len = out->suffix_len;
            uint32_t n = out->suffix_len;
            if (n > 32) n = 32;
            memcpy(out_c->suffix, out->suffix, n);
            if (n < 32) out_c->suffix[n] = 0;
        }
        return 0;
    }
}
