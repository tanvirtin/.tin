const std = @import("std");
const Artifact = @import("../core/artifact.zig");
const output = @import("../lib/output.zig");
const Environment = @import("../core/environment.zig");
const utils = @import("../lib/utils.zig");

const export_mod = Artifact.exporter;
const inspection = @import("../core/inspection.zig");

pub const meta = .{
    .name = "artifact",
    .description = "Browse, validate, and export skills and rules",
};

fn parseFlag(args: []const []const u8, prefix: []const u8) ?[]const u8 {
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, prefix)) {
            const value = arg[prefix.len..];
            if (value.len >= 2 and (value[0] == '"' or value[0] == '\'')) {
                return value[1 .. value.len - 1];
            }
            return value;
        }
    }
    return null;
}

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    var environment = Environment.init(allocator) catch {
        output.err("could not resolve environment paths", .{});
        return 1;
    };
    const paths = environment.paths;

    const artifacts_dir = paths.artifactsDir(allocator) catch {
        output.err("could not resolve artifacts directory", .{});
        return 1;
    };
    defer allocator.free(artifacts_dir);

    var engine = Artifact.init(allocator, paths.tin_dir, artifacts_dir) catch {
        output.err("artifact directory not found at {s}", .{artifacts_dir});
        return 1;
    };
    defer engine.deinit();

    if (args.len == 0) {
        showHelp(allocator, &environment);
        return 0;
    }

    if (parseFlag(args, "--path=")) |path| {
        const format_name = parseFlag(args, "--format=") orelse "yaml";
        return renderDef(allocator, &engine, path, format_name);
    }

    const sub = args[0];
    const sub_args = args[1..];

    if (std.mem.eql(u8, sub, "list")) {
        return list(allocator, &engine, sub_args);
    } else if (std.mem.eql(u8, sub, "validate")) {
        return validate(&engine);
    } else if (std.mem.eql(u8, sub, "export")) {
        return exportTarget(allocator, &engine, &environment, sub_args);
    } else if (std.mem.eql(u8, sub, "inspect")) {
        return inspectOne(allocator, &environment, sub_args);
    } else {
        output.err("unknown artifact command: {s}", .{sub});
        showHelp(allocator, &environment);
        return 1;
    }
}

fn inspectOne(allocator: std.mem.Allocator, environment: *const Environment, args: []const []const u8) u8 {
    if (args.len < 1) {
        output.err("usage: tin artifact inspect <skill-id>", .{});
        return 1;
    }
    const result = inspection.inspectSkill(allocator, environment, args[0]) catch |e| {
        output.err("could not inspect {s}: {s}", .{ args[0], @errorName(e) });
        return 1;
    };
    inspection.renderSkillInspection(result);
    return 0;
}

fn showHelp(allocator: std.mem.Allocator, env: *const Environment) void {
    output.info("artifact — Browse, validate, and export skills and rules", .{});
    output.plain("", .{});
    output.plain("  tin artifact list [skills]                    List definitions", .{});
    output.plain("  tin artifact validate                         Validate all references", .{});
    output.plain("  tin artifact --path=<path> --format=<fmt>     Export a definition", .{});
    output.plain("  tin artifact export [target] [--dry-run] [--adopt-legacy]", .{});
    output.plain("                                                Export skills to a configured target (default: all)", .{});
    output.plain("", .{});
    output.plain("  Paths:   skills/search/ripgrep", .{});
    const targets = Environment.RecipeManager.getExportTargets(allocator, env.config, env.paths) catch &.{};
    defer allocator.free(targets);
    if (targets.len == 0) {
        output.plain("  Targets: (none — add `exports:` to tinrc.yml)", .{});
    } else {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        const w = buf.writer(allocator);
        for (targets) |t| w.print(" {s}", .{t.name}) catch {};
        output.plain("  Targets:{s}", .{buf.items});
    }
}

fn renderDef(allocator: std.mem.Allocator, engine: *const Artifact, path: []const u8, format_name: []const u8) u8 {
    if (std.mem.startsWith(u8, path, "skills/")) {
        const id = path["skills/".len..];
        if (findAndRenderSkill(allocator, engine, id, format_name)) return 0;
    } else {
        output.err("path must start with skills/", .{});
        return 1;
    }
    output.err("not found: {s}", .{path});
    return 1;
}

fn resolveSkill(allocator: std.mem.Allocator, skill: Artifact.Skill, rules: []const Artifact.Rule) Artifact.Skill {
    const resolved_system = skill.resolveSystem(allocator, rules) catch return skill;
    var resolved = skill;
    resolved.system = resolved_system;
    return resolved;
}

const SkillFormatter = struct {
    name: []const u8,
    render: *const fn (allocator: std.mem.Allocator, skill: Artifact.Skill) anyerror!void,
};

fn renderSkillYaml(allocator: std.mem.Allocator, skill: Artifact.Skill) !void {
    _ = allocator;
    output.plain("id: {s}", .{skill.id});
    output.plain("description: {s}", .{skill.description});
    if (skill.command) |cmd| output.plain("command: {s}", .{cmd});
    if (skill.system) |sys| {
        output.plain("system: |", .{});
        output.plain("{s}", .{sys});
    }
    if (skill.skills.len > 0) {
        output.plain("skills:", .{});
        for (skill.skills) |s| output.plain("  - {s}", .{s});
    }
    if (skill.context) |ctx| output.plain("context: {s}", .{ctx});
    if (skill.input.len > 0) {
        output.plain("input:", .{});
        for (skill.input) |param| {
            output.plain("  - name: {s}", .{param.name});
            output.plain("    type: {s}", .{param.type});
            if (param.description) |d| output.plain("    description: {s}", .{d});
            if (param.required) output.plain("    required: true", .{});
        }
    }
}

fn renderSkillMd(allocator: std.mem.Allocator, skill: Artifact.Skill) !void {
    _ = allocator;
    output.plain("---", .{});
    output.plain("name: {s}", .{skill.id});
    output.plain("description: {s}", .{skill.description});
    if (skill.command != null) output.plain("allowed-tools: Bash Read", .{});
    if (skill.context) |ctx| output.plain("context: {s}", .{ctx});
    output.plain("---", .{});
    output.plain("", .{});

    if (skill.system) |sys| output.plain("{s}", .{sys});
    if (skill.command) |cmd| {
        output.plain("", .{});
        output.plain("## Command", .{});
        output.plain("", .{});
        output.plain("`{s}`", .{cmd});
    }
    if (skill.skills.len > 0) {
        output.plain("", .{});
        output.plain("## Composed Skills", .{});
        output.plain("", .{});
        for (skill.skills) |s| output.plain("- {s}", .{s});
    }
    if (skill.input.len > 0) {
        output.plain("", .{});
        output.plain("## Parameters", .{});
        output.plain("", .{});
        output.plain("| Name | Type | Required | Description |", .{});
        output.plain("|------|------|----------|-------------|", .{});
        for (skill.input) |param| {
            const req = if (param.required) "yes" else "no";
            const desc = param.description orelse "";
            output.plain("| {s} | {s} | {s} | {s} |", .{ param.name, param.type, req, desc });
        }
    }
}

const formatters = [_]SkillFormatter{
    .{ .name = "yaml", .render = renderSkillYaml },
    .{ .name = "md", .render = renderSkillMd },
    .{ .name = "json", .render = renderSkillJson },
};

fn findAndRenderSkill(allocator: std.mem.Allocator, engine: *const Artifact, id: []const u8, format_name: []const u8) bool {
    const skills = engine.discoverSkills(allocator) catch return false;
    const rules = engine.discoverRules(allocator) catch {
        output.err("failed to discover rules", .{});
        return false;
    };

    var selected_formatter: ?SkillFormatter = null;
    for (formatters) |f| {
        if (std.mem.eql(u8, f.name, format_name)) {
            selected_formatter = f;
            break;
        }
    }

    const formatter = selected_formatter orelse {
        output.err("unknown format: {s} (available: yaml, md, json)", .{format_name});
        return false;
    };

    for (skills) |skill| {
        if (std.mem.eql(u8, skill.id, id)) {
            const resolved = resolveSkill(allocator, skill, rules);
            formatter.render(allocator, resolved) catch |e| {
                output.err("failed to render {s}: {s}", .{ id, @errorName(e) });
                return false;
            };
            return true;
        }
    }
    return false;
}

fn renderSkillJson(allocator: std.mem.Allocator, skill: Artifact.Skill) !void {
    var props_buf: std.ArrayListUnmanaged(u8) = .{};
    var required_buf: std.ArrayListUnmanaged(u8) = .{};

    try props_buf.appendSlice(allocator, "{");
    try required_buf.appendSlice(allocator, "[");

    var first_prop = true;
    var first_req = true;
    for (skill.input) |param| {
        if (!first_prop) try props_buf.appendSlice(allocator, ",");
        first_prop = false;

        const json_type = if (std.mem.eql(u8, param.type, "bool"))
            "boolean"
        else if (std.mem.eql(u8, param.type, "integer"))
            "integer"
        else
            "string";
        const desc = try utils.escapeJson(allocator, param.description orelse "");
        const name = try utils.escapeJson(allocator, param.name);
        const prop = try std.fmt.allocPrint(allocator, "\"{s}\":{{\"type\":\"{s}\",\"description\":\"{s}\"}}", .{ name, json_type, desc });
        try props_buf.appendSlice(allocator, prop);

        if (param.required) {
            if (!first_req) try required_buf.appendSlice(allocator, ",");
            first_req = false;
            const req = try std.fmt.allocPrint(allocator, "\"{s}\"", .{name});
            try required_buf.appendSlice(allocator, req);
        }
    }

    try props_buf.appendSlice(allocator, "}");
    try required_buf.appendSlice(allocator, "]");

    const cmd = try utils.escapeJson(allocator, skill.command orelse "");
    output.plain("{{\"name\":\"{s}\",\"description\":\"{s}\",\"command\":\"{s}\",\"input_schema\":{{\"type\":\"object\",\"properties\":{s},\"required\":{s}}}}}", .{
        try utils.escapeJson(allocator, skill.id),
        try utils.escapeJson(allocator, skill.description),
        cmd,
        props_buf.items,
        required_buf.items,
    });
}

fn list(allocator: std.mem.Allocator, engine: *const Artifact, args: []const []const u8) u8 {
    const filter = if (args.len > 0) args[0] else "";

    if (filter.len == 0 or std.mem.eql(u8, filter, "skills")) {
        const skills = engine.discoverSkills(allocator) catch {
            output.err("failed to discover skills", .{});
            return 1;
        };
        output.info("skills ({d}):", .{skills.len});
        for (skills) |skill| {
            const kind = if (skill.command != null and skill.system != null)
                "[cli+sys]"
            else if (skill.command != null)
                "[cli]    "
            else
                "[sys]    ";
            output.plain("  {s:<24} {s} {s}", .{ skill.id, kind, skill.description });
        }
        if (skills.len == 0) output.plain("  (none)", .{});
    }
    return 0;
}

fn validate(engine: *Artifact) u8 {
    engine.validate() catch |err| {
        output.err("validation failed: {s}", .{@errorName(err)});
        return 1;
    };
    output.success("all references valid", .{});
    return 0;
}

fn exportTarget(allocator: std.mem.Allocator, engine: *const Artifact, env: *const Environment, args: []const []const u8) u8 {
    var dry_run = false;
    var adopt_legacy = false;
    var target_name: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--adopt-legacy")) {
            adopt_legacy = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            output.err("unknown export flag: {s}", .{arg});
            return 1;
        } else {
            target_name = arg;
        }
    }

    const targets = Environment.RecipeManager.getExportTargets(allocator, env.config, env.paths) catch {
        output.err("could not read exports from tinrc.yml", .{});
        return 1;
    };
    defer allocator.free(targets);

    if (targets.len == 0) {
        output.err("no export targets configured (add `exports:` to tinrc.yml)", .{});
        return 1;
    }

    const skills = engine.discoverSkillsStrict(allocator) catch |e| {
        output.err("failed to discover skills: {s}", .{@errorName(e)});
        return 1;
    };
    const rules = engine.discoverRulesStrict(allocator) catch |e| {
        output.err("failed to discover rules: {s}", .{@errorName(e)});
        return 1;
    };

    if (target_name) |name| {
        if (!std.mem.eql(u8, name, "all")) {
            for (targets) |target| {
                if (std.mem.eql(u8, target.name, name)) {
                    return exportOne(allocator, target, skills, rules, dry_run, adopt_legacy);
                }
            }
            var buf: std.ArrayListUnmanaged(u8) = .{};
            const w = buf.writer(allocator);
            for (targets) |target| w.print("{s} ", .{target.name}) catch {};
            output.err("unknown target: {s} (available: {s})", .{ name, buf.items });
            return 1;
        }
    }

    var failed: usize = 0;
    for (targets) |target| {
        if (exportOne(allocator, target, skills, rules, dry_run, adopt_legacy) != 0) failed += 1;
    }
    return if (failed > 0) 1 else 0;
}

fn exportOne(
    allocator: std.mem.Allocator,
    target: Environment.RecipeManager.ExportTarget,
    skills: []const Artifact.Skill,
    rules: []const Artifact.Rule,
    dry_run: bool,
    adopt_legacy: bool,
) u8 {
    const prepared = export_mod.prepareWithOptions(allocator, target.dir, skills, rules, .{ .adopt_legacy = adopt_legacy }) catch |e| {
        output.record(.err, .{ .action = "export", .target = target.name, .status = "preflight-failed" }, "export preflight failed for {s}: {s}", .{ target.name, @errorName(e) });
        return 1;
    };

    reportPlan(target, prepared);

    if (dry_run) {
        if (prepared.hasConflicts()) {
            output.record(.err, .{ .action = "export", .target = target.name, .status = "preview-conflict" }, "export preview for {s}: blocking conflicts present; nothing written", .{target.name});
            return 1;
        }
        output.record(.success, .{ .action = "export", .target = target.name, .status = "preview-ok" }, "export preview for {s}: {d} definitions, no conflicts", .{ target.name, exportedCount(prepared) });
        return 0;
    }

    if (prepared.hasConflicts()) {
        output.record(.err, .{ .action = "export", .target = target.name, .status = "refused" }, "export refused for {s}: resolve conflicts before exporting", .{target.name});
        return 1;
    }

    export_mod.apply(allocator, prepared) catch |e| {
        output.record(.err, .{ .action = "export", .target = target.name, .status = "failed" }, "export failed for {s}: {s} (ownership manifest preserved; retry to reconcile)", .{ target.name, @errorName(e) });
        return 1;
    };

    output.record(.success, .{ .action = "export", .target = target.dir, .status = "applied" }, "exported {d} definitions to {s}/", .{ exportedCount(prepared), target.dir });
    return 0;
}

fn exportedCount(prepared: export_mod.Prepared) usize {
    var count: usize = 0;
    for (prepared.entries) |entry| {
        if (entry.action == .create or entry.action == .update or entry.action == .unchanged) count += 1;
    }
    return count;
}

fn reportPlan(target: Environment.RecipeManager.ExportTarget, prepared: export_mod.Prepared) void {
    output.record(.info, .{ .action = "export", .target = target.name, .status = "plan" }, "{s} -> {s}", .{ target.name, target.dir });
    for (prepared.entries) |entry| {
        const action = switch (entry.action) {
            .create => "create",
            .update => "update",
            .unchanged => "unchanged",
            .remove => "remove",
            .conflict => "conflict",
        };
        const ownership = switch (entry.ownership) {
            .managed => "managed",
            .foreign => "foreign",
            .legacy => "legacy",
            .none => "none",
        };
        if (entry.reason) |reason| {
            output.record(.plain, .{ .action = action, .target = entry.slug, .status = ownership }, "  {s:<9} {s:<8} {s} ({s})", .{ action, ownership, entry.slug, reason });
        } else {
            output.record(.plain, .{ .action = action, .target = entry.slug, .status = ownership }, "  {s:<9} {s:<8} {s}", .{ action, ownership, entry.slug });
        }
    }
}

test "parseFlag extracts unquoted value" {
    const args = [_][]const u8{ "--path=skills/foo", "--format=md" };
    try std.testing.expectEqualStrings("skills/foo", parseFlag(&args, "--path=").?);
    try std.testing.expectEqualStrings("md", parseFlag(&args, "--format=").?);
}

test "parseFlag strips surrounding quotes" {
    const args = [_][]const u8{"--path=\"skills/foo\""};
    try std.testing.expectEqualStrings("skills/foo", parseFlag(&args, "--path=").?);
}

test "parseFlag returns null when prefix absent" {
    const args = [_][]const u8{"--other=x"};
    try std.testing.expect(parseFlag(&args, "--path=") == null);
}

test "resolveSkill merges rule content into system" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const skill = Artifact.Skill{
        .id = "test",
        .description = "test",
        .system = "before {{ clarity }} after",
        .include = &.{"clarity"},
    };
    const rules = &[_]Artifact.Rule{.{
        .id = "clarity",
        .description = "clarity",
        .content = "RULES",
    }};
    const resolved = resolveSkill(arena.allocator(), skill, rules);
    try std.testing.expect(std.mem.indexOf(u8, resolved.system.?, "RULES") != null);
}
