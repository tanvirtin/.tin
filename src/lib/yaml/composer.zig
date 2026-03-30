const std = @import("std");
const token = @import("token.zig");
const value_mod = @import("value.zig");

const Token = token.Token;
const ParseError = value_mod.ParseError;
const Value = value_mod.Value;
const Entry = value_mod.Entry;

pub const Composer = struct {
    alloc: std.mem.Allocator,
    tokens: []const Token,
    pos: usize = 0,
    anchors: std.StringHashMap(Value),

    pub fn init(alloc: std.mem.Allocator, tokens: []const Token) Composer {
        return .{ .alloc = alloc, .tokens = tokens, .anchors = std.StringHashMap(Value).init(alloc) };
    }

    fn peek(self: *Composer) ?Token {
        return if (self.pos < self.tokens.len) self.tokens[self.pos] else null;
    }

    fn next(self: *Composer) Token {
        const t = self.tokens[self.pos];
        self.pos += 1;
        return t;
    }

    pub fn compose(self: *Composer) !Value {
        _ = self.next(); // stream_start

        var result: Value = .{ .scalar = "" };
        var compose_iters: usize = 0;
        var after_doc_end = false;

        while (self.peek()) |t| {
            compose_iters += 1;
            if (compose_iters > self.tokens.len + 10) return error.InvalidYaml;
            if (t.tag == .stream_end) break;
            if (t.tag == .document_end) {
                after_doc_end = true;
                _ = self.next();
                continue;
            }
            if (t.tag == .document_start) {
                after_doc_end = false;
                _ = self.next();
                continue;
            }
            if (t.tag == .block_end) {
                _ = self.next();
                continue;
            }

            // Content after document-end without new document-start
            if (after_doc_end) {
                // Allow bare documents after doc-end
                after_doc_end = false;
            }

            result = try self.composeNode();
        }

        return result;
    }

    fn composeNode(self: *Composer) ParseError!Value {
        var anchor_name: ?[]const u8 = null;

        // Consume one anchor and/or one tag before the node
        while (self.peek()) |t| {
            if (t.tag == .anchor and anchor_name == null) {
                anchor_name = t.value;
                _ = self.next();
            } else if (t.tag == .tag) {
                _ = self.next();
            } else break;
        }

        // Reject multiple anchors on same node
        if (self.peek()) |check| {
            if (check.tag == .anchor) return error.InvalidYaml;
        }

        const t = self.peek() orelse return .{ .scalar = "" };
        var value: Value = undefined;

        switch (t.tag) {
            .scalar => { value = .{ .scalar = self.next().value orelse "" }; },
            .alias => {
                if (anchor_name != null) return error.InvalidYaml; // Can't have anchor + alias on same node
                const n = self.next();
                value = self.anchors.get(n.value orelse "") orelse .{ .scalar = "" };
            },
            .block_sequence_start, .flow_sequence_start => { value = try self.composeSeq(); },
            .block_mapping_start, .flow_mapping_start => { value = try self.composeMap(); },
            .key_token => { value = try self.composeMap(); },
            .block_end => { _ = self.next(); return .{ .scalar = "" }; },
            .document_start, .document_end, .stream_end => { return .{ .scalar = "" }; },
            else => { _ = self.next(); return .{ .scalar = "" }; },
        }

        if (anchor_name) |a| self.anchors.put(a, value) catch return error.OutOfMemory;
        return value;
    }

    fn composeSeq(self: *Composer) !Value {
        const t = self.next();
        const is_flow = t.tag == .flow_sequence_start;
        var items: std.ArrayList(Value) = .{};
        var seq_iters: usize = 0;

        while (self.peek()) |tok| {
            seq_iters += 1;
            if (seq_iters > self.tokens.len + 10) break;
            if (tok.tag == .block_end or tok.tag == .flow_sequence_end) { _ = self.next(); break; }
            if (tok.tag == .flow_entry) { _ = self.next(); continue; }
            if (tok.tag == .block_entry) {
                _ = self.next();
                if (self.peek()) |nx| {
                    if (nx.tag == .block_entry or nx.tag == .block_end) {
                        items.append(self.alloc, .{ .scalar = "" }) catch return error.OutOfMemory;
                        continue;
                    }
                }
            } else if (!is_flow) break;

            items.append(self.alloc, try self.composeNode()) catch return error.OutOfMemory;
        }

        return .{ .sequence = items.items };
    }

    fn composeMap(self: *Composer) !Value {
        const t = self.peek() orelse return .{ .mapping = &.{} };
        const is_flow = t.tag == .flow_mapping_start;
        if (t.tag == .block_mapping_start or t.tag == .flow_mapping_start) _ = self.next();

        var entries: std.ArrayList(Entry) = .{};
        var map_iters: usize = 0;

        while (self.peek()) |tok| {
            map_iters += 1;
            if (map_iters > self.tokens.len + 10) break;
            if (tok.tag == .block_end or tok.tag == .flow_mapping_end) { _ = self.next(); break; }
            if (tok.tag == .flow_entry) { _ = self.next(); continue; }

            if (tok.tag == .key_token) {
                _ = self.next();
                var key_str: []const u8 = "";
                if (self.peek()) |nx| {
                    if (nx.tag != .value_token and nx.tag != .block_end and nx.tag != .flow_mapping_end and nx.tag != .flow_entry and nx.tag != .key_token) {
                        const kv = try self.composeNode();
                        key_str = kv.getString() orelse "";
                    }
                }

                var val: Value = .{ .scalar = "" };
                if (self.peek()) |nx| {
                    if (nx.tag == .value_token) {
                        _ = self.next();
                        if (self.peek()) |vt| {
                            if (vt.tag != .key_token and vt.tag != .block_end and vt.tag != .flow_mapping_end and vt.tag != .flow_entry) {
                                val = try self.composeNode();
                            }
                        }
                    }
                }

                entries.append(self.alloc, .{ .key = key_str, .value = val }) catch return error.OutOfMemory;
            } else if (is_flow) {
                const kv = try self.composeNode();
                const key_str = kv.getString() orelse "";
                var val: Value = .{ .scalar = "" };
                if (self.peek()) |nx| {
                    if (nx.tag == .value_token) {
                        _ = self.next();
                        if (self.peek()) |vt| {
                            if (vt.tag != .key_token and vt.tag != .block_end and vt.tag != .flow_mapping_end and vt.tag != .flow_entry) {
                                val = try self.composeNode();
                            }
                        }
                    }
                }
                entries.append(self.alloc, .{ .key = key_str, .value = val }) catch return error.OutOfMemory;
            } else break;
        }

        return .{ .mapping = entries.items };
    }
};
