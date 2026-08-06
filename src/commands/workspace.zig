const std = @import("std");
const yaml = @import("yaml");
const output = @import("../lib/output.zig");
const fs = @import("../lib/fs.zig");
const Environment = @import("../core/environment.zig");
const registry = @import("../core/workspace/registry.zig");
const scaffold = @import("../core/workspace/scaffold.zig");
const runtime = @import("../core/workspace/runtime.zig");
const Engine = @import("../spec/engine.zig").Engine;
const validate_mod = @import("../spec/validate.zig");

pub const meta = .{
    .name = "workspace",
    .description = "Register and manage workspaces (session store)",
};

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len == 0) {
        printUsage();
        return;
    }

    const subcommand = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, subcommand, "add")) {
        addWorkspace(allocator, rest);
    } else if (std.mem.eql(u8, subcommand, "list")) {
        listWorkspaces(allocator);
    } else if (std.mem.eql(u8, subcommand, "show")) {
        showWorkspace(allocator, rest);
    } else if (std.mem.eql(u8, subcommand, "validate")) {
        validateWorkspace(allocator, rest);
    } else if (std.mem.eql(u8, subcommand, "up")) {
        upWorkspace(allocator, rest);
    } else if (std.mem.eql(u8, subcommand, "down")) {
        downWorkspace(allocator, rest);
    } else if (std.mem.eql(u8, subcommand, "status")) {
        statusWorkspace(allocator, rest);
    } else if (std.mem.eql(u8, subcommand, "sessions")) {
        sessionsWorkspace(allocator, rest);
    } else {
        output.err("unknown workspace subcommand: {s}", .{subcommand});
        printUsage();
    }
}

fn printUsage() void {
    output.plain("usage: tin workspace <add|list|show|validate|up|down|status|sessions> [...]", .{});
}

fn addWorkspace(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len < 2) {
        output.err("usage: tin workspace add <name> <path>", .{});
        return;
    }
    const name = args[0];
    const path = args[1];

    const env = Environment.init(allocator) catch {
        output.err("could not resolve environment", .{});
        return;
    };

    if (fs.pathExists(env.paths.workspaceFile(allocator, name) catch return)) {
        output.err("workspace already exists: {s}", .{name});
        return;
    }

    const probe = scaffold.probe(allocator, env.paths, path) catch |err| {
        output.err("could not probe path: {s} ({s})", .{ path, @errorName(err) });
        return;
    };

    const yaml_content = scaffold.emitYaml(allocator, &probe) catch {
        output.err("could not generate workspace config", .{});
        return;
    };

    registry.write(allocator, env.paths, name, yaml_content) catch {
        output.err("could not write workspace file", .{});
        return;
    };

    output.success("registered workspace: {s}", .{name});
    output.plain("  path: {s}", .{probe.path});
    output.plain("  git: {s}", .{if (probe.is_git_repo) "yes" else "no"});
    output.plain("  mise: {s}", .{if (probe.has_mise) "yes (tools/env seeded)" else "none"});
    output.plain("  file: {s}", .{env.paths.workspaceFile(allocator, name) catch ""});
    output.plain("", .{});
    output.plain("  Next: tin workspace validate {s} && tin workspace up {s}", .{ name, name });
}

fn listWorkspaces(allocator: std.mem.Allocator) void {
    const env = Environment.init(allocator) catch {
        output.err("could not resolve environment", .{});
        return;
    };

    const names = registry.listNames(allocator, env.paths) catch {
        output.err("could not list workspaces", .{});
        return;
    };

    if (names.len == 0) {
        output.info("no workspaces registered", .{});
        output.plain("  Run 'tin workspace add <name> <path>' to register one.", .{});
        return;
    }

    output.info("workspaces:", .{});
    for (names) |name| {
        const ws = registry.load(allocator, env.paths, name) catch continue;
        output.plain("  {s:<16} {s}", .{ name, ws.path });
    }
}

fn showWorkspace(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len < 1) {
        output.err("usage: tin workspace show <name>", .{});
        return;
    }
    const env = Environment.init(allocator) catch {
        output.err("could not resolve environment", .{});
        return;
    };

    const ws = registry.load(allocator, env.paths, args[0]) catch {
        output.err("workspace not found: {s}", .{args[0]});
        return;
    };

    output.plain("{s}", .{ws.content});
}

fn validateWorkspace(allocator: std.mem.Allocator, args: []const []const u8) void {
    const all = args.len == 1 and std.mem.eql(u8, args[0], "--all");

    const env = Environment.init(allocator) catch {
        output.err("could not resolve environment", .{});
        return;
    };

    var engine = Engine.init(allocator) catch {
        output.err("could not initialize schema engine", .{});
        return;
    };
    defer engine.deinit();

    const schema_path = std.fs.path.join(allocator, &.{ env.paths.tin_dir, "src", "schemas", "workspace.yaml" }) catch {
        output.err("could not resolve schema path", .{});
        return;
    };
    defer allocator.free(schema_path);

    const schema_content = fs.readFileAlloc(allocator, schema_path) catch {
        output.err("could not read schema: {s}", .{schema_path});
        return;
    };
    var schema_doc = yaml.parse(allocator, schema_content) catch return;
    defer schema_doc.deinit();
    var resolver = validate_mod.Resolver.build(allocator, &schema_doc) catch {
        output.err("could not build schema resolver", .{});
        return;
    };
    defer resolver.deinit();

    const schema = engine.loadSchema(schema_content) catch {
        output.err("could not compile workspace schema", .{});
        return;
    };

    if (all) {
        const names = registry.listNames(allocator, env.paths) catch {
            output.err("could not list workspaces", .{});
            return;
        };
        var failed: usize = 0;
        for (names) |name| {
            if (!validateOne(allocator, &engine, &schema, &resolver, env.paths, name)) failed += 1;
        }
        if (failed > 0) std.process.exit(1);
        return;
    }

    if (args.len < 1) {
        output.err("usage: tin workspace validate <name> | --all", .{});
        return;
    }
    if (!validateOne(allocator, &engine, &schema, &resolver, env.paths, args[0])) std.process.exit(1);
}

fn validateOne(
    allocator: std.mem.Allocator,
    engine: *Engine,
    schema: *const @import("../spec/ir.zig").Schema,
    resolver: *const validate_mod.Resolver,
    paths: anytype,
    name: []const u8,
) bool {
    const content = registry.load(allocator, paths, name) catch {
        output.err("workspace not found: {s}", .{name});
        return false;
    };

    var doc = yaml.parse(allocator, content.content) catch {
        output.err("could not parse workspace YAML: {s}", .{name});
        return false;
    };
    defer doc.deinit();

    const diagnostics = validate_mod.validate(allocator, schema, doc.value, resolver, &engine.sublangs, null) catch {
        output.err("internal validation error", .{});
        return false;
    };

    if (diagnostics.len == 0) {
        output.success("valid: {s}", .{name});
        return true;
    }

    output.err("invalid: {s}", .{name});
    for (diagnostics) |d| {
        output.plain("  [{s}] {s} at byte {d}", .{ d.code, d.message, d.span.start });
    }
    return false;
}

fn runtimeEnv(allocator: std.mem.Allocator) ?Environment {
    const env = Environment.init(allocator) catch {
        output.err("could not resolve environment", .{});
        return null;
    };
    return env;
}

fn upWorkspace(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len < 1) {
        output.err("usage: tin workspace up <name> [<svc>]", .{});
        return;
    }
    const env = runtimeEnv(allocator) orelse return;

    const only = if (args.len > 1) args[1] else null;
    runtime.up(allocator, &env.paths, args[0], only) catch |e| {
        reportRuntimeError(e, "up");
        std.process.exit(1);
        return;
    };
}

fn downWorkspace(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len < 1) {
        output.err("usage: tin workspace down <name>", .{});
        return;
    }
    const env = runtimeEnv(allocator) orelse return;

    runtime.down(allocator, &env.paths, args[0]) catch |e| {
        reportRuntimeError(e, "down");
        std.process.exit(1);
        return;
    };
}

fn statusWorkspace(allocator: std.mem.Allocator, args: []const []const u8) void {
    const env = runtimeEnv(allocator) orelse return;

    if (args.len >= 1) {
        const ws = runtime.loadWorkspace(allocator, &env.paths, args[0]) catch {
            output.err("workspace not found: {s}", .{args[0]});
            return;
        };
        runtime.statusOne(allocator, &env.paths, &ws) catch |e| {
            reportRuntimeError(e, "status");
            std.process.exit(1);
            return;
        };
        return;
    }

    runtime.status(allocator, &env.paths) catch |e| {
        reportRuntimeError(e, "status");
        std.process.exit(1);
        return;
    };
}

fn sessionsWorkspace(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len < 1) {
        output.err("usage: tin workspace sessions <name>", .{});
        return;
    }
    const env = runtimeEnv(allocator) orelse return;

    runtime.sessions(allocator, &env.paths, args[0]) catch |e| {
        reportRuntimeError(e, "sessions");
        std.process.exit(1);
        return;
    };
}

fn reportRuntimeError(e: anyerror, op: []const u8) void {
    switch (e) {
        error.NotARegisteredWorkspace => output.err("workspace not registered", .{}),
        error.UnknownMethod => output.err("component references a method not in the catalog [AGENT-UNKNOWN-METHOD]", .{}),
        error.UnsetParam => output.err("component is missing a required parameter [AGENT-UNSET-PARAM]", .{}),
        error.UnknownDep => output.err("depends_on references a component not present [WS-UNKNOWN-DEP]", .{}),
        error.DepCycle => output.err("workspace topology contains a dependency cycle [WS-DEP-CYCLE]", .{}),
        error.TmuxUnavailable => output.err("tmux is required for runtime sessions (not found)", .{}),
        error.DockerUnavailable => output.err("docker is required for container/compose components (not found)", .{}),
        error.NoMise => output.err("task components require mise (not found) [AGENT-NO-MISE]", .{}),
        error.NoHealthcheck => output.err("condition: healthy requires a healthcheck on the dependency", .{}),
        error.CommandFailed => output.err("{s} failed (healthcheck not ready or runtime error)", .{op}),
        else => output.err("{s} failed: {s}", .{ op, @errorName(e) }),
    }
}
