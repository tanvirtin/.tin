const std = @import("std");
const Artifact = @import("../core/artifact.zig");
const fs = @import("../lib/fs.zig");
const output = @import("../lib/output.zig");
const Environment = @import("../core/environment.zig");
const utils = @import("../lib/utils.zig");

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

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) void {
    var environment = Environment.init(allocator) catch {
        output.err("could not resolve environment paths", .{});
        return;
    };
    const paths = environment.paths;

    const artifacts_dir = paths.artifactsDir(allocator) catch {
        output.err("could not resolve artifacts directory", .{});
        return;
    };
    defer allocator.free(artifacts_dir);

    var engine = Artifact.init(allocator, paths.tin_dir, artifacts_dir) catch {
        output.err("artifact directory not found at {s}", .{artifacts_dir});
        return;
    };
    defer engine.deinit();

    if (args.len == 0) {
        showHelp(allocator, &environment);
        return;
    }

    if (parseFlag(args, "--path=")) |path| {
        const format_name = parseFlag(args, "--format=") orelse "yaml";
        renderDef(allocator, &engine, path, format_name);
        return;
    }

    const sub = args[0];
    const sub_args = args[1..];

    if (std.mem.eql(u8, sub, "list")) {
        list(allocator, &engine, sub_args);
    } else if (std.mem.eql(u8, sub, "validate")) {
        validate(&engine);
    } else if (std.mem.eql(u8, sub, "export")) {
        exportTarget(allocator, &engine, &environment, sub_args);
    } else {
        output.err("unknown artifact command: {s}", .{sub});
        showHelp(allocator, &environment);
    }
}

fn showHelp(allocator: std.mem.Allocator, env: *const Environment) void {
    output.info("artifact — Browse, validate, and export skills and rules", .{});
    output.plain("", .{});
    output.plain("  tin artifact list [skills]                    List definitions", .{});
    output.plain("  tin artifact validate                         Validate all references", .{});
    output.plain("  tin artifact --path=<path> --format=<fmt>     Export a definition", .{});
    output.plain("  tin artifact export [target]                  Export skills to a configured target (default: all)", .{});
    output.plain("", .{});
    output.plain("  Paths:   skills/search/ripgrep", .{});
    const targets = Environment.RecipeManager.getExportTargets(allocator, env.config, env.paths) catch &.{};
    defer allocator.free(targets);
    if (targets.len == 0) {
        output.plain("  Targets: (none — add `exports:` to tinrc.yml)", .{});
    } else {
        var buf: std.ArrayList(u8) = .{};
        const w = buf.writer(allocator);
        for (targets) |t| w.print(" {s}", .{t.name}) catch {};
        output.plain("  Targets:{s}", .{buf.items});
    }
}

fn renderDef(allocator: std.mem.Allocator, engine: *const Artifact, path: []const u8, format_name: []const u8) void {
    if (std.mem.startsWith(u8, path, "skills/")) {
        const id = path["skills/".len..];
        if (findAndRenderSkill(allocator, engine, id, format_name)) return;
    } else {
        output.err("path must start with skills/", .{});
        return;
    }
    output.err("not found: {s}", .{path});
}

fn resolveSkill(allocator: std.mem.Allocator, skill: Artifact.Skill, rules: []const Artifact.Rule) Artifact.Skill {
    const resolved_system = skill.resolveSystem(allocator, rules) catch return skill;
    var resolved = skill;
    resolved.system = resolved_system;
    return resolved;
}

const SkillFormatter = struct {
    name: []const u8,
    render: *const fn (allocator: std.mem.Allocator, skill: Artifact.Skill) void,
};

fn renderSkillYaml(allocator: std.mem.Allocator, skill: Artifact.Skill) void {
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

fn renderSkillMd(allocator: std.mem.Allocator, skill: Artifact.Skill) void {
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
            formatter.render(allocator, resolved);
            return true;
        }
    }
    return false;
}

fn renderSkillJson(allocator: std.mem.Allocator, skill: Artifact.Skill) void {
    var props_buf: std.ArrayList(u8) = .{};
    var required_buf: std.ArrayList(u8) = .{};

    props_buf.appendSlice(allocator, "{") catch return;
    required_buf.appendSlice(allocator, "[") catch return;

    var first_prop = true;
    var first_req = true;
    for (skill.input) |param| {
        if (!first_prop) props_buf.appendSlice(allocator, ",") catch continue;
        first_prop = false;

        const json_type = if (std.mem.eql(u8, param.type, "bool"))
            "boolean"
        else if (std.mem.eql(u8, param.type, "integer"))
            "integer"
        else
            "string";
        const desc = utils.escapeJson(allocator, param.description orelse "");
        const name = utils.escapeJson(allocator, param.name);
        const prop = std.fmt.allocPrint(allocator, "\"{s}\":{{\"type\":\"{s}\",\"description\":\"{s}\"}}", .{ name, json_type, desc }) catch continue;
        props_buf.appendSlice(allocator, prop) catch continue;

        if (param.required) {
            if (!first_req) required_buf.appendSlice(allocator, ",") catch continue;
            first_req = false;
            const req = std.fmt.allocPrint(allocator, "\"{s}\"", .{name}) catch continue;
            required_buf.appendSlice(allocator, req) catch continue;
        }
    }

    props_buf.appendSlice(allocator, "}") catch return;
    required_buf.appendSlice(allocator, "]") catch return;

    const cmd = utils.escapeJson(allocator, skill.command orelse "");
    output.plain("{{\"name\":\"{s}\",\"description\":\"{s}\",\"command\":\"{s}\",\"input_schema\":{{\"type\":\"object\",\"properties\":{s},\"required\":{s}}}}}", .{
        utils.escapeJson(allocator, skill.id),
        utils.escapeJson(allocator, skill.description),
        cmd,
        props_buf.items,
        required_buf.items,
    });
}

fn list(allocator: std.mem.Allocator, engine: *const Artifact, args: []const []const u8) void {
    const filter = if (args.len > 0) args[0] else "";

    if (filter.len == 0 or std.mem.eql(u8, filter, "skills")) {
        const skills = engine.discoverSkills(allocator) catch {
            output.err("failed to discover skills", .{});
            return;
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
}

fn validate(engine: *Artifact) void {
    engine.validate() catch |err| {
        output.err("validation failed: {s}", .{@errorName(err)});
        return;
    };
    output.success("all references valid", .{});
}

fn exportTarget(allocator: std.mem.Allocator, engine: *const Artifact, env: *const Environment, args: []const []const u8) void {
    const targets = Environment.RecipeManager.getExportTargets(allocator, env.config, env.paths) catch {
        output.err("could not read exports from tinrc.yml", .{});
        return;
    };
    defer allocator.free(targets);

    if (targets.len == 0) {
        output.err("no export targets configured (add `exports:` to tinrc.yml)", .{});
        return;
    }

    const skills = engine.discoverSkills(allocator) catch {
        output.err("failed to discover skills", .{});
        return;
    };
    const rules = engine.discoverRules(allocator) catch {
        output.err("failed to discover rules", .{});
        return;
    };

    if (args.len == 0 or std.mem.eql(u8, args[0], "all")) {
        for (targets) |target| {
            exportSkills(allocator, target.dir, skills, rules);
        }
        return;
    }

    for (targets) |target| {
        if (std.mem.eql(u8, target.name, args[0])) {
            exportSkills(allocator, target.dir, skills, rules);
            return;
        }
    }

    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(allocator);
    for (targets) |target| w.print("{s} ", .{target.name}) catch {};
    output.err("unknown target: {s} (available: {s})", .{ args[0], buf.items });
}

fn writeExportFile(path: []const u8, content: []const u8) !void {
    try fs.ensureParentDirExists(path);
    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(content);
}

fn renderSkillToMd(allocator: std.mem.Allocator, skill: Artifact.Skill) []const u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(allocator);
    const name = utils.slugify(allocator, skill.id);

    w.print("---\nname: {s}\ndescription: {s}\n", .{ name, skill.description }) catch return "";
    if (skill.command != null) w.print("allowed-tools: Bash Read\n", .{}) catch {};
    if (skill.context) |ctx| w.print("context: {s}\n", .{ctx}) catch {};
    if (skill.skills.len > 0) {
        w.print("skills:\n", .{}) catch {};
        for (skill.skills) |s| w.print("  - {s}\n", .{s}) catch {};
    }
    w.print("---\n\n", .{}) catch return "";

    if (skill.system) |sys| w.print("{s}\n", .{sys}) catch {};
    if (skill.command) |cmd| {
        w.print("\n## Command\n\n`{s}`\n", .{cmd}) catch {};
    }
    if (skill.input.len > 0) {
        w.print("\n## Parameters\n\n", .{}) catch {};
        for (skill.input) |param| {
            const req = if (param.required) " (required)" else "";
            const desc = param.description orelse "";
            w.print("- **{s}** ({s}{s}): {s}\n", .{ param.name, param.type, req, desc }) catch continue;
        }
    }

    return buf.items;
}

fn exportSkills(allocator: std.mem.Allocator, base_dir: []const u8, skills: []const Artifact.Skill, rules: []const Artifact.Rule) void {
    const base = base_dir;
    utils.cleanDir(base) catch |e| {
        output.err("failed to clear {s}: {s}", .{ base, @errorName(e) });
        return;
    };
    var count: usize = 0;
    var failed: usize = 0;

    for (skills) |skill| {
        const resolved_skill = resolveSkill(allocator, skill, rules);
        const slug = utils.slugify(allocator, resolved_skill.id);
        const path = std.fmt.allocPrint(allocator, "{s}/{s}/SKILL.md", .{ base, slug }) catch continue;
        const content = renderSkillToMd(allocator, resolved_skill);
        writeExportFile(path, content) catch |e| {
            failed += 1;
            output.err("failed to write {s}: {s}", .{ path, @errorName(e) });
            continue;
        };
        count += 1;
    }

    if (failed > 0) {
        output.err("exported {d} of {d} definitions to {s}/ ({d} failed)", .{ count, skills.len, base, failed });
        return;
    }

    output.success("exported {d} definitions to {s}/", .{ count, base });
}
