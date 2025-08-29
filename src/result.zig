const Constants = @import("constants.zig");

pattern: u32,
name: [Constants.MAX_FQFN_LEN]u8,
name_len: usize,
suffix: [Constants.MAX_SUFFIX_LEN]u8,
suffix_len: usize,
attempts: usize,
