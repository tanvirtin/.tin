const std = @import("std");
const diag = @import("diagnostic.zig");
const context = @import("context.zig");
const Span = diag.Span;
const Diagnostic = diag.Diagnostic;
const ContextEnv = context.ContextEnv;

const yaml = @import("yaml");
const SourceMap = yaml.SourceMap;

pub const Sublang = struct {
    name: []const u8,

    /// Validate the source string.
    validate: *const fn (
        allocator: std.mem.Allocator,
        source: []const u8,
        span: Span,
        env: ?*const ContextEnv,
        diagnostics: *std.ArrayListUnmanaged(Diagnostic),
        source_map: ?SourceMap,
    ) anyerror!void,
};

pub const SublangRegistry = struct {
    plugins: std.StringHashMap(Sublang),

    pub fn init(allocator: std.mem.Allocator) SublangRegistry {
        return .{ .plugins = std.StringHashMap(Sublang).init(allocator) };
    }

    pub fn deinit(self: *SublangRegistry) void {
        self.plugins.deinit();
    }

    pub fn register(self: *SublangRegistry, plugin: Sublang) !void {
        try self.plugins.put(plugin.name, plugin);
    }

    pub fn get(self: *const SublangRegistry, name: []const u8) ?Sublang {
        return self.plugins.get(name);
    }
};
