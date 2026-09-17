const std = @import("std");
const ast = @import("ast.zig");
const env_mod = @import("env.zig");
const value_mod = @import("value.zig");
const diag = @import("../../diagnostic.zig");

const Node = ast.Node;
pub const Value = value_mod.Value;
const EvalEnv = env_mod.EvalEnv;
const Diagnostic = diag.Diagnostic;

pub const MAX_JSON_DEPTH = 256;

pub const EvalError = error{
    OutOfMemory,
    UnboundVariable,
    UnknownFunction,
    BadArgCount,
    TypeError,
    InvalidIndex,
    InvalidJson,
};

const State = struct {
    allocator: std.mem.Allocator,
    diagnostics: ?*std.ArrayListUnmanaged(Diagnostic),
    span: diag.Span,
};

pub fn evaluate(allocator: std.mem.Allocator, node: *const Node, env: *const EvalEnv) anyerror!Value {
    return evalNode(.{ .allocator = allocator, .diagnostics = null, .span = undefined }, node, env);
}

pub fn evaluateDetailed(
    allocator: std.mem.Allocator,
    node: *const Node,
    env: *const EvalEnv,
    diagnostics: *std.ArrayListUnmanaged(Diagnostic),
    span: diag.Span,
) anyerror!Value {
    return evalNode(.{ .allocator = allocator, .diagnostics = diagnostics, .span = span }, node, env);
}

fn evalNode(state: State, node: *const Node, env: *const EvalEnv) EvalError!Value {
    return switch (node.*) {
        .literal => |l| switch (l) {
            .string => |s| .{ .string = s },
            .number => |n| .{ .number = n },
            .boolean => |b| .{ .boolean = b },
            .null_t => .null_t,
        },
        .variable => |v| blk: {
            if (env.get(v.name)) |val| break :blk val;
            try emit(state, "undefined_context", try std.fmt.allocPrint(state.allocator, "undefined context: '{s}'", .{v.name}));
            return error.UnboundVariable;
        },
        .unary => |u| .{ .boolean = !(try evalNode(state, u.expr, env)).truthy() },
        .binary => |b| try evalBinary(state, b, env),
        .index => |i| try evalIndex(state, i, env),
        .call => |c| try evalCall(state, c, env),
    };
}

fn evalBinary(state: State, b: Node.Binary, env: *const EvalEnv) EvalError!Value {
    switch (b.op) {
        .and_op => {
            const left = try evalNode(state, b.left, env);
            if (!left.truthy()) return left;
            return try evalNode(state, b.right, env);
        },
        .or_op => {
            const left = try evalNode(state, b.left, env);
            if (left.truthy()) return left;
            return try evalNode(state, b.right, env);
        },
        .eq => return .{ .boolean = Value.equal(try evalNode(state, b.left, env), try evalNode(state, b.right, env)) },
        .neq => return .{ .boolean = !Value.equal(try evalNode(state, b.left, env), try evalNode(state, b.right, env)) },
        .lt, .lte, .gt, .gte => {
            const left = try evalNode(state, b.left, env);
            const right = try evalNode(state, b.right, env);
            const ln = left.toNumber();
            const rn = right.toNumber();
            if (std.math.isNan(ln) or std.math.isNan(rn)) return .{ .boolean = false };
            return .{ .boolean = switch (b.op) {
                .lt => ln < rn,
                .lte => ln <= rn,
                .gt => ln > rn,
                .gte => ln >= rn,
                else => unreachable,
            } };
        },
    }
}

fn evalIndex(state: State, i: Node.Index, env: *const EvalEnv) EvalError!Value {
    const container = try evalNode(state, i.expr, env);
    const index = try evalNode(state, i.index, env);
    if (container != .array) {
        if (container == .object) {
            return switch (index) {
                .string => |key| if (container.object.get(key)) |v| v else .{ .string = "" },
                else => .{ .string = "" },
            };
        }
        return .{ .string = "" };
    }
    const arr = container.array;
    return switch (index) {
        .number => |n| blk: {
            if (n != std.math.floor(n) or n < 0) {
                try emit(state, "invalid_index", "array index must be a non-negative integer");
                return error.InvalidIndex;
            }
            const k: usize = @intFromFloat(n);
            if (k >= arr.len) break :blk .{ .string = "" };
            break :blk arr[k];
        },
        else => .{ .string = "" },
    };
}

fn evalCall(state: State, c: Node.Call, env: *const EvalEnv) EvalError!Value {
    return callBuiltin(state, c, env) catch |err| switch (err) {
        error.UnknownFunction => {
            try emit(state, "unknown_function", try std.fmt.allocPrint(state.allocator, "unknown function: {s}()", .{c.func}));
            return err;
        },
        error.BadArgCount => {
            try emit(state, "bad_argument_count", try std.fmt.allocPrint(state.allocator, "function {s}: wrong number of arguments", .{c.func}));
            return err;
        },
        error.TypeError => {
            try emit(state, "type_error", try std.fmt.allocPrint(state.allocator, "function {s}: argument type mismatch", .{c.func}));
            return err;
        },
        error.InvalidJson => {
            try emit(state, "invalid_json", try std.fmt.allocPrint(state.allocator, "function {s}: argument is not valid JSON", .{c.func}));
            return err;
        },
        else => return err,
    };
}

fn emit(state: State, code: []const u8, message: []const u8) EvalError!void {
    if (state.diagnostics) |diags| {
        try diags.append(state.allocator, .{
            .severity = .err,
            .span = state.span,
            .code = try state.allocator.dupe(u8, code),
            .message = message,
            .related = &.{},
            .suggestions = &.{},
        });
    }
}

fn callBuiltin(state: State, c: Node.Call, env: *const EvalEnv) EvalError!Value {
    var args: []Value = &.{};
    if (c.args.len > 0) {
        args = try state.allocator.alloc(Value, c.args.len);
        for (c.args, 0..) |*arg, k| args[k] = try evalNode(state, arg, env);
    }
    const name = c.func;

    if (std.ascii.eqlIgnoreCase(name, "contains")) return builtinContains(state, args);
    if (std.ascii.eqlIgnoreCase(name, "startsWith")) return builtinPrefix(state, args, true);
    if (std.ascii.eqlIgnoreCase(name, "endsWith")) return builtinPrefix(state, args, false);
    if (std.ascii.eqlIgnoreCase(name, "format")) return builtinFormat(state, args);
    if (std.ascii.eqlIgnoreCase(name, "join")) return builtinJoin(state, args);
    if (std.ascii.eqlIgnoreCase(name, "fromJSON")) return builtinFromJson(state, args);
    if (std.ascii.eqlIgnoreCase(name, "toJSON")) return builtinToJson(state, args);
    if (std.ascii.eqlIgnoreCase(name, "case")) return builtinCase(args);
    if (std.ascii.eqlIgnoreCase(name, "always")) return builtinStatus(env, args, .always);
    if (std.ascii.eqlIgnoreCase(name, "success")) return builtinStatus(env, args, .success);
    if (std.ascii.eqlIgnoreCase(name, "failure")) return builtinStatus(env, args, .failure);
    if (std.ascii.eqlIgnoreCase(name, "cancelled")) return builtinStatus(env, args, .cancelled);
    if (std.ascii.eqlIgnoreCase(name, "exists")) return builtinExists(args);
    if (std.ascii.eqlIgnoreCase(name, "commandExists")) return builtinCommandExists(state, args);
    return error.UnknownFunction;
}

fn expectArgs(args: []const Value, min: usize, max: usize) EvalError!void {
    if (args.len < min or args.len > max) return error.BadArgCount;
}

fn builtinContains(state: State, args: []const Value) EvalError!Value {
    try expectArgs(args, 2, 2);
    return switch (args[0]) {
        .string => |haystack| .{ .boolean = containsIgnoreCase(state.allocator, haystack, args[1].toString(state.allocator) catch "") != null },
        .array => |arr| blk: {
            for (arr) |item| {
                if (Value.equal(item, args[1])) break :blk .{ .boolean = true };
            }
            break :blk .{ .boolean = false };
        },
        .object => |obj| switch (args[1]) {
            .string => |key| .{ .boolean = obj.get(key) != null },
            else => .{ .boolean = false },
        },
        else => error.TypeError,
    };
}

fn builtinPrefix(state: State, args: []const Value, is_start: bool) EvalError!Value {
    try expectArgs(args, 2, 2);
    if (args[0] != .string or args[1] != .string) return .{ .boolean = false };
    const s = lowerSlice(state.allocator, args[0].string);
    const p = lowerSlice(state.allocator, args[1].string);
    const found = if (is_start) std.mem.startsWith(u8, s, p) else std.mem.endsWith(u8, s, p);
    return .{ .boolean = found };
}

fn builtinFormat(state: State, args: []const Value) EvalError!Value {
    if (args.len < 1 or args[0] != .string) return error.BadArgCount;
    const format = args[0].string;
    var out = std.ArrayListUnmanaged(u8){};
    var i: usize = 0;
    while (i < format.len) {
        if (format[i] == '{') {
            var j = i + 1;
            var num: ?usize = null;
            var acc: usize = 0;
            while (j < format.len and std.ascii.isDigit(format[j])) {
                acc = acc * 10 + (format[j] - '0');
                num = acc;
                j += 1;
            }
            if (num) |k| if (j < format.len and format[j] == '}') {
                if (k + 1 < args.len) {
                    const s = try args[k + 1].toString(state.allocator);
                    try out.appendSlice(state.allocator, s);
                }
                i = j + 1;
                continue;
            };
        }
        try out.append(state.allocator, format[i]);
        i += 1;
    }
    return .{ .string = try out.toOwnedSlice(state.allocator) };
}

fn builtinJoin(state: State, args: []const Value) EvalError!Value {
    try expectArgs(args, 1, 2);
    if (args[0] != .array) return error.TypeError;
    const sep = if (args.len == 2) try args[1].toString(state.allocator) else ",";
    var out = std.ArrayListUnmanaged(u8){};
    const arr = args[0].array;
    for (arr, 0..) |item, k| {
        if (k > 0) try out.appendSlice(state.allocator, sep);
        try out.appendSlice(state.allocator, try item.toString(state.allocator));
    }
    return .{ .string = try out.toOwnedSlice(state.allocator) };
}

fn builtinFromJson(state: State, args: []const Value) EvalError!Value {
    try expectArgs(args, 1, 1);
    if (args[0] != .string) return error.TypeError;
    return json.parse(state.allocator, args[0].string);
}

fn builtinToJson(state: State, args: []const Value) EvalError!Value {
    try expectArgs(args, 1, 1);
    return .{ .string = try json.stringify(state.allocator, args[0]) };
}

fn builtinCase(args: []const Value) EvalError!Value {
    if (args.len < 2) return error.BadArgCount;
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 2) {
        if (args[i].truthy()) return args[i + 1];
    }
    if (args.len % 2 == 1) return args[args.len - 1];
    return .null_t;
}

fn builtinStatus(env: *const EvalEnv, args: []const Value, which: StatusCheck) EvalError!Value {
    try expectArgs(args, 0, 0);
    const status = env.status orelse env_mod.Status{};
    const b: bool = switch (which) {
        .always => status.always,
        .success => status.success,
        .failure => status.failure,
        .cancelled => status.cancelled,
    };
    return .{ .boolean = b };
}

const StatusCheck = enum { always, success, failure, cancelled };

fn builtinExists(args: []const Value) EvalError!Value {
    try expectArgs(args, 1, 1);
    if (args[0] != .string) return error.TypeError;
    std.fs.cwd().access(args[0].string, .{}) catch return .{ .boolean = false };
    return .{ .boolean = true };
}

fn builtinCommandExists(state: State, args: []const Value) EvalError!Value {
    try expectArgs(args, 1, 1);
    if (args[0] != .string) return error.TypeError;
    const name = args[0].string;
    if (name.len == 0) return .{ .boolean = false };
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        std.fs.cwd().access(name, .{}) catch return .{ .boolean = false };
        return .{ .boolean = true };
    }
    const path = std.posix.getenv("PATH") orelse return .{ .boolean = false };
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fs.path.join(state.allocator, &.{ dir, name }) catch continue;
        defer state.allocator.free(full);
        std.fs.cwd().access(full, .{}) catch continue;
        return .{ .boolean = true };
    }
    return .{ .boolean = false };
}

fn containsIgnoreCase(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8) ?usize {
    const h = lowerSlice(allocator, haystack);
    const n = lowerSlice(allocator, needle);
    if (n.len == 0) return 0;
    return std.mem.indexOf(u8, h, n);
}

fn lowerSlice(allocator: std.mem.Allocator, s: []const u8) []u8 {
    const out = allocator.alloc(u8, s.len) catch return &.{};
    for (s, 0..) |c, k| out[k] = std.ascii.toLower(c);
    return out;
}

const json = struct {
    fn parse(allocator: std.mem.Allocator, source: []const u8) EvalError!Value {
        var p = Parser{ .allocator = allocator, .s = source };
        const v = try p.value();
        p.skipWs();
        if (p.i != source.len) return error.InvalidJson;
        return v;
    }

    const Parser = struct {
        allocator: std.mem.Allocator,
        s: []const u8,
        i: usize = 0,
        depth: usize = 0,

        fn skipWs(self: *Parser) void {
            while (self.i < self.s.len and std.ascii.isWhitespace(self.s[self.i])) self.i += 1;
        }

        fn value(self: *Parser) EvalError!Value {
            self.depth += 1;
            defer self.depth -= 1;
            if (self.depth > MAX_JSON_DEPTH) return error.InvalidJson;
            self.skipWs();
            if (self.i >= self.s.len) return error.InvalidJson;
            return switch (self.s[self.i]) {
                '{' => self.object(),
                '[' => self.array(),
                '"' => blk: {
                    const s = try self.stringValue();
                    break :blk .{ .string = s };
                },
                't' => self.literal("true", .{ .boolean = true }),
                'f' => self.literal("false", .{ .boolean = false }),
                'n' => self.literal("null", .null_t),
                '-', '0'...'9' => self.number(),
                else => error.InvalidJson,
            };
        }

        fn object(self: *Parser) EvalError!Value {
            self.i += 1;
            var map = std.StringHashMap(Value).init(self.allocator);
            self.skipWs();
            if (self.peek('}')) {
                self.i += 1;
                return .{ .object = map };
            }
            while (true) {
                self.skipWs();
                if (self.i >= self.s.len or self.s[self.i] != '"') return error.InvalidJson;
                const key = try self.stringValue();
                self.skipWs();
                if (self.i >= self.s.len or self.s[self.i] != ':') return error.InvalidJson;
                self.i += 1;
                const v = try self.value();
                try map.put(key, v);
                self.skipWs();
                if (self.peek('}')) {
                    self.i += 1;
                    return .{ .object = map };
                }
                if (self.i >= self.s.len or self.s[self.i] != ',') return error.InvalidJson;
                self.i += 1;
            }
        }

        fn array(self: *Parser) EvalError!Value {
            self.i += 1;
            var items = std.ArrayListUnmanaged(Value){};
            self.skipWs();
            if (self.peek(']')) {
                self.i += 1;
                return .{ .array = try items.toOwnedSlice(self.allocator) };
            }
            while (true) {
                try items.append(self.allocator, try self.value());
                self.skipWs();
                if (self.peek(']')) {
                    self.i += 1;
                    return .{ .array = try items.toOwnedSlice(self.allocator) };
                }
                if (self.i >= self.s.len or self.s[self.i] != ',') return error.InvalidJson;
                self.i += 1;
            }
        }

        fn stringValue(self: *Parser) EvalError![]const u8 {
            self.i += 1;
            var out = std.ArrayListUnmanaged(u8){};
            while (self.i < self.s.len) {
                const c = self.s[self.i];
                switch (c) {
                    '"' => {
                        self.i += 1;
                        return try out.toOwnedSlice(self.allocator);
                    },
                    '\\' => {
                        self.i += 1;
                        if (self.i >= self.s.len) return error.InvalidJson;
                        switch (self.s[self.i]) {
                            '"' => try out.append(self.allocator, '"'),
                            '\\' => try out.append(self.allocator, '\\'),
                            '/' => try out.append(self.allocator, '/'),
                            'b' => try out.append(self.allocator, 0x08),
                            'f' => try out.append(self.allocator, 0x0c),
                            'n' => try out.append(self.allocator, '\n'),
                            'r' => try out.append(self.allocator, '\r'),
                            't' => try out.append(self.allocator, '\t'),
                            'u' => {
                                self.i += 1;
                                const cp = try self.hex4();
                                var buf: [4]u8 = undefined;
                                const n = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidJson;
                                try out.appendSlice(self.allocator, buf[0..n]);
                                continue;
                            },
                            else => try out.append(self.allocator, self.s[self.i]),
                        }
                        self.i += 1;
                    },
                    else => {
                        try out.append(self.allocator, c);
                        self.i += 1;
                    },
                }
            }
            return error.InvalidJson;
        }

        fn hex4(self: *Parser) EvalError!u21 {
            if (self.i + 4 > self.s.len) return error.InvalidJson;
            var cp: u21 = 0;
            for (0..4) |k| {
                const c = self.s[self.i + k];
                cp = cp * 16 + switch (c) {
                    '0'...'9' => c - '0',
                    'a'...'f' => c - 'a' + 10,
                    'A'...'F' => c - 'A' + 10,
                    else => return error.InvalidJson,
                };
            }
            self.i += 4;
            return cp;
        }

        fn number(self: *Parser) EvalError!Value {
            const start = self.i;
            while (self.i < self.s.len) {
                const c = self.s[self.i];
                if (std.ascii.isDigit(c) or c == '-' or c == '+' or c == '.' or c == 'e' or c == 'E') {
                    self.i += 1;
                } else break;
            }
            const text = self.s[start..self.i];
            if (std.mem.indexOfAny(u8, text, "xX") != null) return error.InvalidJson;
            const n = std.fmt.parseFloat(f64, text) catch return error.InvalidJson;
            return .{ .number = n };
        }

        fn literal(self: *Parser, word: []const u8, v: Value) EvalError!Value {
            if (self.i + word.len > self.s.len or !std.mem.eql(u8, self.s[self.i .. self.i + word.len], word)) {
                return error.InvalidJson;
            }
            self.i += word.len;
            return v;
        }

        fn peek(self: *const Parser, c: u8) bool {
            return self.i < self.s.len and self.s[self.i] == c;
        }
    };

    fn stringify(allocator: std.mem.Allocator, value: Value) EvalError![]const u8 {
        var out = std.ArrayListUnmanaged(u8){};
        try writeValue(allocator, &out, value);
        return try out.toOwnedSlice(allocator);
    }

    fn writeValue(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: Value) EvalError!void {
        switch (value) {
            .null_t => try out.appendSlice(allocator, "null"),
            .boolean => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
            .number => |n| {
                if (std.math.isNan(n) or std.math.isInf(n)) {
                    try out.appendSlice(allocator, "null");
                    return;
                }
                const s = try std.fmt.allocPrint(allocator, "{d}", .{n});
                defer allocator.free(s);
                try out.appendSlice(allocator, s);
            },
            .string => |s| try writeString(allocator, out, s),
            .array => |arr| {
                try out.append(allocator, '[');
                for (arr, 0..) |item, k| {
                    if (k > 0) try out.append(allocator, ',');
                    try writeValue(allocator, out, item);
                }
                try out.append(allocator, ']');
            },
            .object => |map| {
                var keys = try allocator.alloc([]const u8, map.count());
                defer allocator.free(keys);
                {
                    var it = map.iterator();
                    var k: usize = 0;
                    while (it.next()) |entry| : (k += 1) keys[k] = entry.key_ptr.*;
                }
                std.mem.sort([]const u8, keys, {}, struct {
                    fn lt(_: void, a: []const u8, b: []const u8) bool {
                        return std.mem.order(u8, a, b) == .lt;
                    }
                }.lt);
                try out.append(allocator, '{');
                for (keys, 0..) |key, k| {
                    if (k > 0) try out.append(allocator, ',');
                    try writeString(allocator, out, key);
                    try out.append(allocator, ':');
                    try writeValue(allocator, out, map.get(key).?);
                }
                try out.append(allocator, '}');
            },
        }
    }

    fn writeString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) EvalError!void {
        try out.append(allocator, '"');
        for (s) |c| {
            switch (c) {
                '"' => try out.appendSlice(allocator, "\\\""),
                '\\' => try out.appendSlice(allocator, "\\\\"),
                '\n' => try out.appendSlice(allocator, "\\n"),
                '\r' => try out.appendSlice(allocator, "\\r"),
                '\t' => try out.appendSlice(allocator, "\\t"),
                else => {
                    if (c < 0x20) {
                        const esc = try std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{c});
                        defer allocator.free(esc);
                        try out.appendSlice(allocator, esc);
                    } else {
                        try out.append(allocator, c);
                    }
                },
            }
        }
        try out.append(allocator, '"');
    }
};