const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var args = std.process.args();
    _ = args.next();
    const path = args.next() orelse std.process.exit(1);
    const dir = std.fs.path.dirname(path) orelse std.process.exit(1);
    const base = std.fs.path.basename(dir);

    if (std.mem.endsWith(u8, base, "-crash")) std.process.exit(3);
    if (std.mem.endsWith(u8, base, "-hang")) {
        std.Thread.sleep(60 * std.time.ns_per_s);
        std.process.exit(0);
    }
    if (std.mem.endsWith(u8, base, "-misaccept")) std.process.exit(0);
    if (std.mem.endsWith(u8, base, "-misreject")) std.process.exit(2);

    const err = std.fs.path.join(allocator, &.{ dir, "error" }) catch std.process.exit(0);
    defer allocator.free(err);
    std.fs.cwd().access(err, .{}) catch std.process.exit(0);
    std.process.exit(2);
}