const std = @import("std");
const GpuCtx = @import("gpu.zig");

pub const Utils = @import("utils.zig");
pub const Constants = @import("constants.zig");

pub const BitMasks = @import("bitmasks.zig");
pub const BitMasks160 = @import("bitmasks160.zig");
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
    var suffix_buffer: [Constants.MAX_SUFFIX_LEN]u8 = [_]u8{0} ** Constants.MAX_SUFFIX_LEN;

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
            start,
            count,
        );

        attempts += @intCast(count);

        if (br.found) {
            const len = @min(Constants.MAX_SUFFIX_LEN, br.suffix_len);
            var name_buffer: [Constants.MAX_FQFN_LEN]u8 = undefined;
            var writer = std.Io.Writer.fixed(&name_buffer);
            const name_len = try makeFQFN(&writer, prefix, br.suffix[0..len], args_str);
            return .{
                .pattern = br.selector,
                .name = name_buffer,
                .name_len = name_len,
                .suffix = br.suffix,
                .suffix_len = br.suffix_len,
                .attempts = attempts,
            };
        }
    }
    return VFSError.NotFound;
}

pub const Create2Result = struct {
    salt: [32]u8,
    address: [20]u8,
    attempts: usize,
};

/// Search for a CREATE2 salt that produces an address matching the pattern
/// deployer: The address that will deploy the contract (20 bytes)
/// init_code: The initialization code for the contract
/// pattern: The bit mask pattern for the desired address
pub fn searchCreate2GPU(
    deployer: [20]u8,
    init_code: []const u8,
    pattern: BitMasks160,
) !Create2Result {
    // Hash the init code
    var init_code_hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(init_code, &init_code_hash, .{});

    var ctx = GpuCtx.initCreate2(null) catch return VFSError.NotFound;
    defer ctx.deinit();

    // Convert u160 bit masks to [5]u32 arrays for GPU
    const must_be_one = BitMasks160.toU32Array(pattern.must_be_one);
    const must_be_zero = BitMasks160.toU32Array(pattern.must_be_zero);

    // Search space: we'll search 2^64 salts (using lower 64 bits)
    // In practice, we'll search in batches and hopefully find a match early
    const batch: u64 = 1024 * 1024 * 16; // 16M salts per batch
    const max_search: u64 = 1 << 40; // Search up to 2^40 salts (~1 trillion)
    var start: u64 = 0;
    var attempts: usize = 0;

    while (start < max_search) : (start += batch) {
        const count = @min(batch, max_search - start);
        const br = try ctx.searchCreate2Batch(
            deployer,
            init_code_hash,
            must_be_one,
            must_be_zero,
            start,
            count,
        );

        attempts += @intCast(count);

        if (br.found) {
            return .{
                .salt = br.salt,
                .address = br.address,
                .attempts = attempts,
            };
        }
    }
    return VFSError.NotFound;
}

/// CPU-based CREATE2 search (fallback when GPU is unavailable)
fn create2Worker(
    pattern: BitMasks160,
    deployer: [20]u8,
    init_code_hash: [32]u8,
    id: usize,
    stride: usize,
    stop: *bool,
    result_out: *Create2Result,
) void {
    var attempts: usize = 0;
    var counter: u64 = id;

    // CREATE2 message buffer: 0xff ++ deployer ++ salt ++ init_code_hash
    var msg: [85]u8 = undefined;
    msg[0] = 0xff;
    @memcpy(msg[1..21], &deployer);
    @memcpy(msg[53..85], &init_code_hash);

    while (!stop.*) {
        // Convert counter to 32-byte salt (big-endian u256, using lower 64 bits)
        var salt: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u64, salt[24..32], counter, .big);
        @memcpy(msg[21..53], &salt);

        // Compute keccak256
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(&msg, &hash, .{});

        // Extract address (last 20 bytes)
        var address: [20]u8 = undefined;
        @memcpy(&address, hash[12..32]);

        attempts += 1;

        // Check pattern
        if (pattern.checkBytes(address)) {
            stop.* = true;
            result_out.* = .{
                .salt = salt,
                .address = address,
                .attempts = attempts,
            };
            break;
        }

        counter += @intCast(stride);
    }
}

pub fn searchCreate2CPU(
    deployer: [20]u8,
    init_code: []const u8,
    pattern: BitMasks160,
) Create2Result {
    // Hash the init code
    var init_code_hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(init_code, &init_code_hash, .{});

    const cpu_count = std.Thread.getCpuCount() catch 1;
    var stop = false;
    var result: Create2Result = undefined;

    var thread_handles: [Constants.MAX_THREADS]std.Thread = undefined;
    const thread_count: usize = @min(cpu_count, Constants.MAX_THREADS);

    for (0..thread_count) |i| {
        thread_handles[i] = std.Thread.spawn(.{}, create2Worker, .{
            pattern,
            deployer,
            init_code_hash,
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
