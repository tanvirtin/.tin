const std = @import("std");
const Sn = @import("../core/sn.zig");
const fs = @import("../lib/fs.zig");
const output = @import("../lib/output.zig");
const Environment = @import("../core/environment.zig");

pub const meta = .{
    .name = "sn",
    .description = "AI orchestration engine — skills and rules",
};

const Format = enum { yaml, md, json };

fn escapeJson(allocator: std.mem.Allocator, s: []const u8) []const u8 {
    var needs_escape = false;
    for (s) |c| {
        if (c == '"' or c == '\\' or c == '\n' or c == '\r' or c == '\t') {
            needs_escape = true;
            break;
        }
    }
    if (!needs_escape) return s;

    var buf: std.ArrayList(u8) = .{};
    for (s) |c| {
        switch (c) {
            '"' => buf.appendSlice(allocator, "\\\"") catch continue,
            '\\' => buf.appendSlice(allocator, "\\\\") catch continue,
            '\n' => buf.appendSlice(allocator, "\\n") catch continue,
            '\r' => buf.appendSlice(allocator, "\\r") catch continue,
            '\t' => buf.appendSlice(allocator, "\\t") catch continue,
            else => buf.append(allocator, c) catch continue,
        }
    }
    return buf.items;
}

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
    const env = Environment.init(allocator) catch {
        output.err("could not resolve environment", .{});
        return;
    };

    const sn = Sn.init(allocator, env.tin_dir) catch {
        output.err("sn directory not found — run from a .tin project", .{});
        return;
    };

    if (args.len == 0) {
        showHelp();
        return;
    }

    if (parseFlag(args, "--path=")) |path| {
        const format_str = parseFlag(args, "--format=") orelse "yaml";
        const format = std.meta.stringToEnum(Format, format_str) orelse {
            output.err("unknown format: {s} (use yaml, md, or json)", .{format_str});
            return;
        };
        renderDef(allocator, &sn, path, format);
        return;
    }

    const sub = args[0];
    const sub_args = args[1..];

    if (std.mem.eql(u8, sub, "list")) {
        list(allocator, &sn, sub_args);
    } else if (std.mem.eql(u8, sub, "validate")) {
        validate(allocator, &sn);
    } else if (std.mem.eql(u8, sub, "export")) {
        exportTarget(allocator, &sn, env.tin_dir, sub_args);
    } else {
        output.err("unknown sn command: {s}", .{sub});
        showHelp();
    }
}

fn showHelp() void {
    output.info("sn — AI orchestration engine", .{});
    output.plain("", .{});
    output.plain("  tin sn list [skills]                           List definitions", .{});
    output.plain("  tin sn validate                               Validate all references", .{});
    output.plain("  tin sn --path=<path> --format=<yaml|md|json>  Export a definition", .{});
    output.plain("  tin sn export <target>                        Export all for a consumer", .{});
    output.plain("", .{});
    output.plain("  Paths:   skills/search/ripgrep", .{});
    output.plain("  Targets: claude, codex, opencode", .{});
}

fn renderDef(allocator: std.mem.Allocator, sn: *const Sn, path: []const u8, format: Format) void {
    if (std.mem.startsWith(u8, path, "skills/")) {
        const id = path["skills/".len..];
        if (findAndRenderSkill(allocator, sn, id, format)) return;
    } else {
        output.err("path must start with skills/", .{});
        return;
    }
    output.err("not found: {s}", .{path});
}

fn resolveSkill(allocator: std.mem.Allocator, skill: Sn.Skill, rules: []const Sn.Rule) Sn.Skill {
    const resolved_system = skill.resolveSystem(allocator, rules) catch return skill;
    var resolved = skill;
    resolved.system = resolved_system;
    return resolved;
}

fn findAndRenderSkill(allocator: std.mem.Allocator, sn: *const Sn, id: []const u8, format: Format) bool {
    const skills = sn.discoverSkills(allocator) catch return false;
    const rules = sn.discoverRules(allocator) catch &.{};
    for (skills) |skill| {
        if (std.mem.eql(u8, skill.id, id)) {
            const resolved = resolveSkill(allocator, skill, rules);
            switch (format) {
                .yaml => renderSkillYaml(resolved),
                .md => renderSkillMd(resolved),
                .json => renderSkillJson(allocator, resolved),
            }
            return true;
        }
    }
    return false;
}

fn renderSkillYaml(skill: Sn.Skill) void {
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

fn renderSkillMd(skill: Sn.Skill) void {
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

fn renderSkillJson(allocator: std.mem.Allocator, skill: Sn.Skill) void {
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
        const desc = escapeJson(allocator, param.description orelse "");
        const name = escapeJson(allocator, param.name);
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

    const cmd = escapeJson(allocator, skill.command orelse "");
    output.plain("{{\"name\":\"{s}\",\"description\":\"{s}\",\"command\":\"{s}\",\"input_schema\":{{\"type\":\"object\",\"properties\":{s},\"required\":{s}}}}}", .{
        escapeJson(allocator, skill.id),
        escapeJson(allocator, skill.description),
        cmd,
        props_buf.items,
        required_buf.items,
    });
}

fn list(allocator: std.mem.Allocator, sn: *const Sn, args: []const []const u8) void {
    const filter = if (args.len > 0) args[0] else "";

    if (filter.len == 0 or std.mem.eql(u8, filter, "skills")) {
        const skills = sn.discoverSkills(allocator) catch {
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

fn validate(allocator: std.mem.Allocator, sn: *const Sn) void {
    sn.validate(allocator) catch |err| {
        output.err("validation failed: {s}", .{@errorName(err)});
        return;
    };
    output.success("all references valid", .{});
}

const ExportTarget = enum { claude, codex, opencode };

fn exportTarget(allocator: std.mem.Allocator, sn: *const Sn, tin_dir: []const u8, args: []const []const u8) void {
    if (args.len == 0) {
        output.err("usage: tin sn export <claude|codex|opencode>", .{});
        return;
    }

    const target = std.meta.stringToEnum(ExportTarget, args[0]) orelse {
        output.err("unknown target: {s} (use claude, codex, opencode)", .{args[0]});
        return;
    };

    const skills = sn.discoverSkills(allocator) catch {
        output.err("failed to discover skills", .{});
        return;
    };
    const rules = sn.discoverRules(allocator) catch &.{};

    switch (target) {
        .claude => exportClaude(allocator, tin_dir, skills, rules),
        .codex => exportGeneric(allocator, tin_dir, ".codex", skills, rules),
        .opencode => exportGeneric(allocator, tin_dir, ".opencode", skills, rules),
    }
}

fn slugify(allocator: std.mem.Allocator, id: []const u8) []const u8 {
    var buf: std.ArrayList(u8) = .{};
    for (id) |c| {
        buf.append(allocator, if (c == '/') '-' else c) catch continue;
    }
    return buf.items;
}

fn cleanDir(allocator: std.mem.Allocator, path: []const u8) void {
    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .directory) {
            const sub = std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name }) catch continue;
            cleanDir(allocator, sub);
            dir.deleteDir(entry.name) catch {};
        } else {
            dir.deleteFile(entry.name) catch {};
        }
    }
}

fn writeExportFile(path: []const u8, content: []const u8) bool {
    fs.ensureParentDirExists(path) catch {};
    const file = std.fs.createFileAbsolute(path, .{}) catch return false;
    defer file.close();
    file.writeAll(content) catch return false;
    return true;
}

fn renderSkillToMd(allocator: std.mem.Allocator, skill: Sn.Skill) []const u8 {
    var buf: std.ArrayList(u8) = .{};
    const w = buf.writer(allocator);

    w.print("---\nname: {s}\ndescription: {s}\n", .{ skill.id, skill.description }) catch return "";
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

fn exportClaude(allocator: std.mem.Allocator, tin_dir: []const u8, skills: []const Sn.Skill, rules: []const Sn.Rule) void {
    const base = std.fmt.allocPrint(allocator, "{s}/.claude/skills", .{tin_dir}) catch return;
    cleanDir(allocator, base);
    var count: usize = 0;

    for (skills) |skill| {
        const resolved_skill = resolveSkill(allocator, skill, rules);
        const slug = slugify(allocator, resolved_skill.id);
        const path = std.fmt.allocPrint(allocator, "{s}/{s}/SKILL.md", .{ base, slug }) catch continue;
        const content = renderSkillToMd(allocator, resolved_skill);
        if (writeExportFile(path, content)) count += 1;
    }

    output.success("exported {d} definitions to {s}/", .{ count, base });
}

fn exportGeneric(allocator: std.mem.Allocator, tin_dir: []const u8, dir_name: []const u8, skills: []const Sn.Skill, rules: []const Sn.Rule) void {
    const base = std.fmt.allocPrint(allocator, "{s}/{s}", .{ tin_dir, dir_name }) catch return;
    cleanDir(allocator, base);
    var count: usize = 0;

    for (skills) |skill| {
        const resolved_skill = resolveSkill(allocator, skill, rules);
        const slug = slugify(allocator, resolved_skill.id);
        const path = std.fmt.allocPrint(allocator, "{s}/skills/{s}.md", .{ base, slug }) catch continue;
        const content = renderSkillToMd(allocator, resolved_skill);
        if (writeExportFile(path, content)) count += 1;
    }

    output.success("exported {d} definitions to {s}/", .{ count, base });
}
