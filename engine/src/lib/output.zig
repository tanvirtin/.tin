const std = @import("std");

const Color = enum {
    green,
    blue,
    yellow,
    red,
    reset,
};

fn colorCode(color: Color) []const u8 {
    return switch (color) {
        .green => "\x1b[32m",
        .blue => "\x1b[34m",
        .yellow => "\x1b[33m",
        .red => "\x1b[31m",
        .reset => "\x1b[0m",
    };
}

fn isTty() bool {
    return std.posix.isatty(std.posix.STDOUT_FILENO);
}

fn printPrefix(writer: anytype, color: Color) void {
    if (isTty()) {
        writer.print("{s}[tin]{s} ", .{ colorCode(color), colorCode(.reset) }) catch return;
    } else {
        writer.print("[tin] ", .{}) catch return;
    }
}

pub fn success(comptime fmt: []const u8, args: anytype) void {
    const writer = std.fs.File.stdout().deprecatedWriter();
    printPrefix(writer, .green);
    writer.print(fmt ++ "\n", args) catch return;
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    const writer = std.fs.File.stdout().deprecatedWriter();
    printPrefix(writer, .blue);
    writer.print(fmt ++ "\n", args) catch return;
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    const writer = std.fs.File.stderr().deprecatedWriter();
    printPrefix(writer, .yellow);
    writer.print(fmt ++ "\n", args) catch return;
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    const writer = std.fs.File.stderr().deprecatedWriter();
    printPrefix(writer, .red);
    writer.print(fmt ++ "\n", args) catch return;
}

pub fn plain(comptime fmt: []const u8, args: anytype) void {
    const writer = std.fs.File.stdout().deprecatedWriter();
    writer.print(fmt ++ "\n", args) catch return;
}

test "isTty returns a boolean" {
    _ = isTty();
}
