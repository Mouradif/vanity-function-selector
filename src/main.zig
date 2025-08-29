const std = @import("std");
const lib = @import("root.zig");
const utils = @import("utils.zig");
const Constants = @import("constants.zig");

const VFSError = lib.VFSError;
const BitMasks = lib.BitMasks;

var stdout_buffer: [Constants.BUF_SIZE]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;

fn usage() u8 {
    std.debug.print("Usage: vfs <pattern> <function-name> [...ARG_TYPE]\n\n", .{});
    std.debug.print("Examples\n\n", .{});
    std.debug.print("# Will return a function mintXX() (where 'XX' is the brute-forced suffix) that has a selector starting with 0xaa\n", .{});
    std.debug.print("$ vfs 0xaa mint\n\n", .{});
    std.debug.print("# Use the character 'x' as a wildcard. The following is equivalent to just 0xaa\n", .{});
    std.debug.print("$ vfs 0xaaxxxxxx mint\n\n", .{});
    std.debug.print("# You can pass function argument types as subsequent arguments\n", .{});
    std.debug.print("$ vfs 0xf0f0 bridge address address uint256\n\n", .{});
    std.debug.print("# Or as a single argument if you have complex types like tuples or structs\n", .{});
    std.debug.print("$ vfs 0x00 swap \"(address,address,uint256[]),(address,address,uint256[])\"\n\n", .{});
    return 1;
}

fn print(comptime format: []const u8, args: anytype) void {
    stdout.print(format, args) catch {};
    stdout.flush() catch {};
}

pub fn main() u8 {
    const args = std.os.argv;
    if (args.len < 3) return usage();

    const pattern_str = utils.toStringWithMaxLength(args[1], 11);
    const pattern = BitMasks.fromPattern(pattern_str) catch |e| {
            utils.printError(e);
            return 1;
    };
    const fct_name = utils.toStringWithMaxLength(args[2], 64);
    if (!utils.isFunctionNameIsValid(fct_name)) {
        std.debug.print("Invalid function name {s}\n", .{args[2]});
        return 2;
    }
    var args_buffer: [Constants.MAX_FQFN_LEN]u8 = undefined;
    const args_str = utils.flattenArgs(args[3..], &args_buffer);
    print("Computing... Looking for a suffix for function {s}<suffix>({s}) to get a signature matching pattern {s:x<10}\n", .{
        fct_name,
        args_str,
        pattern_str,
    });
    const result = lib.searchByPatternGPU(pattern, fct_name, args_str) catch lib.searchByPattern(pattern, fct_name, args_str);
    print("Found suffix: \"{s}\" after {d} attempts\n", .{ result.suffix[0..result.suffix_len], result.attempts });
    print("0x{x:0>8}: {s}\n", .{ result.pattern, result.name[0..result.name_len] });
    return 0;
}
