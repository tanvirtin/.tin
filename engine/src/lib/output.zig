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

fn emit(file: std.fs.File, color: ?Color, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var file_writer = file.writerStreaming(&buf);
    const writer = &file_writer.interface;
    defer writer.flush() catch {};
    if (color) |c| printPrefix(writer, c);
    writer.print(fmt ++ "\n", args) catch return;
}

pub fn success(comptime fmt: []const u8, args: anytype) void {
    emit(std.fs.File.stdout(), .green, fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    emit(std.fs.File.stdout(), .blue, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    emit(std.fs.File.stderr(), .yellow, fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    emit(std.fs.File.stderr(), .red, fmt, args);
}

pub fn plain(comptime fmt: []const u8, args: anytype) void {
    emit(std.fs.File.stdout(), null, fmt, args);
}

test "isTty returns a boolean" {
    _ = isTty();
}
