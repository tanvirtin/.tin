const std = @import("std");
const fs = @import("../lib/fs.zig");
const output = @import("../lib/output.zig");
const Environment = @import("../core/environment.zig");

pub const meta = .{
    .name = "schema",
    .description = "Browse built-in YAML validation schemas",
};

pub fn schemasDir(allocator: std.mem.Allocator) ?[]const u8 {
    const env = Environment.init(allocator) catch return null;
    return std.fs.path.join(allocator, &.{ env.paths.tin_dir, "src", "schemas" }) catch null;
}

pub fn resolveSchemaRef(allocator: std.mem.Allocator, schemas_dir: []const u8, ref: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, ref, '/') != null or
        std.mem.endsWith(u8, ref, ".yaml") or
        std.mem.endsWith(u8, ref, ".yml"))
    {
        return ref;
    }
    const candidate = std.fmt.allocPrint(allocator, "{s}/{s}.yaml", .{ schemas_dir, ref }) catch return null;
    std.fs.cwd().access(candidate, .{}) catch return null;
    return candidate;
}

fn listSchemas(allocator: std.mem.Allocator, dir_path: []const u8) void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
        output.err("could not open schemas directory: {s}", .{dir_path});
        std.process.exit(2);
    };
    defer dir.close();

    var names = std.ArrayListUnmanaged([]const u8){};
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".yaml")) continue;
        const name = allocator.dupe(u8, entry.name[0 .. entry.name.len - 5]) catch continue;
        names.append(allocator, name) catch continue;
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);

    for (names.items) |n| output.plain("{s}", .{n});
}

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) void {
    const sub = if (args.len > 0) args[0] else "list";

    const dir_path = schemasDir(allocator) orelse {
        output.err("could not resolve schemas directory", .{});
        std.process.exit(2);
    };

    if (std.mem.eql(u8, sub, "list")) {
        listSchemas(allocator, dir_path);
        return;
    }

    if (args.len < 2) {
        output.err("usage: tin schema <list|show|path> [name]", .{});
        std.process.exit(2);
    }
    const name = args[1];

    const resolved = resolveSchemaRef(allocator, dir_path, name) orelse {
        output.err("unknown schema: {s}", .{name});
        std.process.exit(2);
    };

    if (std.mem.eql(u8, sub, "path")) {
        const abs = std.fs.cwd().realpathAlloc(allocator, resolved) catch {
            output.err("could not resolve schema file: {s}", .{resolved});
            std.process.exit(2);
        };
        output.plain("{s}", .{abs});
        return;
    }

    if (std.mem.eql(u8, sub, "show")) {
        const content = fs.readFileAlloc(allocator, resolved) catch {
            output.err("could not read schema file: {s}", .{resolved});
            std.process.exit(2);
        };
        output.plain("{s}", .{content});
        return;
    }

    output.err("unknown subcommand: {s} (expected list|show|path)", .{sub});
    std.process.exit(2);
}
