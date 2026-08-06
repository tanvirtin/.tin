const std = @import("std");
const output = @import("../lib/output.zig");
const fs = @import("../lib/fs.zig");
const envfile = @import("../lib/envfile.zig");
const pi_env = @import("../core/environment/pi_env.zig");
const Environment = @import("../core/environment.zig");

pub const meta = .{
    .name = "env",
    .description = "Manage API keys and model defaults via the gitignored .env file",
};

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len == 0) {
        status(allocator);
        return;
    }

    const subcommand = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, subcommand, "status") or std.mem.eql(u8, subcommand, "show")) {
        status(allocator);
    } else if (std.mem.eql(u8, subcommand, "sync")) {
        sync(allocator);
    } else if (std.mem.eql(u8, subcommand, "set")) {
        setValue(allocator, rest);
    } else {
        output.err("unknown env subcommand: {s}", .{subcommand});
        output.plain("usage: tin env [status|sync|set KEY=VALUE]", .{});
    }
}

fn loadEnv(allocator: std.mem.Allocator, env: *const Environment) ?[]const envfile.Entry {
    const path = env.paths.envFile(allocator) catch {
        output.err("could not resolve .env path", .{});
        return null;
    };

    if (!fs.pathExists(path)) {
        output.info("no .env file at {s}", .{path});
        return null;
    }

    const content = fs.readFileAlloc(allocator, path) catch {
        output.err("could not read .env", .{});
        return null;
    };

    return envfile.parse(allocator, content) catch {
        output.err("could not parse .env", .{});
        return null;
    };
}

fn mask(value: []const u8, buf: []u8) []const u8 {
    if (value.len <= 8) return value;
    const n = @min(value.len, buf.len);
    const head = @min(@as(usize, 4), n);
    @memcpy(buf[0..head], value[0..head]);
    for (head..n - 1) |i| buf[i] = '*';
    buf[n - 1] = value[value.len - 1];
    return buf[0..n];
}

fn status(allocator: std.mem.Allocator) void {
    const env = Environment.init(allocator) catch {
        output.err("could not resolve environment", .{});
        return;
    };

    const entries = loadEnv(allocator, &env) orelse return;

    output.info("env file: {s}", .{env.paths.envFile(allocator) catch ""});
    output.info("api keys:", .{});
    var configured: usize = 0;
    for (pi_env.PROVIDERS) |p| {
        if (envfile.find(entries, p.env_var)) |value| {
            var buf: [80]u8 = undefined;
            output.plain("  {s:<24} {s:<22} {s}", .{ p.env_var, p.provider, mask(value, &buf) });
            configured += 1;
        }
    }
    if (configured == 0) output.plain("  (none configured)", .{});

    output.info("defaults:", .{});
    if (envfile.find(entries, pi_env.DEFAULT_PROVIDER_VAR)) |p| {
        output.plain("  provider: {s}", .{p});
    }
    if (envfile.find(entries, pi_env.DEFAULT_MODEL_VAR)) |m| {
        output.plain("  model:    {s}", .{m});
    }
    if (envfile.find(entries, pi_env.DEFAULT_PROVIDER_VAR) == null and
        envfile.find(entries, pi_env.DEFAULT_MODEL_VAR) == null)
    {
        output.plain("  (unset)", .{});
    }

    output.plain("", .{});
    output.plain("Run 'tin env sync' to apply keys and defaults.", .{});
}

fn sync(allocator: std.mem.Allocator) void {
    const env = Environment.init(allocator) catch {
        output.err("could not resolve environment", .{});
        return;
    };

    const entries = loadEnv(allocator, &env) orelse {
        output.err("nothing to sync", .{});
        return;
    };

    const auth_path = env.paths.piAuthFile(allocator) catch {
        output.err("could not resolve pi auth path", .{});
        return;
    };
    const count = pi_env.syncAuth(allocator, auth_path, entries) catch |err| {
        output.err("could not write pi auth: {s}", .{@errorName(err)});
        return;
    };

    const settings_path = env.paths.piSettingsFile(allocator) catch {
        output.err("could not resolve pi settings path", .{});
        return;
    };
    const updated = pi_env.syncSettings(allocator, settings_path, entries) catch false;

    output.success("synced {d} provider key(s) to {s}", .{ count, auth_path });
    if (updated) {
        output.success("defaults written to {s}", .{settings_path});
    }
}

fn setValue(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len < 1) {
        output.err("usage: tin env set KEY=VALUE", .{});
        return;
    }

    const env = Environment.init(allocator) catch {
        output.err("could not resolve environment", .{});
        return;
    };
    const path = env.paths.envFile(allocator) catch {
        output.err("could not resolve .env path", .{});
        return;
    };

    const kv = args[0];
    const eq = std.mem.indexOfScalar(u8, kv, '=') orelse {
        output.err("expected KEY=VALUE, got: {s}", .{kv});
        return;
    };
    const key = kv[0..eq];
    const value = kv[eq + 1 ..];

    var buf = std.ArrayListUnmanaged(u8){};
    if (fs.pathExists(path)) {
        const content = fs.readFileAlloc(allocator, path) catch {
            output.err("could not read .env", .{});
            return;
        };
        buf.appendSlice(allocator, content) catch return;
    }

    const line = std.fmt.allocPrint(allocator, "{s}=\"{s}\"\n", .{ key, value }) catch return;
    buf.appendSlice(allocator, line) catch return;

    const file = std.fs.createFileAbsolute(path, .{ .mode = 0o600, .truncate = true }) catch {
        output.err("could not write .env", .{});
        return;
    };
    defer file.close();
    file.writeAll(buf.items) catch {
        output.err("could not write .env", .{});
        return;
    };

    output.success("set {s} in {s}", .{ key, path });
    output.plain("Run 'tin env sync' to apply.", .{});
}

test "mask hides middle of long values" {
    var buf: [80]u8 = undefined;
    const masked = mask("sk-ant-abcdefghij", &buf);
    try std.testing.expectEqualStrings("sk-a************j", masked);
}
