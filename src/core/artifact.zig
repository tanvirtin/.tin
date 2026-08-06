const std = @import("std");
const fs = @import("../lib/fs.zig");
const yaml = @import("yaml");
const output = @import("../lib/output.zig");

pub const Rule = @import("artifact/rule.zig");
pub const Skill = @import("artifact/skill.zig");

const Engine = @import("../spec/engine.zig").Engine;
const Catalog = @import("../spec/resolve.zig").Catalog;
const Schema = @import("../spec/ir.zig").Schema;
const compile = @import("../spec/compile.zig");
const validate_mod = @import("../spec/validate.zig");

const Sn = @This();

pub const Error = error{
    DirectoryNotFound,
    ParseFailed,
};

allocator: std.mem.Allocator,
sn_dir: []const u8,
engine: Engine,
skill_schema: Schema,
rule_schema: Schema,
catalog: Catalog,

pub fn init(allocator: std.mem.Allocator, tin_dir: []const u8) !Sn {
    const sn_dir = try std.fmt.allocPrint(allocator, "{s}/artifacts", .{tin_dir});

    var dir = std.fs.openDirAbsolute(sn_dir, .{}) catch return Error.DirectoryNotFound;
    dir.close();

    var engine = try Engine.init(allocator);
    
    const skill_schema_content = try std.fs.cwd().readFileAlloc(allocator, "src/schemas/skill.yaml", 1024 * 1024);
    const skill_schema = try engine.loadSchema(skill_schema_content);

    const rule_schema_content = try std.fs.cwd().readFileAlloc(allocator, "src/schemas/rule.yaml", 1024 * 1024);
    const rule_schema = try engine.loadSchema(rule_schema_content);

    return .{
        .allocator = allocator,
        .sn_dir = sn_dir,
        .engine = engine,
        .skill_schema = skill_schema,
        .rule_schema = rule_schema,
        .catalog = Catalog.init(allocator),
    };
}

pub fn validate(self: *Sn) !void {
    var all_pending_refs = std.ArrayListUnmanaged(validate_mod.PendingReference){};
    defer all_pending_refs.deinit(self.allocator);
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

    for (all_pending_refs.items) |pr| {
        if (pr.catalog_kind) |ck| {
            if (self.catalog.resolve(ck, pr.name) == null) {
                try all_diagnostics.append(self.allocator, .{
                    .severity = .err,
                    .span = pr.span,
                    .code = try self.allocator.dupe(u8, "undefined_reference"),
                    .message = try std.fmt.allocPrint(self.allocator, "undefined reference: {s} ({s})", .{pr.name, ck}),
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
    self: *Sn,
    sub_dir: []const u8,
    schema: *const Schema,
    catalog_kind: []const u8,
    all_pending_refs: *std.ArrayListUnmanaged(validate_mod.PendingReference),
    all_diagnostics: *std.ArrayListUnmanaged(validate_mod.Diagnostic),
) !void {
    const base_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.sn_dir, sub_dir });
    defer self.allocator.free(base_dir);

    var dir = std.fs.openDirAbsolute(base_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    try self.walkAndProcess(dir, base_dir, base_dir, schema, catalog_kind, all_pending_refs, all_diagnostics);
}

fn walkAndProcess(
    self: *Sn,
    dir: std.fs.Dir,
    base_dir: []const u8,
    current_dir: []const u8,
    schema: *const Schema,
    catalog_kind: []const u8,
    all_pending_refs: *std.ArrayListUnmanaged(validate_mod.PendingReference),
    all_diagnostics: *std.ArrayListUnmanaged(validate_mod.Diagnostic),
) !void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            const sub_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ current_dir, entry.name });
            defer self.allocator.free(sub_path);
            var sub_dir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
            defer sub_dir.close();
            try self.walkAndProcess(sub_dir, base_dir, sub_path, schema, catalog_kind, all_pending_refs, all_diagnostics);
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".yml")) {
            const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ current_dir, entry.name });
            defer self.allocator.free(file_path);
            const content = fs.readFileAlloc(self.allocator, file_path) catch continue;
            defer self.allocator.free(content);
            const id = try deriveId(self.allocator, base_dir, file_path);

            const doc = try yaml.parse(self.allocator, content);
            var v = validate_mod.Validator.init(self.allocator, null, &self.engine.sublangs, &self.catalog);
            try validate_mod.validateImpl(&v, schema, doc.value);

            for (v.diagnostics.items) |d| {
                try all_diagnostics.append(self.allocator, try cloneDiagnostic(self.allocator, d));
            }

            for (v.pending_refs.items) |pr| {
                try all_pending_refs.append(self.allocator, pr);
            }
            v.pending_refs = .{};

            if (!v.hasErrors()) {
                try self.catalog.register(catalog_kind, id, .{
                    .span = .{ .file_id = 0, .start = 0, .end = @intCast(content.len) },
                    .node = doc.value,
                });
            }
        }
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

pub fn discoverSkills(self: *const Sn, allocator: std.mem.Allocator) ![]Skill {
    const dir = try std.fmt.allocPrint(allocator, "{s}/skills", .{self.sn_dir});
    return discover(Skill, allocator, dir);
}

pub fn discoverRules(self: *const Sn, allocator: std.mem.Allocator) ![]Rule {
    const dir = try std.fmt.allocPrint(allocator, "{s}/rules", .{self.sn_dir});
    return discover(Rule, allocator, dir);
}

fn discover(comptime T: type, allocator: std.mem.Allocator, base_dir: []const u8) ![]T {
    var items = std.ArrayListUnmanaged(T){};

    var dir = std.fs.openDirAbsolute(base_dir, .{ .iterate = true }) catch return items.toOwnedSlice(allocator);
    defer dir.close();

    try walkAndParse(T, allocator, dir, base_dir, base_dir, &items);

    return items.toOwnedSlice(allocator);
}

fn walkAndParse(comptime T: type, allocator: std.mem.Allocator, dir: std.fs.Dir, base_dir: []const u8, current_dir: []const u8, items: *std.ArrayListUnmanaged(T)) !void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            const sub_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ current_dir, entry.name });
            defer allocator.free(sub_path);
            var sub_dir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
            defer sub_dir.close();
            try walkAndParse(T, allocator, sub_dir, base_dir, sub_path, items);
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".yml")) {
            const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ current_dir, entry.name });
            defer allocator.free(file_path);
            const content = fs.readFileAlloc(allocator, file_path) catch continue;
            defer allocator.free(content);
            const id = deriveId(allocator, base_dir, file_path) catch continue;

            var item = parseYaml(T, allocator, content) catch {
                allocator.free(id);
                continue;
            };
            item.id = id;
            try items.append(allocator, item);
        }
    }
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

test {
    _ = Rule;
    _ = Skill;
}
