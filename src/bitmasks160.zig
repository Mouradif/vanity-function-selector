const BitMasks160 = @This();

const utils = @import("utils.zig");
const VFSError = @import("errors.zig").VFSError;
const std = @import("std");

// Ethereum addresses are 160 bits (20 bytes)
must_be_one: u160 = 0,
must_be_zero: u160 = 0,

/// Parse an Ethereum address pattern (with wildcards) into bit masks
/// Pattern format: "0x" followed by up to 40 hex digits (20 bytes)
/// Use 'x' or 'X' as wildcards for don't-care positions
/// Examples: "0xdead", "0xdeadbeefxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", "0x00000000cafebabe"
pub fn fromPattern(pattern: []const u8) VFSError!BitMasks160 {
    if (pattern.len < 2 or pattern[0] != '0' or pattern[1] != 'x') {
        return VFSError.ParseError;
    }
    if (pattern.len > 42) { // 0x + 40 hex digits
        return VFSError.PatternTooLong;
    }

    var must_be_one: u160 = 0;
    var must_be_zero: u160 = 0;

    for (pattern[2..], 0..) |c, i| {
        if (c == 'x' or c == 'X') continue;

        // 40 hex digits, each is 4 bits
        // Most significant digit is at i=0, shift by (159-156) = 156
        // Least significant digit is at i=39, shift by 0
        const shift: u8 = @intCast(156 - (4 * i));

        const digit_value = try utils.parseSingleHexDigit(c);

        // Set bits that must be 1
        must_be_one |= @as(u160, digit_value) << shift;

        // Set bits that must be 0 (inverse of the digit value)
        for (0..4) |bit| {
            const mini_shift: u2 = @intCast(bit);
            if ((@as(u4, 1) << mini_shift) & digit_value == 0) {
                must_be_zero |= @as(u160, 1) << (shift + mini_shift);
            }
        }
    }

    return .{
        .must_be_one = must_be_one,
        .must_be_zero = must_be_zero,
    };
}

/// Check if an address (as u160) matches the pattern
pub fn check(self: BitMasks160, addr: u160) bool {
    return (addr & self.must_be_one) == self.must_be_one and (addr & self.must_be_zero) == 0;
}

/// Check if an address (as 20-byte array) matches the pattern
pub fn checkBytes(self: BitMasks160, addr: [20]u8) bool {
    const addr_int = std.mem.readInt(u160, &addr, .big);
    return self.check(addr_int);
}

/// Convert a 20-byte address to u160 (big-endian)
pub fn addressToU160(addr: [20]u8) u160 {
    return std.mem.readInt(u160, &addr, .big);
}

/// Convert u160 to a 20-byte address (big-endian)
pub fn u160ToAddress(val: u160) [20]u8 {
    var addr: [20]u8 = undefined;
    std.mem.writeInt(u160, &addr, val, .big);
    return addr;
}

/// Convert bit mask to 5 x u32 array for Metal shader (big-endian)
/// The GPU shader uses [5]u32 where [0] is most significant
pub fn toU32Array(val: u160) [5]u32 {
    var result: [5]u32 = undefined;
    var temp = val;
    // Extract from least significant to most significant
    result[4] = @truncate(temp);
    temp >>= 32;
    result[3] = @truncate(temp);
    temp >>= 32;
    result[2] = @truncate(temp);
    temp >>= 32;
    result[1] = @truncate(temp);
    temp >>= 32;
    result[0] = @truncate(temp);
    return result;
}
