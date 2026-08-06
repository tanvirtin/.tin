const std = @import("std");
const yaml = @import("yaml");
const diag = @import("diagnostic.zig");
const ir = @import("ir.zig");
const Span = diag.Span;
pub const ReferenceKind = ir.ReferenceKind;

pub const Declaration = struct {
    span: Span,
    node: yaml.Value,
    path: []const PathSegment = &.{},
};

pub const Scope = struct {
    kind: ReferenceKind,
    parent: ?*Scope,
    declarations: std.StringHashMap(Declaration),

    pub fn init(allocator: std.mem.Allocator, kind: ReferenceKind, parent: ?*Scope) Scope {
        return .{
            .kind = kind,
            .parent = parent,
            .declarations = std.StringHashMap(Declaration).init(allocator),
        };
    }

    pub fn deinit(self: *Scope) void {
        self.declarations.deinit();
    }

    pub fn declare(self: *Scope, name: []const u8, decl: Declaration) !void {
        try self.declarations.put(name, decl);
    }

    pub fn resolve(self: *const Scope, name: []const u8, pattern: ?PathExpression) ?Declaration {
        if (self.declarations.get(name)) |decl| {
            if (pattern) |p| {
                if (p.matches(decl.path)) return decl;
            } else {
                return decl;
            }
        }
        if (self.parent) |p| return p.resolve(name, pattern);
        return null;
    }
};

pub const PathSegment = union(enum) {
    key: []const u8,
    wildcard,      // *
    recursive,     // **
};

pub const PathExpression = struct {
    segments: []const PathSegment,

    pub fn parse(allocator: std.mem.Allocator, path: []const u8) !PathExpression {
        if (!std.mem.startsWith(u8, path, "#/")) return error.InvalidPath;
        var segments = std.ArrayListUnmanaged(PathSegment){};
        var it = std.mem.splitSequence(u8, path[2..], "/");
        while (it.next()) |s| {
            if (std.mem.eql(u8, s, "*")) {
                try segments.append(allocator, .wildcard);
            } else if (std.mem.eql(u8, s, "**")) {
                try segments.append(allocator, .recursive);
            } else {
                try segments.append(allocator, .{ .key = try allocator.dupe(u8, s) });
            }
        }
        return .{ .segments = try segments.toOwnedSlice(allocator) };
    }

    pub fn deinit(self: PathExpression, allocator: std.mem.Allocator) void {
        for (self.segments) |s| {
            if (s == .key) allocator.free(s.key);
        }
        allocator.free(self.segments);
    }

    pub fn matches(self: PathExpression, path: []const PathSegment) bool {
        return matchesInternal(self.segments, path);
    }

    fn matchesInternal(pattern: []const PathSegment, path: []const PathSegment) bool {
        if (pattern.len == 0) return path.len == 0;

        switch (pattern[0]) {
            .key => |k| {
                if (path.len == 0) return false;
                switch (path[0]) {
                    .key => |pk| if (!std.mem.eql(u8, k, pk)) return false,
                    else => return false,
                }
                return matchesInternal(pattern[1..], path[1..]);
            },
            .wildcard => {
                if (path.len == 0) return false;
                return matchesInternal(pattern[1..], path[1..]);
            },
            .recursive => {
                if (pattern.len == 1) return true;
                var i: usize = 0;
                while (i <= path.len) : (i += 1) {
                    if (matchesInternal(pattern[1..], path[i..])) return true;
                }
                return false;
            },
        }
    }
};

pub const PendingReference = struct {
    span: Span,
    kind: ReferenceKind,
    name: []const u8,
    scope: *Scope,
    path: PathExpression,
    catalog_kind: ?[]const u8 = null,
};

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    kinds: std.StringHashMap(std.StringHashMap(Declaration)),

    pub fn init(allocator: std.mem.Allocator) Catalog {
        return .{
            .allocator = allocator,
            .kinds = std.StringHashMap(std.StringHashMap(Declaration)).init(allocator),
        };
    }

    pub fn deinit(self: *Catalog) void {
        var it = self.kinds.iterator();
        while (it.next()) |entry| {
            var inner_it = entry.value_ptr.iterator();
            while (inner_it.next()) |inner_entry| {
                self.allocator.free(inner_entry.key_ptr.*);
            }
            entry.value_ptr.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.kinds.deinit();
    }

    pub fn register(self: *Catalog, kind: []const u8, name: []const u8, decl: Declaration) !void {
        var res = try self.kinds.getOrPut(kind);
        if (!res.found_existing) {
            res.key_ptr.* = try self.allocator.dupe(u8, kind);
            res.value_ptr.* = std.StringHashMap(Declaration).init(self.allocator);
        }
        try res.value_ptr.put(try self.allocator.dupe(u8, name), decl);
    }

    pub fn resolve(self: *const Catalog, kind: []const u8, name: []const u8) ?Declaration {
        const inner_map = self.kinds.get(kind) orelse return null;
        return inner_map.get(name);
    }
};
