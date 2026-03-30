const token = @import("token.zig");
const value = @import("value.zig");

const Token = token.Token;
const TokenTag = token.TokenTag;
const ParseError = value.ParseError;

pub const Parser = struct {
    tokens: []const Token,
    pos: usize = 0,

    fn peek(self: *Parser) ?TokenTag {
        return if (self.pos < self.tokens.len) self.tokens[self.pos].tag else null;
    }

    fn advance(self: *Parser) void {
        if (self.pos < self.tokens.len) self.pos += 1;
    }

    pub fn validate(self: *Parser) ParseError!void {
        if (self.peek() != .stream_start) return error.InvalidYaml;
        self.advance();

        var iters: usize = 0;
        while (self.peek()) |t| {
            iters += 1;
            if (iters > self.tokens.len * 2 + 100) return error.InvalidYaml;
            if (t == .stream_end) break;
            try self.parseDocument();
        }
    }

    fn parseDocument(self: *Parser) ParseError!void {
        while (self.peek()) |t| {
            if (t == .document_start or t == .document_end) {
                self.advance();
            } else break;
        }

        if (self.peek()) |t| {
            if (t == .stream_end) return;
            try self.parseNode();
        }

        // After root node, only document boundaries are valid
        while (self.peek()) |t| {
            if (t == .block_end) { self.advance(); } else break;
        }
        if (self.peek()) |t| {
            if (t != .document_start and t != .document_end and t != .stream_end) {
                return error.InvalidYaml;
            }
        }

        while (self.peek()) |t| {
            if (t == .document_end) { self.advance(); } else break;
        }
    }

    fn parseNode(self: *Parser) ParseError!void {
        // Skip anchors and tags
        while (self.peek()) |t| {
            if (t == .anchor or t == .tag) { self.advance(); } else break;
        }

        const t = self.peek() orelse return;
        switch (t) {
            .scalar, .alias => self.advance(),
            .block_sequence_start => try self.parseBlockSeq(),
            .block_mapping_start => try self.parseBlockMap(),
            .flow_sequence_start => try self.parseFlowSeq(),
            .flow_mapping_start => try self.parseFlowMap(),
            .key_token => {},
            .block_entry => {
                // Block entry without preceding block_sequence_start
                // Parse as inline sequence entries
                var entry_iters: usize = 0;
                while (self.peek()) |nt| {
                    entry_iters += 1;
                    if (entry_iters > self.tokens.len * 2 + 100) return error.InvalidYaml;
                    if (nt == .block_entry) {
                        self.advance();
                        if (self.peek()) |nx| {
                            if (nx != .block_end and nx != .block_entry and nx != .document_start and nx != .stream_end) {
                                try self.parseNode();
                            }
                        }
                    } else if (nt == .block_end) {
                        break;
                    } else break;
                }
            },
            .block_end, .value_token, .flow_entry,
            .flow_sequence_end, .flow_mapping_end,
            .document_start, .document_end, .stream_end => {},
            else => self.advance(),
        }
    }

    fn parseBlockSeq(self: *Parser) ParseError!void {
        self.advance();
        var iters: usize = 0;
        while (self.peek()) |t| {
            iters += 1;
            if (iters > self.tokens.len * 2 + 100) return error.InvalidYaml;
            if (t == .block_end) { self.advance(); return; }
            if (t == .block_entry) {
                self.advance();
                if (self.peek()) |nt| {
                    if (nt != .block_end and nt != .block_entry) {
                        try self.parseNode();
                    }
                }
            } else {
                return error.InvalidYaml;
            }
        }
    }

    fn parseBlockMap(self: *Parser) ParseError!void {
        if (self.peek() == .block_mapping_start) self.advance();
        var iters: usize = 0;
        while (self.peek()) |t| {
            iters += 1;
            if (iters > self.tokens.len * 2 + 100) return error.InvalidYaml;
            if (t == .block_end) { self.advance(); return; }
            if (t == .key_token) {
                self.advance();
                if (self.peek()) |nt| {
                    if (nt != .value_token and nt != .key_token and nt != .block_end) {
                        try self.parseNode();
                    }
                }
                if (self.peek() == .value_token) {
                    self.advance();
                    if (self.peek()) |nt| {
                        if (nt != .key_token and nt != .block_end) {
                            try self.parseNode();
                        }
                    }
                }
            } else if (t == .value_token) {
                // Standalone value without key
                self.advance();
                if (self.peek()) |nt| {
                    if (nt != .key_token and nt != .block_end) {
                        try self.parseNode();
                    }
                }
            } else {
                return error.InvalidYaml;
            }
        }
    }

    fn parseFlowSeq(self: *Parser) ParseError!void {
        self.advance(); // flow_sequence_start
        var first = true;
        while (self.peek()) |t| {
            if (t == .flow_sequence_end) { self.advance(); return; }
            if (t == .stream_end) return error.InvalidYaml;
            if (!first) {
                if (t == .flow_entry) {
                    self.advance();
                    if (self.peek() == .flow_sequence_end) { self.advance(); return; }
                } else {
                    return error.InvalidYaml; // Missing comma
                }
            }
            first = false;
            try self.parseFlowEntry();
        }
        return error.InvalidYaml;
    }

    fn parseFlowMap(self: *Parser) ParseError!void {
        self.advance(); // flow_mapping_start
        var first = true;
        while (self.peek()) |t| {
            if (t == .flow_mapping_end) { self.advance(); return; }
            if (t == .stream_end) return error.InvalidYaml;
            if (!first) {
                if (t == .flow_entry) {
                    self.advance();
                    if (self.peek() == .flow_mapping_end) { self.advance(); return; }
                } else {
                    return error.InvalidYaml; // Missing comma
                }
            }
            first = false;
            try self.parseFlowEntry();
        }
        return error.InvalidYaml;
    }

    fn parseFlowEntry(self: *Parser) ParseError!void {
        // Consume exactly one flow entry: [key :] value
        var depth: usize = 0;
        var had_key = false;
        var had_value_indicator = false;
        var had_content = false;
        var iters: usize = 0;

        while (self.peek()) |t| {
            iters += 1;
            if (iters > self.tokens.len * 2 + 100) return error.InvalidYaml;

            switch (t) {
                .flow_sequence_start, .flow_mapping_start => { depth += 1; self.advance(); },
                .flow_sequence_end, .flow_mapping_end => {
                    if (depth == 0) return;
                    depth -= 1;
                    self.advance();
                    if (depth == 0) had_content = true;
                },
                .flow_entry => {
                    if (depth == 0) return;
                    self.advance();
                },
                .stream_end => return error.InvalidYaml,
                .key_token => {
                    if (depth == 0) had_key = true;
                    self.advance();
                },
                .value_token => {
                    if (depth == 0) {
                        // Value indicator after content without key = stale key error
                        if (had_content and !had_key) return error.InvalidYaml;
                        if (had_value_indicator and had_content) {
                            // Second value indicator after content = new entry without comma
                            return error.InvalidYaml;
                        }
                        had_value_indicator = true;
                        had_content = false;
                    }
                    self.advance();
                },
                .scalar, .alias => {
                    if (depth == 0) {
                        if (had_content and !had_key and !had_value_indicator) return;
                        had_content = true;
                    }
                    self.advance();
                },
                .anchor, .tag => self.advance(),
                else => self.advance(),
            }
        }
    }
};
