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
    token_pos: usize = 0, // index in tokens array where key should be inserted
    byte_pos: usize = 0,  // scanner byte position when key was saved
    line: usize = 0,
    col: usize = 0,
    is_quoted: bool = false, // quoted keys can span lines in flow context
};

pub const Scanner = struct {
    alloc: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,
    line: usize = 0,
    col: usize = 0,
    indent: i32 = -1,
    indents: std.ArrayList(i32) = .{},
    flow_level: usize = 0,
    tokens: std.ArrayList(Token) = .{},
    simple_keys: std.ArrayList(SimpleKey) = .{},  // stack: one per flow level + base
    simple_key_allowed: bool = true,
    started: bool = false,
    ended: bool = false,
    total_steps: usize = 0,
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

    // ── Character access ──

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

    fn checkRunaway(self: *Scanner) ParseError!void {
        if (self.total_steps > self.src.len * 20 + 1000) return error.InvalidYaml;
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

    fn isFlowIndicator(c: u8) bool {
        return c == '[' or c == ']' or c == '{' or c == '}' or c == ',';
    }

    // ── Emit helpers ──

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
            try self.emit(.{ .tag = .block_end });
            if (self.indents.items.len > 0) {
                self.indent = self.indents.items[self.indents.items.len - 1];
                self.indents.items.len -= 1;
            } else {
                self.indent = -1;
            }
        }
    }

    // ── Simple Key Management ──

    fn saveSimpleKey(self: *Scanner) void {
        if (!self.simple_key_allowed) return;
        // Remove previous simple key if it exists and is required
        if (self.currentSimpleKey().*.possible and self.currentSimpleKey().*.required) {
            // Can't have two required simple keys — this shouldn't happen in practice
        }
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
            return error.InvalidYaml; // Expected ':' for simple key
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

    // ── Eat whitespace between tokens ──

    fn eatSpacesAndComments(self: *Scanner) ParseError!void {
        while (!self.eof()) {
            if (self.ch() == ' ' or self.ch() == '\t') {
                self.step();
            } else if (self.ch() == '#') {
                // # must be preceded by whitespace or be at start of line to be a comment
                if (self.pos > 0 and self.col > 0 and !isBlank(self.src[self.pos - 1]) and !isBreak(self.src[self.pos - 1])) {
                    return error.InvalidYaml; // # without preceding space
                }
                while (!self.eof() and !isBreak(self.ch())) self.step();
            } else break;
        }
    }

    fn eatToNextToken(self: *Scanner) ParseError!void {
        var eat_iters: usize = 0;
        while (!self.eof() and eat_iters < 10000) {
            eat_iters += 1;
            try self.eatSpacesAndComments();
            if (!self.eof() and isBreak(self.ch())) {
                self.skipBreak();
                self.value_indicator_on_line = false;
                self.simple_key_allowed = true;
                if (self.flow_level == 0) {
                    return;
                }
            } else break;
        }
    }

    // ── Main scan loop ──

    fn currentSimpleKey(self: *Scanner) *SimpleKey {
        return &self.simple_keys.items[self.simple_keys.items.len - 1];
    }

    fn isFlowSequence(self: *Scanner) bool {
        return self.flow_types.items.len > 0 and self.flow_types.items[self.flow_types.items.len - 1] == .seq;
    }

    pub fn scan(self: *Scanner) ![]const Token {
        // Initialize simple key stack with base level
        self.simple_keys.append(self.alloc, .{}) catch return error.OutOfMemory;
        try self.emit(.{ .tag = .stream_start });
        self.started = true;

        var scan_iterations: usize = 0;
        const max_iterations = self.src.len * 10 + 100;
        while (true) {
            scan_iterations += 1;
            if (scan_iterations > max_iterations) return error.InvalidYaml;
            try self.checkRunaway();

            try self.eatToNextToken();

            // After a newline in block context, eat leading spaces for indentation.
            // Also skip past any blank/comment lines.
            // Note: scanPlainScalar may consume newlines internally, so we need to
            // detect that we're at a new line and re-enable simple keys.
            if (self.flow_level == 0) {
                var skip_iters: usize = 0;
                var found_content = false;
                while (!found_content and skip_iters < self.src.len + 10) {
                    skip_iters += 1;
                    while (!self.eof() and self.ch() == ' ') self.step();
                    // Tab as indentation is invalid in YAML
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
                }
            }

            if (self.eof()) {
                if (self.flow_level > 0) return error.InvalidYaml;
                if (self.had_directive and !self.had_doc_start) return error.InvalidYaml;
                try self.removeSimpleKey();
                try self.unrollIndent(-1);
                try self.emit(.{ .tag = .stream_end });
                break;
            }

            try self.staleSimpleKeys();

            // In flow context, content at or below enclosing block indent is invalid
            if (self.flow_level > 0 and !self.eof()) {
                const ci: i32 = @intCast(self.col);
                if (ci <= self.indent) {
                    const fc = self.ch();
                    // Flow end indicators and comments are OK at any indent
                    if (fc != ']' and fc != '}' and fc != ',' and fc != '#') {
                        return error.InvalidYaml;
                    }
                }
            }

            // In block context, unroll/roll indentation based on column
            if (self.flow_level == 0) {
                const col_i32: i32 = @intCast(self.col);
                const indent_before = self.indent;
                try self.unrollIndent(col_i32);
                // Bad indentation: column is between two indent levels after unrolling
                // But only if no simple key is pending (flow-as-key patterns have valid intermediate indent)
                if (indent_before > self.indent and col_i32 > self.indent and !self.currentSimpleKey().*.possible) {
                    if (!self.eof()) {
                        const nc = self.ch();
                        // Allow block indicators that start new levels
                        if (nc != '-' and nc != '?' and nc != ':' and nc != '#' and !isBreak(nc)) {
                            return error.InvalidYaml;
                        }
                    }
                }
            }

            const c = self.ch();
            const token_start_pos = self.pos;

            // --- Document indicators inside flow = error ---
            if (self.flow_level > 0 and self.col == 0) {
                if ((c == '-' and self.chAt(1) == '-' and self.chAt(2) == '-' and self.isBlankOrBreakOrEofAt(3)) or
                    (c == '.' and self.chAt(1) == '.' and self.chAt(2) == '.' and self.isBlankOrBreakOrEofAt(3)))
                {
                    return error.InvalidYaml; // Document marker inside flow collection
                }
            }

            // --- Document indicators at column 0 (not in flow context) ---
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
                try self.emit(.{ .tag = .document_start });
                continue;
            }
            if (self.flow_level == 0 and self.col == 0 and c == '.' and self.chAt(1) == '.' and self.chAt(2) == '.' and self.isBlankOrBreakOrEofAt(3)) {
                try self.unrollIndent(-1);
                try self.removeSimpleKey();
                self.simple_key_allowed = true;
                self.step(); self.step(); self.step();
                // Only whitespace/comments allowed after ...
                while (!self.eof() and isBlank(self.ch())) self.step();
                if (!self.eof() and !isBreak(self.ch()) and self.ch() != '#') {
                    return error.InvalidYaml; // Content after document end marker
                }
                self.had_doc_end = true;
                self.had_content = false;
                try self.emit(.{ .tag = .document_end });
                continue;
            }

            // --- Directive (only between documents at column 0) ---
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

            // --- Flow indicators ---
            if (c == '[') {
                self.saveSimpleKey();
                self.flow_level += 1;
                self.simple_keys.append(self.alloc, .{}) catch return error.OutOfMemory;
                self.flow_types.append(self.alloc, .seq) catch return error.OutOfMemory;
                self.simple_key_allowed = true;
                self.flow_just_started = true;
                self.last_was_flow_entry = false;
                                self.step();
                try self.emit(.{ .tag = .flow_sequence_start });
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
                try self.emit(.{ .tag = .flow_mapping_start });
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
                try self.emit(.{ .tag = .flow_sequence_end });
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
                try self.emit(.{ .tag = .flow_mapping_end });
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
                try self.emit(.{ .tag = .flow_entry });
                continue;
            }

            // --- Block entry ---
            if (c == '-' and self.isBlankOrBreakOrEofAt(1) and self.flow_level == 0) {
                if (!self.simple_key_allowed and !self.explicit_key_pending) return error.InvalidYaml;
                if (self.value_indicator_on_line and !self.value_after_explicit_key) return error.InvalidYaml;
                try self.rollIndent(@intCast(self.col), .block_sequence_start);
                try self.removeSimpleKey();
                self.simple_key_allowed = true;
                self.step();
                try self.emit(.{ .tag = .block_entry });
                continue;
            }

            // --- Explicit key ---
            if (c == '?' and (self.flow_level > 0 or self.isBlankOrBreakOrEofAt(1))) {
                if (self.flow_level == 0) try self.rollIndent(@intCast(self.col), .block_mapping_start);
                try self.removeSimpleKey();
                self.simple_key_allowed = false;
                self.explicit_key_pending = true;
                                self.step();
                try self.emit(.{ .tag = .key_token });
                continue;
            }

            // --- Value indicator ---
            if (c == ':' and (self.flow_level > 0 or self.isBlankOrBreakOrEofAt(1))) {
                self.last_was_flow_entry = false;
                self.flow_just_started = false;
                if (self.currentSimpleKey().*.possible) {
                    // In flow context, plain simple key can't span multiple lines (quoted keys can)
                    if (self.flow_level > 0 and self.currentSimpleKey().*.line != self.line) {
                        if (!self.currentSimpleKey().*.is_quoted) return error.InvalidYaml;
                        // Quoted key in flow SEQUENCE needs : followed by whitespace/flow-indicator
                        if (self.isFlowSequence() and !self.isBlankOrBreakOrEofAt(1) and !isFlowIndicator(self.chAt(1))) {
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
                            try self.insertAt(sk_pos, .{ .tag = .block_mapping_start });
                            try self.insertAt(sk_pos + 1, .{ .tag = .key_token });
                            self.indents.append(self.alloc, self.indent) catch return error.OutOfMemory;
                            self.indent = key_col;
                        } else {
                            try self.insertAt(sk_pos, .{ .tag = .key_token });
                        }
                    } else {
                        try self.insertAt(sk_pos, .{ .tag = .key_token });
                    }
                    self.currentSimpleKey().*.possible = false;
                    if (self.flow_level == 0) self.value_indicator_on_line = true;
                } else {
                    if (self.explicit_key_pending) {
                        // After explicit ?, just emit value without another key
                    } else if (self.flow_level == 0) {
                        try self.rollIndent(@intCast(self.col), .block_mapping_start);
                        try self.emit(.{ .tag = .key_token });
                    }
                }
                self.step();
                self.value_after_explicit_key = self.explicit_key_pending;
                self.explicit_key_pending = false;
                self.simple_key_allowed = (self.flow_level == 0);
                try self.emit(.{ .tag = .value_token });
                continue;
            }

            // --- Anchor ---
            if (c == '&') {
                self.last_was_flow_entry = false;
                self.flow_just_started = false;
                self.saveSimpleKey();
                self.simple_key_allowed = false;

                self.step();
                const start = self.pos;
                while (!self.eof() and !isBlank(self.ch()) and !isBreak(self.ch()) and !isFlowIndicator(self.ch())) self.step();
                try self.emit(.{ .tag = .anchor, .value = self.src[start..self.pos] });
                continue;
            }

            // --- Alias ---
            if (c == '*') {
                self.last_was_flow_entry = false;
                self.flow_just_started = false;
                self.saveSimpleKey();
                self.simple_key_allowed = false;
                self.step();
                const start = self.pos;
                while (!self.eof() and !isBlank(self.ch()) and !isBreak(self.ch()) and !isFlowIndicator(self.ch())) self.step();
                try self.emit(.{ .tag = .alias, .value = self.src[start..self.pos] });
                continue;
            }

            // --- Tag ---
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
                    while (!self.eof() and !isBlank(self.ch()) and !isBreak(self.ch()) and !isFlowIndicator(self.ch())) self.step();
                }
                // Validate named tag handles (!name!...) are declared
                const tag_text = self.src[start..self.pos];
                if (tag_text.len > 1 and tag_text[0] == '!' and tag_text[1] != '<') {
                    // Find second '!' for named handle pattern
                    if (std.mem.indexOfScalarPos(u8, tag_text, 1, '!')) |second_bang| {
                        if (second_bang > 1) { // Named handle like !prefix!
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

            // --- Block scalar ---
            if (c == '|' or c == '>') {
                try self.removeSimpleKey();
                self.simple_key_allowed = true;
                self.value_indicator_on_line = false;
                try self.scanBlockScalar(c);
                continue;
            }

            // --- Quoted scalar ---
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

            // --- Plain scalar ---
            // In flow context, '-' must be followed by ns-plain-safe (not blank/flow-indicator)
            if (self.flow_level > 0 and c == '-') {
                if (self.isBlankOrBreakOrEofAt(1) or isFlowIndicator(self.chAt(1))) {
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
                    // Update simple key line for multiline flow scalars
                    if (self.currentSimpleKey().*.possible and self.currentSimpleKey().*.line == line_before_plain) {
                        self.currentSimpleKey().*.line = self.line;
                    }
                }
            }

            // Safety: if we didn't advance past this token position, skip character
            if (self.pos == token_start_pos) {
                if (!self.eof()) self.step() else break;
            }
        }

        return self.tokens.items;
    }

    fn isBlankOrBreakOrEofAt(self: *Scanner, off: usize) bool {
        const p = self.pos + off;
        if (p >= self.src.len) return true;
        return isBlank(self.src[p]) or isBreak(self.src[p]);
    }

    // ── Block Scalar ──

    fn scanBlockScalar(self: *Scanner, indicator: u8) !void {
        const style: ScalarStyle = if (indicator == '|') .literal else .folded;
        self.step();

        var chomping: enum { clip, strip, keep } = .clip;
        var explicit_indent: ?usize = null;

        // Parse indicators after | or >
        while (!self.eof() and !isBreak(self.ch())) {
            if (self.ch() == '+') { chomping = .keep; self.step(); } else if (self.ch() == '-') { chomping = .strip; self.step(); } else if (self.ch() >= '1' and self.ch() <= '9') {
                explicit_indent = self.ch() - '0';
                self.step();
            } else if (isBlank(self.ch())) {
                self.step();
            } else if (self.ch() == '#') {
                // Comment must be preceded by whitespace
                if (self.pos > 0 and !isBlank(self.src[self.pos - 1])) return error.InvalidYaml;
                while (!self.eof() and !isBreak(self.ch())) self.step();
            } else return error.InvalidYaml; // Invalid text after block scalar indicator
        }

        // Consume line break after indicator
        if (!self.eof() and isBreak(self.ch())) self.skipBreak();

        // Determine block indentation
        var block_indent: usize = 0;
        if (explicit_indent) |ei| {
            block_indent = if (self.indent >= 0) @as(usize, @intCast(self.indent)) + ei else ei;
        } else {
            // Auto-detect: find first content line
            var look = self.pos;
            var found_content = false;
            var max_blank_indent: usize = 0;
            var blank_line_start: usize = look;
            while (look < self.src.len) {
                if (self.src[look] == ' ') {
                    look += 1;
                } else if (isBreak(self.src[look])) {
                    // Track indent of this blank line
                    const blank_indent = look - blank_line_start;
                    if (blank_indent > max_blank_indent) max_blank_indent = blank_indent;
                    look += 1;
                    if (look < self.src.len and self.src[look - 1] == '\r' and self.src[look] == '\n') look += 1;
                    blank_line_start = look;
                } else {
                    // Count spaces from start of this line
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
                // Check blank lines even when no content found
                if (max_blank_indent > block_indent) return error.InvalidYaml;
            }
            if (found_content and block_indent > 0 and max_blank_indent > block_indent) return error.InvalidYaml;
        }

        var result: std.ArrayList(u8) = .{};
        var trailing_breaks: usize = 0;
        var block_iterations: usize = 0;

        while (!self.eof()) {
            block_iterations += 1;
            if (block_iterations > self.src.len + 10) break;
            try self.checkRunaway();
            // Count leading spaces
            var line_indent: usize = 0;
            while (!self.eof() and self.ch() == ' ') {
                line_indent += 1;
                self.step();
            }

            // Document indicator check
            if (line_indent == 0 and self.col == 0 and !self.eof()) {
                if ((self.ch() == '-' and self.chAt(1) == '-' and self.chAt(2) == '-' and self.isBlankOrBreakOrEofAt(3)) or
                    (self.ch() == '.' and self.chAt(1) == '.' and self.chAt(2) == '.' and self.isBlankOrBreakOrEofAt(3)))
                    break;
            }

            // Blank line
            if (self.eof() or isBreak(self.ch())) {
                trailing_breaks += 1;
                if (!self.eof()) self.skipBreak();
                continue;
            }

            // Under-indented = end of block scalar
            if (line_indent < block_indent) {
                self.pos -= line_indent;
                self.col -= line_indent;
                break;
            }

            // Emit accumulated trailing breaks
            if (style == .folded and trailing_breaks == 1 and result.items.len > 0) {
                result.append(self.alloc, ' ') catch return error.OutOfMemory;
            } else {
                var b: usize = 0;
                while (b < trailing_breaks) : (b += 1) {
                    result.append(self.alloc, '\n') catch return error.OutOfMemory;
                }
            }
            trailing_breaks = 0;

            // Extra indentation (keep as-is)
            if (line_indent > block_indent) {
                // For folded: if prev char was space (from fold), replace with newline
                if (style == .folded and result.items.len > 0 and result.items[result.items.len - 1] == ' ') {
                    result.items[result.items.len - 1] = '\n';
                }
                var extra = line_indent - block_indent;
                while (extra > 0) : (extra -= 1) {
                    result.append(self.alloc, ' ') catch return error.OutOfMemory;
                }
            }

            // Content
            while (!self.eof() and !isBreak(self.ch())) {
                result.append(self.alloc, self.ch()) catch return error.OutOfMemory;
                self.step();
            }

            // Line break
            if (!self.eof()) {
                trailing_breaks = 1;
                self.skipBreak();
            }
        }

        // Chomping
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

        try self.emit(.{ .tag = .scalar, .value = result.items, .style = style });
    }

    // ── Quoted Scalar ──

    fn scanQuotedScalar(self: *Scanner, quote: u8) !void {
        self.step(); // opening quote
        var result: std.ArrayList(u8) = .{};
        const style: ScalarStyle = if (quote == '\'') .single_quoted else .double_quoted;
        var found_closing = false;

        while (!self.eof()) {
            const c = self.ch();

            // Check for document indicators inside quoted strings (only in block context)
            if (self.flow_level == 0 and self.col == 0 and !self.eof()) {
                const dc = self.ch();
                if ((dc == '-' and self.chAt(1) == '-' and self.chAt(2) == '-' and self.isBlankOrBreakOrEofAt(3)) or
                    (dc == '.' and self.chAt(1) == '.' and self.chAt(2) == '.' and self.isBlankOrBreakOrEofAt(3)))
                {
                    return error.InvalidYaml; // Unterminated quoted scalar
                }
            }

            if (c == quote) {
                if (quote == '\'' and self.chAt(1) == '\'') {
                    result.append(self.alloc, '\'') catch return error.OutOfMemory;
                    self.step();
                    self.step();
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
                    'n' => result.append(self.alloc, '\n') catch return error.OutOfMemory,
                    't' => result.append(self.alloc, '\t') catch return error.OutOfMemory,
                    'r' => result.append(self.alloc, '\r') catch return error.OutOfMemory,
                    '\\' => result.append(self.alloc, '\\') catch return error.OutOfMemory,
                    '"' => result.append(self.alloc, '"') catch return error.OutOfMemory,
                    '/' => result.append(self.alloc, '/') catch return error.OutOfMemory,
                    '0' => result.append(self.alloc, 0) catch return error.OutOfMemory,
                    'a' => result.append(self.alloc, 0x07) catch return error.OutOfMemory,
                    'b' => result.append(self.alloc, 0x08) catch return error.OutOfMemory,
                    'e' => result.append(self.alloc, 0x1b) catch return error.OutOfMemory,
                    'f' => result.append(self.alloc, 0x0c) catch return error.OutOfMemory,
                    'v' => result.append(self.alloc, 0x0b) catch return error.OutOfMemory,
                    ' ' => result.append(self.alloc, ' ') catch return error.OutOfMemory,
                    'x' => { if (self.readHex(2)) |cp| self.writeUtf8(&result, cp); },
                    'u' => { if (self.readHex(4)) |cp| self.writeUtf8(&result, cp); },
                    'U' => { if (self.readHex(8)) |cp| self.writeUtf8(&result, cp); },
                    '\n', '\r' => {
                        if (esc == '\r' and !self.eof() and self.ch() == '\n') self.step();
                        while (!self.eof() and isBlank(self.ch())) self.step();
                    },
                    else => return error.InvalidYaml, // Invalid escape sequence
                }
                continue;
            }

            if (isBreak(c)) {
                self.skipBreak();
                var line_indent: usize = 0;
                while (!self.eof() and isBlank(self.ch())) {
                    if (self.ch() == ' ') line_indent += 1;
                    self.step();
                }
                // Check indentation of continuation line (must be > block indent)
                if (!self.eof() and !isBreak(self.ch()) and self.ch() != quote) {
                    const min_indent: usize = if (self.indent >= 0) @as(usize, @intCast(self.indent)) + 1 else 0;
                    if (line_indent < min_indent) return error.InvalidYaml;
                }
                if (!self.eof() and isBreak(self.ch())) {
                    result.append(self.alloc, '\n') catch return error.OutOfMemory;
                } else if (result.items.len > 0) {
                    result.append(self.alloc, ' ') catch return error.OutOfMemory;
                }
                continue;
            }

            result.append(self.alloc, c) catch return error.OutOfMemory;
            self.step();
        }

        if (!found_closing) return error.InvalidYaml;
        try self.emit(.{ .tag = .scalar, .value = result.items, .style = style });

        // Validate trailing content on the same line
        try self.validateTrailing();
    }

    fn validateTrailing(self: *Scanner) !void {
        // After certain tokens, only whitespace, valid comment (space before #), or newline/EOF allowed
        const had_space = !self.eof() and isBlank(self.ch());
        while (!self.eof() and isBlank(self.ch())) self.step();
        if (self.eof() or isBreak(self.ch())) return;
        if (self.ch() == '#') {
            if (!had_space) return error.InvalidYaml; // Comment needs space before #
            return;
        }
        // In flow context, colons, commas, brackets are valid
        if (self.flow_level > 0) {
            if (self.ch() == ':' or self.ch() == ',' or isFlowIndicator(self.ch())) return;
        }
        // In block context, colon is valid (key: "value": is weird but the : triggers value)
        if (self.ch() == ':' and self.isBlankOrBreakOrEofAt(1)) return;
        return error.InvalidYaml;
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

    fn writeUtf8(self: *Scanner, result: *std.ArrayList(u8), cp: u21) void {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return;
        result.appendSlice(self.alloc, buf[0..len]) catch return;
    }

    // ── Plain Scalar ──

    fn scanPlainScalar(self: *Scanner) !void {
        const start_indent = self.indent;
        const start_col = self.col;

        // Fast path: single-word scalar (no spaces, no line breaks)
        // Handles the most common case: keys and simple values like "name", "true", "8080"
        {
            const start = self.pos;
            var end = start;
            while (end < self.src.len) {
                const c = self.src[end];
                if (isBreak(c) or isBlank(c) or (self.flow_level > 0 and isFlowIndicator(c))) break;
                if (c == ':' and (end + 1 >= self.src.len or isBlank(self.src[end + 1]) or isBreak(self.src[end + 1]))) break;
                if (c == ':' and self.flow_level > 0 and end + 1 < self.src.len and isFlowIndicator(self.src[end + 1])) break;
                end += 1;
            }
            if (end > start and (end >= self.src.len or
                (self.src[end] == ':') or
                (self.flow_level > 0 and isFlowIndicator(self.src[end]))))
            {
                const len = end - start;
                self.pos = end;
                self.col += len;
                self.total_steps += len;
                try self.emit(.{ .tag = .scalar, .value = self.src[start..end], .style = .plain });
                return;
            }
        }

        var result: std.ArrayList(u8) = .{};
        var spaces: std.ArrayList(u8) = .{};
        var breaks: usize = 0;
        var plain_iterations: usize = 0;

        while (!self.eof()) {
            plain_iterations += 1;
            if (plain_iterations > self.src.len + 10) break;
            try self.checkRunaway();
            const c = self.ch();

            // End conditions
            if (c == ':' and self.isBlankOrBreakOrEofAt(1)) break;
            if (c == ':' and self.flow_level > 0 and (self.isBlankOrBreakOrEofAt(1) or isFlowIndicator(self.chAt(1)))) break;
            if (self.flow_level > 0 and isFlowIndicator(c)) break;
            if (c == '#' and self.pos > 0 and isBlank(self.src[self.pos - 1])) break;

            if (isBreak(c)) {
                if (self.flow_level > 0) {
                    // Flow context: continue scalar across newlines per YAML spec
                    // Save position in case we need to back up
                    const saved_pos = self.pos;
                    const saved_line = self.line;
                    const saved_col = self.col;
                    self.skipBreak();
                    while (!self.eof() and self.ch() == ' ') self.step();
                    if (self.eof()) break;
                    if (isBreak(self.ch())) { breaks += 1; spaces.items.len = 0; continue; }
                    // Check for end conditions — restore position if breaking
                    if (isFlowIndicator(self.ch()) or self.ch() == '#' or
                        (self.ch() == ':' and (self.isBlankOrBreakOrEofAt(1) or isFlowIndicator(self.chAt(1)))))
                    {
                        self.pos = saved_pos;
                        self.line = saved_line;
                        self.col = saved_col;
                        break;
                    }
                    breaks += 1;
                    spaces.items.len = 0;
                    continue;
                }
                self.skipBreak();
                self.value_indicator_on_line = false;

                // Eat leading spaces on next line
                var next_indent: usize = 0;
                while (!self.eof() and self.ch() == ' ') {
                    next_indent += 1;
                    self.step();
                }

                // EOF after newline
                if (self.eof()) break;

                // Blank line - just count and continue
                if (isBreak(self.ch())) {
                    breaks += 1;
                    spaces.items.len = 0;
                    continue;
                }

                // Document indicators end plain scalar
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

                // Block indicators at or below current indent end plain scalar
                if (!self.eof()) {
                    const nc = self.ch();
                    const at_or_below_indent = @as(i32, @intCast(next_indent)) <= start_indent;
                    if (at_or_below_indent) {
                        self.pos -= next_indent;
                        self.col -= next_indent;
                        break;
                    }
                    // Block indicators stop the scalar only at or above scalar start column
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
                spaces.items.len = 0;
                continue;
            }

            if (isBlank(c)) {
                spaces.append(self.alloc, c) catch return error.OutOfMemory;
                self.step();
                continue;
            }

            // Emit accumulated whitespace
            if (breaks > 0) {
                if (breaks == 1) {
                    result.append(self.alloc, ' ') catch return error.OutOfMemory;
                } else {
                    var b: usize = 1;
                    while (b < breaks) : (b += 1) {
                        result.append(self.alloc, '\n') catch return error.OutOfMemory;
                    }
                }
                breaks = 0;
            } else if (spaces.items.len > 0) {
                result.appendSlice(self.alloc, spaces.items) catch return error.OutOfMemory;
            }
            spaces.items.len = 0;

            result.append(self.alloc, c) catch return error.OutOfMemory;
            self.step();
        }

        if (result.items.len > 0) {
            try self.emit(.{ .tag = .scalar, .value = result.items, .style = .plain });
        }
    }
};
