const std = @import("std");

const Result = struct {
    pattern: u32,
    name: []const u8,
    suffix: []const u8,
    attempts: usize
};

pub fn searchByDifficulty(difficulty: u8, prefix: []const u8, args: [][*:0]u8, buffer: []u8) Result {
    _ = difficulty;
    _ = prefix;
    _ = args;
    return .{
        .pattern = 0,
        .name = buffer[0..0],
        .suffix = buffer[0..0],
        .attempts = 0,
    };
}

pub fn searchByPattern(pattern: u32, prefix: []const u8, args: [][*:0]u8, buffer: []u8) Result {
    _ = prefix;
    _ = args;
    return .{
        .pattern = pattern,
        .name = buffer[0..0],
        .suffix = buffer[0..0],
        .attempts = 0,
    };
}

pub fn getPattern(difficulty: u8) u32 {
    _ = difficulty;
    return 0;
}
