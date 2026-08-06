const std = @import("std");
const token = @import("token.zig");
const value_mod = @import("value.zig");

const Token = token.Token;
const ParseError = value_mod.ParseError;
const Tag = value_mod.Tag;
const Tree = value_mod.Tree;
const Node = value_mod.Node;

pub const Composer = struct {
    alloc: std.mem.Allocator,
    tokens: []const Token,
    src: []const u8,
    pos: usize = 0,
    tree: *Tree,
    parent_stack: std.ArrayListUnmanaged(u32) = .{},

    const Error = ParseError || std.mem.Allocator.Error;

    pub fn init(alloc: std.mem.Allocator, tokens: []const Token, src: []const u8, tree: *Tree) Composer {
        return .{
            .alloc = alloc,
            .tokens = tokens,
            .src = src,
            .tree = tree,
        };
    }

    pub fn deinit(self: *Composer) void {
        self.parent_stack.deinit(self.alloc);
    }

    fn peek(self: *Composer) ?Token {
        return if (self.pos < self.tokens.len) self.tokens[self.pos] else null;
    }

    fn next(self: *Composer) Token {
        const t = self.tokens[self.pos];
        self.pos += 1;
        return t;
    }

    fn currentParent(self: *Composer) u32 {
        return if (self.parent_stack.items.len > 0) self.parent_stack.items[self.parent_stack.items.len - 1] else 0;
    }

    fn addNode(self: *Composer, node: Node) Error!u32 {
        const parent = self.currentParent();
        
        if (parent == 0 and self.tree.nodes.items[0].tag == .null and (node.tag == .mapping or node.tag == .sequence)) {
            self.tree.nodes.items[0].tag = node.tag;
            return 0;
        }

        const idx = try self.tree.addNode(self.alloc, node);
        
        if (idx != 0) {
            if (self.tree.nodes.items[parent].first_child == 0) {
                self.tree.nodes.items[parent].first_child = idx;
                self.tree.nodes.items[parent].last_child = idx;
            } else {
                const prev_last = self.tree.nodes.items[parent].last_child;
                self.tree.nodes.items[prev_last].next_sibling = idx;
                self.tree.nodes.items[parent].last_child = idx;
            }
        }
        return idx;
    }

    pub fn compose(self: *Composer) Error!void {
        if (self.tokens.len == 0) return;
        _ = self.next(); // stream_start
        try self.parent_stack.append(self.alloc, 0); // Root

        while (self.peek()) |t| {
            if (t.tag == .stream_end) break;
            if (t.tag == .document_start or t.tag == .document_end or t.tag == .block_end) {
                _ = self.next();
                continue;
            }

            _ = try self.composeNode();
        }
        
        if (self.tree.nodes.items[0].tag == .null) {
            const first = self.tree.nodes.items[0].first_child;
            if (first != 0) {
                const f_node = self.tree.nodes.items[first];
                if (f_node.tag == .scalar and f_node.next_sibling == 0) {
                    self.tree.nodes.items[0].tag = .scalar;
                    self.tree.nodes.items[0].start = f_node.start;
                    self.tree.nodes.items[0].end = f_node.end;
                    self.tree.nodes.items[0].computed_value = f_node.computed_value;
                    self.tree.nodes.items[0].source_map = f_node.source_map;
                } else if (f_node.next_sibling != 0) {
                    self.tree.nodes.items[0].tag = .mapping;
                }
            }
        }
    }

    fn composeNode(self: *Composer) Error!u32 {
        var had_anchor = false;
        while (self.peek()) |t| {
            if (t.tag == .anchor) {
                if (had_anchor) return error.InvalidYaml;
                had_anchor = true;
                _ = self.next();
            } else if (t.tag == .tag) {
                _ = self.next();
            } else break;
        }

        const t = self.peek() orelse return 0;
        var idx: u32 = 0;

        switch (t.tag) {
            .scalar => {
                const tok = self.next();
                idx = try self.addNode(.{
                    .tag = .scalar,
                    .start = tok.start,
                    .end = tok.end,
                    .computed_value = tok.value,
                    .source_map = tok.source_map,
                    .parent = self.currentParent(),
                });
            },
            .alias => {
                if (had_anchor) return error.InvalidYaml;
                const tok = self.next();
                idx = try self.addNode(.{
                    .tag = .scalar,
                    .start = tok.start,
                    .end = tok.end,
                    .computed_value = tok.value,
                    .source_map = tok.source_map,
                    .parent = self.currentParent(),
                });
            },
            .block_sequence_start, .flow_sequence_start => { 
                idx = try self.composeSeq(); 
            },
            .block_mapping_start, .flow_mapping_start => { 
                idx = try self.composeMap(); 
            },
            .key_token => {
                idx = try self.composeMap();
            },
            else => { _ = self.next(); },
        }

        return idx;
    }

    fn composeSeq(self: *Composer) Error!u32 {
        _ = self.next(); // start
        const idx = try self.addNode(.{
            .tag = .sequence,
            .parent = self.currentParent(),
        });
        try self.parent_stack.append(self.alloc, idx);
        defer _ = self.parent_stack.pop();

        while (self.peek()) |tok| {
            if (tok.tag == .block_end or tok.tag == .flow_sequence_end) { _ = self.next(); break; }
            if (tok.tag == .flow_entry) { _ = self.next(); continue; }
            if (tok.tag == .block_entry) {
                _ = self.next();
                if (self.peek()) |nx| {
                    if (nx.tag == .block_entry or nx.tag == .block_end) {
                        _ = try self.addNode(.{ .tag = .null, .parent = idx });
                        continue;
                    }
                }
            }

            _ = try self.composeNode();
        }

        return idx;
    }

    fn composeMap(self: *Composer) Error!u32 {
        const first = self.peek() orelse return 0;
        if (first.tag == .block_mapping_start or first.tag == .flow_mapping_start) _ = self.next();

        const idx = try self.addNode(.{
            .tag = .mapping,
            .parent = self.currentParent(),
        });
        try self.parent_stack.append(self.alloc, idx);
        defer _ = self.parent_stack.pop();

        while (self.peek()) |tok| {
            if (tok.tag == .block_end or tok.tag == .flow_mapping_end) { _ = self.next(); break; }
            if (tok.tag == .flow_entry) { _ = self.next(); continue; }

            if (tok.tag == .key_token) {
                _ = self.next();
                _ = try self.composeNode(); // Key
                if (self.peek()) |nx| {
                    if (nx.tag == .value_token) {
                        _ = self.next();
                        _ = try self.composeNode(); // Value
                    }
                }
            } else {
                const key_idx = try self.composeNode(); // Key
                if (key_idx != 0) {
                    if (self.peek()) |nx| {
                        if (nx.tag == .value_token) {
                            _ = self.next();
                            _ = try self.composeNode(); // Value
                        }
                    }
                }
            }
        }

        return idx;
    }
};
