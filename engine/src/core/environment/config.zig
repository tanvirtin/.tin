const std = @import("std");
const yaml = @import("yaml");
const Paths = @import("paths.zig");
const output = @import("../../lib/output.zig");
const fs = @import("../../lib/fs.zig");
const Engine = @import("../../schemalang/engine.zig").Engine;
const Diagnostic = @import("../../schemalang/diagnostic.zig").Diagnostic;

pub const Config = @This();

doc: ?yaml.DocNode,

const max_config_bytes = 256 * 1024;

pub const LoadError = error{
    ConfigUnreadable,
    ConfigTooLarge,
    ConfigMalformed,
    ConfigSchemaUnavailable,
    ConfigSchemaInvalid,
};

fn isEmptyDoc(doc: yaml.DocNode) bool {
    return doc.value.tree.nodes.items[doc.value.idx].tag == .null;
}

pub fn load(allocator: std.mem.Allocator, paths: Paths) !?Config {
    const selection = try paths.selectTinrc(allocator);
    defer selection.deinit(allocator);
    const config_path = selection.path orelse return null;

    const file = std.fs.openFileAbsolute(config_path, .{}) catch |e| {
        output.err("cannot read configuration {s}: {s}", .{ config_path, @errorName(e) });
        return LoadError.ConfigUnreadable;
    };
    defer file.close();

    const size = file.getEndPos() catch |e| {
        output.err("cannot stat configuration {s}: {s}", .{ config_path, @errorName(e) });
        return LoadError.ConfigUnreadable;
    };
    if (size > max_config_bytes) {
        output.err("configuration {s} is {d} bytes, over the {d}KB limit — refusing to load a truncated config", .{ config_path, size, max_config_bytes / 1024 });
        return LoadError.ConfigTooLarge;
    }

    const content = file.readToEndAlloc(allocator, max_config_bytes) catch |e| {
        output.err("cannot read configuration {s}: {s}", .{ config_path, @errorName(e) });
        return LoadError.ConfigUnreadable;
    };
    defer allocator.free(content);

    var doc = yaml.parse(allocator, content) catch |e| {
        output.err("configuration {s} is not valid YAML: {s}", .{ config_path, @errorName(e) });
        return LoadError.ConfigMalformed;
    };
    errdefer doc.deinit();

    if (!isEmptyDoc(doc)) {
        const diagnostics = validate(allocator, paths, config_path) catch |e| {
            output.err("cannot validate configuration {s}: schema engine unavailable ({s})", .{ config_path, @errorName(e) });
            return LoadError.ConfigSchemaUnavailable;
        };
        if (diagnostics.len > 0) {
            output.err("configuration {s} failed schema validation ({d} error(s)):", .{ config_path, diagnostics.len });
            for (diagnostics) |d| {
                output.err("  [{s}] {s} at byte {d}", .{ d.code, d.message, d.span.start });
            }
            return LoadError.ConfigSchemaInvalid;
        }
    }

    return .{ .doc = doc };
}

pub fn loadOrEmpty(allocator: std.mem.Allocator, paths: Paths) !Config {
    return (try load(allocator, paths)) orelse .{ .doc = null };
}

pub fn validate(allocator: std.mem.Allocator, paths: Paths, config_path: []const u8) ![]const Diagnostic {
    const schemas_dir = try paths.schemasDir(allocator);
    defer allocator.free(schemas_dir);

    var engine = try Engine.initWithSchemasDir(allocator, schemas_dir);
    defer engine.deinit();

    return engine.validateFile(allocator, schemas_dir, "tinrc.yaml", config_path);
}

pub fn getMapping(self: *const Config, key: []const u8) ?yaml.Value {
    const doc = self.doc orelse return null;
    return doc.getMapping(key);
}

const Fixture = struct {
    root: []const u8,
    tin_dir: []const u8,
    config_dir: []const u8,
    personal: []const u8,
    repo: []const u8,
    paths: Paths,
};

fn fixture(a: std.mem.Allocator, tmp: *std.testing.TmpDir) !Fixture {
    const root = try tmp.parent_dir.realpathAlloc(a, &tmp.sub_path);
    const tin_dir = try std.fs.path.join(a, &.{ root, ".tin" });
    const config_dir = try std.fs.path.join(a, &.{ root, ".config", "tin" });
    const personal = try std.fs.path.join(a, &.{ config_dir, "tinrc.yml" });
    const repo = try std.fs.path.join(a, &.{ tin_dir, "tinrc.yml" });
    return .{
        .root = root,
        .tin_dir = tin_dir,
        .config_dir = config_dir,
        .personal = personal,
        .repo = repo,
        .paths = Paths{ .tin_dir = tin_dir, .home_dir = root },
    };
}

fn installSchemas(a: std.mem.Allocator, tin_dir: []const u8) !void {
    const schemas_dir = try std.fs.path.join(a, &.{ tin_dir, "engine", "src", "schemas" });
    try fs.ensureDirectoryExists(schemas_dir);
    const meta_src = try std.fs.cwd().readFileAlloc(a, "src/schemas/meta-schema.yaml", 1 << 20);
    const tinrc_src = try std.fs.cwd().readFileAlloc(a, "src/schemas/tinrc.yaml", 1 << 20);
    const meta_dst = try std.fs.path.join(a, &.{ schemas_dir, "meta-schema.yaml" });
    const tinrc_dst = try std.fs.path.join(a, &.{ schemas_dir, "tinrc.yaml" });
    try fs.writeFile(meta_dst, meta_src);
    try fs.writeFile(tinrc_dst, tinrc_src);
}

test "getMapping returns value for present key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try yaml.parse(arena.allocator(), "a: 1\nb: hello");
    const config = Config{ .doc = doc };
    try std.testing.expect(config.getMapping("a") != null);
    try std.testing.expect(config.getMapping("b") != null);
}

test "getMapping returns null for missing key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try yaml.parse(arena.allocator(), "a: 1");
    const config = Config{ .doc = doc };
    try std.testing.expect(config.getMapping("missing") == null);
}

test "getMapping returns null when doc is absent" {
    const config = Config{ .doc = null };
    try std.testing.expect(config.getMapping("anything") == null);
}

test "load returns null when neither config file exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try fixture(a, &tmp);

    try std.testing.expect((try load(a, f.paths)) == null);
    const empty = try loadOrEmpty(a, f.paths);
    try std.testing.expect(empty.getMapping("identity") == null);
}

test "load reads a repo-only configuration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try fixture(a, &tmp);

    try installSchemas(a, f.tin_dir);
    try fs.ensureDirectoryExists(f.tin_dir);
    try fs.writeFile(f.repo, "identity:\n  name: repo\n");

    const config = (try load(a, f.paths)).?;
    try std.testing.expect(config.getMapping("identity") != null);
}

test "load prefers a personal configuration over the repo default" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try fixture(a, &tmp);

    try installSchemas(a, f.tin_dir);
    try fs.ensureDirectoryExists(f.tin_dir);
    try fs.writeFile(f.repo, "identity:\n  name: repo\n");
    try fs.ensureDirectoryExists(f.config_dir);
    try fs.writeFile(f.personal, "identity:\n  name: personal\n");

    const config = (try load(a, f.paths)).?;
    const identity = config.getMapping("identity").?;
    const name = identity.getMapping("name").?;
    try std.testing.expectEqualStrings("personal", name.getString().?);
}

test "load accepts an existing but empty configuration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try fixture(a, &tmp);

    try installSchemas(a, f.tin_dir);
    try fs.ensureDirectoryExists(f.tin_dir);
    try fs.writeFile(f.repo, "");

    const config = (try load(a, f.paths)).?;
    try std.testing.expect(config.getMapping("identity") == null);
}

test "load reports malformed YAML as an error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try fixture(a, &tmp);

    try installSchemas(a, f.tin_dir);
    try fs.ensureDirectoryExists(f.tin_dir);
    try fs.writeFile(f.repo, "identity: [unterminated\n");

    try std.testing.expectError(LoadError.ConfigMalformed, load(a, f.paths));
}

test "load rejects schema-invalid but syntactically valid configuration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try fixture(a, &tmp);

    try installSchemas(a, f.tin_dir);
    try fs.ensureDirectoryExists(f.tin_dir);
    try fs.writeFile(f.repo, "identity: not-an-object\n");

    try std.testing.expectError(LoadError.ConfigSchemaInvalid, load(a, f.paths));
}

test "load rejects an oversized configuration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try fixture(a, &tmp);

    try fs.ensureDirectoryExists(f.tin_dir);
    const big = try a.alloc(u8, max_config_bytes + 1);
    @memset(big, 'a');
    try fs.writeFile(f.repo, big);

    try std.testing.expectError(LoadError.ConfigTooLarge, load(a, f.paths));
}

test "load reports an unreadable selected configuration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try fixture(a, &tmp);

    try fs.ensureDirectoryExists(f.tin_dir);
    try fs.writeFile(f.repo, "identity:\n  name: repo\n");
    const file = try std.fs.openFileAbsolute(f.repo, .{});
    try file.chmod(0o000);
    file.close();
    defer {
        const restore = std.fs.openFileAbsolute(f.repo, .{}) catch null;
        if (restore) |r| {
            r.chmod(0o600) catch {};
            r.close();
        }
    }

    try std.testing.expectError(LoadError.ConfigUnreadable, load(a, f.paths));
}

test "load reports a dangling personal symlink instead of falling back to repo" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try fixture(a, &tmp);

    try installSchemas(a, f.tin_dir);
    try fs.ensureDirectoryExists(f.tin_dir);
    try fs.writeFile(f.repo, "identity:\n  name: repo\n");
    try fs.ensureDirectoryExists(f.config_dir);
    const absent = try std.fs.path.join(a, &.{ f.root, "absent.yml" });
    try std.fs.symLinkAbsolute(absent, f.personal, .{});

    try std.testing.expectError(LoadError.ConfigUnreadable, load(a, f.paths));
}

test "load keeps relative paths resolving against the tin dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try fixture(a, &tmp);

    try installSchemas(a, f.tin_dir);
    try fs.ensureDirectoryExists(f.tin_dir);
    try fs.writeFile(f.repo, "exports:\n  local:\n    dir: relative/skills\n");

    const config = (try load(a, f.paths)).?;
    const targets = try @import("recipe_manager.zig").getExportTargets(a, config, f.paths);
    try std.testing.expectEqual(@as(usize, 1), targets.len);
    const expected = try std.fs.path.join(a, &.{ f.tin_dir, "relative/skills" });
    try std.testing.expectEqualStrings(expected, targets[0].dir);
}

test "load fails clearly when the schema engine is unavailable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try fixture(a, &tmp);

    try fs.ensureDirectoryExists(f.tin_dir);
    try fs.writeFile(f.repo, "identity:\n  name: repo\n");

    try std.testing.expectError(LoadError.ConfigSchemaUnavailable, load(a, f.paths));
}
