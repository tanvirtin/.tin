const std = @import("std");
const diag = @import("diagnostic.zig");

const Span = diag.Span;
const Diagnostic = diag.Diagnostic;

const Schema = @import("ir.zig").Schema;

pub const ContextSet = struct {
    map: std.StringHashMap(*Schema),

    pub fn contains(self: ContextSet, name: []const u8) bool {
        return self.map.contains(name);
    }

    pub fn get(self: ContextSet, name: []const u8) ?*Schema {
        return self.map.get(name);
    }
};

pub const ContextEnv = struct {
    parent: ?*const ContextEnv,
    contributions: ContextSet,

    pub fn lookup(self: *const ContextEnv, name: []const u8) ?*Schema {
        if (self.contributions.get(name)) |s| return s;
        if (self.parent) |p| return p.lookup(name);
        return null;
    }

    pub fn isAvailable(self: *const ContextEnv, name: []const u8) bool {
        return self.lookup(name) != null;
    }
};
