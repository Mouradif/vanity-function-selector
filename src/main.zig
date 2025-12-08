const std = @import("std");
const vfs = @import("vfs");
const Utils = vfs.Utils;
const Constants = vfs.Constants;

const VFSError = vfs.VFSError;
const BitMasks = vfs.BitMasks;
const BitMasks160 = vfs.BitMasks160;

var stdout_buffer: [Constants.BUF_SIZE]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;

fn usage() u8 {
    std.debug.print("Ethereum Vanity Cruncher\n\n", .{});
    std.debug.print("Usage: vfs <mode> [options...]\n\n", .{});
    std.debug.print("Modes:\n", .{});
    std.debug.print("  selector  - Find vanity function selectors\n", .{});
    std.debug.print("  create2   - Find vanity CREATE2 addresses\n\n", .{});
    std.debug.print("Selector Mode:\n", .{});
    std.debug.print("  vfs selector <pattern> <function-name> [...ARG_TYPE]\n\n", .{});
    std.debug.print("  Examples:\n", .{});
    std.debug.print("    vfs selector 0xaa mint\n", .{});
    std.debug.print("    vfs selector 0xaaxxxxxx mint    # 'x' is wildcard\n", .{});
    std.debug.print("    vfs selector 0xf00xxf00 bridge address address uint256\n\n", .{});
    std.debug.print("CREATE2 Mode:\n", .{});
    std.debug.print("  vfs create2 <pattern> <deployer-address> <init-code-hex>\n\n", .{});
    std.debug.print("  Examples:\n", .{});
    std.debug.print("    vfs create2 0xdead 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed 0x60...\n", .{});
    std.debug.print("    vfs create2 0x0000cafe 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed 0x60...\n\n", .{});
    return 1;
}

fn print(comptime format: []const u8, args: anytype) void {
    stdout.print(format, args) catch {};
    stdout.flush() catch {};
}

fn runSelectorMode(args: [][*:0]u8) u8 {
    if (args.len < 2) {
        std.debug.print("selector mode requires: <pattern> <function-name> [...ARG_TYPE]\n", .{});
        return 1;
    }

    const pattern_str = Utils.toStringWithMaxLength(args[0], 11);
    const pattern = BitMasks.fromPattern(pattern_str) catch |e| {
        Utils.printError(e);
        return 1;
    };
    const fct_name = Utils.toStringWithMaxLength(args[1], 64);
    if (!Utils.isFunctionNameIsValid(fct_name)) {
        std.debug.print("Invalid function name {s}\n", .{args[1]});
        return 2;
    }
    var args_buffer: [Constants.MAX_FQFN_LEN]u8 = undefined;
    const args_str = Utils.flattenArgs(args[2..], &args_buffer);
    print("Computing... Looking for a suffix for function {s}<suffix>({s}) to get a signature matching pattern {s:x<10}\n", .{
        fct_name,
        args_str,
        pattern_str,
    });
    var result = vfs.searchByPatternGPU(pattern, fct_name, args_str) catch null;
    if (result == null) {
        std.debug.print("Failed to connect GPU (Metal). Falling back on the CPU\n", .{});
        result = vfs.searchByPattern(pattern, fct_name, args_str);
    }
    print("Found suffix: \"{s}\" after {d} attempts\n", .{ result.?.suffix[0..result.?.suffix_len], result.?.attempts });
    print("0x{x:0>8}: {s}\n", .{ result.?.pattern, result.?.name[0..result.?.name_len] });
    return 0;
}

fn parseHexAddress(str: []const u8) ![20]u8 {
    var addr: [20]u8 = undefined;
    const hex_str = if (str.len >= 2 and str[0] == '0' and (str[1] == 'x' or str[1] == 'X'))
        str[2..]
    else
        str;

    if (hex_str.len != 40) return error.InvalidAddressLength;

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        addr[i] = try std.fmt.parseInt(u8, hex_str[i * 2 .. i * 2 + 2], 16);
    }
    return addr;
}

fn parseHexBytes(allocator: std.mem.Allocator, str: []const u8) ![]u8 {
    const hex_str = if (str.len >= 2 and str[0] == '0' and (str[1] == 'x' or str[1] == 'X'))
        str[2..]
    else
        str;

    if (hex_str.len % 2 != 0) return error.InvalidHexLength;

    const bytes = try allocator.alloc(u8, hex_str.len / 2);
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        bytes[i] = try std.fmt.parseInt(u8, hex_str[i * 2 .. i * 2 + 2], 16);
    }
    return bytes;
}

fn runCreate2Mode(args: [][*:0]u8) u8 {
    if (args.len < 3) {
        std.debug.print("create2 mode requires: <pattern> <deployer-address> <init-code-hex>\n", .{});
        return 1;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const pattern_str = Utils.toStringWithMaxLength(args[0], 43); // 0x + 40 hex digits
    const pattern = BitMasks160.fromPattern(pattern_str) catch |e| {
        Utils.printError(e);
        return 1;
    };

    const deployer_str = Utils.toStringWithMaxLength(args[1], 256);
    const deployer = parseHexAddress(deployer_str) catch {
        std.debug.print("Invalid deployer address: {s}\n", .{deployer_str});
        return 1;
    };

    const init_code_str = Utils.toStringWithMaxLength(args[2], 65536);
    const init_code = parseHexBytes(allocator, init_code_str) catch {
        std.debug.print("Invalid init code hex: {s}\n", .{init_code_str});
        return 1;
    };
    defer allocator.free(init_code);

    print("Computing... Looking for a CREATE2 salt with deployer 0x{x} to get an address matching pattern {s}\n", .{
        deployer,
        pattern_str,
    });

    var result = vfs.searchCreate2GPU(deployer, init_code, pattern) catch blk: {
        std.debug.print("Failed to connect GPU (Metal). Falling back on the CPU\n", .{});
        break :blk vfs.searchCreate2CPU(deployer, init_code, pattern);
    };

    print("Found salt after {d} attempts\n", .{result.attempts});
    print("Salt:    0x{x}\n", .{result.salt});
    print("Address: 0x{x}\n", .{result.address});
    return 0;
}

pub fn main() u8 {
    const args = std.os.argv;
    if (args.len < 2) return usage();

    const mode_str = Utils.toStringWithMaxLength(args[1], 32);

    if (std.mem.eql(u8, mode_str, "selector")) {
        return runSelectorMode(args[2..]);
    } else if (std.mem.eql(u8, mode_str, "create2")) {
        return runCreate2Mode(args[2..]);
    } else {
        std.debug.print("Unknown mode: {s}\n\n", .{mode_str});
        return usage();
    }
}
