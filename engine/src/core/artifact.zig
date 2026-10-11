const std = @import("std");
const fs = @import("../lib/fs.zig");
const yaml = @import("yaml");
const output = @import("../lib/output.zig");
const mcp = @import("mcp.zig");

pub const Rule = @import("artifact/rule.zig");
pub const Skill = @import("artifact/skill.zig");
pub const exporter = @import("artifact/export.zig");

const Engine = @import("../schemalang/engine.zig").Engine;
const Catalog = @import("../schemalang/resolve.zig").Catalog;
const Schema = @import("../schemalang/ir.zig").Schema;
const validate_mod = @import("../schemalang/core.zig");
const PathExpression = @import("../schemalang/resolve.zig").PathExpression;

const Artifact = @This();

pub const Error = error{
    DirectoryNotFound,
    ParseFailed,
};

allocator: std.mem.Allocator,
artifacts_dir: []const u8,
engine: Engine,
skill_schema: Schema,
rule_schema: Schema,
mcp_schema: Schema,
dialect_schema: Schema,
catalog: Catalog,

pub fn init(allocator: std.mem.Allocator, tin_dir: []const u8, artifacts_dir: []const u8) !Artifact {
    const owned_dir = try allocator.dupe(u8, artifacts_dir);

    var dir = std.fs.openDirAbsolute(owned_dir, .{}) catch {
        allocator.free(owned_dir);
        return Error.DirectoryNotFound;
    };
    dir.close();

    const schemas_dir = try std.fmt.allocPrint(allocator, "{s}/engine/src/schemas", .{tin_dir});
    defer allocator.free(schemas_dir);

    var engine = try Engine.initWithSchemasDir(allocator, schemas_dir);

    const skill_schema = try loadSchemaFile(allocator, &engine, schemas_dir, "skill.yaml");
    const rule_schema = try loadSchemaFile(allocator, &engine, schemas_dir, "rule.yaml");
    const mcp_schema = try loadSchemaFile(allocator, &engine, schemas_dir, "mcp.yaml");
    const dialect_schema = try loadSchemaFile(allocator, &engine, schemas_dir, "dialect.yaml");

    return .{
        .allocator = allocator,
        .artifacts_dir = owned_dir,
        .engine = engine,
        .skill_schema = skill_schema,
        .rule_schema = rule_schema,
        .mcp_schema = mcp_schema,
        .dialect_schema = dialect_schema,
        .catalog = Catalog.init(allocator),
    };
}

fn loadSchemaFile(allocator: std.mem.Allocator, engine: *Engine, schemas_dir: []const u8, filename: []const u8) !Schema {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ schemas_dir, filename });
    defer allocator.free(path);
    const content = try fs.readFileAlloc(allocator, path);
    defer allocator.free(content);
    return engine.loadSchema(content);
}

pub fn deinit(self: *Artifact) void {
    self.catalog.deinit();
    self.engine.deinit();
    self.allocator.free(self.artifacts_dir);
}

pub fn validate(self: *Artifact) !void {
    var all_pending_refs = std.ArrayListUnmanaged(validate_mod.PendingReference){};
    defer {
        freePendingRefs(self.allocator, all_pending_refs.items);
        all_pending_refs.deinit(self.allocator);
    }
    var all_diagnostics = std.ArrayListUnmanaged(validate_mod.Diagnostic){};
    defer {
        for (all_diagnostics.items) |d| {
            self.allocator.free(d.code);
            self.allocator.free(d.message);
        }
        all_diagnostics.deinit(self.allocator);
    }

    try self.processArtifacts("rules", &self.rule_schema, "rule_id", &all_pending_refs, &all_diagnostics);
    try self.processArtifacts("skills", &self.skill_schema, "skill_id", &all_pending_refs, &all_diagnostics);
    try self.processArtifacts("dialects", &self.dialect_schema, "dialect_id", &all_pending_refs, &all_diagnostics);
    try self.processArtifacts("mcp", &self.mcp_schema, "mcp_id", &all_pending_refs, &all_diagnostics);

    for (all_pending_refs.items) |pr| {
        if (pr.catalog_kind) |ck| {
            if (self.catalog.resolve(ck, pr.name) == null) {
                try all_diagnostics.append(self.allocator, .{
                    .severity = .err,
                    .span = pr.span,
                    .code = try self.allocator.dupe(u8, "undefined_reference"),
                    .message = try std.fmt.allocPrint(self.allocator, "undefined reference: {s} ({s})", .{ pr.name, ck }),
                    .related = &.{},
                    .suggestions = &.{},
                });
            }
        }
    }

    if (all_diagnostics.items.len > 0) {
        for (all_diagnostics.items) |d| {
            output.err("[{s}] {s}", .{ d.code, d.message });
        }
        return Error.ParseFailed;
    }
}

fn processArtifacts(
    self: *Artifact,
    sub_dir: []const u8,
    schema: *const Schema,
    catalog_kind: []const u8,
    all_pending_refs: *std.ArrayListUnmanaged(validate_mod.PendingReference),
    all_diagnostics: *std.ArrayListUnmanaged(validate_mod.Diagnostic),
) !void {
    const base_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.artifacts_dir, sub_dir });
    defer self.allocator.free(base_dir);

    var dir = std.fs.openDirAbsolute(base_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var ctx = ValidateCtx{
        .artifact = self,
        .base_dir = base_dir,
        .schema = schema,
        .catalog_kind = catalog_kind,
        .pending = all_pending_refs,
        .diagnostics = all_diagnostics,
    };
    try walkYmlFiles(self.allocator, dir, base_dir, &ctx, processArtifactFile);
}

const ValidateCtx = struct {
    artifact: *Artifact,
    base_dir: []const u8,
    schema: *const Schema,
    catalog_kind: []const u8,
    pending: *std.ArrayListUnmanaged(validate_mod.PendingReference),
    diagnostics: *std.ArrayListUnmanaged(validate_mod.Diagnostic),
};

fn processArtifactFile(ctx: *ValidateCtx, file_path: []const u8) anyerror!void {
    const self = ctx.artifact;
    const content = fs.readFileAlloc(self.allocator, file_path) catch return;
    defer self.allocator.free(content);
    const id = try deriveId(self.allocator, ctx.base_dir, file_path);

    const doc = try yaml.parse(self.allocator, content);
    var v = validate_mod.Validator.init(self.allocator, null, &self.engine.sublangs, &self.catalog);
    defer v.deinit();
    try validate_mod.validateImpl(&v, ctx.schema, doc.value);

    for (v.diagnostics.items) |d| {
        try ctx.diagnostics.append(self.allocator, try cloneDiagnostic(self.allocator, d));
    }

    for (v.pending_refs.items) |pr| {
        try ctx.pending.append(self.allocator, pr);
    }
    v.pending_refs = .{};

    if (!v.hasErrors()) {
        try self.catalog.register(ctx.catalog_kind, id, .{
            .span = .{ .file_id = 0, .start = 0, .end = @intCast(content.len) },
            .node = doc.value,
        });
    }
}

fn walkYmlFiles(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    current_dir: []const u8,
    ctx: anytype,
    comptime onFile: anytype,
) anyerror!void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            const sub_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ current_dir, entry.name });
            defer allocator.free(sub_path);
            var sub_dir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
            defer sub_dir.close();
            try walkYmlFiles(allocator, sub_dir, sub_path, ctx, onFile);
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".yml")) {
            const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ current_dir, entry.name });
            defer allocator.free(file_path);
            try onFile(ctx, file_path);
        }
    }
}

fn freePendingRefs(allocator: std.mem.Allocator, refs: []const validate_mod.PendingReference) void {
    for (refs) |pr| {
        allocator.free(pr.name);
        pr.path.deinit(allocator);
    }
}

fn cloneDiagnostic(allocator: std.mem.Allocator, d: validate_mod.Diagnostic) !validate_mod.Diagnostic {
    return .{
        .severity = d.severity,
        .span = d.span,
        .code = try allocator.dupe(u8, d.code),
        .message = try allocator.dupe(u8, d.message),
        .related = &.{},
        .suggestions = &.{},
    };
}

pub fn discoverSkills(self: *const Artifact, allocator: std.mem.Allocator) ![]Skill {
    const dir = try std.fmt.allocPrint(allocator, "{s}/skills", .{self.artifacts_dir});
    defer allocator.free(dir);
    return discover(Skill, allocator, dir);
}

pub fn discoverRules(self: *const Artifact, allocator: std.mem.Allocator) ![]Rule {
    const dir = try std.fmt.allocPrint(allocator, "{s}/rules", .{self.artifacts_dir});
    defer allocator.free(dir);
    return discover(Rule, allocator, dir);
}

pub fn discoverSkillsStrict(self: *const Artifact, allocator: std.mem.Allocator) ![]Skill {
    const dir = try std.fmt.allocPrint(allocator, "{s}/skills", .{self.artifacts_dir});
    defer allocator.free(dir);
    return discoverStrict(Skill, allocator, dir, true);
}

pub fn discoverRulesStrict(self: *const Artifact, allocator: std.mem.Allocator) ![]Rule {
    const dir = try std.fmt.allocPrint(allocator, "{s}/rules", .{self.artifacts_dir});
    defer allocator.free(dir);
    return discoverStrict(Rule, allocator, dir, false);
}

pub fn discoverMcp(self: *const Artifact, allocator: std.mem.Allocator) ![]mcp.Server {
    const dir = try std.fmt.allocPrint(allocator, "{s}/mcp", .{self.artifacts_dir});
    defer allocator.free(dir);
    return discoverWith(mcp.Server, allocator, dir, mcp.parseServer);
}

pub fn discoverDialects(self: *const Artifact, allocator: std.mem.Allocator) ![]mcp.Dialect {
    const dir = try std.fmt.allocPrint(allocator, "{s}/dialects", .{self.artifacts_dir});
    defer allocator.free(dir);
    return discoverWith(mcp.Dialect, allocator, dir, mcp.parseDialect);
}

fn discover(comptime T: type, allocator: std.mem.Allocator, base_dir: []const u8) ![]T {
    var items = std.ArrayListUnmanaged(T){};

    var dir = std.fs.openDirAbsolute(base_dir, .{ .iterate = true }) catch return items.toOwnedSlice(allocator);
    defer dir.close();

    var ctx = ParseCtx(T){ .allocator = allocator, .base_dir = base_dir, .items = &items };
    try walkYmlFiles(allocator, dir, base_dir, &ctx, parseOneFile);

    return items.toOwnedSlice(allocator);
}

fn discoverStrict(comptime T: type, allocator: std.mem.Allocator, base_dir: []const u8, require_root: bool) ![]T {
    var items = std.ArrayListUnmanaged(T){};

    var dir = std.fs.openDirAbsolute(base_dir, .{ .iterate = true }) catch |e| {
        if (!require_root and e == error.FileNotFound) return items.toOwnedSlice(allocator);
        return e;
    };
    defer dir.close();

    var ctx = ParseCtx(T){ .allocator = allocator, .base_dir = base_dir, .items = &items };
    try walkYmlFiles(allocator, dir, base_dir, &ctx, parseOneFileStrict);

    return items.toOwnedSlice(allocator);
}

fn discoverWith(
    comptime T: type,
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    comptime parseFn: anytype,
) ![]T {
    var items = std.ArrayListUnmanaged(T){};

    var dir = std.fs.openDirAbsolute(base_dir, .{ .iterate = true }) catch return items.toOwnedSlice(allocator);
    defer dir.close();

    var ctx = CustomCtx(T, parseFn){ .allocator = allocator, .base_dir = base_dir, .items = &items };
    try walkYmlFiles(allocator, dir, base_dir, &ctx, parseCustomFile);

    return items.toOwnedSlice(allocator);
}

fn CustomCtx(comptime T: type, comptime parseFn: anytype) type {
    return struct {
        allocator: std.mem.Allocator,
        base_dir: []const u8,
        items: *std.ArrayListUnmanaged(T),

        const Parse = parseFn;
        const Item = T;
    };
}

fn parseCustomFile(ctx: anytype, file_path: []const u8) anyerror!void {
    const Ctx = @TypeOf(ctx.*);
    const allocator = ctx.allocator;
    const content = fs.readFileAlloc(allocator, file_path) catch return;
    defer allocator.free(content);
    const id = deriveId(allocator, ctx.base_dir, file_path) catch return;

    const doc = yaml.parse(allocator, content) catch {
        allocator.free(id);
        return;
    };
    var item = Ctx.Parse(allocator, doc.value) catch {
        allocator.free(id);
        return;
    };
    item.id = id;
    try ctx.items.append(allocator, item);
}

fn ParseCtx(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        base_dir: []const u8,
        items: *std.ArrayListUnmanaged(T),

        const Item = T;
    };
}

fn parseOneFile(ctx: anytype, file_path: []const u8) anyerror!void {
    const T = @TypeOf(ctx.*).Item;
    const allocator = ctx.allocator;
    const content = fs.readFileAlloc(allocator, file_path) catch return;
    defer allocator.free(content);
    const id = deriveId(allocator, ctx.base_dir, file_path) catch return;

    var item = parseYaml(T, allocator, content) catch {
        allocator.free(id);
        return;
    };
    item.id = id;
    if (@hasField(T, "source_path")) {
        item.source_path = allocator.dupe(u8, file_path) catch null;
    }
    try ctx.items.append(allocator, item);
}

fn parseOneFileStrict(ctx: anytype, file_path: []const u8) anyerror!void {
    const T = @TypeOf(ctx.*).Item;
    const allocator = ctx.allocator;
    const content = try fs.readFileAlloc(allocator, file_path);
    defer allocator.free(content);
    const id = try deriveId(allocator, ctx.base_dir, file_path);

    var item = try parseYaml(T, allocator, content);
    item.id = id;
    if (@hasField(T, "source_path")) {
        item.source_path = try allocator.dupe(u8, file_path);
    }
    try ctx.items.append(allocator, item);
}

fn parseYaml(comptime T: type, allocator: std.mem.Allocator, content: []const u8) !T {
    const doc = yaml.parse(allocator, content) catch return Error.ParseFailed;
    const item = yaml.decode(T, allocator, doc) catch return Error.ParseFailed;
    if (@hasDecl(T, "validate")) try item.validate();
    return item;
}

fn deriveId(allocator: std.mem.Allocator, base_dir: []const u8, file_path: []const u8) ![]const u8 {
    const yml_ext = ".yml";
    const prefix_len = base_dir.len + 1;
    if (file_path.len <= prefix_len) return Error.ParseFailed;
    const relative = file_path[prefix_len..];
    if (relative.len < yml_ext.len + 1) return Error.ParseFailed;
    const without_ext = relative[0 .. relative.len - yml_ext.len];
    return try allocator.dupe(u8, without_ext);
}

test "deriveId strips base dir and .yml" {
    const id = try deriveId(std.testing.allocator, "/home/.tin/artifacts/skills", "/home/.tin/artifacts/skills/fs/read.yml");
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("fs/read", id);
}

test "deriveId handles nested paths" {
    const id = try deriveId(std.testing.allocator, "/artifacts/skills", "/artifacts/skills/git/log.yml");
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("git/log", id);
}

test "deriveId handles single level" {
    const id = try deriveId(std.testing.allocator, "/artifacts/rules", "/artifacts/rules/clarity.yml");
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("clarity", id);
}

test "deriveId rejects path equal to base dir" {
    try std.testing.expectError(Error.ParseFailed, deriveId(std.testing.allocator, "/artifacts/skills", "/artifacts/skills"));
}

test "deriveId rejects too-short relative path" {
    try std.testing.expectError(Error.ParseFailed, deriveId(std.testing.allocator, "/artifacts/skills", "/artifacts/skills/a.ym"));
}

test "freePendingRefs releases reference names and paths" {
    const allocator = std.testing.allocator;
    var refs = std.ArrayListUnmanaged(validate_mod.PendingReference){};
    defer refs.deinit(allocator);
    try refs.append(allocator, .{
        .span = .{ .file_id = 0, .start = 0, .end = 0 },
        .kind = "rule_id",
        .name = try allocator.dupe(u8, "some_rule"),
        .path = try PathExpression.parse(allocator, "#/rules/**"),
    });

    freePendingRefs(allocator, refs.items);
}

test {
    _ = Rule;
    _ = Skill;
    _ = @import("artifact/export.zig");
}

test "discoverStrict propagates failures and records source_path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.parent_dir.realpathAlloc(std.testing.allocator, &tmp.sub_path);
    defer std.testing.allocator.free(base);

    const skills_dir = try std.fs.path.join(a, &.{ base, "skills" });
    try fs.ensureDirectoryExists(skills_dir);
    try fs.writeFile(try std.fs.path.join(a, &.{ skills_dir, "alpha.yml" }), "description: a\nsystem: s\n");

    const found = try discoverStrict(Skill, a, skills_dir, true);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("alpha", found[0].id);
    try std.testing.expect(found[0].source_path != null);

    const missing = try std.fs.path.join(a, &.{ base, "nope" });
    try std.testing.expectError(error.FileNotFound, discoverStrict(Skill, a, missing, true));

    try fs.writeFile(try std.fs.path.join(a, &.{ skills_dir, "bad.yml" }), "description: [unterminated\n");
    try std.testing.expectError(Error.ParseFailed, discoverStrict(Skill, a, skills_dir, true));
}
