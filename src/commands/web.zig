const std = @import("std");
const output = @import("../lib/output.zig");
const process = @import("../lib/process.zig");
const fs = @import("../lib/fs.zig");
const envfile = @import("../lib/envfile.zig");

pub const meta = .{
    .name = "web",
    .description = "Web search, extraction, and raw fetch (tin web search|extract|fetch)",
};

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len == 0) {
        output.err("usage: tin web <search|extract|fetch>", .{});
        return;
    }
    const sub = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, sub, "search")) {
        search(allocator, rest);
    } else if (std.mem.eql(u8, sub, "extract")) {
        extract(allocator, rest);
    } else if (std.mem.eql(u8, sub, "fetch")) {
        fetch(allocator, rest);
    } else {
        output.err("usage: tin web <search|extract|fetch>", .{});
    }
}

/// Read a key from ~/.tin/.env. Shared by search and extract.
fn readEnvKey(allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    const env_path = std.fmt.allocPrint(allocator, "{s}/.tin/.env", .{home}) catch return null;
    defer allocator.free(env_path);
    const content = fs.readFileAlloc(allocator, env_path) catch return null;
    defer allocator.free(content);
    const entries = envfile.parse(allocator, content) catch return null;
    return envfile.find(entries, key);
}

fn search(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len == 0) {
        output.err("usage: tin web search <query> [--max <n>]", .{});
        return;
    }
    const query = args[0];

    var max_results: u8 = 10;
    if (args.len >= 3 and std.mem.eql(u8, args[1], "--max")) {
        if (std.fmt.parseInt(u8, args[2], 10)) |n| {
            if (n > 0 and n <= 20) max_results = n;
        } else |_| {}
    }

    const api_key = readEnvKey(allocator, "TAVILY_API_KEY") orelse {
        output.err("TAVILY_API_KEY not set in ~/.tin/.env", .{});
        return;
    };

    const body = std.fmt.allocPrint(allocator,
        \\{{"api_key":"{s}","query":"{s}","search_depth":"advanced","include_answer":true,"max_results":{d}}}
    , .{ api_key, query, max_results }) catch return;
    defer allocator.free(body);

    const cmd = std.fmt.allocPrint(allocator,
        "curl -fsSL --max-time 30 -H 'Content-Type: application/json' -d '{s}' https://api.tavily.com/search",
        .{body}) catch return;
    defer allocator.free(cmd);

    const res = process.captureExit(allocator, &.{ "sh", "-c", cmd }) catch {
        output.err("search request failed (network error)", .{});
        return;
    };

    if (res.code != 0) {
        output.err("search returned status {d}", .{res.code});
        return;
    }

    output.plain("{s}", .{res.stdout});
}

fn extract(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len == 0) {
        output.err("usage: tin web extract <url>", .{});
        return;
    }
    const url = args[0];

    const api_key = readEnvKey(allocator, "TAVILY_API_KEY") orelse {
        output.err("TAVILY_API_KEY not set in ~/.tin/.env", .{});
        return;
    };

    const body = std.fmt.allocPrint(allocator,
        \\{{"api_key":"{s}","urls":["{s}"],"include_images":false}}
    , .{ api_key, url }) catch return;
    defer allocator.free(body);

    const cmd = std.fmt.allocPrint(allocator,
        "curl -fsSL --max-time 45 -H 'Content-Type: application/json' -d '{s}' https://api.tavily.com/extract",
        .{body}) catch return;
    defer allocator.free(cmd);

    const res = process.captureExit(allocator, &.{ "sh", "-c", cmd }) catch {
        output.err("extract request failed (network error)", .{});
        return;
    };

    if (res.code != 0) {
        output.err("extract returned status {d}", .{res.code});
        return;
    }

    output.plain("{s}", .{res.stdout});
}

/// Raw HTTP GET — no API key, no processing. For URLs Tavily's extract
/// endpoint can't reach (raw.githubusercontent.com, plain-text, APIs).
fn fetch(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len == 0) {
        output.err("usage: tin web fetch <url>", .{});
        return;
    }
    const url = args[0];

    const cmd = std.fmt.allocPrint(allocator,
        "curl -fsSL --max-time 30 -A 'Mozilla/5.0' '{s}'",
        .{url}) catch return;
    defer allocator.free(cmd);

    const res = process.captureExit(allocator, &.{ "sh", "-c", cmd }) catch {
        output.err("fetch request failed (network error)", .{});
        return;
    };

    if (res.code != 0) {
        output.err("fetch returned status {d}", .{res.code});
        return;
    }

    output.plain("{s}", .{res.stdout});
}
