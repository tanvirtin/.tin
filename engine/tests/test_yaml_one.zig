const std = @import("std");
const yaml = @import("yaml");

const accepted_exit: u8 = 0;
const rejection_exit: u8 = 2;
const operational_exit: u8 = 1;

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var args = std.process.args();
    _ = args.next();
    const path = args.next() orelse {
        std.debug.print("test_yaml_one: missing input path\n", .{});
        std.process.exit(operational_exit);
    };
    const file = std.fs.openFileAbsolute(path, .{}) catch {
        std.debug.print("test_yaml_one: cannot open {s}\n", .{path});
        std.process.exit(operational_exit);
    };
    defer file.close();
    const content = file.readToEndAlloc(arena.allocator(), 64 * 1024 * 1024) catch {
        std.debug.print("test_yaml_one: cannot read {s}\n", .{path});
        std.process.exit(operational_exit);
    };
    if (yaml.parse(arena.allocator(), content)) |doc| {
        _ = doc;
        std.process.exit(accepted_exit);
    } else |_| {
        std.process.exit(rejection_exit);
    }
}
