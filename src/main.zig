const std = @import("std");
const lib = @import("vfs_lib");

const BUF_SIZE = 2049;
const stdout = std.io.getStdOut().writer();

const VFSError = error {
    DifficultyTooHigh,
    PatternTooLong,
};

fn strlen(str: [*:0]u8, max: usize) usize {
    var i: usize = 0;
    while (str[i] > 0 and i <= max): (i += 1) {}
    return i;
}

fn printError(err: VFSError) void {
    std.debug.print("{s}\n", .{
        switch (err) {
            VFSError.DifficultyTooHigh => "Difficulty must be between 1 and 4",
            VFSError.PatternTooLong => "The pattern cannot be longer than 4 bytes (\"0x\" followed by 8 hex digits)"
        }
    });
}

fn isNumeric(str: [*:0]u8) bool {
    var i: usize = 0;
    while (true): (i += 1) {
        const c = str[i];
        if (c == 0) break;
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn isHex(str: [*:0]u8) bool {
    if (strlen(str, 16) < 2 or str[0] != '0' or str[1] != 'x') {
        return false;
    }
    var i: usize = 2;
    while (true): (i += 1) {
        const c = str[i];
        if (c == 0) break;
        if (
            i > 16 or
            (c >= '0' and c <= '9') or
            (c >= 'a' and c <= 'f') or
            (c >= 'A' and c <= 'F')
        ) continue;
        return false;
    }
    return true;
}

fn parseDifficulty(arg: [*:0]u8) VFSError!u8 {
    if (strlen(arg, 2) > 1) return VFSError.DifficultyTooHigh;
    return arg[0] - '0';
}

fn parsePattern(arg: [*:0]u8) VFSError!u32 {
    const len = strlen(arg, 11);
    if (len > 10) return VFSError.PatternTooLong;
    var buffer: [10]u8 = .{ '0', 'x', '0', '0', '0', '0', '0', '0', '0', '0' };
    for (2..10) |i| {
        if (i >= len) break;
        buffer[i] = arg[i];
    }
    return std.fmt.parseInt(u32, buffer[0..10], 0) catch { unreachable; };
}

fn isFunctionNameIsValid(fct: [*:0]u8) bool {
    if (
        fct[0] != '_' and (
            fct[0] < 'A' or // This includes the nul terminator in case the string is empty
            fct[0] > 'z' or
            (fct[0] > 'Z' and fct[0] < 'a')
        )
    ) return false;
    var i: usize = 1;
    while (true): (i += 1) {
        const c = fct[i];
        if (c == 0) break;
        if (
            (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_'
        ) continue;
        return false;
    }
    return true;
}

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

pub fn main() u8 {
    const args = std.os.argv;
    if (args.len < 3) {
        std.debug.print("Usage: vfs <pattern|byte-difficulty> <function-name> [...ARG_TYPE]\n\n", .{});
        std.debug.print("Examples\n", .{});
        std.debug.print("$ vfs 2 mint\n", .{});
        std.debug.print("$ vfs 0xf0f0 bridge address address uint256\n\n", .{});
        return 1;
    }
    if (!isFunctionNameIsValid(args[2])) {
        std.debug.print("Invalid function name {s}\n", .{args[2]});
        return 2;
    }
    const fctlen = strlen(args[2], 64);
    if (isNumeric(args[1])) {
        const difficulty = parseDifficulty(args[1]) catch |e| {
            printError(e);
            return 3;
        };
        var buffer: [BUF_SIZE]u8 = undefined;
        stdout.print("Computing... Looking for a suffix for function {s}({s}) to get a signature starting with 0x{x:0>8}\n", .{
            args[2],
            flattenArgs(args[3..args.len], &buffer),
            lib.getPattern(difficulty),
        }) catch {};
        const result = lib.searchByDifficulty(difficulty, args[2][0..fctlen], args[3..args.len], &buffer);
        std.debug.print("Found suffix: \"{s}\" after {d} attempts\n", .{ result.suffix, result.attempts});
        std.debug.print("0x{x:0>8}: {s}\n", .{ result.pattern, result.name });
        return 0;
    }
    if (isHex(args[1])) {
        const pattern = parsePattern(args[1]) catch |e| {
            printError(e);
            return 4;
        };
        var buffer: [BUF_SIZE]u8 = undefined;
        stdout.print("Computing... Looking for a suffix for function {s}({s}) to get a signature starting with 0x{x:0>8}\n", .{
            args[2],
            flattenArgs(args[3..args.len], &buffer),
            pattern
        }) catch {};
        const result = lib.searchByPattern(pattern, args[2][0..fctlen], args[3..args.len], &buffer);
        std.debug.print("Found suffix: \"{s}\" after {d} attempts\n", .{ result.suffix, result.attempts});
        std.debug.print("0x{x:0>8}: {s}\n", .{ result.pattern, result.name });
        return 0;
    }
    std.debug.print("Invalid difficulty or pattern {s}\n", .{ args[1] });
    return 5;
}
