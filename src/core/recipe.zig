const std = @import("std");
const fs = @import("../lib/fs.zig");
const yaml = @import("../lib/yaml.zig");
const output = @import("../lib/output.zig");
const process = @import("../lib/process.zig");
const Environment = @import("environment.zig");
const template = @import("../lib/template.zig");
const platform = @import("../platform/platform.zig");

const Recipe = @This();

pub const RecipeError = error{
    MissingName,
    MissingSteps,
    InvalidStep,
    ParseFailed,
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
    name: ?[]const u8,
    action: Action,
    condition: ?[]const u8,
};

name: []const u8,
description: ?[]const u8,
steps: []const Step,

pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Recipe {
    const doc = yaml.parse(allocator, content) catch return RecipeError.ParseFailed;

    const name = if (doc.getMapping("name")) |v| v.getString() orelse return RecipeError.MissingName else return RecipeError.MissingName;
    const description = if (doc.getMapping("description")) |v| v.getString() else null;

    const steps_val = doc.getMapping("steps") orelse return RecipeError.MissingSteps;
    const steps_seq = steps_val.getSequence() orelse return RecipeError.MissingSteps;

    var steps: std.ArrayList(Step) = .{};
    for (steps_seq) |step_val| {
        const action = try parseAction(step_val);
        try steps.append(allocator, .{
            .name = if (step_val.getMapping("name")) |v| v.getString() else null,
            .action = action,
            .condition = if (step_val.getMapping("if")) |v| v.getString() else null,
        });
    }

    return .{
        .name = name,
        .description = description,
        .steps = steps.items,
    };
}

fn parseAction(step_val: yaml.Value) RecipeError!Action {
    if (step_val.getMapping("run")) |v| {
        if (v.getString()) |s| return .{ .run = s };
    }
    if (step_val.getMapping("install")) |v| {
        if (v.getString()) |s| return .{ .install = s };
    }
    if (step_val.getMapping("recipe")) |v| {
        if (v.getString()) |s| return .{ .recipe = s };
    }
    if (step_val.getMapping("link") != null) return .link;
    if (step_val.getMapping("fonts") != null) return .fonts;
    if (step_val.getMapping("mkdir")) |v| {
        if (v.getString()) |s| return .{ .mkdir = s };
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

        return .{ .download = .{ .url = url, .to = to } };
    }
    if (step_val.getMapping("clone")) |v| {
        if (v.getString()) |repo| {
            const to = step_val.getMapping("to") orelse return RecipeError.InvalidStep;
            return .{ .clone = .{ .repo = repo, .to = to.getString() orelse return RecipeError.InvalidStep } };
        }
    }
    return RecipeError.InvalidStep;
}

pub fn execute(self: *const Recipe, allocator: std.mem.Allocator) bool {
    return self.executeWithDepth(allocator, 0);
}

fn executeWithDepth(self: *const Recipe, allocator: std.mem.Allocator, depth: usize) bool {
    const vars = blk: {
        const env = Environment.init(allocator) catch break :blk &[_]Environment.TemplateVar{};
        break :blk env.templateVars(allocator) catch break :blk &[_]Environment.TemplateVar{};
    };

    var failed: usize = 0;

    for (self.steps) |step| {
        if (step.condition) |condition| {
            if (!evaluateCondition(allocator, condition)) {
                if (step.name) |name| {
                    output.info("  skip {s} (condition not met)", .{name});
                }
                continue;
            }
        }

        if (step.name) |name| {
            output.info("  {s}", .{name});
        }

        if (!executeAction(allocator, step.action, vars, depth)) {
            output.err("  step failed: {s}", .{step.name orelse "unnamed"});
            failed += 1;
        }
    }

    if (failed > 0) {
        output.err("{d} step(s) failed", .{failed});
    }
    return failed == 0;
}

fn executeAction(allocator: std.mem.Allocator, action: Action, vars: []const Environment.TemplateVar, depth: usize) bool {
    switch (action) {
        .run => |cmd| {
            const rendered = template.render(allocator, cmd, vars) catch cmd;
            process.runShell(allocator, rendered) catch return false;
        },
        .install => |pkg| {
            platform.installPackage(allocator, pkg) catch return false;
        },
        .recipe => |recipe_name| {
            return executeSubRecipe(allocator, recipe_name, depth);
        },
        .link => executeLink(allocator),
        .fonts => executeFonts(allocator),
        .mkdir => |dir| {
            const rendered = template.render(allocator, dir, vars) catch dir;
            const resolved = resolveHome(allocator, rendered) catch rendered;
            fs.ensureParentDirExists(resolved) catch {};
            fs.ensureDirectoryExists(resolved) catch return false;
        },
        .download => |dl| {
            const to_expanded = template.render(allocator, dl.to, vars) catch dl.to;
            const to_resolved = resolveHome(allocator, to_expanded) catch to_expanded;
            const rendered_url = template.render(allocator, dl.url, vars) catch dl.url;
            const cmd = std.fmt.allocPrint(allocator, "curl -fsSL -o {s} {s}", .{ to_resolved, rendered_url }) catch return false;
            process.runShell(allocator, cmd) catch return false;
        },
        .clone => |cl| {
            const to_expanded = template.render(allocator, cl.to, vars) catch cl.to;
            const to_resolved = resolveHome(allocator, to_expanded) catch to_expanded;
            const rendered_repo = template.render(allocator, cl.repo, vars) catch cl.repo;
            if (fs.pathExists(to_resolved)) {
                output.info("  skip clone (already exists): {s}", .{to_resolved});
                return true;
            }
            const cmd = std.fmt.allocPrint(allocator, "git clone {s} {s}", .{ rendered_repo, to_resolved }) catch return false;
            process.runShell(allocator, cmd) catch return false;
        },
    }
    return true;
}

fn executeSubRecipe(allocator: std.mem.Allocator, recipe_name: []const u8, depth: usize) bool {
    const max_recipe_depth = 16;
    if (depth >= max_recipe_depth) {
        output.err("  recipe cycle detected (depth > {d}): {s}", .{ max_recipe_depth, recipe_name });
        return false;
    }

    const env = Environment.init(allocator) catch {
        output.err("  could not resolve environment", .{});
        return false;
    };

    const recipes_dir = env.recipesDir(allocator) catch {
        output.err("  could not resolve recipes directory", .{});
        return false;
    };

    const path = std.fmt.allocPrint(allocator, "{s}/{s}.yml", .{ recipes_dir, recipe_name }) catch {
        output.err("  allocation failed", .{});
        return false;
    };

    const content = fs.readFileAlloc(allocator, path) catch {
        output.err("  recipe not found: {s}", .{recipe_name});
        return false;
    };

    const sub_recipe = Recipe.parse(allocator, content) catch {
        output.err("  failed to parse recipe: {s}", .{recipe_name});
        return false;
    };

    output.info("  running recipe: {s}", .{sub_recipe.name});
    const ok = sub_recipe.executeWithDepth(allocator, depth + 1);
    if (ok) {
        output.success("  recipe complete: {s}", .{sub_recipe.name});
    }
    return ok;
}

fn executeLink(allocator: std.mem.Allocator) void {
    const env = Environment.init(allocator) catch {
        output.err("  could not resolve environment", .{});
        return;
    };

    const symlinks = env.managedSymlinks(allocator) catch {
        output.err("  could not resolve symlink mappings", .{});
        return;
    };

    for (symlinks) |symlink| {
        switch (symlink.status()) {
            .linked => output.success("  skip {s} (already linked)", .{symlink.name}),
            .missing => {
                symlink.link() catch {
                    output.err("  failed to link {s}", .{symlink.name});
                    continue;
                };
                output.success("  link {s}", .{symlink.name});
            },
            .wrong_target, .not_a_symlink => {
                symlink.backup(allocator) catch {
                    output.err("  failed to backup {s}", .{symlink.name});
                    continue;
                };
                symlink.link() catch {
                    output.err("  failed to link {s}", .{symlink.name});
                    continue;
                };
                output.success("  link {s} (backed up existing)", .{symlink.name});
            },
            .broken => {
                symlink.unlink() catch {};
                symlink.link() catch {
                    output.err("  failed to link {s}", .{symlink.name});
                    continue;
                };
                output.success("  link {s} (replaced broken)", .{symlink.name});
            },
        }
    }
}

fn executeFonts(allocator: std.mem.Allocator) void {
    const env = Environment.init(allocator) catch {
        output.err("  could not resolve environment", .{});
        return;
    };

    const source_dir_path = env.fontSourceDir(allocator) catch {
        output.err("  could not resolve font source directory", .{});
        return;
    };

    const dest_dir_path = platform.getFontDir(allocator, env.home_dir) catch {
        output.err("  could not resolve font destination directory", .{});
        return;
    };

    fs.ensureDirectoryExists(dest_dir_path) catch {
        output.err("  could not create font directory", .{});
        return;
    };

    var source_dir = std.fs.openDirAbsolute(source_dir_path, .{ .iterate = true }) catch {
        output.err("  could not open font source", .{});
        return;
    };
    defer source_dir.close();

    var installed: usize = 0;
    var skipped: usize = 0;
    var iter = source_dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".ttf")) continue;

        const dest_path = std.fs.path.join(allocator, &.{ dest_dir_path, entry.name }) catch continue;
        if (fs.pathExists(dest_path)) {
            skipped += 1;
            continue;
        }

        const source_path = std.fs.path.join(allocator, &.{ source_dir_path, entry.name }) catch continue;
        std.fs.copyFileAbsolute(source_path, dest_path, .{}) catch {
            output.err("  failed to copy {s}", .{entry.name});
            continue;
        };
        output.success("  copy {s}", .{entry.name});
        installed += 1;
    }

    platform.postFontInstall(allocator) catch {};

    if (installed > 0) {
        output.success("  fonts installed ({d} new, {d} skipped)", .{ installed, skipped });
    } else {
        output.success("  fonts up to date ({d} skipped)", .{skipped});
    }
}


fn resolveHome(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, path, "~/")) {
        const home = fs.homeDir() catch return path;
        return std.fs.path.join(allocator, &.{ home, path[2..] });
    }
    return path;
}

fn evaluateCondition(allocator: std.mem.Allocator, condition: []const u8) bool {
    const trimmed = std.mem.trim(u8, condition, " ");

    if (std.mem.startsWith(u8, trimmed, "not exists ")) {
        const path = std.mem.trim(u8, trimmed["not exists ".len..], " ");
        const resolved = resolveHome(allocator, path) catch path;
        return !fs.pathExists(resolved);
    }

    if (std.mem.startsWith(u8, trimmed, "exists ")) {
        const path = std.mem.trim(u8, trimmed["exists ".len..], " ");
        const resolved = resolveHome(allocator, path) catch path;
        return fs.pathExists(resolved);
    }

    if (std.mem.startsWith(u8, trimmed, "command_exists ")) {
        const cmd = std.mem.trim(u8, trimmed["command_exists ".len..], " ");
        const check = std.fmt.allocPrint(allocator, "command -v {s} >/dev/null 2>&1", .{cmd}) catch return false;
        process.runShell(allocator, check) catch return false;
        return true;
    }

    if (std.mem.startsWith(u8, trimmed, "os")) {
        const eq_pos = std.mem.indexOf(u8, trimmed, "==") orelse return false;
        const rhs = std.mem.trimLeft(u8, trimmed[eq_pos + 2 ..], " ");
        const value = unquote(rhs);
        return std.mem.eql(u8, platform.getOsName(), value);
    }

    return false;
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and (s[0] == '\'' or s[0] == '"')) {
        const quote = s[0];
        if (std.mem.indexOfScalarPos(u8, s, 1, quote)) |end| {
            return s[1..end];
        }
    }
    return s;
}

test "parse minimal recipe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try Recipe.parse(arena.allocator(), "name: test\nsteps:\n  - run: echo hello");
    try std.testing.expectEqualStrings("test", r.name);
    try std.testing.expectEqual(@as(usize, 1), r.steps.len);
    try std.testing.expectEqualStrings("echo hello", r.steps[0].action.run);
}

test "parse recipe with all step types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\name: full
        \\steps:
        \\  - run: echo hello
        \\  - install: tmux
        \\  - recipe: git
        \\  - link: all
        \\  - fonts: all
    ;
    const r = try Recipe.parse(arena.allocator(), input);
    try std.testing.expectEqual(@as(usize, 5), r.steps.len);
    try std.testing.expectEqualStrings("echo hello", r.steps[0].action.run);
    try std.testing.expectEqualStrings("tmux", r.steps[1].action.install);
    try std.testing.expectEqualStrings("git", r.steps[2].action.recipe);
    try std.testing.expectEqual(Action.link, r.steps[3].action);
    try std.testing.expectEqual(Action.fonts, r.steps[4].action);
}

test "parse mkdir and clone steps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\name: test
        \\steps:
        \\  - mkdir: ~/.config/foo
        \\  - clone: https://github.com/user/repo
        \\    to: ~/.config/repo
    ;
    const r = try Recipe.parse(arena.allocator(), input);
    try std.testing.expectEqual(@as(usize, 2), r.steps.len);
    try std.testing.expectEqualStrings("~/.config/foo", r.steps[0].action.mkdir);
    try std.testing.expectEqualStrings("https://github.com/user/repo", r.steps[1].action.clone.repo);
    try std.testing.expectEqualStrings("~/.config/repo", r.steps[1].action.clone.to);
}

test "parse fails without name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(RecipeError.MissingName, Recipe.parse(arena.allocator(), "steps:\n  - run: echo hi"));
}

test "parse fails without steps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(RecipeError.MissingSteps, Recipe.parse(arena.allocator(), "name: test"));
}

test "evaluateCondition rejects wrong os" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(!evaluateCondition(arena.allocator(), "os == 'windows'"));
}

test "evaluateCondition exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(evaluateCondition(arena.allocator(), "exists /"));
    try std.testing.expect(!evaluateCondition(arena.allocator(), "exists /nonexistent_path_xyz"));
}

test "evaluateCondition not exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(evaluateCondition(arena.allocator(), "not exists /nonexistent_path_xyz"));
    try std.testing.expect(!evaluateCondition(arena.allocator(), "not exists /"));
}

test "evaluateCondition command_exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(evaluateCondition(arena.allocator(), "command_exists sh"));
    try std.testing.expect(!evaluateCondition(arena.allocator(), "command_exists nonexistent_cmd_xyz"));
}

test "parse recipe with description" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try Recipe.parse(arena.allocator(), "name: git\ndescription: Configure git\nsteps:\n  - run: echo hi");
    try std.testing.expectEqualStrings("git", r.name);
    try std.testing.expectEqualStrings("Configure git", r.description.?);
}

test "parse recipe without description" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try Recipe.parse(arena.allocator(), "name: test\nsteps:\n  - run: echo hi");
    try std.testing.expect(r.description == null);
}

test "parse download step" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\name: test
        \\steps:
        \\  - download: https://example.com/file
        \\    to: /tmp/file
    ;
    const r = try Recipe.parse(arena.allocator(), input);
    try std.testing.expectEqual(@as(usize, 1), r.steps.len);
    try std.testing.expectEqualStrings("https://example.com/file", r.steps[0].action.download.url);
    try std.testing.expectEqualStrings("/tmp/file", r.steps[0].action.download.to);
}

test "parse step with condition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\name: test
        \\steps:
        \\  - run: brew install tmux
        \\    if: os == 'darwin'
    ;
    const r = try Recipe.parse(arena.allocator(), input);
    try std.testing.expectEqualStrings("os == 'darwin'", r.steps[0].condition.?);
}

test "parse step with name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input =
        \\name: test
        \\steps:
        \\  - name: greet
        \\    run: echo hello
    ;
    const r = try Recipe.parse(arena.allocator(), input);
    try std.testing.expectEqualStrings("greet", r.steps[0].name.?);
}

test "parse fails with invalid step type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(RecipeError.InvalidStep, Recipe.parse(arena.allocator(), "name: test\nsteps:\n  - bogus: value"));
}

test "evaluateCondition os match for current platform" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const os_name = platform.getOsName();
    const condition = std.fmt.allocPrint(arena.allocator(), "os == '{s}'", .{os_name}) catch return;
    try std.testing.expect(evaluateCondition(arena.allocator(), condition));
}

test "evaluateCondition returns false for unknown condition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(!evaluateCondition(arena.allocator(), "unknown_condition foo"));
}

test "unquote strips single quotes" {
    try std.testing.expectEqualStrings("hello", unquote("'hello'"));
}

test "unquote strips double quotes" {
    try std.testing.expectEqualStrings("world", unquote("\"world\""));
}

test "unquote returns unquoted string as-is" {
    try std.testing.expectEqualStrings("bare", unquote("bare"));
}
