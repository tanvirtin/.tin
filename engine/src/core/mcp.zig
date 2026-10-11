const std = @import("std");
const yaml = @import("yaml");


pub const ServerType = enum { stdio, http };
pub const Format = enum { json, toml };
pub const Transport = enum { explicit, inferred };
pub const CommandStyle = enum { scalar, object };
pub const SecretStyle = enum { env_ref, var_ref, input_ref, env_var_name };

pub const Error = error{
    MissingType,
    InvalidType,
    MissingCommand,
    MissingUrl,
    MissingContainer,
    MissingFormat,
    InvalidFormat,
    MissingTransport,
    InvalidTransport,
    MissingCommandStyle,
    InvalidCommandStyle,
    MissingSecretStyle,
    InvalidSecretStyle,
};

pub const FieldValue = union(enum) {
    string: []const u8,
    strings: []const []const u8,
    object: []const Field,
};

pub const Field = struct {
    key: []const u8,
    value: FieldValue,
};

pub const Secret = struct {
    style: SecretStyle,
    key: ?[]const u8 = null,
    input_key: ?[]const u8 = null,
    input_id: ?[]const u8 = null,
};

pub const Server = struct {
    id: []const u8 = "",
    type: ServerType,
    command: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    env: []const Field = &.{},
    url: ?[]const u8 = null,
    headers: []const Field = &.{},
    secrets: []const []const u8 = &.{},
    description: ?[]const u8 = null,
    x: []const Field = &.{},

    pub fn validate(self: *const Server) Error!void {
        switch (self.type) {
            .stdio => if (self.command == null) return Error.MissingCommand,
            .http => if (self.url == null) return Error.MissingUrl,
        }
    }
};

pub const Dialect = struct {
    id: []const u8 = "",
    container: []const u8,
    format: Format,
    transport: Transport,
    command_style: CommandStyle,
    command_path_key: ?[]const u8 = null,
    command_args_key: ?[]const u8 = null,
    inject: []const Field = &.{},
    secret: ?Secret = null,
    description: ?[]const u8 = null,
};

pub const Entry = struct {
    name: []const u8,
    fields: []const Field,
    needs_input: bool = false,
};


fn optString(val: yaml.Value, key: []const u8) ?[]const u8 {
    const v = val.getMapping(key) orelse return null;
    return v.getString();
}

fn optStringDup(allocator: std.mem.Allocator, val: yaml.Value, key: []const u8) !?[]const u8 {
    const s = optString(val, key) orelse return null;
    return try allocator.dupe(u8, s);
}

fn stringSeq(allocator: std.mem.Allocator, val: yaml.Value, key: []const u8) ![]const []const u8 {
    const v = val.getMapping(key) orelse return &.{};
    const seq = v.getSequence() orelse return &.{};
    var list: std.ArrayListUnmanaged([]const u8) = .{};
    for (seq) |item| {
        const s = item.getString() orelse continue;
        try list.append(allocator, try allocator.dupe(u8, s));
    }
    return list.toOwnedSlice(allocator);
}

fn valueToFieldValue(allocator: std.mem.Allocator, val: yaml.Value) std.mem.Allocator.Error!?FieldValue {
    if (val.getString()) |s| return FieldValue{ .string = try allocator.dupe(u8, s) };

    if (val.getSequence()) |seq| {
        var items: std.ArrayListUnmanaged([]const u8) = .{};
        for (seq) |item| {
            const s = item.getString() orelse continue;
            try items.append(allocator, try allocator.dupe(u8, s));
        }
        return FieldValue{ .strings = try items.toOwnedSlice(allocator) };
    }

    const node = val.tree.nodes.items[val.idx];
    if (node.tag == .mapping) return FieldValue{ .object = try mappingFields(allocator, val) };
    return null;
}

fn mappingFields(allocator: std.mem.Allocator, val: yaml.Value) std.mem.Allocator.Error![]const Field {
    const node = val.tree.nodes.items[val.idx];
    if (node.tag != .mapping) return &.{};

    var list: std.ArrayListUnmanaged(Field) = .{};
    var child = node.first_child;
    while (child != 0) {
        const key_node = val.tree.nodes.items[child];
        const key = key_node.computed_value orelse val.tree.source[key_node.start..key_node.end];
        const val_idx = key_node.next_sibling;
        if (val_idx == 0) break;

        const child_val = yaml.Value{ .tree = val.tree, .idx = val_idx, .arena = val.arena };
        if (try valueToFieldValue(allocator, child_val)) |fv| {
            try list.append(allocator, .{ .key = try allocator.dupe(u8, key), .value = fv });
        }
        child = val.tree.nodes.items[val_idx].next_sibling;
    }
    return list.toOwnedSlice(allocator);
}

pub fn parseServer(allocator: std.mem.Allocator, val: yaml.Value) !Server {
    const type_s = optString(val, "type") orelse return Error.MissingType;
    const server_type = std.meta.stringToEnum(ServerType, type_s) orelse return Error.InvalidType;

    var server = Server{ .type = server_type };
    server.command = try optStringDup(allocator, val, "command");
    server.args = try stringSeq(allocator, val, "args");
    server.cwd = try optStringDup(allocator, val, "cwd");
    if (val.getMapping("env")) |env| server.env = try mappingFields(allocator, env);
    server.url = try optStringDup(allocator, val, "url");
    if (val.getMapping("headers")) |headers| server.headers = try mappingFields(allocator, headers);
    server.secrets = try stringSeq(allocator, val, "secrets");
    server.description = try optStringDup(allocator, val, "description");
    if (val.getMapping("x")) |x| server.x = try mappingFields(allocator, x);

    try server.validate();
    return server;
}

fn parseSecret(allocator: std.mem.Allocator, val: yaml.Value) !Secret {
    const style_s = optString(val, "style") orelse return Error.MissingSecretStyle;
    const style = std.meta.stringToEnum(SecretStyle, style_s) orelse return Error.InvalidSecretStyle;
    return .{
        .style = style,
        .key = try optStringDup(allocator, val, "key"),
        .input_key = try optStringDup(allocator, val, "input_key"),
        .input_id = try optStringDup(allocator, val, "input_id"),
    };
}

pub fn parseDialect(allocator: std.mem.Allocator, val: yaml.Value) !Dialect {
    var dialect = Dialect{
        .container = (try optStringDup(allocator, val, "container")) orelse return Error.MissingContainer,
        .format = undefined,
        .transport = undefined,
        .command_style = undefined,
    };

    const format_s = optString(val, "format") orelse return Error.MissingFormat;
    dialect.format = std.meta.stringToEnum(Format, format_s) orelse return Error.InvalidFormat;

    const transport_s = optString(val, "transport") orelse return Error.MissingTransport;
    dialect.transport = std.meta.stringToEnum(Transport, transport_s) orelse return Error.InvalidTransport;

    const command_s = optString(val, "command_style") orelse return Error.MissingCommandStyle;
    dialect.command_style = std.meta.stringToEnum(CommandStyle, command_s) orelse return Error.InvalidCommandStyle;

    dialect.command_path_key = try optStringDup(allocator, val, "command_path_key");
    dialect.command_args_key = try optStringDup(allocator, val, "command_args_key");
    if (val.getMapping("inject")) |inject| dialect.inject = try mappingFields(allocator, inject);
    dialect.description = try optStringDup(allocator, val, "description");
    if (val.getMapping("secret")) |secret| dialect.secret = try parseSecret(allocator, secret);

    return dialect;
}


fn lookupString(fields: []const Field, path: []const u8) ?[]const u8 {
    const dot = std.mem.indexOfScalar(u8, path, '.');
    const head = if (dot) |d| path[0..d] else path;
    const rest = if (dot) |d| path[d + 1 ..] else null;

    for (fields) |field| {
        if (!std.mem.eql(u8, field.key, head)) continue;
        if (rest) |tail| switch (field.value) {
            .object => |nested| return lookupString(nested, tail),
            else => return null,
        };
        return switch (field.value) {
            .string => |s| s,
            else => null,
        };
    }
    return null;
}

fn replaceString(fields: []Field, path: []const u8, replacement: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, path, '.');
    const head = if (dot) |d| path[0..d] else path;
    const rest = if (dot) |d| path[d + 1 ..] else null;

    for (fields) |*field| {
        if (!std.mem.eql(u8, field.key, head)) continue;
        if (rest) |tail| switch (field.value) {
            .object => |nested| return replaceString(@constCast(nested), tail, replacement),
            else => return false,
        };
        switch (field.value) {
            .string => {
                field.value = .{ .string = replacement };
                return true;
            },
            else => return false,
        }
    }
    return false;
}

fn applySecret(
    allocator: std.mem.Allocator,
    fields: *std.ArrayListUnmanaged(Field),
    server_type: ServerType,
    dialect: Dialect,
    path: []const u8,
) !void {
    const secret = dialect.secret orelse return;
    const name = lookupString(fields.items, path) orelse return;

    switch (secret.style) {
        .env_ref => {
            const repl = try std.fmt.allocPrint(allocator, "${{env:{s}}}", .{name});
            _ = replaceString(fields.items, path, repl);
        },
        .var_ref => {
            const repl = try std.fmt.allocPrint(allocator, "${{{s}}}", .{name});
            _ = replaceString(fields.items, path, repl);
        },
        .input_ref => {
            const input_id = secret.input_id orelse "tin";
            const repl = try std.fmt.allocPrint(allocator, "${{input:{s}}}", .{input_id});
            _ = replaceString(fields.items, path, repl);
        },
        .env_var_name => {
            if (server_type != .http) return;
            const key = secret.key orelse "token";
            const remaining = try removePath(allocator, fields.items, path);
            fields.items = remaining;
            fields.capacity = remaining.len;
            try fields.append(allocator, .{ .key = key, .value = .{ .string = name } });
        },
    }
}

fn removePath(allocator: std.mem.Allocator, fields: []Field, path: []const u8) std.mem.Allocator.Error![]Field {
    const dot = std.mem.indexOfScalar(u8, path, '.');
    const head = if (dot) |d| path[0..d] else path;
    const rest = if (dot) |d| path[d + 1 ..] else null;

    var out: std.ArrayListUnmanaged(Field) = .{};
    for (fields) |field| {
        if (rest) |tail| {
            if (std.mem.eql(u8, field.key, head)) switch (field.value) {
                .object => |nested| {
                    try out.append(allocator, .{
                        .key = field.key,
                        .value = .{ .object = try removePath(allocator, @constCast(nested), tail) },
                    });
                    continue;
                },
                else => {},
            };
        } else if (std.mem.eql(u8, field.key, head)) {
            continue;
        }
        try out.append(allocator, field);
    }
    return out.toOwnedSlice(allocator);
}

fn cloneFields(allocator: std.mem.Allocator, fields: []const Field) std.mem.Allocator.Error![]Field {
    var list: std.ArrayListUnmanaged(Field) = .{};
    for (fields) |field| try list.append(allocator, try cloneField(allocator, field));
    return list.toOwnedSlice(allocator);
}

fn cloneField(allocator: std.mem.Allocator, field: Field) std.mem.Allocator.Error!Field {
    return .{ .key = try allocator.dupe(u8, field.key), .value = try cloneFieldValue(allocator, field.value) };
}

fn cloneFieldValue(allocator: std.mem.Allocator, value: FieldValue) std.mem.Allocator.Error!FieldValue {
    return switch (value) {
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .strings => |items| blk: {
            var list: std.ArrayListUnmanaged([]const u8) = .{};
            for (items) |item| try list.append(allocator, try allocator.dupe(u8, item));
            break :blk .{ .strings = try list.toOwnedSlice(allocator) };
        },
        .object => |nested| .{ .object = try cloneFields(allocator, nested) },
    };
}

pub fn buildEntry(allocator: std.mem.Allocator, server: Server, dialect: Dialect) !Entry {
    var fields: std.ArrayListUnmanaged(Field) = .{};

    if (dialect.transport == .explicit) {
        try fields.append(allocator, .{ .key = "type", .value = .{ .string = @tagName(server.type) } });
    }

    switch (server.type) {
        .stdio => {
            const command = server.command orelse return Error.MissingCommand;
            if (dialect.command_style == .object) {
                var nested: std.ArrayListUnmanaged(Field) = .{};
                try nested.append(allocator, .{
                    .key = dialect.command_path_key orelse "path",
                    .value = .{ .string = command },
                });
                if (server.args.len > 0) {
                    try nested.append(allocator, .{
                        .key = dialect.command_args_key orelse "args",
                        .value = .{ .strings = server.args },
                    });
                }
                try fields.append(allocator, .{
                    .key = "command",
                    .value = .{ .object = try nested.toOwnedSlice(allocator) },
                });
            } else {
                try fields.append(allocator, .{ .key = "command", .value = .{ .string = command } });
                if (server.args.len > 0) {
                    try fields.append(allocator, .{ .key = "args", .value = .{ .strings = server.args } });
                }
            }
            if (server.cwd) |cwd| {
                try fields.append(allocator, .{ .key = "cwd", .value = .{ .string = cwd } });
            }
            if (server.env.len > 0) {
                try fields.append(allocator, .{ .key = "env", .value = .{ .object = try cloneFields(allocator, server.env) } });
            }
        },
        .http => {
            const url = server.url orelse return Error.MissingUrl;
            try fields.append(allocator, .{ .key = "url", .value = .{ .string = url } });
            if (server.headers.len > 0) {
                try fields.append(allocator, .{ .key = "headers", .value = .{ .object = try cloneFields(allocator, server.headers) } });
            }
        },
    }

    for (dialect.inject) |field| try fields.append(allocator, try cloneField(allocator, field));
    for (server.x) |field| try fields.append(allocator, try cloneField(allocator, field));

    for (server.secrets) |path| try applySecret(allocator, &fields, server.type, dialect, path);

    return .{
        .name = server.id,
        .fields = try fields.toOwnedSlice(allocator),
        .needs_input = dialect.secret != null and dialect.secret.?.style == .input_ref and server.secrets.len > 0,
    };
}


fn fieldValueToJson(allocator: std.mem.Allocator, value: FieldValue) !std.json.Value {
    switch (value) {
        .string => |s| return .{ .string = s },
        .strings => |items| {
            var array = std.json.Array.init(allocator);
            for (items) |item| try array.append(.{ .string = item });
            return .{ .array = array };
        },
        .object => |fields| {
            var object = std.json.ObjectMap.init(allocator);
            for (fields) |field| {
                try object.put(field.key, try fieldValueToJson(allocator, field.value));
            }
            return .{ .object = object };
        },
    }
}

pub fn mergeJson(
    allocator: std.mem.Allocator,
    existing: ?[]const u8,
    dialect: Dialect,
    entries: []const Entry,
) ![]const u8 {
    var root: std.json.Value = .{ .object = std.json.ObjectMap.init(allocator) };
    if (existing) |text| {
        if (std.mem.trim(u8, text, " \t\r\n").len > 0) {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch
                return error.InvalidExistingConfig;
            switch (parsed.value) {
                .object => root = parsed.value,
                else => return error.InvalidExistingConfig,
            }
        }
    }

    if (root.object.getPtr(dialect.container)) |container| {
        switch (container.*) {
            .object => {},
            else => container.* = .{ .object = std.json.ObjectMap.init(allocator) },
        }
    } else {
        try root.object.put(dialect.container, .{ .object = std.json.ObjectMap.init(allocator) });
    }
    const container = root.object.getPtr(dialect.container).?;

    for (entries) |entry| {
        var object = std.json.ObjectMap.init(allocator);
        for (entry.fields) |field| {
            try object.put(field.key, try fieldValueToJson(allocator, field.value));
        }
        try container.object.put(entry.name, .{ .object = object });
    }

    var needs_input = false;
    for (entries) |entry| needs_input = needs_input or entry.needs_input;
    if (needs_input) {
        if (dialect.secret) |secret| {
            const input_key = secret.input_key orelse "inputs";
            const input_id = secret.input_id orelse "tin";
            if (root.object.getPtr(input_key) == null) {
                var spec = std.json.ObjectMap.init(allocator);
                try spec.put("type", .{ .string = "promptString" });
                try spec.put("id", .{ .string = input_id });
                try spec.put("description", .{ .string = "tin secret" });
                try spec.put("password", .{ .bool = true });
                var array = std.json.Array.init(allocator);
                try array.append(.{ .object = spec });
                try root.object.put(input_key, .{ .array = array });
            }
        }
    }

    var out = std.io.Writer.Allocating.init(allocator);
    try std.json.Stringify.value(root, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeAll("\n");
    return out.toOwnedSlice();
}


fn tomlString(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    try out.append(allocator, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        else => try out.append(allocator, c),
    };
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

fn isBareKey(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_', '-' => {},
        else => return false,
    };
    return true;
}

fn tomlBareKey(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (isBareKey(s)) return allocator.dupe(u8, s);
    return std.fmt.allocPrint(allocator, "\"{s}\"", .{s});
}

fn renderTomlFields(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    header: []const u8,
    fields: []const Field,
) !void {
    var subtables: std.ArrayListUnmanaged(Field) = .{};
    defer subtables.deinit(allocator);

    try writer.print("[{s}]\n", .{header});
    for (fields) |field| {
        switch (field.value) {
            .string => |s| try writer.print("{s} = {s}\n", .{ field.key, try tomlString(allocator, s) }),
            .strings => |items| {
                try writer.print("{s} = [", .{field.key});
                for (items, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.writeAll(try tomlString(allocator, item));
                }
                try writer.writeAll("]\n");
            },
            .object => try subtables.append(allocator, field),
        }
    }

    for (subtables.items) |subtable| {
        if (subtable.value.object.len == 0) continue;
        try writer.writeAll("\n");
        const sub_header = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header, subtable.key });
        try renderTomlFields(allocator, writer, sub_header, subtable.value.object);
    }
}

fn renderTomlEntry(allocator: std.mem.Allocator, writer: *std.Io.Writer, dialect: Dialect, entry: Entry) !void {
    const name = try tomlBareKey(allocator, entry.name);
    const header = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ dialect.container, name });
    try renderTomlFields(allocator, writer, header, entry.fields);
}

fn stripDots(segment: []const u8) []const u8 {
    if (segment.len >= 2 and segment[0] == '"' and segment[segment.len - 1] == '"') {
        return segment[1 .. segment.len - 1];
    }
    return segment;
}

fn isManagedTomlHeader(header: []const u8, dialect: Dialect, entries: []const Entry) bool {
    if (header.len < 2 or header[0] != '[') return false;
    const end = std.mem.indexOfScalar(u8, header, ']') orelse return false;
    const inner = std.mem.trim(u8, header[1..end], " \t");

    var it = std.mem.splitScalar(u8, inner, '.');
    const first = it.next() orelse return false;
    if (!std.mem.eql(u8, stripDots(first), dialect.container)) return false;
    const second = it.next() orelse return false;
    const name = stripDots(second);
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return true;
    }
    return false;
}

pub fn mergeToml(
    allocator: std.mem.Allocator,
    existing: ?[]const u8,
    dialect: Dialect,
    entries: []const Entry,
) ![]const u8 {
    var kept = std.io.Writer.Allocating.init(allocator);
    if (existing) |text| {
        var skipping = false;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            const is_header = trimmed.len > 0 and trimmed[0] == '[';
            if (is_header) skipping = false;
            if (is_header and isManagedTomlHeader(trimmed, dialect, entries)) {
                skipping = true;
                continue;
            }
            if (skipping) continue;
            try kept.writer.writeAll(line);
            try kept.writer.writeAll("\n");
        }
    }
    const kept_text = std.mem.trimRight(u8, kept.written(), "\n");

    var rendered = std.io.Writer.Allocating.init(allocator);
    for (entries, 0..) |entry, i| {
        if (i > 0) try rendered.writer.writeAll("\n\n");
        try renderTomlEntry(allocator, &rendered.writer, dialect, entry);
    }
    const rendered_text = std.mem.trimRight(u8, rendered.written(), "\n");

    var out = std.io.Writer.Allocating.init(allocator);
    if (kept_text.len > 0) {
        try out.writer.writeAll(kept_text);
        if (rendered_text.len > 0) try out.writer.writeAll("\n\n");
    }
    if (rendered_text.len > 0) try out.writer.writeAll(rendered_text);
    try out.writer.writeAll("\n");
    return out.toOwnedSlice();
}

pub fn merge(
    allocator: std.mem.Allocator,
    existing: ?[]const u8,
    dialect: Dialect,
    entries: []const Entry,
) ![]const u8 {
    return switch (dialect.format) {
        .json => mergeJson(allocator, existing, dialect, entries),
        .toml => mergeToml(allocator, existing, dialect, entries),
    };
}

pub fn renderPreview(allocator: std.mem.Allocator, dialect: Dialect, entries: []const Entry) ![]const u8 {
    switch (dialect.format) {
        .json => {
            var container = std.json.ObjectMap.init(allocator);
            for (entries) |entry| {
                var object = std.json.ObjectMap.init(allocator);
                for (entry.fields) |field| {
                    try object.put(field.key, try fieldValueToJson(allocator, field.value));
                }
                try container.put(entry.name, .{ .object = object });
            }
            var root = std.json.ObjectMap.init(allocator);
            try root.put(dialect.container, .{ .object = container });
            var out = std.io.Writer.Allocating.init(allocator);
            try std.json.Stringify.value(std.json.Value{ .object = root }, .{ .whitespace = .indent_2 }, &out.writer);
            return out.toOwnedSlice();
        },
        .toml => return mergeToml(allocator, null, dialect, entries),
    }
}


fn parseOne(allocator: std.mem.Allocator, text: []const u8) !yaml.DocNode {
    return yaml.parse(allocator, text);
}

test "parseServer decodes an http server" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try parseOne(a,
        \\type: http
        \\url: https://mcp.example.com/mcp
        \\headers:
        \\  Authorization: TOKEN_VAR
        \\secrets:
        \\  - headers.Authorization
    );
    const server = try parseServer(a, doc.value);
    try std.testing.expectEqual(ServerType.http, server.type);
    try std.testing.expectEqualStrings("https://mcp.example.com/mcp", server.url.?);
    try std.testing.expectEqual(@as(usize, 1), server.headers.len);
    try std.testing.expectEqualStrings("Authorization", server.headers[0].key);
    try std.testing.expectEqual(@as(usize, 1), server.secrets.len);
}

test "parseServer decodes a stdio server" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try parseOne(a,
        \\type: stdio
        \\command: uvx
        \\args:
        \\  - mem0-mcp
        \\env:
        \\  MEM0_API_KEY: KEY_VAR
    );
    const server = try parseServer(a, doc.value);
    try std.testing.expectEqual(ServerType.stdio, server.type);
    try std.testing.expectEqualStrings("uvx", server.command.?);
    try std.testing.expectEqual(@as(usize, 1), server.args.len);
    try std.testing.expectEqual(@as(usize, 1), server.env.len);
}

test "parseServer rejects missing command for stdio" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try parseOne(a, "type: stdio\nargs:\n  - x");
    try std.testing.expectError(Error.MissingCommand, parseServer(a, doc.value));
}

test "parseDialect decodes zed-style object command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try parseOne(a,
        \\container: context_servers
        \\format: json
        \\transport: inferred
        \\command_style: object
        \\command_path_key: path
        \\command_args_key: args
        \\inject:
        \\  source: custom
        \\  settings: {}
    );
    const dialect = try parseDialect(a, doc.value);
    try std.testing.expectEqualStrings("context_servers", dialect.container);
    try std.testing.expectEqual(CommandStyle.object, dialect.command_style);
    try std.testing.expectEqualStrings("path", dialect.command_path_key.?);
    try std.testing.expectEqual(@as(usize, 2), dialect.inject.len);
    try std.testing.expectEqualStrings("custom", dialect.inject[0].value.string);
}

test "buildEntry shapes a stdio command as an object when the dialect says so" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const server = Server{ .id = "x", .type = .stdio, .command = "/bin/x", .args = &.{"serve"} };
    const dialect = Dialect{
        .container = "context_servers",
        .format = .json,
        .transport = .inferred,
        .command_style = .object,
        .command_path_key = "path",
        .command_args_key = "args",
        .inject = &.{.{ .key = "source", .value = .{ .string = "custom" } }},
    };
    const entry = try buildEntry(a, server, dialect);
    try std.testing.expectEqual(@as(usize, 2), entry.fields.len);
    try std.testing.expectEqualStrings("command", entry.fields[0].key);
    try std.testing.expectEqualStrings("path", entry.fields[0].value.object[0].key);
    try std.testing.expectEqualStrings("/bin/x", entry.fields[0].value.object[0].value.string);
    try std.testing.expectEqualStrings("source", entry.fields[1].key);
}

test "buildEntry tags transport when explicit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const server = Server{ .id = "x", .type = .http, .url = "https://h/mcp" };
    const dialect = Dialect{
        .container = "mcpServers",
        .format = .json,
        .transport = .explicit,
        .command_style = .scalar,
    };
    const entry = try buildEntry(a, server, dialect);
    try std.testing.expectEqualStrings("type", entry.fields[0].key);
    try std.testing.expectEqualStrings("http", entry.fields[0].value.string);
    try std.testing.expectEqualStrings("url", entry.fields[1].key);
}

test "applySecret rewrites an env_ref reference inline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const server = Server{
        .id = "x",
        .type = .http,
        .url = "https://h/mcp",
        .headers = &.{.{ .key = "Authorization", .value = .{ .string = "MEM0_API_KEY" } }},
        .secrets = &.{"headers.Authorization"},
    };
    const dialect = Dialect{
        .container = "mcpServers",
        .format = .json,
        .transport = .inferred,
        .command_style = .scalar,
        .secret = .{ .style = .env_ref },
    };
    const entry = try buildEntry(a, server, dialect);
    try std.testing.expectEqualStrings("${env:MEM0_API_KEY}", entry.fields[1].value.object[0].value.string);
}

test "applySecret hoists an env_var_name into the dialect key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const server = Server{
        .id = "x",
        .type = .http,
        .url = "https://h/mcp",
        .headers = &.{.{ .key = "Authorization", .value = .{ .string = "MEM0_API_KEY" } }},
        .secrets = &.{"headers.Authorization"},
    };
    const dialect = Dialect{
        .container = "mcp_servers",
        .format = .toml,
        .transport = .inferred,
        .command_style = .scalar,
        .secret = .{ .style = .env_var_name, .key = "bearer_token_env_var" },
    };
    const entry = try buildEntry(a, server, dialect);
    var found = false;
    for (entry.fields) |field| {
        if (std.mem.eql(u8, field.key, "bearer_token_env_var")) {
            found = true;
            try std.testing.expectEqualStrings("MEM0_API_KEY", field.value.string);
        }
    }
    try std.testing.expect(found);
}

test "mergeJson preserves foreign keys and adds the server" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dialect = Dialect{
        .container = "mcpServers",
        .format = .json,
        .transport = .inferred,
        .command_style = .scalar,
    };
    const entries = [_]Entry{.{
        .name = "mem0",
        .fields = &.{.{ .key = "url", .value = .{ .string = "https://mcp.mem0.ai/mcp" } }},
    }};
    const existing =
        \\{
        \\  "mcpServers": {
        \\    "other": { "command": "keep-me" }
        \\  },
        \\  "unrelated": { "a": 1 }
        \\}
    ;
    const merged = try mergeJson(a, existing, dialect, &entries);
    try std.testing.expect(std.mem.indexOf(u8, merged, "keep-me") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "unrelated") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "mem0") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "https://mcp.mem0.ai/mcp") != null);
}

test "mergeJson refuses to overwrite unparseable config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dialect = Dialect{ .container = "mcpServers", .format = .json, .transport = .inferred, .command_style = .scalar };
    try std.testing.expectError(error.InvalidExistingConfig, mergeJson(a, "{ not json", dialect, &.{}));
}

test "mergeJson creates config from scratch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dialect = Dialect{ .container = "servers", .format = .json, .transport = .explicit, .command_style = .scalar, .secret = .{ .style = .input_ref, .input_key = "inputs", .input_id = "tin" } };
    const entries = [_]Entry{.{
        .name = "mem0",
        .fields = &.{.{ .key = "type", .value = .{ .string = "http" } }},
        .needs_input = true,
    }};
    const merged = try mergeJson(a, null, dialect, &entries);
    try std.testing.expect(std.mem.indexOf(u8, merged, "\"servers\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "\"inputs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "${input:tin}") == null);
}

test "mergeToml replaces a managed block and keeps the rest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dialect = Dialect{ .container = "mcp_servers", .format = .toml, .transport = .inferred, .command_style = .scalar };
    const entries = [_]Entry{.{
        .name = "mem0",
        .fields = &.{
            .{ .key = "url", .value = .{ .string = "https://mcp.mem0.ai/mcp" } },
            .{ .key = "bearer_token_env_var", .value = .{ .string = "MEM0_API_KEY" } },
        },
    }};
    const existing =
        \\model = "gpt-5"
        \\
        \\[mcp_servers.mem0]
        \\url = "https://stale"
        \\
        \\[mcp_servers.other]
        \\command = "keep"
        \\
    ;
    const merged = try mergeToml(a, existing, dialect, &entries);
    try std.testing.expect(std.mem.indexOf(u8, merged, "\"https://stale\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "https://mcp.mem0.ai/mcp") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "keep") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "model = \"gpt-5\"") != null);
}

test "mergeToml is idempotent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dialect = Dialect{ .container = "mcp_servers", .format = .toml, .transport = .inferred, .command_style = .scalar };
    const entries = [_]Entry{.{
        .name = "mem0",
        .fields = &.{.{ .key = "url", .value = .{ .string = "https://mcp.mem0.ai/mcp" } }},
    }};
    const once = try mergeToml(a, null, dialect, &entries);
    const twice = try mergeToml(a, once, dialect, &entries);
    try std.testing.expectEqualStrings(once, twice);
}
