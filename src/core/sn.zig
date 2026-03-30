const std = @import("std");
const fs = @import("../lib/fs.zig");
const yaml = @import("../lib/yaml.zig");
const output = @import("../lib/output.zig");

pub const Rule = @import("sn/rule.zig");
pub const Skill = @import("sn/skill.zig");

const Sn = @This();

pub const Error = error{
    DirectoryNotFound,
    ParseFailed,
};

sn_dir: []const u8,

pub fn init(allocator: std.mem.Allocator, tin_dir: []const u8) !Sn {
    const sn_dir = try std.fmt.allocPrint(allocator, "{s}/sn", .{tin_dir});

    var dir = std.fs.openDirAbsolute(sn_dir, .{}) catch return Error.DirectoryNotFound;
    dir.close();

    return .{ .sn_dir = sn_dir };
}

pub fn discoverSkills(self: *const Sn, allocator: std.mem.Allocator) ![]Skill {
    const dir = try std.fmt.allocPrint(allocator, "{s}/skills", .{self.sn_dir});
    return discover(Skill, allocator, dir);
}

pub fn discoverRules(self: *const Sn, allocator: std.mem.Allocator) ![]Rule {
    const dir = try std.fmt.allocPrint(allocator, "{s}/rules", .{self.sn_dir});
    return discover(Rule, allocator, dir);
}

pub fn validate(self: *const Sn, allocator: std.mem.Allocator) !void {
    const rules = try self.discoverRules(allocator);
    const skills = try self.discoverSkills(allocator);

    var errors: usize = 0;

    var rule_id_set = std.StringHashMap(void).init(allocator);
    for (rules) |rule| {
        if (rule_id_set.contains(rule.id)) {
            output.err("duplicate rule id: \"{s}\"", .{rule.id});
            errors += 1;
        } else {
            try rule_id_set.put(rule.id, {});
        }
    }

    var skill_id_set = std.StringHashMap(void).init(allocator);
    for (skills) |skill| {
        if (skill_id_set.contains(skill.id)) {
            output.err("duplicate skill id: \"{s}\"", .{skill.id});
            errors += 1;
        } else {
            try skill_id_set.put(skill.id, {});
        }
    }

    var skill_ids: std.ArrayList([]const u8) = .{};
    for (skills) |skill| try skill_ids.append(allocator, skill.id);
    var rule_ids: std.ArrayList([]const u8) = .{};
    for (rules) |rule| try rule_ids.append(allocator, rule.id);

    for (skills) |skill| {
        if (skill.validateRefs(allocator, skill_ids.items, rule_ids.items)) |ref_errors| {
            for (ref_errors) |ref_err| {
                switch (ref_err.kind) {
                    .unknown_skill => output.err("skill \"{s}\": references unknown skill \"{s}\"", .{ ref_err.skill_id, ref_err.ref_id }),
                    .unknown_rule => output.err("skill \"{s}\": includes unknown rule \"{s}\"", .{ ref_err.skill_id, ref_err.ref_id }),
                }
                errors += 1;
            }
        }
    }

    if (errors > 0) {
        output.err("{d} validation error(s)", .{errors});
        return Error.ParseFailed;
    }
}

fn discover(comptime T: type, allocator: std.mem.Allocator, base_dir: []const u8) ![]T {
    var items: std.ArrayList(T) = .{};

    var dir = std.fs.openDirAbsolute(base_dir, .{ .iterate = true }) catch return items.items;
    defer dir.close();

    try walkAndParse(T, allocator, dir, base_dir, base_dir, &items);

    return items.items;
}

fn walkAndParse(comptime T: type, allocator: std.mem.Allocator, dir: std.fs.Dir, base_dir: []const u8, current_dir: []const u8, items: *std.ArrayList(T)) !void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            const sub_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ current_dir, entry.name });
            var sub_dir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
            defer sub_dir.close();
            try walkAndParse(T, allocator, sub_dir, base_dir, sub_path, items);
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".yml")) {
            const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ current_dir, entry.name });
            const content = fs.readFileAlloc(allocator, file_path) catch continue;
            const id = deriveId(allocator, base_dir, file_path) catch continue;

            var item = parseYaml(T, allocator, content) catch continue;
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
    const id = try deriveId(std.testing.allocator, "/home/.tin/sn/skills", "/home/.tin/sn/skills/fs/read.yml");
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("fs/read", id);
}

test "deriveId handles nested paths" {
    const id = try deriveId(std.testing.allocator, "/sn/skills", "/sn/skills/git/log.yml");
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("git/log", id);
}

test "deriveId handles single level" {
    const id = try deriveId(std.testing.allocator, "/sn/rules", "/sn/rules/clarity.yml");
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("clarity", id);
}

test "deriveId rejects path equal to base dir" {
    try std.testing.expectError(Error.ParseFailed, deriveId(std.testing.allocator, "/sn/skills", "/sn/skills"));
}

test "deriveId rejects too-short relative path" {
    try std.testing.expectError(Error.ParseFailed, deriveId(std.testing.allocator, "/sn/skills", "/sn/skills/a.ym"));
}

test {
    _ = Rule;
    _ = Skill;
}
