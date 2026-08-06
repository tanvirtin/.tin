const std = @import("std");

const SourceMap = @import("token.zig").SourceMap;

pub const ParseError = error{
    InvalidYaml,
    OutOfMemory,
};

pub const Tag = enum(u8) {
    null,
    scalar,
    sequence,
    mapping,
};

pub const Node = struct {
    tag: Tag,
    start: u32 = 0,
    end: u32 = 0,
    computed_value: ?[]const u8 = null,
    source_map: ?SourceMap = null,
    parent: u32 = 0,
    first_child: u32 = 0,
    last_child: u32 = 0,
    next_sibling: u32 = 0,
};

const Token = @import("token.zig").Token;

pub const Tree = struct {
    nodes: std.ArrayListUnmanaged(Node) = .{},
    source: []const u8,
    tokens: []const Token = &.{},

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !*Tree {
        const self = try allocator.create(Tree);
        self.* = .{ .source = source };
        try self.nodes.append(allocator, .{ .tag = .null }); // Root 0
        return self;
    }

    pub fn deinit(self: *Tree, allocator: std.mem.Allocator) void {
        for (self.tokens) |t| {
            if (t.value) |v| {
                const vp = @intFromPtr(v.ptr);
                const sp = @intFromPtr(self.source.ptr);
                if (vp < sp or vp >= sp + self.source.len) {
                    allocator.free(v);
                }
            }
            if (t.source_map) |sm| {
                allocator.free(sm.entries);
            }
        }
        allocator.free(self.tokens);
        self.nodes.deinit(allocator);
        allocator.destroy(self);
    }
    
    pub fn addNode(self: *Tree, allocator: std.mem.Allocator, node: Node) !u32 {
        const idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(allocator, node);
        return idx;
    }

    pub fn getString(self: Tree, idx: u32) ?[]const u8 {
        if (idx >= self.nodes.items.len) return null;
        const node = self.nodes.items[idx];
        if (node.tag == .scalar) return node.computed_value orelse self.source[node.start..node.end];
        return null;
    }
};

pub const Value = struct {
    tree: *const Tree,
    idx: u32,
    arena: *std.heap.ArenaAllocator,

    pub fn get(self: Value, key: []const u8) ?Value {
        const node = self.tree.nodes.items[self.idx];
        if (node.tag != .mapping) return null;
        var child = node.first_child;
        while (child != 0) {
            const k_node = self.tree.nodes.items[child];
            const k_str = k_node.computed_value orelse self.tree.source[k_node.start..k_node.end];
            const val_idx = k_node.next_sibling;
            
            if (std.mem.eql(u8, k_str, key)) {
                if (val_idx == 0) return null;
                return .{ .tree = self.tree, .idx = val_idx, .arena = self.arena };
            }
            
            if (val_idx == 0) break;
            child = self.tree.nodes.items[val_idx].next_sibling;
        }
        return null;
    }

    pub fn getMapping(self: Value, key: []const u8) ?Value {
        return self.get(key);
    }

    pub fn getString(self: Value) ?[]const u8 {
        return self.tree.getString(self.idx);
    }

    pub fn getSourceMap(self: Value) ?SourceMap {
        if (self.idx >= self.tree.nodes.items.len) return null;
        return self.tree.nodes.items[self.idx].source_map;
    }

    pub fn getSequence(self: Value) ?[]const Value {
        const node = self.tree.nodes.items[self.idx];
        if (node.tag != .sequence) return null;
        
        var count: usize = 0;
        var child = node.first_child;
        while (child != 0) : (child = self.tree.nodes.items[child].next_sibling) count += 1;
        
        const slice = self.arena.allocator().alloc(Value, count) catch return null;
        child = node.first_child;
        var i: usize = 0;
        while (child != 0) : (child = self.tree.nodes.items[child].next_sibling) {
            slice[i] = .{ .tree = self.tree, .idx = child, .arena = self.arena };
            i += 1;
        }
        return slice;
    }
};

pub const Entry = struct {
    key: []const u8,
    value: Value,
};
