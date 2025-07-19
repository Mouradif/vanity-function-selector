const std = @import("std");
const crypto = std.crypto;
const Allocator = std.mem.Allocator;

const Result = struct {
    pattern: u32,
    name: []const u8,
    suffix: []const u8,
    attempts: usize,
};

const Alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_";
const MaxSuffixLen = 8;

fn keccak256(input: []const u8) u256 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(input, &hash, .{});
    return @byteSwap(@as(u256, @bitCast(hash)));
}

fn selector(hash: u256) u32 {
    return @truncate(hash >> 224);
}

pub fn getPattern(difficulty: u8) u32 {
    return switch (difficulty) {
        0 => 0xFFFFFFFF,
        1 => 0x00FFFFFF,
        2 => 0x0000FFFF,
        3 => 0x000000FF,
        else => 0,
    };
}

fn keccakSelector(sig: []const u8) u32 {
    return selector(keccak256(sig));
}

fn makeFQFN(allocator: Allocator, prefix: []const u8, suffix: []const u8, args: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}({s})", .{ prefix, suffix, args });
}

fn worker(
    allocator: Allocator,
    pattern: u32,
    prefix: []const u8,
    args: []const u8,
    id: usize,
    stride: usize,
    stop: *bool,
    result_out: *Result,
) void {
    var attempts: usize = 0;
    var suffix_buf: [MaxSuffixLen]u8 = undefined;
    var suffix_len: usize = 1;
    var counter: usize = id;

    while (!stop.*) {
        var n = counter;
        for (0..MaxSuffixLen) |i| {
            suffix_buf[i] = Alphabet[n % Alphabet.len];
            n /= Alphabet.len;
            if (n == 0) {
                suffix_len = i + 1;
                break;
            }
        }

        const suffix = suffix_buf[0..suffix_len];
        const fqfn = makeFQFN(allocator, prefix, suffix, args) catch continue;
        const sel = keccakSelector(fqfn);
        attempts += 1;

        if (sel == pattern) {
            stop.* = true;
            result_out.* = .{
                .pattern = sel,
                .name = allocator.dupe(u8, fqfn) catch fqfn,
                .suffix = allocator.dupe(u8, suffix) catch suffix,
                .attempts = attempts,
            };
            break;
        }

        counter += stride;
    }
}

pub fn searchByPattern(
    pattern: u32,
    prefix: []const u8,
    args: [][*:0]u8,
    buffer: []u8,
) Result {
    const arg_string = flattenArgs(args, buffer);

    const allocator = std.heap.page_allocator;
    const cpu_count = std.Thread.getCpuCount() catch 1;

    var stop = false;
    var result: Result = undefined;

    var threads = std.ArrayList(std.Thread).init(allocator);
    defer threads.deinit();

    for (0..cpu_count) |i| {
        const th = std.Thread.spawn(.{}, worker, .{
            allocator, pattern, prefix, arg_string, i, cpu_count, &stop, &result
        }) catch continue;
        threads.append(th) catch {};
    }

    for (threads.items) |th| {
        th.join();
    }

    return result;
}

pub fn searchByDifficulty(
    difficulty: u8,
    prefix: []const u8,
    args: [][*:0]u8,
    buffer: []u8,
) Result {
    const pattern = getPattern(difficulty);
    return searchByPattern(pattern, prefix, args, buffer);
}

/// Joins multiple C strings (`[*:0]u8`) with ',' into a single flat buffer
pub fn flattenArgs(args: [][*:0]u8, buffer: []u8) []u8 {
    var i: usize = 0;
    for (args) |arg| {
        if (i > 0) {
            buffer[i] = ',';
            i += 1;
        }
        var j: usize = 0;
        while (true): (j += 1) {
            const c = arg[j];
            if (c == 0) break;
            buffer[i] = arg[j];
            i += 1;
        }
    }
    return buffer[0..i];
}

