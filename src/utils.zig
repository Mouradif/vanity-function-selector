const std = @import("std");
const lib = @import("root.zig");
const VFSError = lib.VFSError;

pub fn printError(err: VFSError) void {
    std.debug.print("{s}\n", .{
        switch (err) {
            VFSError.ParseError => "Parse Error",
            VFSError.DifficultyTooHigh => "Difficulty must be between 1 and 4",
            VFSError.PatternTooLong => "The pattern cannot be longer than 4 bytes (\"0x\" followed by 8 hex digits)"
        }
    });
}

pub fn isNumeric(str: [*:0]u8) bool {
    var i: usize = 0;
    while (true): (i += 1) {
        const c = str[i];
        if (c == 0) break;
        if (c < '0' or c > '9') return false;
    }
    return true;
}

pub fn isLowerHexDigit(c: u8) bool {
    return (
        c >= '0' and c <= '9'
    ) or (
        c >= 'a' and c <= 'f'
    );
}

pub fn isHexString(str: []const u8) bool {
    if (str.len < 3 or str[0] != '0' or str[1] != 'x') return false;
    for (str[2..]) |c| {
        const d = toLowerCase(c);
        if (!isLowerHexDigit(d)) return false;
    }
    return true;
}

pub fn isFunctionNameIsValid(fct: []const u8) bool {
    if (fct.len == 0) return false;
    if (
        fct[0] != '_' and (
            fct[0] < 'A' or // This includes the nul terminator in case the string is empty
            fct[0] > 'z' or
            (fct[0] > 'Z' and fct[0] < 'a')
        )
    ) return false;
    for (fct[1..]) |c| {
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

pub fn strlen(str: [*:0]u8, max: usize) usize {
    var i: usize = 0;
    while (str[i] > 0 and i <= max): (i += 1) {}
    return i;
}

pub fn toLowerCase(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

pub fn parseSingleHexDigit(digit: u8) VFSError!u4 {
    const c = toLowerCase(digit);
    if (!isLowerHexDigit(c)) {
        return VFSError.ParseError;
    }
    if (c <= '9') return @truncate(c - 48);
    return @truncate(c - 87);
}

pub fn toStringWithMaxLength(arg: [*:0]u8, max_len: usize) []const u8{
    const len = strlen(arg, max_len);
    return arg[0..len];
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
