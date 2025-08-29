const BitMasks = @This();

const utils = @import("utils.zig");
const VFSError = @import("errors.zig").VFSError;

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
        const digit_value = try utils.parseSingleHexDigit(c);
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
