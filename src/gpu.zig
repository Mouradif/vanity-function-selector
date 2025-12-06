const GpuCtx = @This();

const std = @import("std");
const Constants = @import("constants.zig");
const C = @cImport({
    @cInclude("gvfs_metal.h");
});

ptr: ?*C.gvfs_ctx = null,

pub fn init(metallib_path: ?[:0]const u8) !GpuCtx {
    const cpath: [*c]const u8 = if (metallib_path) |p| @ptrCast(p.ptr) else null;
    const ctx = C.gvfs_create(cpath, "vanity_selector");
    if (ctx == null) return error.NoMetalDevice;
    return .{ .ptr = ctx };
}

pub fn deinit(self: *GpuCtx) void {
    if (self.ptr) |p| C.gvfs_destroy(p);
    self.ptr = null;
}

pub fn totalSpace(alphabet_len: u32, max_suffix_len: u32) u64 {
    return C.gvfs_total_space(alphabet_len, max_suffix_len);
}

pub const BatchResult = struct {
    found: bool,
    selector: u32,
    suffix: [Constants.MAX_SUFFIX_LEN]u8,
    suffix_len: u32,
};

pub fn searchBatch(
    self: *GpuCtx,
    prefix: []const u8,
    args: []const u8,
    alphabet: []const u8,
    must_be_one: u32,
    must_be_zero: u32,
    max_suffix_len: u32,
    start_index: u64,
    batch_count: u64,
) !BatchResult {
    var out: C.gvfs_result = undefined;
    const rc = C.gvfs_search_batch(
        self.ptr.?, 
        @as([*c]const u8, @ptrCast(prefix.ptr)), @as(u32, @intCast(prefix.len)),
        @as([*c]const u8, @ptrCast(args.ptr)),   @as(u32, @intCast(args.len)),
        @as([*c]const u8, @ptrCast(alphabet.ptr)), @as(u32, @intCast(alphabet.len)),
        must_be_one, must_be_zero,
        @as(u32, @intCast(max_suffix_len)),
        start_index, batch_count,
        &out
    );
    if (rc != 0) return error.GpuSearchFailed;

    var suffix: [Constants.MAX_SUFFIX_LEN]u8 = [_]u8{0} ** Constants.MAX_SUFFIX_LEN;
    if (out.suffix_len > 0) {
        const len = @min(out.suffix_len, Constants.MAX_SUFFIX_LEN);
        @memcpy(suffix[0..len], @as([*]const u8, @ptrCast(&out.suffix))[0..len]);
    }
    return .{
        .found = (out.found != 0),
        .selector = out.selector,
        .suffix = suffix,
        .suffix_len = out.suffix_len,
    };
}
