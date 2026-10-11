const std = @import("std");
const fs = @import("../lib/fs.zig");
const utils = @import("../lib/utils.zig");
const output = @import("../lib/output.zig");
const Paths = @import("environment/paths.zig");
const Config = @import("environment/config.zig");
const RecipeManager = @import("environment/recipe_manager.zig");
const Symlink = @import("symlink.zig");
const Environment = @import("environment.zig");
const Artifact = @import("artifact.zig");

const export_mod = Artifact.exporter;
const Skill = Artifact.Skill;

pub const Error = error{
    UnknownSkill,
    InspectionIncomplete,
};

pub const ConfigState = enum { absent, loaded, invalid };

pub const ConfigReport = struct {
    selected_path: ?[]const u8,
    origin: Paths.Origin,
    personal_path: []const u8,
    repo_path: []const u8,
    state: ConfigState,
    reason: ?[]const u8,
};

pub const TargetState = enum { match, missing, modified, conflict, foreign };

pub const TargetInspection = struct {
    name: []const u8,
    dir: []const u8,
    path: []const u8,
    state: TargetState,
    ownership: export_mod.Ownership,
    reason: ?[]const u8,
};

pub const SkillInspection = struct {
    id: []const u8,
    name: []const u8,
    source_path: ?[]const u8,
    targets: []const TargetInspection,
};

pub const SymlinkInfo = struct {
    name: []const u8,
    source: []const u8,
    target: []const u8,
    status: Symlink.Status,
    copy: bool,
};

pub const StatusReport = struct {
    config: ConfigReport,
    symlinks: []const SymlinkInfo,
    artifacts_dir: []const u8,
    artifacts_present: bool,
    schemas_dir: []const u8,
    schemas_present: bool,
    revision: ?[]const u8,
};

const LoadedConfig = struct {
    report: ConfigReport,
    config: ?Config,
};

fn pathPresent(path: []const u8) bool {
    _ = std.posix.fstatat(std.posix.AT.FDCWD, path, std.posix.AT.SYMLINK_NOFOLLOW) catch return false;
    return true;
}

fn loadConfig(allocator: std.mem.Allocator, paths: Paths) !LoadedConfig {
    const selection = try paths.selectTinrc(allocator);
    if (selection.path == null) {
        return .{
            .report = .{
                .selected_path = null,
                .origin = selection.origin,
                .personal_path = selection.personal_path,
                .repo_path = selection.repo_path,
                .state = .absent,
                .reason = null,
            },
            .config = null,
        };
    }

    const loaded = Config.load(allocator, paths) catch |e| {
        return .{
            .report = .{
                .selected_path = selection.path,
                .origin = selection.origin,
                .personal_path = selection.personal_path,
                .repo_path = selection.repo_path,
                .state = .invalid,
                .reason = try allocator.dupe(u8, @errorName(e)),
            },
            .config = null,
        };
    };

    return .{
        .report = .{
            .selected_path = selection.path,
            .origin = selection.origin,
            .personal_path = selection.personal_path,
            .repo_path = selection.repo_path,
            .state = .loaded,
            .reason = null,
        },
        .config = loaded,
    };
}

pub fn inspectConfig(allocator: std.mem.Allocator, paths: Paths) !ConfigReport {
    const loaded = try loadConfig(allocator, paths);
    return loaded.report;
}

fn readRevision(allocator: std.mem.Allocator, tin_dir: []const u8) ?[]const u8 {
    const path = std.fmt.allocPrint(allocator, "{s}/.tin-revision", .{tin_dir}) catch return null;
    const raw = fs.readFileAlloc(allocator, path) catch return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return allocator.dupe(u8, trimmed) catch null;
}

pub fn inspectStatus(allocator: std.mem.Allocator, paths: Paths) !StatusReport {
    const loaded = try loadConfig(allocator, paths);

    const artifacts_dir = try paths.artifactsDir(allocator);
    const schemas_dir = try paths.schemasDir(allocator);

    var symlinks = std.ArrayListUnmanaged(SymlinkInfo){};
    if (loaded.config) |config| {
        const managed = RecipeManager.getManagedSymlinks(allocator, config, paths) catch &.{};
        for (managed) |symlink| {
            try symlinks.append(allocator, .{
                .name = symlink.name,
                .source = symlink.source,
                .target = symlink.target,
                .status = symlink.status(),
                .copy = symlink.copy,
            });
        }
    }

    return .{
        .config = loaded.report,
        .symlinks = try symlinks.toOwnedSlice(allocator),
        .artifacts_dir = artifacts_dir,
        .artifacts_present = pathPresent(artifacts_dir),
        .schemas_dir = schemas_dir,
        .schemas_present = pathPresent(schemas_dir),
        .revision = readRevision(allocator, paths.tin_dir),
    };
}

fn targetState(entry: export_mod.Entry) TargetState {
    return switch (entry.action) {
        .unchanged => .match,
        .create => .missing,
        .update => .modified,
        .remove => .missing,
        .conflict => if (entry.ownership == .foreign) .foreign else .conflict,
    };
}

fn entryForId(entries: []const export_mod.Entry, id: []const u8) ?export_mod.Entry {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
}

fn findSkill(skills: []const Skill, skill_id: []const u8) ?Skill {
    for (skills) |skill| {
        if (std.mem.eql(u8, skill.id, skill_id)) return skill;
    }
    return null;
}

pub fn inspectSkill(
    allocator: std.mem.Allocator,
    environment: *const Environment,
    skill_id: []const u8,
) !SkillInspection {
    const paths = environment.paths;
    const artifacts_dir = try paths.artifactsDir(allocator);

    var engine = try Artifact.init(allocator, paths.tin_dir, artifacts_dir);
    defer engine.deinit();

    const skills = try engine.discoverSkillsStrict(allocator);
    const rules = try engine.discoverRulesStrict(allocator);

    const skill = findSkill(skills, skill_id) orelse return Error.UnknownSkill;
    const name = try utils.slugify(allocator, skill.id);

    const targets = try RecipeManager.getExportTargets(allocator, environment.config, paths);

    var results = std.ArrayListUnmanaged(TargetInspection){};
    for (targets) |target| {
        const prepared = try export_mod.prepare(allocator, target.dir, skills, rules);
        const entry = entryForId(prepared.entries, skill.id) orelse return Error.InspectionIncomplete;
        try results.append(allocator, .{
            .name = target.name,
            .dir = target.dir,
            .path = entry.path,
            .state = targetState(entry),
            .ownership = entry.ownership,
            .reason = entry.reason,
        });
    }

    return .{
        .id = skill.id,
        .name = name,
        .source_path = skill.source_path,
        .targets = try results.toOwnedSlice(allocator),
    };
}

pub fn originLabel(origin: Paths.Origin) []const u8 {
    return switch (origin) {
        .personal => "personal",
        .repo => "repo",
        .none => "none",
    };
}

pub fn targetStateLabel(state: TargetState) []const u8 {
    return switch (state) {
        .match => "match",
        .missing => "missing",
        .modified => "modified",
        .conflict => "conflict",
        .foreign => "foreign",
    };
}

pub fn ownershipLabel(ownership: export_mod.Ownership) []const u8 {
    return switch (ownership) {
        .managed => "managed",
        .foreign => "foreign",
        .legacy => "legacy",
        .none => "none",
    };
}

pub fn symlinkStatusLabel(status: Symlink.Status) []const u8 {
    return switch (status) {
        .linked => "ok",
        .missing => "not linked",
        .wrong_target => "wrong target",
        .not_a_symlink => "not a symlink",
        .broken => "broken",
        .source_missing => "source missing",
    };
}

pub fn renderConfig(report: ConfigReport) void {
    output.info("config selection:", .{});
    if (report.selected_path) |path| {
        output.plain("  effective: {s}", .{path});
    } else {
        output.plain("  effective: (none — no tinrc.yml found)", .{});
    }
    output.plain("  origin:    {s}", .{originLabel(report.origin)});
    output.plain("  personal:  {s} ({s})", .{ report.personal_path, if (pathPresent(report.personal_path)) "present" else "absent" });
    output.plain("  repo:      {s} ({s})", .{ report.repo_path, if (pathPresent(report.repo_path)) "present" else "absent" });
    switch (report.state) {
        .loaded => output.plain("  state:     loaded", .{}),
        .absent => output.plain("  state:     absent", .{}),
        .invalid => output.err("  state:     invalid ({s})", .{report.reason orelse "unknown"}),
    }
}

pub fn renderStatus(report: StatusReport) void {
    output.info("status:", .{});
    if (report.config.selected_path) |path| {
        output.plain("  config:    {s} ({s})", .{ path, originLabel(report.config.origin) });
    } else {
        output.plain("  config:    (none)", .{});
    }
    switch (report.config.state) {
        .loaded => {},
        .absent => output.plain("  config state: absent", .{}),
        .invalid => output.err("  config state: invalid ({s})", .{report.config.reason orelse "unknown"}),
    }
    output.plain("  artifacts: {s} ({s})", .{ report.artifacts_dir, if (report.artifacts_present) "present" else "absent" });
    output.plain("  schemas:   {s} ({s})", .{ report.schemas_dir, if (report.schemas_present) "present" else "absent" });
    if (report.revision) |revision| {
        output.plain("  revision:  {s}", .{revision});
    } else {
        output.plain("  revision:  (unknown)", .{});
    }
    output.plain("  managed symlinks:", .{});
    if (report.symlinks.len == 0) {
        output.plain("    (none)", .{});
    } else {
        for (report.symlinks) |symlink| {
            const kind = if (symlink.copy) "copy" else "link";
            output.plain("    [{s}] {s} ({s}) -> {s}", .{ symlinkStatusLabel(symlink.status), symlink.name, kind, symlink.target });
        }
    }
}

pub fn renderSkillInspection(result: SkillInspection) void {
    output.info("skill {s} (rendered name: {s})", .{ result.id, result.name });
    if (result.source_path) |path| {
        output.plain("  source: {s}", .{path});
    } else {
        output.plain("  source: (unknown)", .{});
    }
    if (result.targets.len == 0) {
        output.plain("  no export targets configured", .{});
        return;
    }
    output.plain("  export targets:", .{});
    for (result.targets) |target| {
        output.plain("    {s} -> {s}", .{ target.name, target.dir });
        if (target.reason) |reason| {
            output.plain("      {s:<9} {s:<8} {s} ({s})", .{ targetStateLabel(target.state), ownershipLabel(target.ownership), target.path, reason });
        } else {
            output.plain("      {s:<9} {s:<8} {s}", .{ targetStateLabel(target.state), ownershipLabel(target.ownership), target.path });
        }
    }
}

const testing = std.testing;

const Fixture = struct {
    root: []const u8,
    tin_dir: []const u8,
    config_dir: []const u8,
    artifacts_dir: []const u8,
    personal: []const u8,
    repo: []const u8,
    paths: Paths,
};

fn makeFixture(a: std.mem.Allocator, tmp: *std.testing.TmpDir) !Fixture {
    const root = try tmp.parent_dir.realpathAlloc(a, &tmp.sub_path);
    const tin_dir = try std.fs.path.join(a, &.{ root, ".tin" });
    const config_dir = try std.fs.path.join(a, &.{ root, ".config", "tin" });
    const artifacts_dir = try std.fs.path.join(a, &.{ config_dir, "artifacts" });
    const personal = try std.fs.path.join(a, &.{ config_dir, "tinrc.yml" });
    const repo = try std.fs.path.join(a, &.{ tin_dir, "tinrc.yml" });
    return .{
        .root = root,
        .tin_dir = tin_dir,
        .config_dir = config_dir,
        .artifacts_dir = artifacts_dir,
        .personal = personal,
        .repo = repo,
        .paths = Paths{ .tin_dir = tin_dir, .home_dir = root },
    };
}

const schema_files = [_][]const u8{ "meta-schema.yaml", "tinrc.yaml", "skill.yaml", "rule.yaml", "mcp.yaml", "dialect.yaml" };

fn installSchemas(a: std.mem.Allocator, tin_dir: []const u8) !void {
    const schemas_dir = try std.fs.path.join(a, &.{ tin_dir, "engine", "src", "schemas" });
    try fs.ensureDirectoryExists(schemas_dir);
    for (schema_files) |name| {
        const src = try std.fs.path.join(a, &.{ "src", "schemas", name });
        const content = try std.fs.cwd().readFileAlloc(a, src, 1 << 20);
        const dst = try std.fs.path.join(a, &.{ schemas_dir, name });
        try fs.writeFile(dst, content);
    }
}

fn writeSkill(a: std.mem.Allocator, artifacts_dir: []const u8) !void {
    const skills_dir = try std.fs.path.join(a, &.{ artifacts_dir, "skills" });
    const rules_dir = try std.fs.path.join(a, &.{ artifacts_dir, "rules" });
    try fs.ensureDirectoryExists(skills_dir);
    try fs.ensureDirectoryExists(rules_dir);
    try fs.writeFile(
        try std.fs.path.join(a, &.{ skills_dir, "learn.yml" }),
        "description: learn things\nsystem: |\n  Follow {{ clarity }}.\ninclude:\n  - clarity\n",
    );
    try fs.writeFile(
        try std.fs.path.join(a, &.{ rules_dir, "clarity.yml" }),
        "description: clarity\ncontent: be clear\n",
    );
}

fn environmentFor(a: std.mem.Allocator, f: Fixture, config_body: []const u8) !Environment {
    try fs.ensureDirectoryExists(f.tin_dir);
    try fs.writeFile(f.repo, config_body);
    const config = (try Config.load(a, f.paths)) orelse Config{ .doc = null };
    return .{ .paths = f.paths, .config = config, .tin_dir = f.tin_dir, .home_dir = f.root };
}

fn seedExport(a: std.mem.Allocator, f: Fixture, target_dir: []const u8) !void {
    var engine = try Artifact.init(a, f.tin_dir, f.artifacts_dir);
    defer engine.deinit();
    const skills = try engine.discoverSkillsStrict(a);
    const rules = try engine.discoverRulesStrict(a);
    const prepared = try export_mod.prepare(a, target_dir, skills, rules);
    try export_mod.apply(a, prepared);
}

const Snapshot = std.StringHashMapUnmanaged([]const u8);

fn snapshotTree(a: std.mem.Allocator, root: []const u8) !Snapshot {
    var map: Snapshot = .{};
    var dir = std.fs.openDirAbsolute(root, .{ .iterate = true }) catch return map;
    defer dir.close();
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        const abs = try std.fs.path.join(a, &.{ root, entry.path });
        const desc = switch (entry.kind) {
            .directory => try a.dupe(u8, "dir"),
            .sym_link => blk: {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const target = std.fs.readLinkAbsolute(abs, &buf) catch "?";
                break :blk try std.fmt.allocPrint(a, "link:{s}", .{target});
            },
            .file => blk: {
                const data = fs.readFileAlloc(a, abs) catch "";
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
                const hex = std.fmt.bytesToHex(digest, .lower);
                break :blk try std.fmt.allocPrint(a, "file:{d}:{s}", .{ data.len, hex[0..] });
            },
            else => try a.dupe(u8, "other"),
        };
        try map.put(a, try a.dupe(u8, entry.path), desc);
    }
    return map;
}

fn expectNoMutations(before: Snapshot, after: Snapshot) !void {
    try std.testing.expectEqual(before.count(), after.count());
    var it = before.iterator();
    while (it.next()) |entry| {
        const other = after.get(entry.key_ptr.*) orelse {
            std.debug.print("path disappeared during inspection: {s}\n", .{entry.key_ptr.*});
            return error.SnapshotMismatch;
        };
        try std.testing.expectEqualStrings(entry.value_ptr.*, other);
    }
}

test "inspectConfig reports absent selection when neither file exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try makeFixture(a, &tmp);

    const report = try inspectConfig(a, f.paths);
    try std.testing.expectEqual(ConfigState.absent, report.state);
    try std.testing.expectEqual(Paths.Origin.none, report.origin);
    try std.testing.expect(report.selected_path == null);
    try std.testing.expectEqualStrings(f.personal, report.personal_path);
    try std.testing.expectEqualStrings(f.repo, report.repo_path);
}

test "inspectConfig reports repo origin for a repo-only configuration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try makeFixture(a, &tmp);
    try installSchemas(a, f.tin_dir);
    try fs.ensureDirectoryExists(f.tin_dir);
    try fs.writeFile(f.repo, "identity:\n  name: repo\n");

    const report = try inspectConfig(a, f.paths);
    try std.testing.expectEqual(ConfigState.loaded, report.state);
    try std.testing.expectEqual(Paths.Origin.repo, report.origin);
    try std.testing.expectEqualStrings(f.repo, report.selected_path.?);
}

test "inspectConfig prefers a personal configuration over the repo default" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try makeFixture(a, &tmp);
    try installSchemas(a, f.tin_dir);
    try fs.ensureDirectoryExists(f.tin_dir);
    try fs.writeFile(f.repo, "identity:\n  name: repo\n");
    try fs.ensureDirectoryExists(f.config_dir);
    try fs.writeFile(f.personal, "identity:\n  name: personal\n");

    const report = try inspectConfig(a, f.paths);
    try std.testing.expectEqual(ConfigState.loaded, report.state);
    try std.testing.expectEqual(Paths.Origin.personal, report.origin);
    try std.testing.expectEqualStrings(f.personal, report.selected_path.?);
}

test "inspectConfig reports a broken configuration with a reason and no fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try makeFixture(a, &tmp);
    try installSchemas(a, f.tin_dir);
    try fs.ensureDirectoryExists(f.tin_dir);
    try fs.writeFile(f.repo, "identity: [unterminated\n");

    const report = try inspectConfig(a, f.paths);
    try std.testing.expectEqual(ConfigState.invalid, report.state);
    try std.testing.expectEqual(Paths.Origin.repo, report.origin);
    try std.testing.expectEqualStrings(f.repo, report.selected_path.?);
    try std.testing.expect(report.reason != null);
}

test "inspectStatus reports symlink state, presence, and revision without writing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try makeFixture(a, &tmp);
    try installSchemas(a, f.tin_dir);
    try fs.ensureDirectoryExists(f.tin_dir);
    try fs.writeFile(f.repo,
        \\symlinks:
        \\  shell:
        \\    - source: environment/config/.zshrc
        \\      target: ~/.zshrc
        \\    - source: environment/config/.tmux.conf
        \\      target: ~/.tmux.conf
        \\exports:
        \\  zed:
        \\    dir: ~/.agents/skills
    );
    try fs.ensureDirectoryExists(try std.fs.path.join(a, &.{ f.tin_dir, "environment", "config" }));
    try fs.writeFile(try std.fs.path.join(a, &.{ f.tin_dir, "environment", "config", ".zshrc" }), "zshrc\n");
    try fs.writeFile(try std.fs.path.join(a, &.{ f.tin_dir, "environment", "config", ".tmux.conf" }), "tmux\n");
    try fs.ensureDirectoryExists(f.artifacts_dir);
    const source = try std.fs.path.join(a, &.{ f.tin_dir, "environment", "config", ".zshrc" });
    try std.fs.symLinkAbsolute(source, try std.fs.path.join(a, &.{ f.root, ".zshrc" }), .{});
    try fs.writeFile(try std.fs.path.join(a, &.{ f.tin_dir, ".tin-revision" }), "abc123\n");

    const before = try snapshotTree(a, f.root);
    const report = try inspectStatus(a, f.paths);
    const after = try snapshotTree(a, f.root);

    try std.testing.expectEqual(ConfigState.loaded, report.config.state);
    try std.testing.expectEqual(@as(usize, 2), report.symlinks.len);
    try std.testing.expectEqual(Symlink.Status.linked, report.symlinks[0].status);
    try std.testing.expectEqual(Symlink.Status.missing, report.symlinks[1].status);
    try std.testing.expect(report.artifacts_present);
    try std.testing.expect(report.schemas_present);
    try std.testing.expectEqualStrings("abc123", report.revision.?);
    try expectNoMutations(before, after);
}

test "inspectStatus reports broken config and keeps symlinks empty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try makeFixture(a, &tmp);
    try installSchemas(a, f.tin_dir);
    try fs.ensureDirectoryExists(f.tin_dir);
    try fs.writeFile(f.repo, "identity: nope\n");

    const report = try inspectStatus(a, f.paths);
    try std.testing.expectEqual(ConfigState.invalid, report.config.state);
    try std.testing.expectEqual(@as(usize, 0), report.symlinks.len);
    try std.testing.expect(report.revision == null);
}

test "inspectSkill reports a skill with included rules across multiple missing targets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try makeFixture(a, &tmp);
    try installSchemas(a, f.tin_dir);
    try writeSkill(a, f.artifacts_dir);
    const env = try environmentFor(a, f,
        \\exports:
        \\  one:
        \\    dir: ~/targets/one
        \\  two:
        \\    dir: ~/targets/two
    );

    const before = try snapshotTree(a, f.root);
    const result = try inspectSkill(a, &env, "learn");
    const after = try snapshotTree(a, f.root);

    try std.testing.expectEqualStrings("learn", result.id);
    try std.testing.expectEqualStrings("learn", result.name);
    try std.testing.expect(result.source_path != null);
    try std.testing.expect(std.mem.endsWith(u8, result.source_path.?, "learn.yml"));
    try std.testing.expectEqual(@as(usize, 2), result.targets.len);
    for (result.targets) |target| {
        try std.testing.expectEqual(TargetState.missing, target.state);
    }
    try expectNoMutations(before, after);
}

test "inspectSkill reports match after an export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try makeFixture(a, &tmp);
    try installSchemas(a, f.tin_dir);
    try writeSkill(a, f.artifacts_dir);
    const env = try environmentFor(a, f,
        \\exports:
        \\  one:
        \\    dir: ~/targets/one
    );
    const target_dir = try std.fs.path.join(a, &.{ f.root, "targets", "one" });
    try seedExport(a, f, target_dir);

    const before = try snapshotTree(a, f.root);
    const result = try inspectSkill(a, &env, "learn");
    const after = try snapshotTree(a, f.root);

    try std.testing.expectEqual(@as(usize, 1), result.targets.len);
    try std.testing.expectEqual(TargetState.match, result.targets[0].state);
    try std.testing.expectEqual(export_mod.Ownership.managed, result.targets[0].ownership);
    try expectNoMutations(before, after);
}

test "inspectSkill reports modified when the source rendering changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try makeFixture(a, &tmp);
    try installSchemas(a, f.tin_dir);
    try writeSkill(a, f.artifacts_dir);
    const env = try environmentFor(a, f,
        \\exports:
        \\  one:
        \\    dir: ~/targets/one
    );
    const target_dir = try std.fs.path.join(a, &.{ f.root, "targets", "one" });
    try seedExport(a, f, target_dir);

    try fs.writeFile(
        try std.fs.path.join(a, &.{ f.artifacts_dir, "skills", "learn.yml" }),
        "description: learn much more\nsystem: |\n  Follow {{ clarity }}.\ninclude:\n  - clarity\n",
    );

    const before = try snapshotTree(a, f.root);
    const result = try inspectSkill(a, &env, "learn");
    const after = try snapshotTree(a, f.root);

    try std.testing.expectEqual(TargetState.modified, result.targets[0].state);
    try expectNoMutations(before, after);
}

test "inspectSkill reports conflict for a locally edited managed file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try makeFixture(a, &tmp);
    try installSchemas(a, f.tin_dir);
    try writeSkill(a, f.artifacts_dir);
    const env = try environmentFor(a, f,
        \\exports:
        \\  one:
        \\    dir: ~/targets/one
    );
    const target_dir = try std.fs.path.join(a, &.{ f.root, "targets", "one" });
    try seedExport(a, f, target_dir);
    try fs.writeFile(try std.fs.path.join(a, &.{ target_dir, "learn", "SKILL.md" }), "locally edited\n");

    const before = try snapshotTree(a, f.root);
    const result = try inspectSkill(a, &env, "learn");
    const after = try snapshotTree(a, f.root);

    try std.testing.expectEqual(TargetState.conflict, result.targets[0].state);
    try std.testing.expectEqual(export_mod.Ownership.managed, result.targets[0].ownership);
    try expectNoMutations(before, after);
}

test "inspectSkill reports foreign conflict for an unmanaged same-name file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try makeFixture(a, &tmp);
    try installSchemas(a, f.tin_dir);
    try writeSkill(a, f.artifacts_dir);
    const env = try environmentFor(a, f,
        \\exports:
        \\  one:
        \\    dir: ~/targets/one
    );
    const foreign_file = try std.fs.path.join(a, &.{ f.root, "targets", "one", "learn", "SKILL.md" });
    try fs.ensureParentDirExists(foreign_file);
    try fs.writeFile(foreign_file, "someone else's skill\n");

    const before = try snapshotTree(a, f.root);
    const result = try inspectSkill(a, &env, "learn");
    const after = try snapshotTree(a, f.root);

    try std.testing.expectEqual(TargetState.foreign, result.targets[0].state);
    try std.testing.expectEqual(export_mod.Ownership.foreign, result.targets[0].ownership);
    try expectNoMutations(before, after);
}

test "inspectSkill rejects an unknown skill" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try makeFixture(a, &tmp);
    try installSchemas(a, f.tin_dir);
    try writeSkill(a, f.artifacts_dir);
    const env = try environmentFor(a, f,
        \\exports:
        \\  one:
        \\    dir: ~/targets/one
    );

    try std.testing.expectError(Error.UnknownSkill, inspectSkill(a, &env, "nope"));
}

test "inspectSkill fails when the artifacts directory is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try makeFixture(a, &tmp);
    try installSchemas(a, f.tin_dir);
    const env = try environmentFor(a, f,
        \\exports:
        \\  one:
        \\    dir: ~/targets/one
    );

    try std.testing.expectError(Artifact.Error.DirectoryNotFound, inspectSkill(a, &env, "learn"));
}
