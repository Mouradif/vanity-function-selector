const std = @import("std");
const utils = @import("utils.zig");
const Constants = @import("constants.zig");
const GpuCtx = @import("gpu.zig");

pub const BitMasks = @import("bitmasks.zig");
pub const VFSError = @import("errors.zig").VFSError;
pub const Result = @import("result.zig");

const ResultBuf = struct {
    name_buf: [Constants.MAX_FQFN_LEN]u8 = undefined,
    suffix_buf: [Constants.MAX_SUFFIX_LEN]u8 = undefined,
};

fn keccakSelector(sig: []const u8) u32 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(sig, &hash, .{});
    return std.mem.readInt(u32, hash[0..4], .big);
}

fn makeFQFN(
    writer: *std.Io.Writer,
    prefix: []const u8,
    suffix: []const u8,
    args: []const u8,
) !usize {
    var size: usize = 0;
    size += try writer.write(prefix);
    size += try writer.write(suffix);
    size += try writer.write("(");
    size += try writer.write(args);
    size += try writer.write(")");
    return size;
}

fn worker(
    bit_mask: BitMasks,
    prefix: []const u8,
    args: []const u8,
    id: usize,
    stride: usize,
    stop: *bool,
    result_out: *Result,
) void {
    var attempts: usize = 0;
    var counter: usize = id;
    var suffix_buffer: [Constants.MAX_SUFFIX_LEN]u8 = undefined;

    while (!stop.*) {
        var suffix_len: usize = 0;
        var n = counter;
        while (suffix_len < Constants.MAX_SUFFIX_LEN) : (suffix_len += 1) {
            suffix_buffer[suffix_len] = Constants.ALPHABET[n % Constants.ALPHABET.len];
            n /= Constants.ALPHABET.len;
            if (n == 0) break;
        }

        var name_buffer: [Constants.MAX_FQFN_LEN]u8 = undefined;
        var writer = std.Io.Writer.fixed(&name_buffer);
        const name_len = makeFQFN(&writer, prefix, suffix_buffer[0..suffix_len], args) catch continue;
        const sel = keccakSelector(writer.buffered());
        attempts += 1;

        if (bit_mask.check(sel)) {
            stop.* = true;
            result_out.* = .{
                .pattern = sel,
                .name = name_buffer,
                .name_len = name_len,
                .suffix = suffix_buffer,
                .suffix_len = suffix_len,
                .attempts = attempts,
            };
            break;
        }

        counter += stride;
    }
}

pub fn searchByPattern(
    bit_mask: BitMasks,
    prefix: []const u8,
    args_str: []const u8,
) Result {
    const cpu_count = std.Thread.getCpuCount() catch 1;

    var stop = false;
    var result: Result = undefined;

    var thread_handles: [Constants.MAX_THREADS]std.Thread = undefined;
    const thread_count: usize = @min(cpu_count, Constants.MAX_THREADS);

    for (0..thread_count) |i| {
        thread_handles[i] = std.Thread.spawn(.{}, worker, .{
            bit_mask,
            prefix,
            args_str,
            i,
            thread_count,
            &stop,
            &result,
        }) catch unreachable;
    }

    for (0..thread_count) |i| {
        thread_handles[i].join();
    }

    return result;
}

pub fn searchByPatternGPU(
    bit_mask: BitMasks,
    prefix: []const u8,
    args_str: []const u8,
) !Result {
    var ctx = GpuCtx.init(null) catch return VFSError.NotFound;
    defer ctx.deinit();

    const total = GpuCtx.totalSpace(Constants.ALPHABET.len, Constants.MAX_SUFFIX_LEN);
    const batch: u64 = 1024 * 1024 * 8;
    var start: u64 = 0;

    var attempts: usize = 0;

    while (start < total) : (start += batch) {
        const count = @min(batch, total - start);
        const br = try ctx.searchBatch(
            prefix,
            args_str,
            Constants.ALPHABET,
            bit_mask.must_be_one,
            bit_mask.must_be_zero,
            Constants.MAX_SUFFIX_LEN,
            start, count,
        );

        attempts += @intCast(count);

        if (br.found) {
            var suffix: [Constants.MAX_SUFFIX_LEN]u8 = undefined;
            const len = @min(Constants.MAX_SUFFIX_LEN, br.suffix_len);
            @memcpy(suffix[0..len], br.suffix[0..len]);

            var name_buffer: [Constants.MAX_FQFN_LEN]u8 = undefined;
            var writer = std.Io.Writer.fixed(&name_buffer);
            const name_len = try makeFQFN(&writer, prefix, br.suffix, args_str);
            return .{
                .pattern = br.selector,
                .name = name_buffer,
                .name_len = name_len,
                .suffix = suffix,
                .suffix_len = br.suffix_len,
                .attempts = attempts,
            };
        }
    }
    return VFSError.NotFound;
}
