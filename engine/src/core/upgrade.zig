const std = @import("std");
const process = @import("../lib/process.zig");

pub const default_repo_slug = "tanvirtin/.tin";
pub const default_api_base = "https://api.github.com";
pub const default_installer_url = "https://raw.githubusercontent.com/tanvirtin/.tin/master/install.sh";

pub const State = enum { current, behind, unknown };

pub fn classify(installed: ?[]const u8, latest: ?[]const u8) State {
    const local = installed orelse return .unknown;
    const remote = latest orelse return .unknown;
    return if (std.mem.eql(u8, local, remote)) .current else .behind;
}

pub fn repoSlug(allocator: std.mem.Allocator) []const u8 {
    return std.process.getEnvVarOwned(allocator, "TIN_REPO_SLUG") catch default_repo_slug;
}

pub fn installerUrl(allocator: std.mem.Allocator) []const u8 {
    return std.process.getEnvVarOwned(allocator, "TIN_INSTALLER_URL") catch default_installer_url;
}

pub fn apiBase(allocator: std.mem.Allocator) []const u8 {
    return std.process.getEnvVarOwned(allocator, "TIN_API_BASE_URL") catch default_api_base;
}

pub fn parseTagName(json: []const u8) ?[]const u8 {
    return jsonString(json, "\"tag_name\"");
}

pub fn parseCommitSha(json: []const u8) ?[]const u8 {
    const sha = jsonString(json, "\"sha\"") orelse return null;
    if (sha.len != 40) return null;
    for (sha) |c| {
        if (!std.ascii.isHex(c)) return null;
    }
    return sha;
}

pub fn fetchLatestTag(allocator: std.mem.Allocator) ?[]const u8 {
    const url = std.fmt.allocPrint(allocator, "{s}/repos/{s}/releases/latest", .{ apiBase(allocator), repoSlug(allocator) }) catch return null;
    const body = httpGet(allocator, url) orelse return null;
    return parseTagName(body);
}

pub fn fetchTagRevision(allocator: std.mem.Allocator, tag: []const u8) ?[]const u8 {
    const url = std.fmt.allocPrint(allocator, "{s}/repos/{s}/commits/{s}", .{ apiBase(allocator), repoSlug(allocator), tag }) catch return null;
    const body = httpGet(allocator, url) orelse return null;
    return parseCommitSha(body);
}

fn httpGet(allocator: std.mem.Allocator, url: []const u8) ?[]const u8 {
    const result = process.capture(allocator, &.{
        "curl",
        "-fsSL",
        "--max-time",
        "15",
        "-H",
        "Accept: application/vnd.github+json",
        "-H",
        "User-Agent: tin",
        url,
    }) catch return null;
    defer result.deinit(allocator);
    if (result.code != 0) return null;
    return allocator.dupe(u8, result.stdout) catch null;
}

fn jsonString(json: []const u8, key: []const u8) ?[]const u8 {
    const key_at = std.mem.indexOf(u8, json, key) orelse return null;
    var i = key_at + key.len;
    while (i < json.len and json[i] != ':') : (i += 1) {}
    if (i >= json.len) return null;
    i += 1;
    while (i < json.len and std.ascii.isWhitespace(json[i])) : (i += 1) {}
    if (i >= json.len or json[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < json.len and json[i] != '"') : (i += 1) {}
    if (i >= json.len) return null;
    return json[start..i];
}

test "classify compares revisions and reports unknown when either side is missing" {
    try std.testing.expectEqual(State.current, classify("abc", "abc"));
    try std.testing.expectEqual(State.behind, classify("abc", "def"));
    try std.testing.expectEqual(State.unknown, classify(null, "def"));
    try std.testing.expectEqual(State.unknown, classify("abc", null));
}

test "parseTagName extracts the latest release tag" {
    const json = "{\"url\":\"https://api.github.com/repos/x/y/releases/1\",\"tag_name\":\"v0.1.2\",\"name\":\"Release\"}";
    try std.testing.expectEqualStrings("v0.1.2", parseTagName(json).?);
}

test "parseTagName returns null when the field is absent" {
    try std.testing.expect(parseTagName("{\"name\":\"Release\"}") == null);
}

test "parseCommitSha extracts the leading full commit hash" {
    const json = "{\"sha\":\"0123456789abcdef0123456789abcdef01234567\",\"node_id\":\"x\",\"parents\":[{\"sha\":\"ffffffffffffffffffffffffffffffffffffffff\"}]}";
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef01234567", parseCommitSha(json).?);
}

test "parseCommitSha rejects a short or non-hex sha" {
    try std.testing.expect(parseCommitSha("{\"sha\":\"abc\"}") == null);
    try std.testing.expect(parseCommitSha("{\"sha\":\"zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\"}") == null);
}
