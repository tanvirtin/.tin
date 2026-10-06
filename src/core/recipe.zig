const std = @import("std");
const fs = @import("../lib/fs.zig");
const yaml = @import("yaml");
const output = @import("../lib/output.zig");
const process = @import("../lib/process.zig");
const Environment = @import("environment.zig");
const template = @import("../lib/template.zig");
const platform = @import("../platform/platform.zig");
const expression = @import("../spec/sublang/expression/mod.zig");
const diag = @import("../spec/diagnostic.zig");

const Recipe = @This();

pub const RecipeError = error{
    MissingName,
    MissingSteps,
    InvalidStep,
    ParseFailed,
    ExecutionFailed,
};

pub const Action = union(enum) {
    run: []const u8,
    install: []const u8,
    recipe: []const u8,
    link,
    fonts,
    mkdir: []const u8,
    download: struct { url: []const u8, to: []const u8 },
    clone: struct { repo: []const u8, to: []const u8 },
};

pub const Step = struct {
    name: ?[]const u8 = null,
    action: Action,
    condition: ?[]const u8 = null,
};

name: []const u8,
description: ?[]const u8,
steps: []const Step,

pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Recipe {
    var doc = yaml.parse(allocator, content) catch return RecipeError.ParseFailed;
    defer doc.deinit();

    const name_raw = if (doc.getMapping("name")) |v| v.getString() orelse return RecipeError.MissingName else return RecipeError.MissingName;
    const name = try allocator.dupe(u8, name_raw);

    const description = if (doc.getMapping("description")) |v| blk: {
        const s = v.getString() orelse break :blk null;
        break :blk try allocator.dupe(u8, s);
    } else null;

    const steps_val = doc.getMapping("steps") orelse return RecipeError.MissingSteps;
    const steps_seq = steps_val.getSequence() orelse return RecipeError.MissingSteps;

    var steps: std.ArrayListUnmanaged(Step) = .{};
    defer steps.deinit(allocator);

    for (steps_seq) |step_val| {
        const action = try parseAction(step_val, allocator);
        try steps.append(allocator, .{
            .name = if (step_val.getMapping("name")) |v| blk: {
                const s = v.getString() orelse break :blk null;
                break :blk try allocator.dupe(u8, s);
            } else null,
            .action = action,
            .condition = if (step_val.getMapping("if")) |v| blk: {
                const s = v.getString() orelse break :blk null;
                break :blk try allocator.dupe(u8, s);
            } else null,
        });
    }

    return .{
        .name = name,
        .description = description,
        .steps = try steps.toOwnedSlice(allocator),
    };
}

fn parseAction(step_val: yaml.Value, allocator: std.mem.Allocator) !Action {
    if (step_val.getMapping("run")) |v| {
        if (v.getString()) |s| return .{ .run = try allocator.dupe(u8, s) };
    }
    if (step_val.getMapping("install")) |v| {
        if (v.getString()) |s| return .{ .install = try allocator.dupe(u8, s) };
    }
    if (step_val.getMapping("recipe")) |v| {
        if (v.getString()) |s| return .{ .recipe = try allocator.dupe(u8, s) };
    }
    if (step_val.getMapping("link") != null) return .link;
    if (step_val.getMapping("fonts") != null) return .fonts;
    if (step_val.getMapping("mkdir")) |v| {
        if (v.getString()) |s| return .{ .mkdir = try allocator.dupe(u8, s) };
    }
    if (step_val.getMapping("download")) |dl| {
        const url = if (dl.getString()) |s|
            s
        else if (dl.getMapping("url")) |v|
            v.getString() orelse return RecipeError.InvalidStep
        else
            return RecipeError.InvalidStep;

        const to_val = if (dl.getString() != null)
            step_val.getMapping("to")
        else
            dl.getMapping("to");
        const to = (to_val orelse return RecipeError.InvalidStep).getString() orelse return RecipeError.InvalidStep;

        return .{ .download = .{
            .url = try allocator.dupe(u8, url),
            .to = try allocator.dupe(u8, to),
        } };
    }
    if (step_val.getMapping("clone")) |v| {
        if (v.getString()) |repo| {
            const to_val = step_val.getMapping("to") orelse return RecipeError.InvalidStep;
            const to_str = to_val.getString() orelse return RecipeError.InvalidStep;
            return .{ .clone = .{
                .repo = try allocator.dupe(u8, repo),
                .to = try allocator.dupe(u8, to_str),
            } };
        }
    }
    return RecipeError.InvalidStep;
}

pub fn execute(self: *const Recipe, allocator: std.mem.Allocator) anyerror!void {
    const paths = Environment.Paths.init(allocator) catch {
        output.err("could not resolve environment paths", .{});
        return;
    };

    const vars = blk: {
        const config = Environment.Config.load(allocator, paths) orelse break :blk &[_]Environment.TemplateVar{};
        break :blk Environment.IdentityProvider.getTemplateVars(allocator, config) catch break :blk &[_]Environment.TemplateVar{};
    };

    output.info("Executing recipe: {s}", .{self.name});
    if (self.description) |desc| {
        output.plain("  {s}", .{desc});
    }

    const cond_env = buildConditionEnv(allocator) catch |err| {
        output.err("could not build condition environment: {s}", .{@errorName(err)});
        return;
    };

    for (self.steps) |step| {
        if (step.condition) |condition| {
            if (!checkCondition(condition, allocator, &cond_env)) {
                if (step.name) |name| {
                    output.info("  skip {s} (condition not met)", .{name});
                }
                continue;
            }
        }

        if (step.name) |name| {
            output.info("  Step: {s}", .{name});
        }

        executeAction(allocator, step.action, vars, paths) catch {
            output.err("  step failed: {s}", .{step.name orelse "unnamed"});
            return;
        };
    }
}

fn executeAction(allocator: std.mem.Allocator, action: Action, vars: []const Environment.TemplateVar, paths: Environment.Paths) anyerror!void {
    switch (action) {
        .run => |cmd| {
            const rendered = template.render(allocator, cmd, vars) catch cmd;
            try process.runShell(allocator, rendered);
        },
        .install => |pkg| {
            try platform.installPackage(allocator, pkg);
        },
        .recipe => |recipe_name| {
            const rendered = template.render(allocator, recipe_name, vars) catch recipe_name;
            var search = try paths.recipeSearch(allocator);
            defer search.deinit(allocator);
            const found = (try search.resolve(allocator, rendered)) orelse {
                output.err("recipe not found: {s}", .{rendered});
                return error.RecipeNotFound;
            };
            defer allocator.free(found.path);
            const content = try fs.readFileAlloc(allocator, found.path);
            defer allocator.free(content);
            const sub = try parse(allocator, content);
            try sub.execute(allocator);
        },
        .link => {},
        .fonts => {},
        .mkdir => |dir| {
            const rendered = template.render(allocator, dir, vars) catch dir;
            const resolved = paths.absolutePath(allocator, rendered) catch rendered;
            try fs.ensureDirectoryExists(resolved);
        },
        .download => |dl| {
            const to_expanded = template.render(allocator, dl.to, vars) catch dl.to;
            const to_resolved = paths.absolutePath(allocator, to_expanded) catch to_expanded;
            const rendered_url = template.render(allocator, dl.url, vars) catch dl.url;
            const cmd = try std.fmt.allocPrint(allocator, "curl -fsSL -o {s} {s}", .{ to_resolved, rendered_url });
            defer allocator.free(cmd);
            try process.runShell(allocator, cmd);
        },
        .clone => |cl| {
            const to_expanded = template.render(allocator, cl.to, vars) catch cl.to;
            const to_resolved = paths.absolutePath(allocator, to_expanded) catch to_expanded;
            const rendered_repo = template.render(allocator, cl.repo, vars) catch cl.repo;
            if (fs.pathExists(to_resolved)) {
                output.info("  skip clone (already exists): {s}", .{to_resolved});
                return;
            }
            const cmd = try std.fmt.allocPrint(allocator, "git clone {s} {s}", .{ rendered_repo, to_resolved });
            defer allocator.free(cmd);
            try process.runShell(allocator, cmd);
        },
    }
}

fn checkCondition(cond: []const u8, allocator: std.mem.Allocator, env: *const expression.EvalEnv) bool {
    var diagnostics = std.ArrayListUnmanaged(diag.Diagnostic){};
    defer diagnostics.deinit(allocator);
    const v = expression.evaluateDetailed(allocator, cond, env, &diagnostics, .{ .file_id = 0, .start = 0, .end = 0 }) catch |err| {
        if (diagnostics.items.len > 0) {
            output.err("invalid condition '{s}': {s}", .{ cond, diagnostics.items[0].message });
        } else {
            output.err("invalid condition '{s}': {s}", .{ cond, @errorName(err) });
        }
        return false;
    };
    return v.truthy();
}

fn buildConditionEnv(allocator: std.mem.Allocator) !expression.EvalEnv {
    var env = expression.EvalEnv.init(allocator);
    try env.set("os", .{ .string = @tagName(@import("builtin").os.tag) });

    var map = std.StringHashMap(expression.Value).init(allocator);
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    var it = env_map.hash_map.iterator();
    while (it.next()) |entry| {
        try map.put(try allocator.dupe(u8, entry.key_ptr.*), .{ .string = try allocator.dupe(u8, entry.value_ptr.*) });
    }
    try env.set("env", .{ .object = map });
    return env;
}

test "parse minimal recipe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "name: test\nsteps:\n  - run: echo hello");
    try std.testing.expectEqualStrings("test", r.name);
    try std.testing.expectEqual(@as(usize, 1), r.steps.len);
    try std.testing.expectEqualStrings("echo hello", r.steps[0].action.run);
}

test "parse recipe step composes another recipe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "name: parent\nsteps:\n  - recipe: child");
    switch (r.steps[0].action) {
        .recipe => |name| try std.testing.expectEqualStrings("child", name),
        else => @panic("expected recipe action"),
    }
}
