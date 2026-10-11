const std = @import("std");
const fs = @import("../../lib/fs.zig");
const utils = @import("../../lib/utils.zig");
const template = @import("../../lib/template.zig");
const Skill = @import("skill.zig");
const Rule = @import("rule.zig");

pub const Action = enum { create, update, unchanged, remove, conflict };
pub const Ownership = enum { managed, foreign, legacy, none };

pub const Entry = struct {
    id: []const u8,
    slug: []const u8,
    path: []const u8,
    content: ?[]const u8,
    action: Action,
    ownership: Ownership,
    reason: ?[]const u8 = null,
};

pub const Prepared = struct {
    base_dir: []const u8,
    adopt_legacy: bool = false,
    entries: []Entry = &.{},

    pub fn hasConflicts(self: Prepared) bool {
        for (self.entries) |e| {
            if (e.action == .conflict) return true;
        }
        return false;
    }
};

pub const Options = struct {
    adopt_legacy: bool = false,
};

pub const Error = error{
    InvalidName,
    UnsupportedSkill,
    UnresolvedRule,
    ManifestMalformed,
    ManifestUnreadable,
    ReadFailed,
    WriteFailed,
    Conflicts,
    Locked,
};

const manifest_name = ".tin-skills";
const manifest_tmp = ".tin-skills.tmp";
const lock_name = ".tin-skills.lock";
const manifest_header = "tin-skills 2";

const ManifestEntry = struct {
    slug: []const u8,
    hash: [64]u8,
};

const Manifest = struct {
    present: bool,
    legacy: bool,
    entries: []ManifestEntry,
    legacy_slugs: []const []const u8,

    fn find(self: Manifest, slug: []const u8) ?ManifestEntry {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.slug, slug)) return e;
        }
        return null;
    }

    fn hasLegacy(self: Manifest, slug: []const u8) bool {
        for (self.legacy_slugs) |s| {
            if (std.mem.eql(u8, s, slug)) return true;
        }
        return false;
    }
};

const Kind = enum { absent, symlink, dir, file, other };

fn statKind(path: []const u8) Kind {
    const st = std.posix.fstatat(std.posix.AT.FDCWD, path, std.posix.AT.SYMLINK_NOFOLLOW) catch |e| switch (e) {
        error.FileNotFound => return .absent,
        else => return .other,
    };
    const mode: u32 = @intCast(st.mode);
    if (std.posix.S.ISLNK(mode)) return .symlink;
    if (std.posix.S.ISDIR(mode)) return .dir;
    if (std.posix.S.ISREG(mode)) return .file;
    return .other;
}

fn sha256Hex(content: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn resolveSystem(allocator: std.mem.Allocator, skill: Skill, rules: []const Rule) ![]const u8 {
    const system = skill.system orelse return "";
    if (skill.include.len == 0) return system;

    var vars: std.ArrayListUnmanaged(struct { []const u8, []const u8 }) = .{};
    defer vars.deinit(allocator);
    for (skill.include) |rule_id| {
        var found = false;
        for (rules) |rule| {
            if (std.mem.eql(u8, rule.id, rule_id)) {
                try vars.append(allocator, .{ rule_id, rule.content });
                found = true;
                break;
            }
        }
        if (!found) return Error.UnresolvedRule;
    }
    return template.render(allocator, system, vars.items);
}

pub fn renderSkillMd(allocator: std.mem.Allocator, skill: Skill) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    const w = buf.writer(allocator);
    const name = try utils.slugify(allocator, skill.id);
    try w.print("---\nname: {s}\n", .{name});
    try w.print("description: {s}\n", .{try utils.escapeYamlString(allocator, skill.description)});
    if (skill.command != null) try w.writeAll("allowed-tools: Bash Read\n");
    if (skill.context) |ctx| try w.print("context: {s}\n", .{try utils.escapeYamlString(allocator, ctx)});
    if (skill.skills.len > 0) {
        try w.writeAll("skills:\n");
        for (skill.skills) |s| try w.print("  - {s}\n", .{try utils.escapeYamlString(allocator, s)});
    }
    try w.writeAll("---\n\n");

    if (skill.system) |sys| try w.print("{s}\n", .{sys});
    if (skill.command) |cmd| try w.print("\n## Command\n\n`{s}`\n", .{cmd});
    if (skill.input.len > 0) {
        try w.writeAll("\n## Parameters\n\n");
        for (skill.input) |param| {
            const req = if (param.required) " (required)" else "";
            const desc = param.description orelse "";
            try w.print("- **{s}** ({s}{s}): {s}\n", .{ param.name, param.type, req, desc });
        }
    }

    return buf.toOwnedSlice(allocator);
}

fn readManifest(allocator: std.mem.Allocator, base_dir: []const u8) !Manifest {
    const path = try manifestPath(allocator, base_dir);
    switch (statKind(path)) {
        .absent => return .{ .present = false, .legacy = false, .entries = &.{}, .legacy_slugs = &.{} },
        .file => {},
        else => return Error.ManifestUnreadable,
    }
    const content = fs.readFileAlloc(allocator, path) catch return Error.ManifestUnreadable;

    const first_line = blk: {
        var it = std.mem.splitScalar(u8, content, '\n');
        break :blk std.mem.trim(u8, it.next() orelse "", " \t\r");
    };

    if (std.mem.eql(u8, first_line, manifest_header)) {
        var entries = std.ArrayListUnmanaged(ManifestEntry){};
        var it = std.mem.splitScalar(u8, content, '\n');
        _ = it.next();
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            const tab = std.mem.indexOfScalar(u8, trimmed, '\t') orelse return Error.ManifestMalformed;
            const slug = trimmed[0..tab];
            const hash = trimmed[tab + 1 ..];
            if (hash.len != 64 or !utils.isValidSlug(slug)) return Error.ManifestMalformed;
            var h: [64]u8 = undefined;
            @memcpy(&h, hash);
            try entries.append(allocator, .{ .slug = try allocator.dupe(u8, slug), .hash = h });
        }
        return .{ .present = true, .legacy = false, .entries = try entries.toOwnedSlice(allocator), .legacy_slugs = &.{} };
    }

    if (std.mem.startsWith(u8, first_line, "tin-skills")) return Error.ManifestMalformed;

    var slugs = std.ArrayListUnmanaged([]const u8){};
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        try slugs.append(allocator, try allocator.dupe(u8, trimmed));
    }
    return .{ .present = true, .legacy = true, .entries = &.{}, .legacy_slugs = try slugs.toOwnedSlice(allocator) };
}

const Rendered = struct {
    skill: Skill,
    slug: []const u8,
    content: []const u8,
    hash: [64]u8,
};

pub fn prepare(allocator: std.mem.Allocator, base_dir: []const u8, skills: []const Skill, rules: []const Rule) !Prepared {
    return prepareWithOptions(allocator, base_dir, skills, rules, .{});
}

pub fn prepareWithOptions(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    skills: []const Skill,
    rules: []const Rule,
    options: Options,
) !Prepared {
    const manifest = try readManifest(allocator, base_dir);

    var rendered = std.ArrayListUnmanaged(Rendered){};
    var catalog_slugs = std.StringHashMapUnmanaged(void){};
    var colliding = std.StringHashMapUnmanaged(void){};

    for (skills) |skill| {
        skill.validate() catch return Error.UnsupportedSkill;
        const system = try resolveSystem(allocator, skill, rules);
        var resolved = skill;
        resolved.system = system;
        const content = try renderSkillMd(allocator, resolved);
        const slug = try utils.slugify(allocator, skill.id);
        if (!utils.isValidSlug(slug)) return Error.InvalidName;

        const gop = try catalog_slugs.getOrPut(allocator, slug);
        if (gop.found_existing) {
            try colliding.put(allocator, slug, {});
        }
        try rendered.append(allocator, .{ .skill = skill, .slug = slug, .content = content, .hash = sha256Hex(content) });
    }

    var entries = std.ArrayListUnmanaged(Entry){};

    for (rendered.items) |r| {
        const skill_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_dir, r.slug });
        const skill_file = try std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{skill_dir});

        if (colliding.contains(r.slug)) {
            try entries.append(allocator, conflictEntry(r, skill_file, .none, "flattened name collision"));
            continue;
        }

        const dir_kind = statKind(skill_dir);
        const file_kind = statKind(skill_file);
        if (dir_kind == .symlink or file_kind == .symlink) {
            try entries.append(allocator, conflictEntry(r, skill_file, ownershipFor(manifest, r.slug), "refusing to write through a symbolic link"));
            continue;
        }

        if (manifest.find(r.slug)) |recorded| {
            try appendManaged(allocator, &entries, r, skill_file, file_kind, recorded);
        } else if (manifest.legacy and manifest.hasLegacy(r.slug)) {
            try appendLegacy(allocator, &entries, r, skill_file, dir_kind, file_kind, options.adopt_legacy);
        } else if (dir_kind == .absent and file_kind == .absent) {
            try entries.append(allocator, .{
                .id = r.skill.id,
                .slug = r.slug,
                .path = skill_file,
                .content = r.content,
                .action = .create,
                .ownership = .none,
            });
        } else {
            try entries.append(allocator, conflictEntry(r, skill_file, .foreign, "name already exists and is not managed by Tin"));
        }
    }

    for (manifest.entries) |recorded| {
        if (catalog_slugs.contains(recorded.slug)) continue;
        if (!utils.isValidSlug(recorded.slug)) continue;
        const skill_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_dir, recorded.slug });
        const skill_file = try std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{skill_dir});
        const dir_kind = statKind(skill_dir);
        const file_kind = statKind(skill_file);

        if (dir_kind == .symlink or file_kind == .symlink) {
            try entries.append(allocator, .{
                .id = recorded.slug,
                .slug = recorded.slug,
                .path = skill_file,
                .content = null,
                .action = .conflict,
                .ownership = .managed,
                .reason = "refusing to prune through a symbolic link",
            });
            continue;
        }
        if (file_kind == .absent) {
            try entries.append(allocator, .{
                .id = recorded.slug,
                .slug = recorded.slug,
                .path = skill_file,
                .content = null,
                .action = .remove,
                .ownership = .managed,
                .reason = "already absent",
            });
            continue;
        }
        if (file_kind != .file) {
            try entries.append(allocator, .{
                .id = recorded.slug,
                .slug = recorded.slug,
                .path = skill_file,
                .content = null,
                .action = .conflict,
                .ownership = .managed,
                .reason = "managed path is not a regular file",
            });
            continue;
        }

        const current = fs.readFileAlloc(allocator, skill_file) catch return Error.ReadFailed;
        if (std.mem.eql(u8, &sha256Hex(current), &recorded.hash)) {
            try entries.append(allocator, .{
                .id = recorded.slug,
                .slug = recorded.slug,
                .path = skill_file,
                .content = null,
                .action = .remove,
                .ownership = .managed,
                .reason = "stale managed output",
            });
        } else {
            try entries.append(allocator, .{
                .id = recorded.slug,
                .slug = recorded.slug,
                .path = skill_file,
                .content = null,
                .action = .conflict,
                .ownership = .managed,
                .reason = "stale managed output was modified locally; preserved",
            });
        }
    }

    if (manifest.legacy) {
        for (manifest.legacy_slugs) |slug| {
            if (catalog_slugs.contains(slug)) continue;
            const skill_file = try std.fmt.allocPrint(allocator, "{s}/{s}/SKILL.md", .{ base_dir, slug });
            try entries.append(allocator, .{
                .id = slug,
                .slug = slug,
                .path = skill_file,
                .content = null,
                .action = .conflict,
                .ownership = .legacy,
                .reason = "stale legacy output preserved; remove manually if unused",
            });
        }
    }

    return .{
        .base_dir = base_dir,
        .adopt_legacy = options.adopt_legacy,
        .entries = try entries.toOwnedSlice(allocator),
    };
}

fn ownershipFor(manifest: Manifest, slug: []const u8) Ownership {
    if (manifest.find(slug) != null) return .managed;
    if (manifest.legacy and manifest.hasLegacy(slug)) return .legacy;
    return .none;
}

fn conflictEntry(r: Rendered, path: []const u8, ownership: Ownership, reason: []const u8) Entry {
    return .{
        .id = r.skill.id,
        .slug = r.slug,
        .path = path,
        .content = r.content,
        .action = .conflict,
        .ownership = ownership,
        .reason = reason,
    };
}

fn appendManaged(
    allocator: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged(Entry),
    r: Rendered,
    path: []const u8,
    file_kind: Kind,
    recorded: ManifestEntry,
) !void {
    if (file_kind == .absent) {
        try entries.append(allocator, .{
            .id = r.skill.id,
            .slug = r.slug,
            .path = path,
            .content = r.content,
            .action = .create,
            .ownership = .managed,
            .reason = "managed output was missing; recreated",
        });
        return;
    }
    if (file_kind != .file) {
        try entries.append(allocator, conflictEntry(r, path, .managed, "managed path is not a regular file"));
        return;
    }

    const current = fs.readFileAlloc(allocator, path) catch return Error.ReadFailed;
    const current_hash = sha256Hex(current);
    if (std.mem.eql(u8, &current_hash, &r.hash)) {
        try entries.append(allocator, .{
            .id = r.skill.id,
            .slug = r.slug,
            .path = path,
            .content = r.content,
            .action = .unchanged,
            .ownership = .managed,
        });
    } else if (std.mem.eql(u8, &current_hash, &recorded.hash)) {
        try entries.append(allocator, .{
            .id = r.skill.id,
            .slug = r.slug,
            .path = path,
            .content = r.content,
            .action = .update,
            .ownership = .managed,
        });
    } else {
        try entries.append(allocator, conflictEntry(r, path, .managed, "locally modified managed output; preserved"));
    }
}

fn appendLegacy(
    allocator: std.mem.Allocator,
    entries: *std.ArrayListUnmanaged(Entry),
    r: Rendered,
    path: []const u8,
    dir_kind: Kind,
    file_kind: Kind,
    adopt: bool,
) !void {
    if (file_kind == .file) {
        const current = fs.readFileAlloc(allocator, path) catch return Error.ReadFailed;
        const matches = std.mem.eql(u8, &sha256Hex(current), &r.hash);
        if (!matches) {
            try entries.append(allocator, conflictEntry(r, path, .legacy, "legacy output differs from current rendering; preserved"));
        } else if (adopt) {
            try entries.append(allocator, .{
                .id = r.skill.id,
                .slug = r.slug,
                .path = path,
                .content = r.content,
                .action = .unchanged,
                .ownership = .managed,
                .reason = "adopted verified legacy output",
            });
        } else {
            try entries.append(allocator, conflictEntry(r, path, .legacy, "legacy output verified; pass --adopt-legacy to take ownership"));
        }
        return;
    }
    if (file_kind == .absent and dir_kind == .absent) {
        try entries.append(allocator, .{
            .id = r.skill.id,
            .slug = r.slug,
            .path = path,
            .content = r.content,
            .action = .create,
            .ownership = if (adopt) .managed else .none,
            .reason = "legacy entry had no output; created",
        });
        return;
    }
    try entries.append(allocator, conflictEntry(r, path, .legacy, "legacy path is not a regular file; preserved"));
}

fn manifestPath(allocator: std.mem.Allocator, base_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_dir, manifest_name });
}

fn writeManifest(allocator: std.mem.Allocator, base_dir: []const u8, entries: []const ManifestEntry) !void {
    var buf = std.ArrayListUnmanaged(u8){};
    const w = buf.writer(allocator);
    try w.print("{s}\n", .{manifest_header});
    for (entries) |e| try w.print("{s}\t{s}\n", .{ e.slug, e.hash });

    const tmp = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_dir, manifest_tmp });
    const dest = try manifestPath(allocator, base_dir);
    errdefer std.fs.deleteFileAbsolute(tmp) catch {};
    try fs.writeFile(tmp, buf.items);
    try std.fs.renameAbsolute(tmp, dest);
}

fn writeAtomic(allocator: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    try fs.ensureParentDirExists(path);
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tin-tmp", .{path});
    errdefer std.fs.deleteFileAbsolute(tmp) catch {};
    const file = try std.fs.createFileAbsolute(tmp, .{ .truncate = true });
    try file.writeAll(content);
    file.close();
    try std.fs.renameAbsolute(tmp, path);
}

fn deleteStaleFile(path: []const u8) !void {
    std.fs.deleteFileAbsolute(path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };
    const dir = std.fs.path.dirname(path) orelse return;
    std.fs.deleteDirAbsolute(dir) catch {};
}

pub fn apply(allocator: std.mem.Allocator, prepared: Prepared) !void {
    if (prepared.hasConflicts()) return Error.Conflicts;

    fs.ensureDirectoryExists(prepared.base_dir) catch return Error.WriteFailed;

    const lock_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prepared.base_dir, lock_name });
    const lock = std.fs.createFileAbsolute(lock_path, .{ .exclusive = true }) catch |e| switch (e) {
        error.PathAlreadyExists => return Error.Locked,
        else => return Error.WriteFailed,
    };
    lock.close();
    defer std.fs.deleteFileAbsolute(lock_path) catch {};

    var owned = std.ArrayListUnmanaged(ManifestEntry){};

    for (prepared.entries) |entry| {
        switch (entry.action) {
            .conflict => return Error.Conflicts,
            .unchanged => {
                try owned.append(allocator, .{ .slug = entry.slug, .hash = sha256Hex(entry.content.?) });
            },
            .create, .update => {
                writeAtomic(allocator, entry.path, entry.content.?) catch return Error.WriteFailed;
                try owned.append(allocator, .{ .slug = entry.slug, .hash = sha256Hex(entry.content.?) });
                writeManifest(allocator, prepared.base_dir, owned.items) catch return Error.WriteFailed;
            },
            .remove => {
                deleteStaleFile(entry.path) catch return Error.WriteFailed;
                writeManifest(allocator, prepared.base_dir, owned.items) catch return Error.WriteFailed;
            },
        }
    }

    writeManifest(allocator, prepared.base_dir, owned.items) catch return Error.WriteFailed;
}

const testing = std.testing;

fn tmpBase() !struct { dir: []const u8, tmp: std.testing.TmpDir } {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const dir = try tmp.parent_dir.realpathAlloc(testing.allocator, &tmp.sub_path);
    return .{ .dir = dir, .tmp = tmp };
}

fn actionFor(prepared: Prepared, slug: []const u8) ?Entry {
    for (prepared.entries) |e| {
        if (std.mem.eql(u8, e.slug, slug)) return e;
    }
    return null;
}

test "prepare and apply create, then repeat is unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var t = try tmpBase();
    defer testing.allocator.free(t.dir);
    defer t.tmp.cleanup();

    const skills = [_]Skill{
        .{ .id = "alpha", .description = "a", .system = "sa" },
        .{ .id = "search/ripgrep", .description = "r", .system = "sr" },
    };

    const first = try prepare(a, t.dir, &skills, &.{});
    try testing.expect(!first.hasConflicts());
    try apply(a, first);

    try testing.expect(fs.pathExists(try std.fs.path.join(a, &.{ t.dir, "alpha", "SKILL.md" })));
    try testing.expect(fs.pathExists(try std.fs.path.join(a, &.{ t.dir, "search-ripgrep", "SKILL.md" })));

    const second = try prepare(a, t.dir, &skills, &.{});
    for (second.entries) |e| try testing.expectEqual(Action.unchanged, e.action);

    const content = try fs.readFileAlloc(a, try std.fs.path.join(a, &.{ t.dir, "alpha", "SKILL.md" }));
    try testing.expect(std.mem.startsWith(u8, content, "---\nname: alpha\n"));
}

test "prepare rejects unresolved rule references" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const skills = [_]Skill{
        .{ .id = "alpha", .description = "a", .system = "{{ missing }}", .include = &.{"missing"} },
    };
    try testing.expectError(Error.UnresolvedRule, prepare(a, "/tmp/tin_export_unused", &skills, &.{}));
}

test "prepare rejects invalid names and reports collisions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bad = [_]Skill{.{ .id = "..", .description = "x", .system = "s" }};
    try testing.expectError(Error.InvalidName, prepare(a, "/tmp/tin_export_unused", &bad, &.{}));

    var t = try tmpBase();
    defer testing.allocator.free(t.dir);
    defer t.tmp.cleanup();

    const collide = [_]Skill{
        .{ .id = "a/b", .description = "one", .system = "s" },
        .{ .id = "a-b", .description = "two", .system = "s" },
    };
    const prepared = try prepare(a, t.dir, &collide, &.{});
    try testing.expect(prepared.hasConflicts());
    try testing.expectError(Error.Conflicts, apply(a, prepared));
}

test "foreign names and unrelated entries are preserved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var t = try tmpBase();
    defer testing.allocator.free(t.dir);
    defer t.tmp.cleanup();

    try fs.ensureDirectoryExists(try std.fs.path.join(a, &.{ t.dir, "foreign" }));
    try fs.writeFile(try std.fs.path.join(a, &.{ t.dir, "foreign", "SKILL.md" }), "user content");
    try fs.writeFile(try std.fs.path.join(a, &.{ t.dir, "other.txt" }), "keep me");

    const skills = [_]Skill{
        .{ .id = "foreign", .description = "f", .system = "s" },
        .{ .id = "alpha", .description = "a", .system = "s" },
    };
    const prepared = try prepare(a, t.dir, &skills, &.{});
    try testing.expectEqual(Action.conflict, actionFor(prepared, "foreign").?.action);
    try testing.expectEqual(Ownership.foreign, actionFor(prepared, "foreign").?.ownership);
    try testing.expectEqual(Action.create, actionFor(prepared, "alpha").?.action);
    try testing.expectError(Error.Conflicts, apply(a, prepared));

    try testing.expectEqualStrings("user content", try fs.readFileAlloc(a, try std.fs.path.join(a, &.{ t.dir, "foreign", "SKILL.md" })));
    try testing.expect(fs.pathExists(try std.fs.path.join(a, &.{ t.dir, "other.txt" })));
}

test "managed folder resources and local edits survive; stale owned output is pruned" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var t = try tmpBase();
    defer testing.allocator.free(t.dir);
    defer t.tmp.cleanup();

    const two = [_]Skill{
        .{ .id = "alpha", .description = "a", .system = "sa" },
        .{ .id = "beta", .description = "b", .system = "sb" },
    };
    try apply(a, try prepare(a, t.dir, &two, &.{}));

    try fs.writeFile(try std.fs.path.join(a, &.{ t.dir, "alpha", "RESOURCE.md" }), "extra resource");
    try fs.writeFile(try std.fs.path.join(a, &.{ t.dir, "beta", "SKILL.md" }), "locally edited");

    const one = [_]Skill{.{ .id = "alpha", .description = "a", .system = "sa" }};
    const prepared = try prepare(a, t.dir, &one, &.{});

    try testing.expectEqual(Action.unchanged, actionFor(prepared, "alpha").?.action);
    try testing.expectEqual(Action.conflict, actionFor(prepared, "beta").?.action);
    try testing.expectEqual(Ownership.managed, actionFor(prepared, "beta").?.ownership);

    try testing.expectError(Error.Conflicts, apply(a, prepared));
    try testing.expect(fs.pathExists(try std.fs.path.join(a, &.{ t.dir, "alpha", "RESOURCE.md" })));
    try testing.expectEqualStrings("locally edited", try fs.readFileAlloc(a, try std.fs.path.join(a, &.{ t.dir, "beta", "SKILL.md" })));
}

test "stale managed output is removed without touching sibling resources" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var t = try tmpBase();
    defer testing.allocator.free(t.dir);
    defer t.tmp.cleanup();

    const two = [_]Skill{
        .{ .id = "alpha", .description = "a", .system = "sa" },
        .{ .id = "beta", .description = "b", .system = "sb" },
    };
    try apply(a, try prepare(a, t.dir, &two, &.{}));
    try fs.writeFile(try std.fs.path.join(a, &.{ t.dir, "beta", "keep.md" }), "resource");

    const one = [_]Skill{.{ .id = "alpha", .description = "a", .system = "sa" }};
    const prepared = try prepare(a, t.dir, &one, &.{});
    try testing.expectEqual(Action.remove, actionFor(prepared, "beta").?.action);
    try apply(a, prepared);

    try testing.expect(!fs.pathExists(try std.fs.path.join(a, &.{ t.dir, "beta", "SKILL.md" })));
    try testing.expect(fs.pathExists(try std.fs.path.join(a, &.{ t.dir, "beta", "keep.md" })));
    try testing.expect(fs.pathExists(try std.fs.path.join(a, &.{ t.dir, "alpha", "SKILL.md" })));
}

test "deliberate empty export prunes owned output only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var t = try tmpBase();
    defer testing.allocator.free(t.dir);
    defer t.tmp.cleanup();

    const one = [_]Skill{.{ .id = "alpha", .description = "a", .system = "sa" }};
    try apply(a, try prepare(a, t.dir, &one, &.{}));
    try fs.ensureDirectoryExists(try std.fs.path.join(a, &.{ t.dir, "bespoke" }));
    try fs.writeFile(try std.fs.path.join(a, &.{ t.dir, "bespoke", "SKILL.md" }), "bespoke");

    const empty = [_]Skill{};
    try apply(a, try prepare(a, t.dir, &empty, &.{}));

    try testing.expect(!fs.pathExists(try std.fs.path.join(a, &.{ t.dir, "alpha", "SKILL.md" })));
    try testing.expect(fs.pathExists(try std.fs.path.join(a, &.{ t.dir, "bespoke", "SKILL.md" })));
}

test "malformed and unreadable manifests stop preparation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var t = try tmpBase();
    defer testing.allocator.free(t.dir);
    defer t.tmp.cleanup();

    try fs.writeFile(try std.fs.path.join(a, &.{ t.dir, ".tin-skills" }), "tin-skills 3\nbogus\n");
    const skills = [_]Skill{.{ .id = "alpha", .description = "a", .system = "s" }};
    try testing.expectError(Error.ManifestMalformed, prepare(a, t.dir, &skills, &.{}));

    std.fs.deleteFileAbsolute(try std.fs.path.join(a, &.{ t.dir, ".tin-skills" })) catch {};
    try fs.ensureDirectoryExists(try std.fs.path.join(a, &.{ t.dir, ".tin-skills" }));
    try testing.expectError(Error.ManifestUnreadable, prepare(a, t.dir, &skills, &.{}));
}

test "prepare alone writes nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var t = try tmpBase();
    defer testing.allocator.free(t.dir);
    defer t.tmp.cleanup();

    const target = try std.fs.path.join(a, &.{ t.dir, "dry", "run" });
    const skills = [_]Skill{.{ .id = "alpha", .description = "a", .system = "s" }};
    _ = try prepare(a, target, &skills, &.{});
    try testing.expect(!fs.pathExists(target));
}

test "symlinked output is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var t = try tmpBase();
    defer testing.allocator.free(t.dir);
    defer t.tmp.cleanup();

    const outside = try std.fs.path.join(a, &.{ t.dir, "outside" });
    try fs.ensureDirectoryExists(outside);
    const link = try std.fs.path.join(a, &.{ t.dir, "alpha" });
    try std.fs.cwd().symLink(outside, link, .{ .is_directory = true });

    const skills = [_]Skill{.{ .id = "alpha", .description = "a", .system = "s" }};
    const prepared = try prepare(a, t.dir, &skills, &.{});
    try testing.expectEqual(Action.conflict, actionFor(prepared, "alpha").?.action);
    try testing.expectError(Error.Conflicts, apply(a, prepared));
}

test "legacy manifest requires explicit adoption and never blind deletes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var t = try tmpBase();
    defer testing.allocator.free(t.dir);
    defer t.tmp.cleanup();

    const skills = [_]Skill{
        .{ .id = "alpha", .description = "a", .system = "sa" },
        .{ .id = "beta", .description = "b", .system = "sb" },
    };

    const verified = try renderSkillMd(a, skills[0]);
    try fs.ensureDirectoryExists(try std.fs.path.join(a, &.{ t.dir, "alpha" }));
    try fs.writeFile(try std.fs.path.join(a, &.{ t.dir, "alpha", "SKILL.md" }), verified);
    try fs.writeFile(try std.fs.path.join(a, &.{ t.dir, ".tin-skills" }), "alpha\nstale-legacy\n");

    const not_adopted = try prepare(a, t.dir, &skills, &.{});
    try testing.expectEqual(Action.conflict, actionFor(not_adopted, "alpha").?.action);
    try testing.expectEqual(Ownership.legacy, actionFor(not_adopted, "alpha").?.ownership);
    try testing.expectError(Error.Conflicts, apply(a, not_adopted));
    try testing.expect(fs.pathExists(try std.fs.path.join(a, &.{ t.dir, "alpha", "SKILL.md" })));

    const adopted = try prepareWithOptions(a, t.dir, &skills, &.{}, .{ .adopt_legacy = true });
    try testing.expectEqual(Action.unchanged, actionFor(adopted, "alpha").?.action);
    try testing.expectEqual(Ownership.managed, actionFor(adopted, "alpha").?.ownership);
    try testing.expectEqual(Action.conflict, actionFor(adopted, "stale-legacy").?.action);
    try testing.expectEqual(Ownership.legacy, actionFor(adopted, "stale-legacy").?.ownership);
}

test "writer lock refuses concurrent apply" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var t = try tmpBase();
    defer testing.allocator.free(t.dir);
    defer t.tmp.cleanup();

    try fs.writeFile(try std.fs.path.join(a, &.{ t.dir, ".tin-skills.lock" }), "");
    const skills = [_]Skill{.{ .id = "alpha", .description = "a", .system = "s" }};
    const prepared = try prepare(a, t.dir, &skills, &.{});
    try testing.expectError(Error.Locked, apply(a, prepared));
}

test "frontmatter remains valid for descriptions with quotes colons and newlines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const skill = Skill{ .id = "weird", .description = "has: \"quotes\"\nand a newline", .system = "s" };
    const md = try renderSkillMd(a, skill);
    try testing.expect(std.mem.indexOf(u8, md, "description: \"has: \\\"quotes\\\"\\nand a newline\"") != null);
}
