const std = @import("std");
const token = @import("token.zig");
const value = @import("value.zig");

const Token = token.Token;
const TokenTag = token.TokenTag;
const ScalarStyle = token.ScalarStyle;
const ParseError = value.ParseError;

pub const SimpleKey = struct {
    possible: bool = false,
    required: bool = false,
    token_pos: usize = 0,
    byte_pos: usize = 0,
    line: usize = 0,
    col: usize = 0,
    is_quoted: bool = false,
};

pub const Scanner = struct {
    fn validateTrailing(self: *Scanner) !void {
        const had_space = !self.eof() and isBlank(self.ch());
        while (!self.eof() and isBlank(self.ch())) self.step();
        if (self.eof() or isBreak(self.ch())) return;
        if (self.ch() == '#') {
            if (!had_space) return error.InvalidYaml;
            return;
        }
        if (self.flow_level > 0) {
            if (self.ch() == ':' or self.ch() == ',' or self.isFlowIndicator(self.ch())) return;
        }
        if (self.ch() == ':' and self.isBlankOrBreakOrEofAt(1)) return;
        return error.InvalidYaml;
    }

    alloc: std.mem.Allocator,
    src: []u8,
    pos: usize = 0,
    line: usize = 0,
    col: usize = 0,
    indent: i32 = -1,
    indents: std.ArrayListUnmanaged(i32) = .{},
    flow_level: usize = 0,
    tokens: std.ArrayListUnmanaged(Token) = .{},
    simple_keys: std.ArrayListUnmanaged(SimpleKey) = .{},
    simple_key_allowed: bool = true,
    started: bool = false,
    ended: bool = false,
    had_directive: bool = false,
    had_yaml_directive: bool = false,
    had_doc_start: bool = false,
    had_doc_end: bool = false,
    had_content: bool = false,
    last_was_flow_entry: bool = false,
    flow_just_started: bool = false,
    explicit_key_pending: bool = false,
    value_indicator_on_line: bool = false,
    value_after_explicit_key: bool = false,
    doc_start_line: ?usize = null,
    flow_types: std.ArrayList(enum { seq, map }) = .{},
    tag_handles: std.ArrayList([]const u8) = .{},
    total_steps: usize = 0,

    fn ch(self: *Scanner) u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else 0;
    }

    fn chAt(self: *Scanner, off: usize) u8 {
        const p = self.pos + off;
        return if (p < self.src.len) self.src[p] else 0;
    }

    fn eof(self: *Scanner) bool {
        return self.pos >= self.src.len;
    }

    fn step(self: *Scanner) void {
        if (self.pos < self.src.len) {
            if (self.src[self.pos] == '\n') {
                self.line += 1;
                self.col = 0;
            } else {
                self.col += 1;
            }
            self.pos += 1;
            self.total_steps += 1;
        }
    }

    fn skipBreak(self: *Scanner) void {
        if (self.ch() == '\r') self.step();
        if (self.ch() == '\n') self.step();
    }

    fn isBlank(c: u8) bool {
        return c == ' ' or c == '\t';
    }

    fn isBreak(c: u8) bool {
        return c == '\n' or c == '\r';
    }

    fn isBlankOrBreakOrEof(self: *Scanner) bool {
        return self.eof() or isBlank(self.ch()) or isBreak(self.ch());
    }

    fn isFlowIndicator(self: *Scanner, c: u8) bool {
        _ = self;
        return c == '[' or c == ']' or c == '{' or c == '}' or c == ',';
    }

    fn emit(self: *Scanner, t: Token) !void {
        self.tokens.append(self.alloc, t) catch return error.OutOfMemory;
    }

    fn insertAt(self: *Scanner, idx: usize, t: Token) !void {
        self.tokens.insert(self.alloc, idx, t) catch return error.OutOfMemory;
    }

    fn rollIndent(self: *Scanner, col: i32, tt: TokenTag) !void {
        if (self.flow_level > 0) return;
        if (col > self.indent) {
            self.indents.append(self.alloc, self.indent) catch return error.OutOfMemory;
            self.indent = col;
            try self.emit(.{ .tag = tt });
        }
    }

    fn unrollIndent(self: *Scanner, col: i32) !void {
        if (self.flow_level > 0) return;
        while (self.indent > col) {
            try self.emit(.{ .tag = .block_end, .start = @intCast(self.pos), .end = @intCast(self.pos) });
            if (self.indents.items.len > 0) {
                self.indent = self.indents.items[self.indents.items.len - 1];
                self.indents.items.len -= 1;
            } else {
                self.indent = -1;
            }
        }
    }

    fn saveSimpleKey(self: *Scanner) void {
        if (!self.simple_key_allowed) return;
        const required = (self.flow_level == 0 and @as(i32, @intCast(self.col)) == self.indent);
        self.currentSimpleKey().* = .{
            .possible = true,
            .required = required,
            .token_pos = self.tokens.items.len,
            .byte_pos = self.pos,
            .line = self.line,
            .col = self.col,
        };
    }

    fn removeSimpleKey(self: *Scanner) ParseError!void {
        if (self.currentSimpleKey().*.possible and self.currentSimpleKey().*.required) {
            return error.InvalidYaml;
        }
        self.currentSimpleKey().*.possible = false;
    }

    fn staleSimpleKeys(self: *Scanner) ParseError!void {
        for (self.simple_keys.items) |*sk| {
            if (!sk.possible) continue;
            const line_changed = (sk.line != self.line);
            const too_long = (self.pos > sk.byte_pos and self.pos - sk.byte_pos > 1024);
            if (too_long or (line_changed and !(sk.is_quoted and self.flow_level > 0))) {
                if (sk.required) return error.InvalidYaml;
                sk.possible = false;
            }
        }
    }

    fn eatSpacesAndComments(self: *Scanner) ParseError!void {
        while (!self.eof()) {
            if (self.ch() == ' ' or self.ch() == '\t') {
                self.step();
            } else if (self.ch() == '#') {
                if (self.pos > 0 and self.col > 0 and !isBlank(self.src[self.pos - 1]) and !isBreak(self.src[self.pos - 1])) {
                    return error.InvalidYaml;
                }
                while (!self.eof() and !isBreak(self.ch())) self.step();
            } else break;
        }
    }

    fn eatToNextToken(self: *Scanner) ParseError!void {
        const start_pos = self.pos;
        while (!self.eof()) {
            try self.eatSpacesAndComments();
            if (!self.eof() and isBreak(self.ch())) {
                self.skipBreak();
                self.value_indicator_on_line = false;
                self.simple_key_allowed = true;
                if (self.flow_level == 0) {
                    return;
                }
            } else break;
            if (self.pos == start_pos) break; // Rule 1: Progress-based
        }
    }

    fn currentSimpleKey(self: *Scanner) *SimpleKey {
        return &self.simple_keys.items[self.simple_keys.items.len - 1];
    }

    fn isFlowSequence(self: *Scanner) bool {
        return self.flow_types.items.len > 0 and self.flow_types.items[self.flow_types.items.len - 1] == .seq;
    }

    pub fn scan(self: *Scanner) ![]const Token {
        self.simple_keys.append(self.alloc, .{}) catch return error.OutOfMemory;
        try self.emit(.{ .tag = .stream_start, .start = @intCast(self.pos), .end = @intCast(self.pos) });
        self.started = true;

        while (true) {
            try self.eatToNextToken();

            if (self.flow_level == 0) {
                var found_content = false;
                while (!found_content and !self.eof()) {
                    const iter_start = self.pos;
                    while (!self.eof() and self.ch() == ' ') self.step();
                    if (!self.eof() and self.ch() == '\t' and self.indent >= 0 and self.col <= @as(usize, @intCast(self.indent + 1))) {
                        return error.InvalidYaml;
                    }
                    if (self.eof()) break;
                    if (self.ch() == '#') {
                        while (!self.eof() and !isBreak(self.ch())) self.step();
                    }
                    if (!self.eof() and isBreak(self.ch())) {
                        self.skipBreak();
                        self.value_indicator_on_line = false;
                    } else {
                        found_content = true;
                    }
                    if (self.pos == iter_start) break;
                }
            }

            if (self.eof()) {
                if (self.flow_level > 0) return error.InvalidYaml;
                if (self.had_directive and !self.had_doc_start) return error.InvalidYaml;
                try self.removeSimpleKey();
                try self.unrollIndent(-1);
                try self.emit(.{ .tag = .stream_end, .start = @intCast(self.pos), .end = @intCast(self.pos) });
                break;
            }

            try self.staleSimpleKeys();

            if (self.flow_level > 0 and !self.eof()) {
                const ci: i32 = @intCast(self.col);
                if (ci <= self.indent) {
                    const fc = self.ch();
                    if (fc != ']' and fc != '}' and fc != ',' and fc != '#') {
                        return error.InvalidYaml;
                    }
                }
            }

            if (self.flow_level == 0) {
                const col_i32: i32 = @intCast(self.col);
                const indent_before = self.indent;
                try self.unrollIndent(col_i32);
                if (indent_before > self.indent and col_i32 > self.indent and !self.currentSimpleKey().*.possible) {
                    if (!self.eof()) {
                        const nc = self.ch();
                        if (nc != '-' and nc != '?' and nc != ':' and nc != '#' and !isBreak(nc)) {
                            return error.InvalidYaml;
                        }
                    }
                }
            }

            const c = self.ch();
            const token_start_pos = self.pos;

            if (self.flow_level > 0 and self.col == 0) {
                if ((c == '-' and self.chAt(1) == '-' and self.chAt(2) == '-' and self.isBlankOrBreakOrEofAt(3)) or
                    (c == '.' and self.chAt(1) == '.' and self.chAt(2) == '.' and self.isBlankOrBreakOrEofAt(3)))
                {
                    return error.InvalidYaml;
                }
            }

            if (self.flow_level == 0 and self.col == 0 and c == '-' and self.chAt(1) == '-' and self.chAt(2) == '-' and self.isBlankOrBreakOrEofAt(3)) {
                try self.unrollIndent(-1);
                try self.removeSimpleKey();
                self.simple_key_allowed = true;
                self.step(); self.step(); self.step();
                self.had_doc_start = true;
                self.had_doc_end = false;
                if (!self.had_directive) self.tag_handles.items.len = 0;
                self.had_directive = false;
                self.had_yaml_directive = false;
                self.had_content = false;
                self.doc_start_line = self.line;
                try self.emit(.{ .tag = .document_start, .start = @intCast(self.pos), .end = @intCast(self.pos) });
                continue;
            }
            if (self.flow_level == 0 and self.col == 0 and c == '.' and self.chAt(1) == '.' and self.chAt(2) == '.' and self.isBlankOrBreakOrEofAt(3)) {
                try self.unrollIndent(-1);
                try self.removeSimpleKey();
                self.simple_key_allowed = true;
                self.step(); self.step(); self.step();
                while (!self.eof() and isBlank(self.ch())) self.step();
                if (!self.eof() and !isBreak(self.ch()) and self.ch() != '#') {
                    return error.InvalidYaml;
                }
                self.had_doc_end = true;
                self.had_content = false;
                try self.emit(.{ .tag = .document_end, .start = @intCast(self.pos), .end = @intCast(self.pos) });
                continue;
            }

            if (self.flow_level == 0 and self.col == 0 and c == '%' and self.indent < 0 and !self.had_content) {
                const rest_start = self.pos + 1;
                const is_yaml_dir = rest_start + 4 <= self.src.len and std.mem.eql(u8, self.src[rest_start..][0..4], "YAML");
                const is_tag_dir = rest_start + 3 <= self.src.len and std.mem.eql(u8, self.src[rest_start..][0..3], "TAG");
                if (is_yaml_dir or is_tag_dir) {
                    if (is_yaml_dir and self.had_yaml_directive) return error.InvalidYaml;
                    if (is_yaml_dir) self.had_yaml_directive = true;
                    self.had_directive = true;
                    while (!self.eof() and !isBlank(self.ch()) and !isBreak(self.ch())) self.step(); // skip %TAG/%YAML
                    while (!self.eof() and isBlank(self.ch())) self.step(); // skip blanks
                    const handle_start = self.pos;
                    while (!self.eof() and !isBlank(self.ch()) and !isBreak(self.ch())) self.step(); // scan handle
                    if (is_tag_dir) {
                        self.tag_handles.append(self.alloc, self.src[handle_start..self.pos]) catch return error.OutOfMemory;
                    }
                    while (!self.eof() and isBlank(self.ch())) self.step(); // skip blanks
                    if (!self.eof() and !isBreak(self.ch()) and self.ch() != '#') {
                        if (is_yaml_dir) return error.InvalidYaml;
                    }
                    while (!self.eof() and !isBreak(self.ch())) self.step();
                    continue;
                }
            }

            if (c == '[') {
                self.saveSimpleKey();
                self.flow_level += 1;
                self.simple_keys.append(self.alloc, .{}) catch return error.OutOfMemory;
                self.flow_types.append(self.alloc, .seq) catch return error.OutOfMemory;
                self.simple_key_allowed = true;
                self.flow_just_started = true;
                self.last_was_flow_entry = false;
                self.step();
                try self.emit(.{ .tag = .flow_sequence_start, .start = @intCast(self.pos), .end = @intCast(self.pos) });
                continue;
            }
            if (c == '{') {
                self.saveSimpleKey();
                self.flow_level += 1;
                self.simple_keys.append(self.alloc, .{}) catch return error.OutOfMemory;
                self.flow_types.append(self.alloc, .map) catch return error.OutOfMemory;
                self.simple_key_allowed = true;
                self.flow_just_started = true;
                self.last_was_flow_entry = false;
                self.step();
                try self.emit(.{ .tag = .flow_mapping_start, .start = @intCast(self.pos), .end = @intCast(self.pos) });
                continue;
            }
            if (c == ']') {
                if (self.flow_level == 0) return error.InvalidYaml;
                try self.removeSimpleKey();
                if (self.simple_keys.items.len > 1) self.simple_keys.items.len -= 1;
                if (self.flow_types.items.len > 0) self.flow_types.items.len -= 1;
                self.flow_level -= 1;
                self.simple_key_allowed = false;
                self.step();
                try self.emit(.{ .tag = .flow_sequence_end, .start = @intCast(self.pos), .end = @intCast(self.pos) });
                if (self.flow_level == 0) try self.validateTrailing();
                continue;
            }
            if (c == '}') {
                if (self.flow_level == 0) return error.InvalidYaml;
                try self.removeSimpleKey();
                if (self.simple_keys.items.len > 1) self.simple_keys.items.len -= 1;
                if (self.flow_types.items.len > 0) self.flow_types.items.len -= 1;
                self.flow_level -= 1;
                self.simple_key_allowed = false;
                self.step();
                try self.emit(.{ .tag = .flow_mapping_end, .start = @intCast(self.pos), .end = @intCast(self.pos) });
                if (self.flow_level == 0) try self.validateTrailing();
                continue;
            }
            if (c == ',') {
                if (self.flow_level == 0) return error.InvalidYaml;
                if (self.last_was_flow_entry or self.flow_just_started) {
                    return error.InvalidYaml;
                }
                try self.removeSimpleKey();
                self.simple_key_allowed = true;
                self.last_was_flow_entry = true;
                self.flow_just_started = false;
                self.step();
                try self.emit(.{ .tag = .flow_entry, .start = @intCast(self.pos), .end = @intCast(self.pos) });
                continue;
            }

            if (c == '-' and self.isBlankOrBreakOrEofAt(1) and self.flow_level == 0) {
                if (!self.simple_key_allowed and !self.explicit_key_pending) return error.InvalidYaml;
                if (self.value_indicator_on_line and !self.value_after_explicit_key) return error.InvalidYaml;
                try self.rollIndent(@intCast(self.col), .block_sequence_start);
                try self.removeSimpleKey();
                self.simple_key_allowed = true;
                self.step();
                try self.emit(.{ .tag = .block_entry, .start = @intCast(self.pos), .end = @intCast(self.pos) });
                continue;
            }

            if (c == '?' and (self.flow_level > 0 or self.isBlankOrBreakOrEofAt(1))) {
                if (self.flow_level == 0) try self.rollIndent(@intCast(self.col), .block_mapping_start);
                try self.removeSimpleKey();
                self.simple_key_allowed = false;
                self.explicit_key_pending = true;
                self.step();
                try self.emit(.{ .tag = .key_token, .start = @intCast(self.pos), .end = @intCast(self.pos) });
                continue;
            }

            if (c == ':' and (self.flow_level > 0 or self.isBlankOrBreakOrEofAt(1))) {
                self.last_was_flow_entry = false;
                self.flow_just_started = false;
                if (self.currentSimpleKey().*.possible) {
                    if (self.flow_level > 0 and self.currentSimpleKey().*.line != self.line) {
                        if (!self.currentSimpleKey().*.is_quoted) return error.InvalidYaml;
                        if (self.isFlowSequence() and !self.isBlankOrBreakOrEofAt(1) and !self.isFlowIndicator(self.chAt(1))) {
                            return error.InvalidYaml;
                        }
                    }
                    const sk_pos = self.currentSimpleKey().*.token_pos;
                    if (self.flow_level == 0) {
                        const key_col: i32 = @intCast(self.currentSimpleKey().*.col);
                        if (key_col > self.indent) {
                            if (self.doc_start_line) |dsl| {
                                if (self.currentSimpleKey().*.line == dsl) return error.InvalidYaml;
                            }
                            if (self.value_indicator_on_line and !self.value_after_explicit_key) return error.InvalidYaml;
                            try self.insertAt(sk_pos, .{ .tag = .block_mapping_start, .start = @intCast(self.pos), .end = @intCast(self.pos) });
                            try self.insertAt(sk_pos + 1, .{ .tag = .key_token, .start = @intCast(self.pos), .end = @intCast(self.pos) });
                            self.indents.append(self.alloc, self.indent) catch return error.OutOfMemory;
                            self.indent = key_col;
                        } else {
                            try self.insertAt(sk_pos, .{ .tag = .key_token, .start = @intCast(self.pos), .end = @intCast(self.pos) });
                        }
                    } else {
                        try self.insertAt(sk_pos, .{ .tag = .key_token, .start = @intCast(self.pos), .end = @intCast(self.pos) });
                    }
                    self.currentSimpleKey().*.possible = false;
                    if (self.flow_level == 0) self.value_indicator_on_line = true;
                } else {
                    if (self.explicit_key_pending) {} else if (self.flow_level == 0) {
                        try self.rollIndent(@intCast(self.col), .block_mapping_start);
                        try self.emit(.{ .tag = .key_token, .start = @intCast(self.pos), .end = @intCast(self.pos) });
                    }
                }
                self.step();
                self.value_after_explicit_key = self.explicit_key_pending;
                self.explicit_key_pending = false;
                self.simple_key_allowed = (self.flow_level == 0);
                try self.emit(.{ .tag = .value_token, .start = @intCast(self.pos), .end = @intCast(self.pos) });
                continue;
            }

            if (c == '&') {
                self.last_was_flow_entry = false;
                self.flow_just_started = false;
                self.saveSimpleKey();
                self.simple_key_allowed = false;

                self.step();
                const start = self.pos;
                while (!self.eof() and !isBlank(self.ch()) and !isBreak(self.ch()) and !self.isFlowIndicator(self.ch())) self.step();
                try self.emit(.{ .tag = .anchor, .value = self.src[start..self.pos] });
                continue;
            }

            if (c == '*') {
                self.last_was_flow_entry = false;
                self.flow_just_started = false;
                self.saveSimpleKey();
                self.simple_key_allowed = false;
                self.step();
                const start = self.pos;
                while (!self.eof() and !isBlank(self.ch()) and !isBreak(self.ch()) and !self.isFlowIndicator(self.ch())) self.step();
                try self.emit(.{ .tag = .alias, .value = self.src[start..self.pos] });
                continue;
            }

            if (c == '!') {
                self.last_was_flow_entry = false;
                self.flow_just_started = false;
                self.saveSimpleKey();
                self.simple_key_allowed = false;

                const start = self.pos;
                self.step();
                if (!self.eof() and self.ch() == '<') {
                    while (!self.eof() and self.ch() != '>') self.step();
                    if (!self.eof()) self.step();
                } else {
                    while (!self.eof() and !isBlank(self.ch()) and !isBreak(self.ch()) and !self.isFlowIndicator(self.ch())) self.step();
                }
                const tag_text = self.src[start..self.pos];
                if (tag_text.len > 1 and tag_text[0] == '!' and tag_text[1] != '<') {
                    if (std.mem.indexOfScalarPos(u8, tag_text, 1, '!')) |second_bang| {
                        if (second_bang > 1) {
                            const handle = tag_text[0 .. second_bang + 1];
                            var found = false;
                            for (self.tag_handles.items) |h| {
                                if (std.mem.eql(u8, h, handle)) { found = true; break; }
                            }
                            if (!found) return error.InvalidYaml;
                        }
                    }
                }
                try self.emit(.{ .tag = .tag, .value = tag_text });
                continue;
            }

            if (c == '|' or c == '>') {
                try self.removeSimpleKey();
                self.simple_key_allowed = true;
                self.value_indicator_on_line = false;
                try self.scanBlockScalar(c);
                continue;
            }

            if (c == '\'' or c == '"') {
                self.last_was_flow_entry = false;
                self.flow_just_started = false;
                const key_saved = self.simple_key_allowed;
                self.saveSimpleKey();
                self.simple_key_allowed = false;
                self.had_content = true;
                if (key_saved) self.currentSimpleKey().*.is_quoted = true;
                try self.scanQuotedScalar(c);
                continue;
            }

            if (self.flow_level > 0 and c == '-') {
                if (self.isBlankOrBreakOrEofAt(1) or self.isFlowIndicator(self.chAt(1))) {
                    return error.InvalidYaml;
                }
            }
            self.last_was_flow_entry = false;
            self.flow_just_started = false;
            self.saveSimpleKey();
            self.simple_key_allowed = false;
            self.had_content = true;
            const line_before_plain = self.line;
            try self.scanPlainScalar();
            if (self.line != line_before_plain) {
                if (self.flow_level == 0) {
                    self.simple_key_allowed = true;
                } else {
                    if (self.currentSimpleKey().*.possible and self.currentSimpleKey().*.line == line_before_plain) {
                        self.currentSimpleKey().*.line = self.line;
                    }
                }
            }

            if (self.pos == token_start_pos) {
                if (!self.eof()) self.step() else break;
            }
        }

        self.indents.deinit(self.alloc);
        self.simple_keys.deinit(self.alloc);
        self.flow_types.deinit(self.alloc);
        self.tag_handles.deinit(self.alloc);

        return try self.tokens.toOwnedSlice(self.alloc);
    }

    fn isBlankOrBreakOrEofAt(self: *Scanner, off: usize) bool {
        const p = self.pos + off;
        if (p >= self.src.len) return true;
        return isBlank(self.src[p]) or isBreak(self.src[p]);
    }

    fn scanBlockScalar(self: *Scanner, indicator: u8) !void {
        const style: ScalarStyle = if (indicator == '|') .literal else .folded;
        self.step();

        var chomping: enum { clip, strip, keep } = .clip;
        var explicit_indent: ?usize = null;

        while (!self.eof() and !isBreak(self.ch())) {
            if (self.ch() == '+') { chomping = .keep; self.step(); } else if (self.ch() == '-') { chomping = .strip; self.step(); } else if (self.ch() >= '1' and self.ch() <= '9') {
                explicit_indent = self.ch() - '0';
                self.step();
            } else if (isBlank(self.ch())) {
                self.step();
            } else if (self.ch() == '#') {
                if (self.pos > 0 and !isBlank(self.src[self.pos - 1])) return error.InvalidYaml;
                while (!self.eof() and !isBreak(self.ch())) self.step();
            } else return error.InvalidYaml;
        }

        if (!self.eof() and isBreak(self.ch())) self.skipBreak();

        var block_indent: usize = 0;
        if (explicit_indent) |ei| {
            block_indent = if (self.indent >= 0) @as(usize, @intCast(self.indent)) + ei else ei;
        } else {
            var look = self.pos;
            var found_content = false;
            var max_blank_indent: usize = 0;
            var blank_line_start: usize = look;
            while (look < self.src.len) {
                if (self.src[look] == ' ') {
                    look += 1;
                } else if (isBreak(self.src[look])) {
                    const blank_indent = look - blank_line_start;
                    if (blank_indent > max_blank_indent) max_blank_indent = blank_indent;
                    look += 1;
                    if (look < self.src.len and self.src[look - 1] == '\r' and self.src[look] == '\n') look += 1;
                    blank_line_start = look;
                } else {
                    var line_start = look;
                    while (line_start > 0 and self.src[line_start - 1] != '\n' and self.src[line_start - 1] != '\r') {
                        line_start -= 1;
                    }
                    block_indent = look - line_start;
                    found_content = true;
                    break;
                }
            }
            if (!found_content) {
                block_indent = if (self.indent >= 0) @as(usize, @intCast(self.indent)) + 1 else 1;
                if (max_blank_indent > block_indent) return error.InvalidYaml;
            }
            if (found_content and block_indent > 0 and max_blank_indent > block_indent) return error.InvalidYaml;
        }

        var result: std.ArrayList(u8) = .{};
        var trailing_breaks: usize = 0;

        var source_map_entries = std.ArrayListUnmanaged(token.SourceMap.Entry){};
        defer source_map_entries.deinit(self.alloc);
        try source_map_entries.append(self.alloc, .{ .parsed = 0, .source = @intCast(self.pos) });

        while (!self.eof()) {
            var line_indent: usize = 0;
            while (!self.eof() and self.ch() == ' ') {
                line_indent += 1;
                self.step();
            }

            if (line_indent == 0 and self.col == 0 and !self.eof()) {
                if ((self.ch() == '-' and self.chAt(1) == '-' and self.chAt(2) == '-' and self.isBlankOrBreakOrEofAt(3)) or
                    (self.ch() == '.' and self.chAt(1) == '.' and self.chAt(2) == '.' and self.isBlankOrBreakOrEofAt(3)))
                    break;
            }

            if (self.eof() or isBreak(self.ch())) {
                trailing_breaks += 1;
                if (!self.eof()) self.skipBreak();
                continue;
            }

            if (line_indent < block_indent) {
                self.pos -= line_indent;
                self.col -= line_indent;
                break;
            }

            if (style == .folded and trailing_breaks == 1 and result.items.len > 0) {
                result.append(self.alloc, ' ') catch return error.OutOfMemory;
            } else {
                var b: usize = 0;
                while (b < trailing_breaks) : (b += 1) {
                    result.append(self.alloc, '\n') catch return error.OutOfMemory;
                }
            }
            trailing_breaks = 0;

            if (line_indent > block_indent) {
                if (style == .folded and result.items.len > 0 and result.items[result.items.len - 1] == ' ') {
                    result.items[result.items.len - 1] = '\n';
                }
                var extra = line_indent - block_indent;
                while (extra > 0) : (extra -= 1) {
                    result.append(self.alloc, ' ') catch return error.OutOfMemory;
                }
            }

            try source_map_entries.append(self.alloc, .{ .parsed = @intCast(result.items.len), .source = @intCast(self.pos) });

            while (!self.eof() and !isBreak(self.ch())) {
                result.append(self.alloc, self.ch()) catch return error.OutOfMemory;
                self.step();
            }

            if (!self.eof()) {
                trailing_breaks = 1;
                self.skipBreak();
            }
        }

        switch (chomping) {
            .clip => { result.append(self.alloc, '\n') catch return error.OutOfMemory; },
            .keep => {
                var b: usize = 0;
                while (b < trailing_breaks) : (b += 1) {
                    result.append(self.alloc, '\n') catch return error.OutOfMemory;
                }
            },
            .strip => {},
        }

        var final_map: ?token.SourceMap = null;
        if (source_map_entries.items.len > 0) {
            final_map = .{ .entries = try source_map_entries.toOwnedSlice(self.alloc) };
        }

        const final_val = try result.toOwnedSlice(self.alloc);
        try self.emit(.{ .tag = .scalar, .value = final_val, .style = style, .source_map = final_map });
    }

    fn writeUtf8InSitu(self: *Scanner, pos: usize, cp: u21) usize {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return 0;
        @memcpy(self.src[pos .. pos + len], buf[0..len]);
        return len;
    }

    fn scanQuotedScalar(self: *Scanner, quote: u8) !void {
        self.step(); // opening quote
        const target_start = self.pos;
        var target_pos = target_start;
        const style: ScalarStyle = if (quote == '\'') .single_quoted else .double_quoted;
        var found_closing = false;

        var source_map_entries = std.ArrayListUnmanaged(token.SourceMap.Entry){};
        defer source_map_entries.deinit(self.alloc);
        try source_map_entries.append(self.alloc, .{ .parsed = 0, .source = @intCast(target_start) });

        while (!self.eof()) {
            const c = self.ch();

            if (self.flow_level == 0 and self.col == 0 and !self.eof()) {
                const dc = self.ch();
                if ((dc == '-' and self.chAt(1) == '-' and self.chAt(2) == '-' and self.isBlankOrBreakOrEofAt(3)) or
                    (dc == '.' and self.chAt(1) == '.' and self.chAt(2) == '.' and self.isBlankOrBreakOrEofAt(3)))
                {
                    return error.InvalidYaml;
                }
            }

            if (c == quote) {
                if (quote == '\'' and self.chAt(1) == '\'') {
                    self.src[target_pos] = '\'';
                    target_pos += 1;
                    self.step();
                    self.step();
                    try source_map_entries.append(self.alloc, .{ .parsed = @intCast(target_pos - target_start), .source = @intCast(self.pos) });
                    continue;
                }
                self.step();
                found_closing = true;
                break;
            }

            if (c == '\\' and quote == '"') {
                self.step();
                if (self.eof()) return error.InvalidYaml;
                const esc = self.ch();
                self.step();
                switch (esc) {
                    'n' => { self.src[target_pos] = '\n'; target_pos += 1; },
                    't' => { self.src[target_pos] = '\t'; target_pos += 1; },
                    'r' => { self.src[target_pos] = '\r'; target_pos += 1; },
                    '\\' => { self.src[target_pos] = '\\'; target_pos += 1; },
                    '"' => { self.src[target_pos] = '"'; target_pos += 1; },
                    '/' => { self.src[target_pos] = '/'; target_pos += 1; },
                    '0' => { self.src[target_pos] = 0; target_pos += 1; },
                    'a' => { self.src[target_pos] = 0x07; target_pos += 1; },
                    'b' => { self.src[target_pos] = 0x08; target_pos += 1; },
                    'e' => { self.src[target_pos] = 0x1b; target_pos += 1; },
                    'f' => { self.src[target_pos] = 0x0c; target_pos += 1; },
                    'v' => { self.src[target_pos] = 0x0b; target_pos += 1; },
                    ' ' => { self.src[target_pos] = ' '; target_pos += 1; },
                    'x' => { if (self.readHex(2)) |cp| target_pos += self.writeUtf8InSitu(target_pos, cp); },
                    'u' => { if (self.readHex(4)) |cp| target_pos += self.writeUtf8InSitu(target_pos, cp); },
                    'U' => { if (self.readHex(8)) |cp| target_pos += self.writeUtf8InSitu(target_pos, cp); },
                    '\n', '\r' => {
                        if (esc == '\r' and !self.eof() and self.ch() == '\n') self.step();
                        while (!self.eof() and isBlank(self.ch())) self.step();
                    },
                    else => return error.InvalidYaml,
                }
                try source_map_entries.append(self.alloc, .{ .parsed = @intCast(target_pos - target_start), .source = @intCast(self.pos) });
                continue;
            }

            if (isBreak(c)) {
                self.skipBreak();
                var line_indent: usize = 0;
                while (!self.eof() and isBlank(self.ch())) {
                    if (self.ch() == ' ') line_indent += 1;
                    self.step();
                }
                if (!self.eof() and !isBreak(self.ch()) and self.ch() != quote) {
                    const min_indent: usize = if (self.indent >= 0) @as(usize, @intCast(self.indent)) + 1 else 0;
                    if (line_indent < min_indent) return error.InvalidYaml;
                }
                if (!self.eof() and isBreak(self.ch())) {
                    self.src[target_pos] = '\n';
                    target_pos += 1;
                } else if (target_pos > target_start) {
                    self.src[target_pos] = ' ';
                    target_pos += 1;
                }
                try source_map_entries.append(self.alloc, .{ .parsed = @intCast(target_pos - target_start), .source = @intCast(self.pos) });
                continue;
            }

            self.src[target_pos] = c;
            target_pos += 1;
            self.step();
        }

        if (!found_closing) return error.InvalidYaml;

        var final_map: ?token.SourceMap = null;
        if (source_map_entries.items.len > 0) {
            final_map = .{ .entries = try source_map_entries.toOwnedSlice(self.alloc) };
        }

        try self.emit(.{ 
            .tag = .scalar, 
            .start = @intCast(target_start), 
            .end = @intCast(target_pos), 
            .style = style,
            .source_map = final_map,
        });

        try self.validateTrailing();
    }

    fn readHex(self: *Scanner, count: usize) ?u21 {
        var val: u21 = 0;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (self.eof()) return null;
            const d = std.fmt.charToDigit(self.ch(), 16) catch return null;
            val = val * 16 + @as(u21, d);
            self.step();
        }
        return val;
    }

    fn scanPlainScalar(self: *Scanner) !void {
        const start_indent = self.indent;
        const start_col = self.col;

        {
            const start = self.pos;
            var end = start;
            while (end < self.src.len) {
                const c = self.src[end];
                if (isBreak(c) or isBlank(c) or (self.flow_level > 0 and self.isFlowIndicator(c))) break;
                if (c == ':' and (end + 1 >= self.src.len or isBlank(self.src[end + 1]) or isBreak(self.src[end + 1]))) break;
                if (c == ':' and self.flow_level > 0 and end + 1 < self.src.len and self.isFlowIndicator(self.chAt(end - self.pos + 1))) break;
                end += 1;
            }
            if (end > start and (end >= self.src.len or
                (self.src[end] == ':') or
                (self.flow_level > 0 and self.isFlowIndicator(self.src[end]))))
            {
                const len = end - start;
                self.pos = end;
                self.col += len;

                var entries = try self.alloc.alloc(token.SourceMap.Entry, 1);
                entries[0] = .{ .parsed = 0, .source = @intCast(start) };

                try self.emit(.{ 
                    .tag = .scalar, 
                    .start = @intCast(start), 
                    .end = @intCast(end), 
                    .style = .plain,
                    .source_map = .{ .entries = entries },
                });
                return;
            }
        }

        const target_start = self.pos;
        var target_pos = target_start;
        var breaks: usize = 0;
        var spaces_count: usize = 0;

        var source_map_entries = std.ArrayListUnmanaged(token.SourceMap.Entry){};
        defer source_map_entries.deinit(self.alloc);
        try source_map_entries.append(self.alloc, .{ .parsed = 0, .source = @intCast(target_start) });

        while (!self.eof()) {
            const c = self.ch();
            const token_loop_start = self.pos;

            if (c == ':' and self.isBlankOrBreakOrEofAt(1)) break;
            if (c == ':' and self.flow_level > 0 and (self.isBlankOrBreakOrEofAt(1) or self.isFlowIndicator(self.chAt(1)))) break;
            if (self.flow_level > 0 and self.isFlowIndicator(c)) break;
            if (c == '#' and self.pos > 0 and isBlank(self.src[self.pos - 1])) break;

            if (isBreak(c)) {
                if (self.flow_level > 0) {
                    const saved_pos = self.pos;
                    const saved_line = self.line;
                    const saved_col = self.col;
                    self.skipBreak();
                    while (!self.eof() and self.ch() == ' ') self.step();
                    if (self.eof()) break;
                    if (isBreak(self.ch())) { breaks += 1; spaces_count = 0; continue; }
                    if (self.isFlowIndicator(self.ch()) or self.ch() == '#' or
                        (self.ch() == ':' and (self.isBlankOrBreakOrEofAt(1) or self.isFlowIndicator(self.chAt(1)))))
                    {
                        self.pos = saved_pos;
                        self.line = saved_line;
                        self.col = saved_col;
                        break;
                    }
                    breaks += 1;
                    spaces_count = 0;
                    continue;
                }
                self.skipBreak();
                self.value_indicator_on_line = false;

                var next_indent: usize = 0;
                while (!self.eof() and self.ch() == ' ') {
                    next_indent += 1;
                    self.step();
                }

                if (self.eof()) break;

                if (isBreak(self.ch())) {
                    breaks += 1;
                    spaces_count = 0;
                    continue;
                }

                if (self.col == 0) {
                    const nc = self.ch();
                    if ((nc == '-' and self.chAt(1) == '-' and self.chAt(2) == '-' and self.isBlankOrBreakOrEofAt(3)) or
                        (nc == '.' and self.chAt(1) == '.' and self.chAt(2) == '.' and self.isBlankOrBreakOrEofAt(3)))
                    {
                        self.pos -= next_indent;
                        self.col = 0;
                        break;
                    }
                }

                if (!self.eof()) {
                    const nc = self.ch();
                    const at_or_below_indent = @as(i32, @intCast(next_indent)) <= start_indent;
                    if (at_or_below_indent) {
                        self.pos -= next_indent;
                        self.col -= next_indent;
                        break;
                    }
                    if (nc == '-' and self.isBlankOrBreakOrEofAt(1) and next_indent >= start_col) {
                        self.pos -= next_indent;
                        self.col -= next_indent;
                        break;
                    }
                    if (nc == '?' and self.isBlankOrBreakOrEofAt(1) and next_indent >= start_col) {
                        self.pos -= next_indent;
                        self.col -= next_indent;
                        break;
                    }
                }

                breaks += 1;
                spaces_count = 0;
                continue;
            }

            if (isBlank(c)) {
                spaces_count += 1;
                self.step();
                continue;
            }

            if (breaks > 0) {
                const current_parsed_pos = target_pos - target_start;
                try source_map_entries.append(self.alloc, .{ .parsed = @intCast(current_parsed_pos), .source = @intCast(self.pos) });

                if (breaks == 1) {
                    self.src[target_pos] = ' ';
                    target_pos += 1;
                } else {
                    var b: usize = 1;
                    while (b < breaks) : (b += 1) {
                        self.src[target_pos] = '\n';
                        target_pos += 1;
                    }
                }
                breaks = 0;
            } else if (spaces_count > 0) {
                var s: usize = 0;
                while (s < spaces_count) : (s += 1) {
                    self.src[target_pos] = ' ';
                    target_pos += 1;
                }
            }
            spaces_count = 0;

            const current_parsed_p = target_pos - target_start;
            if (source_map_entries.items.len == 0 or (self.pos != source_map_entries.items[source_map_entries.items.len - 1].source + (current_parsed_p - source_map_entries.items[source_map_entries.items.len - 1].parsed))) {
                try source_map_entries.append(self.alloc, .{ .parsed = @intCast(current_parsed_p), .source = @intCast(self.pos) });
            }

            self.src[target_pos] = c;
            target_pos += 1;
            self.step();
            if (self.pos == token_loop_start) break; // Progress invariant
        }

        if (target_pos > target_start) {
            const final_map = if (source_map_entries.items.len > 0)
                token.SourceMap{ .entries = try source_map_entries.toOwnedSlice(self.alloc) }
            else null;

            try self.emit(.{ 
                .tag = .scalar, 
                .start = @intCast(target_start), 
                .end = @intCast(target_pos), 
                .style = .plain,
                .source_map = final_map,
            });
        } else {
            source_map_entries.deinit(self.alloc);
        }
    }
};
