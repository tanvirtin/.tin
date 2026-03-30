const std = @import("std");
const yaml = @import("../../lib/yaml.zig");
const template = @import("../../lib/template.zig");
const Rule = @import("rule.zig");

const Skill = @This();

pub const Error = error{
    MissingCommandOrSystem,
};

pub const ValidationError = struct {
    kind: enum { unknown_skill, unknown_rule },
    skill_id: []const u8,
    ref_id: []const u8,
};

pub const Param = struct {
    name: []const u8,
    type: []const u8 = "string",
    description: ?[]const u8 = null,
    required: bool = false,
    default: ?[]const u8 = null,
};

id: []const u8 = "",
description: []const u8,
command: ?[]const u8 = null,
system: ?[]const u8 = null,
input: []const Param = &.{},
skills: []const []const u8 = &.{},
include: []const []const u8 = &.{},
context: ?[]const u8 = null,

pub fn validate(self: *const Skill) Error!void {
    if (self.command == null and self.system == null) return Error.MissingCommandOrSystem;
}

pub fn validateRefs(
    self: *const Skill,
    allocator: std.mem.Allocator,
    skill_ids: []const []const u8,
    rule_ids: []const []const u8,
) ?[]const ValidationError {
    var errors: std.ArrayList(ValidationError) = .{};

    for (self.skills) |ref_id| {
        if (!contains(skill_ids, ref_id)) {
            errors.append(allocator, .{
                .kind = .unknown_skill,
                .skill_id = self.id,
                .ref_id = ref_id,
            }) catch continue;
        }
    }

    for (self.include) |ref_id| {
        if (!contains(rule_ids, ref_id)) {
            errors.append(allocator, .{
                .kind = .unknown_rule,
                .skill_id = self.id,
                .ref_id = ref_id,
            }) catch continue;
        }
    }

    if (errors.items.len == 0) return null;
    return errors.items;
}

pub fn resolveSystem(self: *const Skill, allocator: std.mem.Allocator, rules: []const Rule) ![]const u8 {
    const system = self.system orelse return "";
    if (self.include.len == 0) return system;

    var vars: std.ArrayList(struct { []const u8, []const u8 }) = .{};
    for (self.include) |rule_id| {
        for (rules) |rule| {
            if (std.mem.eql(u8, rule.id, rule_id)) {
                try vars.append(allocator, .{ rule_id, rule.content });
                break;
            }
        }
    }

    return template.render(allocator, system, vars.items);
}

fn contains(ids: []const []const u8, target: []const u8) bool {
    for (ids) |id| {
        if (std.mem.eql(u8, id, target)) return true;
    }
    return false;
}

test "decode succeeds with command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try yaml.parse(arena.allocator(), "description: run shell\ncommand: sh -c");
    const skill = try yaml.decode(Skill, arena.allocator(), doc);
    try std.testing.expectEqualStrings("run shell", skill.description);
    try std.testing.expectEqualStrings("sh -c", skill.command.?);
    try std.testing.expect(skill.system == null);
}

test "decode succeeds with system" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try yaml.parse(arena.allocator(), "description: analyze\nsystem: you are a code reviewer");
    const skill = try yaml.decode(Skill, arena.allocator(), doc);
    try std.testing.expect(skill.command == null);
    try std.testing.expectEqualStrings("you are a code reviewer", skill.system.?);
}

test "decode fails without description" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try yaml.parse(arena.allocator(), "command: echo");
    try std.testing.expectError(yaml.DecodeError.MissingField, yaml.decode(Skill, arena.allocator(), doc));
}

test "decode extracts composed skills" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try yaml.parse(arena.allocator(), "description: review code\nsystem: review\nskills:\n  - search/ripgrep\n  - review/checklist");
    const skill = try yaml.decode(Skill, arena.allocator(), doc);
    try std.testing.expectEqual(@as(usize, 2), skill.skills.len);
    try std.testing.expectEqualStrings("search/ripgrep", skill.skills[0]);
    try std.testing.expectEqualStrings("review/checklist", skill.skills[1]);
}

test "decode extracts include list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try yaml.parse(arena.allocator(), "description: implement\nsystem: code\ninclude:\n  - clarity\n  - naming");
    const skill = try yaml.decode(Skill, arena.allocator(), doc);
    try std.testing.expectEqual(@as(usize, 2), skill.include.len);
    try std.testing.expectEqualStrings("clarity", skill.include[0]);
    try std.testing.expectEqualStrings("naming", skill.include[1]);
}

test "decode extracts input params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try yaml.parse(arena.allocator(), "description: read file\ncommand: cat\ninput:\n  - name: path\n    type: string\n    required: true\n  - name: lines\n    type: integer");
    const skill = try yaml.decode(Skill, arena.allocator(), doc);
    try std.testing.expectEqual(@as(usize, 2), skill.input.len);
    try std.testing.expectEqualStrings("path", skill.input[0].name);
    try std.testing.expect(skill.input[0].required);
    try std.testing.expectEqualStrings("integer", skill.input[1].type);
}

test "decode extracts context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try yaml.parse(arena.allocator(), "description: deep analysis\nsystem: analyze\ncontext: fork");
    const skill = try yaml.decode(Skill, arena.allocator(), doc);
    try std.testing.expectEqualStrings("fork", skill.context.?);
}

test "decode succeeds with both command and system" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try yaml.parse(arena.allocator(), "description: hybrid\ncommand: sh -c\nsystem: you are a helper");
    const skill = try yaml.decode(Skill, arena.allocator(), doc);
    try std.testing.expectEqualStrings("sh -c", skill.command.?);
    try std.testing.expectEqualStrings("you are a helper", skill.system.?);
}

test "decode extracts param default value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try yaml.parse(arena.allocator(), "description: read\ncommand: cat\ninput:\n  - name: lines\n    type: integer\n    default: 10");
    const skill = try yaml.decode(Skill, arena.allocator(), doc);
    try std.testing.expectEqual(@as(usize, 1), skill.input.len);
    try std.testing.expectEqualStrings("10", skill.input[0].default.?);
    try std.testing.expect(!skill.input[0].required);
}

test "validateRefs returns null when all refs valid" {
    const skill = Skill{
        .id = "test",
        .description = "test",
        .system = "sys",
        .skills = &.{"other/skill"},
        .include = &.{"clarity"},
    };
    const result = skill.validateRefs(
        std.testing.allocator,
        &.{"other/skill"},
        &.{"clarity"},
    );
    try std.testing.expect(result == null);
}

test "validateRefs returns errors for unknown rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const skill = Skill{
        .id = "test",
        .description = "test",
        .system = "sys",
        .include = &.{"nonexistent"},
    };
    const result = skill.validateRefs(
        arena.allocator(),
        &.{},
        &.{"clarity"},
    );
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 1), result.?.len);
    try std.testing.expectEqualStrings("nonexistent", result.?[0].ref_id);
}

test "validateRefs returns errors for unknown skill" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const skill = Skill{
        .id = "test",
        .description = "test",
        .system = "sys",
        .skills = &.{"missing/skill"},
    };
    const result = skill.validateRefs(
        arena.allocator(),
        &.{"other/skill"},
        &.{},
    );
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 1), result.?.len);
    try std.testing.expectEqualStrings("missing/skill", result.?[0].ref_id);
}

test "resolveSystem replaces placeholders with rule content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const skill = Skill{
        .id = "test",
        .description = "test",
        .system = "before {{ clarity }} after",
        .include = &.{"clarity"},
    };
    const rules = &[_]Rule{.{
        .id = "clarity",
        .description = "clarity rules",
        .content = "RULES HERE",
    }};
    const result = try skill.resolveSystem(arena.allocator(), rules);
    try std.testing.expectEqualStrings("before RULES HERE after", result);
}

test "validateRefs returns null when no refs to validate" {
    const skill = Skill{
        .id = "test",
        .description = "test",
        .system = "sys",
    };
    const result = skill.validateRefs(
        std.testing.allocator,
        &.{"any/skill"},
        &.{"any_rule"},
    );
    try std.testing.expect(result == null);
}

test "validateRefs returns errors for both unknown skill and rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const skill = Skill{
        .id = "test",
        .description = "test",
        .system = "sys",
        .skills = &.{"missing/skill"},
        .include = &.{"missing_rule"},
    };
    const result = skill.validateRefs(
        arena.allocator(),
        &.{},
        &.{},
    );
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 2), result.?.len);
}

test "resolveSystem returns empty string when system is null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const skill = Skill{
        .id = "test",
        .description = "test",
    };
    const result = try skill.resolveSystem(arena.allocator(), &.{});
    try std.testing.expectEqualStrings("", result);
}

test "resolveSystem replaces multiple includes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const skill = Skill{
        .id = "test",
        .description = "test",
        .system = "{{ clarity }}\n{{ design }}",
        .include = &.{ "clarity", "design" },
    };
    const rules = &[_]Rule{
        .{ .id = "clarity", .description = "c", .content = "CLARITY" },
        .{ .id = "design", .description = "d", .content = "DESIGN" },
    };
    const result = try skill.resolveSystem(arena.allocator(), rules);
    try std.testing.expect(std.mem.indexOf(u8, result, "CLARITY") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "DESIGN") != null);
}

test "resolveSystem returns system unchanged when no includes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const skill = Skill{
        .id = "test",
        .description = "test",
        .system = "no placeholders here",
    };
    const result = try skill.resolveSystem(arena.allocator(), &.{});
    try std.testing.expectEqualStrings("no placeholders here", result);
}

test "validate succeeds with command only" {
    const skill = Skill{ .description = "test", .command = "sh -c" };
    try skill.validate();
}

test "validate succeeds with system only" {
    const skill = Skill{ .description = "test", .system = "you are a reviewer" };
    try skill.validate();
}

test "validate succeeds with both command and system" {
    const skill = Skill{ .description = "test", .command = "sh -c", .system = "you are a reviewer" };
    try skill.validate();
}

test "validate fails without command or system" {
    const skill = Skill{ .description = "test" };
    try std.testing.expectError(Error.MissingCommandOrSystem, skill.validate());
}
