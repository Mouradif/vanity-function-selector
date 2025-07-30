const std = @import("std");
const utils = @import("utils.zig");
const C = @import("constants.zig");
const crypto = std.crypto;
const parseSingleHexDigit = utils.parseSingleHexDigit;

pub const VFSError = error {
    ParseError,
    DifficultyTooHigh,
    PatternTooLong,
};

const Result = struct {
    pattern: u32,
    name: []const u8,
    suffix: []const u8,
    attempts: usize,
};

pub const BitMasks = struct {
    must_be_one: u32 = 0,
    must_be_zero: u32 = 0,

    pub fn fromPattern(pattern: []const u8) VFSError!BitMasks {
        if (pattern.len < 2 or pattern[0] != '0' or pattern[1] != 'x') {
            return VFSError.ParseError;
        }
        if (pattern.len > 10) {
            return VFSError.PatternTooLong;
        }
        var must_be_one: u32 = 0;
        var must_be_zero: u32 = 0;
        for (pattern[2..], 0..) |c, i| {
            if (c == 'x' or c == 'X') continue;
            const shift: u5 = @intCast(28 - (4 * i));
            const digit_value = try parseSingleHexDigit(c);
            must_be_one |= @shlExact(@as(u32, @intCast(digit_value)), shift);
            for (0..4) |bit| {
                const mini_shift: u2 = @intCast(bit);
                if (@shlExact(@as(u4, 1), mini_shift) & digit_value == 0) {
                    must_be_zero |= @shlExact(@as(u32, 1), shift + mini_shift);
                }
            }
        }
        return .{
            .must_be_one = must_be_one,
            .must_be_zero = must_be_zero,
        };
    }

    pub fn check(self: BitMasks, n: u32) bool {
        const must_be_one = self.must_be_one;
        const must_be_zero = self.must_be_zero;
        return (n & must_be_one == must_be_one) and (n & must_be_zero == 0);
    }
};

const ResultBuf = struct {
    name_buf: [C.MAX_FQFN_LEN]u8 = undefined,
    suffix_buf: [C.MAX_SUFFIX_LEN]u8 = undefined,
};

fn keccak256(input: []const u8) u256 {
    var hash: [32]u8 = undefined;
    crypto.hash.sha3.Keccak256.hash(input, &hash, .{});
    return @byteSwap(@as(u256, @bitCast(hash)));
}

fn selector(hash: u256) u32 {
    return @truncate(hash >> 224);
}

fn keccakSelector(sig: []const u8) u32 {
    return selector(keccak256(sig));
}

fn makeFQFN(
    buf: *[C.MAX_FQFN_LEN]u8,
    prefix: []const u8,
    suffix: []const u8,
    args: []const u8,
) []u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();
    writer.print("{s}{s}({s})", .{ prefix, suffix, args }) catch {};
    return stream.getWritten();
}

fn worker(
    bit_mask: BitMasks,
    prefix: []const u8,
    args: []const u8,
    id: usize,
    stride: usize,
    stop: *bool,
    result_out: *Result,
    result_buf: *ResultBuf,
) void {
    var attempts: usize = 0;
    var counter: usize = id;

    while (!stop.*) {
        var suffix_len: usize = 0;
        var n = counter;
        while (suffix_len < C.MAX_SUFFIX_LEN) : (suffix_len += 1) {
            result_buf.suffix_buf[suffix_len] = C.ALPHABET[n % C.ALPHABET.len];
            n /= C.ALPHABET.len;
            if (n == 0) break;
        }

        const suffix = result_buf.suffix_buf[0..suffix_len];
        const fqfn = makeFQFN(&result_buf.name_buf, prefix, suffix, args);
        const sel = keccakSelector(fqfn);
        attempts += 1;

        if (bit_mask.check(sel)) {
            stop.* = true;
            result_out.* = .{
                .pattern = sel,
                .name = fqfn,
                .suffix = suffix,
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

    var thread_handles: [C.MAX_THREADS]std.Thread = undefined;
    var result_bufs: [C.MAX_THREADS]ResultBuf = undefined;
    const thread_count: usize = @min(cpu_count, C.MAX_THREADS);

    for (0..thread_count) |i| {
        thread_handles[i] = std.Thread.spawn(.{}, worker, .{
            bit_mask,
            prefix,
            args_str,
            i,
            thread_count,
            &stop,
            &result,
            &result_bufs[i],
        }) catch unreachable;
    }

    for (0..thread_count) |i| {
        thread_handles[i].join();
    }

    return result;
}
