const std = @import("std");

pub const TokenTag = enum {
    string_literal,
    number_literal,
    boolean_literal,
    null_literal,
    identifier,
    dot,
    comma,
    lparen,
    rparen,
    lbracket,
    rbracket,
    exclamation, // !
    equal,       // ==
    not_equal,   // !=
    less,        // <
    less_equal,  // <=
    greater,     // >
    greater_equal, // >=
    and_op,      // &&
    or_op,       // ||
    eof,
};

pub const Token = struct {
    tag: TokenTag,
    value: []const u8,
    start: usize,
    end: usize,
};

pub const Lexer = struct {
    source: []const u8,
    pos: usize = 0,

    pub fn init(source: []const u8) Lexer {
        return .{ .source = source };
    }

    pub fn next(self: *Lexer) Token {
        self.skipWhitespace();
        if (self.pos >= self.source.len) return self.makeToken(.eof, "");

        const start = self.pos;
        const c = self.source[self.pos];
        self.pos += 1;

        switch (c) {
            '.' => return self.makeToken(.dot, self.source[start..self.pos]),
            ',' => return self.makeToken(.comma, self.source[start..self.pos]),
            '(' => return self.makeToken(.lparen, self.source[start..self.pos]),
            ')' => return self.makeToken(.rparen, self.source[start..self.pos]),
            '[' => return self.makeToken(.lbracket, self.source[start..self.pos]),
            ']' => return self.makeToken(.rbracket, self.source[start..self.pos]),
            '\'' => return self.stringLiteral(start),
            '!' => {
                if (self.match('=')) return self.makeToken(.not_equal, self.source[start..self.pos]);
                return self.makeToken(.exclamation, self.source[start..self.pos]);
            },
            '=' => {
                if (self.match('=')) return self.makeToken(.equal, self.source[start..self.pos]);
                return self.makeToken(.eof, "error"); // GHA doesn't use single =
            },
            '<' => {
                if (self.match('=')) return self.makeToken(.less_equal, self.source[start..self.pos]);
                return self.makeToken(.less, self.source[start..self.pos]);
            },
            '>' => {
                if (self.match('=')) return self.makeToken(.greater_equal, self.source[start..self.pos]);
                return self.makeToken(.greater, self.source[start..self.pos]);
            },
            '&' => {
                if (self.match('&')) return self.makeToken(.and_op, self.source[start..self.pos]);
                return self.makeToken(.eof, "error");
            },
            '|' => {
                if (self.match('|')) return self.makeToken(.or_op, self.source[start..self.pos]);
                return self.makeToken(.eof, "error");
            },
            '0'...'9' => return self.numberLiteral(start),
            'a'...'z', 'A'...'Z', '_' => return self.identifier(start),
            else => return self.makeToken(.eof, "error"),
        }
    }

    fn match(self: *Lexer, expected: u8) bool {
        if (self.pos >= self.source.len or self.source[self.pos] != expected) return false;
        self.pos += 1;
        return true;
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.pos < self.source.len and std.ascii.isWhitespace(self.source[self.pos])) {
            self.pos += 1;
        }
    }

    fn stringLiteral(self: *Lexer, start: usize) Token {
        while (self.pos < self.source.len and self.source[self.pos] != '\'') {
            self.pos += 1;
        }
        if (self.pos < self.source.len) self.pos += 1; // consume closing '
        return self.makeToken(.string_literal, self.source[start..self.pos]);
    }

    fn numberLiteral(self: *Lexer, start: usize) Token {
        while (self.pos < self.source.len and (std.ascii.isDigit(self.source[self.pos]) or self.source[self.pos] == '.')) {
            self.pos += 1;
        }
        return self.makeToken(.number_literal, self.source[start..self.pos]);
    }

    fn identifier(self: *Lexer, start: usize) Token {
        while (self.pos < self.source.len and (std.ascii.isAlphanumeric(self.source[self.pos]) or self.source[self.pos] == '_' or self.source[self.pos] == '-')) {
            self.pos += 1;
        }
        const value = self.source[start..self.pos];
        if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false")) return self.makeToken(.boolean_literal, value);
        if (std.mem.eql(u8, value, "null")) return self.makeToken(.null_literal, value);
        return self.makeToken(.identifier, value);
    }

    fn makeToken(self: *const Lexer, tag: TokenTag, value: []const u8) Token {
        return .{
            .tag = tag,
            .value = value,
            .start = self.pos - value.len,
            .end = self.pos,
        };
    }
};
