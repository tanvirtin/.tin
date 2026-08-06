const std = @import("std");
const fs = @import("../../lib/fs.zig");
const envfile = @import("../../lib/envfile.zig");

pub const Provider = struct {
    env_var: []const u8,
    provider: []const u8,
};

/// env var -> auth.json provider key (mirrors pi's env-api-keys.ts)
pub const PROVIDERS = [_]Provider{
    .{ .env_var = "ANTHROPIC_API_KEY", .provider = "anthropic" },
    .{ .env_var = "OPENAI_API_KEY", .provider = "openai" },
    .{ .env_var = "ANT_LING_API_KEY", .provider = "ant-ling" },
    .{ .env_var = "QWEN_TOKEN_PLAN_API_KEY", .provider = "qwen-token-plan" },
    .{ .env_var = "QWEN_TOKEN_PLAN_CN_API_KEY", .provider = "qwen-token-plan-cn" },
    .{ .env_var = "AZURE_OPENAI_API_KEY", .provider = "azure-openai-responses" },
    .{ .env_var = "NVIDIA_API_KEY", .provider = "nvidia" },
    .{ .env_var = "DEEPSEEK_API_KEY", .provider = "deepseek" },
    .{ .env_var = "GROQ_API_KEY", .provider = "groq" },
    .{ .env_var = "CEREBRAS_API_KEY", .provider = "cerebras" },
    .{ .env_var = "XAI_API_KEY", .provider = "xai" },
    .{ .env_var = "RADIUS_API_KEY", .provider = "radius" },
    .{ .env_var = "OPENROUTER_API_KEY", .provider = "openrouter" },
    .{ .env_var = "AI_GATEWAY_API_KEY", .provider = "vercel-ai-gateway" },
    .{ .env_var = "ZAI_API_KEY", .provider = "zai" },
};

pub const DEFAULT_PROVIDER_VAR = "DEFAULT_PROVIDER";
pub const DEFAULT_MODEL_VAR = "DEFAULT_MODEL";

pub fn providerForEnvVar(env_var: []const u8) ?[]const u8 {
    for (PROVIDERS) |p| {
        if (std.mem.eql(u8, p.env_var, env_var)) return p.provider;
    }
    return null;
}

/// Reads ~/.pi/agent/auth.json, merges in api_key entries for every recognized
/// *_API_KEY present in the env file, and writes it back (0600). Existing
/// entries (subscriptions, oauth) are preserved.
pub fn syncAuth(
    allocator: std.mem.Allocator,
    auth_path: []const u8,
    entries: []const envfile.Entry,
) !usize {
    var root: std.json.Value = .{ .object = std.json.ObjectMap.init(allocator) };

    if (fs.pathExists(auth_path)) {
        if (fs.readFileAlloc(allocator, auth_path)) |content| {
            if (std.json.parseFromSliceLeaky(std.json.Value, allocator, content, .{})) |value| {
                if (value == .object) {
                    root = value;
                }
            } else |_| {}
        } else |_| {}
    }

    var count: usize = 0;
    for (entries) |e| {
        if (providerForEnvVar(e.key)) |provider| {
            var entry = std.json.ObjectMap.init(allocator);
            try entry.put("type", .{ .string = "api_key" });
            try entry.put("key", .{ .string = e.value });
            try root.object.put(provider, .{ .object = entry });
            count += 1;
        }
    }

    const json = std.json.Stringify.valueAlloc(allocator, root, .{ .whitespace = .indent_2 }) catch return 0;

    const file = try std.fs.createFileAbsolute(auth_path, .{ .mode = 0o600, .truncate = true });
    defer file.close();
    try file.writeAll(json);
    return count;
}

pub const SyncResult = struct {
    providers: usize,
    defaults: bool,
};

/// Writes defaultProvider/defaultModel into the pi settings.json.
pub fn syncSettings(
    allocator: std.mem.Allocator,
    settings_path: []const u8,
    entries: []const envfile.Entry,
) !bool {
    const provider = envfile.find(entries, DEFAULT_PROVIDER_VAR);
    const model = envfile.find(entries, DEFAULT_MODEL_VAR);
    if (provider == null and model == null) return false;

    const content = fs.readFileAlloc(allocator, settings_path) catch return false;
    var value = std.json.parseFromSliceLeaky(std.json.Value, allocator, content, .{}) catch return false;

    if (value != .object) return false;
    if (provider) |p| {
        try value.object.put("defaultProvider", .{ .string = p });
    }
    if (model) |m| {
        try value.object.put("defaultModel", .{ .string = m });
    }

    const json = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
    defer allocator.free(json);

    const file = try std.fs.createFileAbsolute(settings_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(json);
    return true;
}

test "providerForEnvVar maps known keys" {
    try std.testing.expectEqualStrings("vercel-ai-gateway", providerForEnvVar("AI_GATEWAY_API_KEY").?);
    try std.testing.expectEqualStrings("anthropic", providerForEnvVar("ANTHROPIC_API_KEY").?);
    try std.testing.expectEqualStrings("openrouter", providerForEnvVar("OPENROUTER_API_KEY").?);
    try std.testing.expect(providerForEnvVar("NOT_A_KEY") == null);
}

test "syncAuth writes merged auth file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const real = tmp.dir.realpathAlloc(allocator, ".") catch unreachable;
    const path = try std.fs.path.join(allocator, &.{ real, "auth.json" });

    const entries = [_]envfile.Entry{
        .{ .key = "AI_GATEWAY_API_KEY", .value = "vck_test" },
        .{ .key = "OPENAI_API_KEY", .value = "sk-test" },
        .{ .key = "UNKNOWN_KEY", .value = "x" },
    };
    const count = try syncAuth(allocator, path, &entries);
    try std.testing.expectEqual(@as(usize, 2), count);

    const content = try fs.readFileAlloc(allocator, path);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, content, .{});
    const obj = parsed.object;
    try std.testing.expect(obj.get("vercel-ai-gateway") != null);
    try std.testing.expect(obj.get("openai") != null);
    try std.testing.expect(obj.get("UNKNOWN_KEY") == null);
    try std.testing.expectEqualStrings("vck_test", obj.get("vercel-ai-gateway").?.object.get("key").?.string);
}
