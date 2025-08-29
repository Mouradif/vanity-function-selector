const std = @import("std");
const lib = @import("root.zig");
const utils = @import("utils.zig");
const C = @import("constants.zig");

const VFSError = lib.VFSError;
const BitMasks = lib.BitMasks;

const printError = utils.printError;
const isFunctionNameIsValid = utils.isFunctionNameIsValid;
const strlen = utils.strlen;
const toStringWithMaxLength = utils.toStringWithMaxLength;
const isHexString = utils.isHexString;
const flattenArgs = utils.flattenArgs;

const BUF_SIZE = 2048;
var stdout_buffer: [BUF_SIZE]u8 = undefined;
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

    const pattern_str = toStringWithMaxLength(args[1], 11);
    const pattern = BitMasks.fromPattern(pattern_str) catch |e| {
            printError(e);
            return 1;
    };
    const fct_name = toStringWithMaxLength(args[2], 64);
    if (!isFunctionNameIsValid(fct_name)) {
        std.debug.print("Invalid function name {s}\n", .{args[2]});
        return 2;
    }
    var buffer: [BUF_SIZE]u8 = undefined;
    const args_str = flattenArgs(args[3..], &buffer);
    print("Computing... Looking for a suffix for function {s}({s}) to get a signature matching pattern {s:x<10}\n", .{
        fct_name,
        args_str,
        pattern_str,
    });
    var result_buf: [C.MAX_FQFN_LEN]u8 = undefined;
    const gpu_res = lib.searchByPatternGPU(&result_buf, pattern, fct_name, args_str);
    if (gpu_res) |r| {
        print("Found (GPU) suffix: \"{s}\" after ~{d} attempts\n", .{ r.suffix, r.attempts });
        print("0x{x:0>8}: {s}\n", .{ r.pattern, r.name });
        return 0;
    }

    // Fallback to CPU
    const result = lib.searchByPattern(pattern, fct_name, args_str);
    print("Found (CPU) suffix: \"{s}\" after {d} attempts\n", .{ result.suffix, result.attempts });
    print("0x{x:0>8}: {s}\n", .{ result.pattern, result.name });
    return 0;
}
