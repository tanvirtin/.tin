const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");

const Node = ast.Node;
const Token = lexer.Token;
const TokenTag = lexer.TokenTag;
const Lexer = lexer.Lexer;

pub const MAX_TOKENS = 1024;
pub const MAX_DEPTH = 128;

pub const ParseError = error{ OutOfMemory, TooManyTokens, TooDeep, InvalidCall, UnexpectedToken };

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: Lexer,
    current_token: Token,
    depth: usize = 0,
    token_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        var p = Parser{
            .allocator = allocator,
            .lexer = Lexer.init(source),
            .current_token = undefined,
        };
        p.current_token = p.lexer.next();
        p.token_count = 1;
        return p;
    }

    fn advance(self: *Parser) !void {
        self.token_count += 1;
        if (self.token_count > MAX_TOKENS) return error.TooManyTokens;
        self.current_token = self.lexer.next();
    }

    fn match(self: *Parser, tag: TokenTag) !bool {
        if (self.current_token.tag == tag) {
            try self.advance();
            return true;
        }
        return false;
    }

    fn expect(self: *Parser, tag: TokenTag) !void {
        if (!try self.match(tag)) return error.UnexpectedToken;
    }

    pub fn parse(self: *Parser) ParseError!Node {
        const node = try self.parseExpression();
        try self.expect(.eof);
        return node;
    }

    fn parseExpression(self: *Parser) ParseError!Node {
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > MAX_DEPTH) return error.TooDeep;
        return self.parseOr();
    }

    fn parseOr(self: *Parser) ParseError!Node {
        var left = try self.parseAnd();
        while (try self.match(.or_op)) {
            const right = try self.parseAnd();
            const left_ptr = try self.allocator.create(Node);
            left_ptr.* = left;
            const right_ptr = try self.allocator.create(Node);
            right_ptr.* = right;
            left = .{ .binary = .{ .op = .or_op, .left = left_ptr, .right = right_ptr } };
        }
        return left;
    }

    fn parseAnd(self: *Parser) ParseError!Node {
        var left = try self.parseEquality();
        while (try self.match(.and_op)) {
            const right = try self.parseEquality();
            const left_ptr = try self.allocator.create(Node);
            left_ptr.* = left;
            const right_ptr = try self.allocator.create(Node);
            right_ptr.* = right;
            left = .{ .binary = .{ .op = .and_op, .left = left_ptr, .right = right_ptr } };
        }
        return left;
    }

    fn parseEquality(self: *Parser) ParseError!Node {
        var left = try self.parseComparison();
        while (true) {
            const op: ?ast.Node.BinaryOp = if (try self.match(.equal)) .eq else if (try self.match(.not_equal)) .neq else null;
            if (op == null) break;
            const right = try self.parseComparison();
            const left_ptr = try self.allocator.create(Node);
            left_ptr.* = left;
            const right_ptr = try self.allocator.create(Node);
            right_ptr.* = right;
            left = .{ .binary = .{ .op = op.?, .left = left_ptr, .right = right_ptr } };
        }
        return left;
    }

    fn parseComparison(self: *Parser) ParseError!Node {
        var left = try self.parseUnary();
        while (true) {
            const op: ?ast.Node.BinaryOp = if (try self.match(.less)) .lt else if (try self.match(.less_equal)) .lte else if (try self.match(.greater)) .gt else if (try self.match(.greater_equal)) .gte else null;
            if (op == null) break;
            const right = try self.parseUnary();
            const left_ptr = try self.allocator.create(Node);
            left_ptr.* = left;
            const right_ptr = try self.allocator.create(Node);
            right_ptr.* = right;
            left = .{ .binary = .{ .op = op.?, .left = left_ptr, .right = right_ptr } };
        }
        return left;
    }

    fn parseUnary(self: *Parser) ParseError!Node {
        if (try self.match(.exclamation)) {
            self.depth += 1;
            defer self.depth -= 1;
            if (self.depth > MAX_DEPTH) return error.TooDeep;
            const expr = try self.parseUnary();
            const expr_ptr = try self.allocator.create(Node);
            expr_ptr.* = expr;
            return .{ .unary = .{ .op = .not, .expr = expr_ptr } };
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) ParseError!Node {
        var node = try self.parseOperand();
        while (true) {
            if (try self.match(.dot)) {
                const id = self.current_token;
                try self.expect(.identifier);
                const node_ptr = try self.allocator.create(Node);
                node_ptr.* = node;
                const index_node = try self.allocator.create(Node);
                index_node.* = .{ .literal = .{ .string = try self.allocator.dupe(u8, id.value) } };
                node = .{ .index = .{ .expr = node_ptr, .index = index_node } };
            } else if (try self.match(.lbracket)) {
                const idx = try self.parseExpression();
                try self.expect(.rbracket);
                const node_ptr = try self.allocator.create(Node);
                node_ptr.* = node;
                const index_node = try self.allocator.create(Node);
                index_node.* = idx;
                node = .{ .index = .{ .expr = node_ptr, .index = index_node } };
            } else if (try self.match(.lparen)) {
                if (node != .variable) return error.InvalidCall;
                var args = std.ArrayListUnmanaged(Node){};
                if (self.current_token.tag != .rparen) {
                    while (true) {
                        try args.append(self.allocator, try self.parseExpression());
                        if (!try self.match(.comma)) break;
                    }
                }
                try self.expect(.rparen);
                const func_name = try self.allocator.dupe(u8, node.variable.name);
                node = .{ .call = .{ .func = func_name, .args = try args.toOwnedSlice(self.allocator) } };
            } else {
                break;
            }
        }
        return node;
    }

    fn parseOperand(self: *Parser) ParseError!Node {
        const token = self.current_token;
        switch (token.tag) {
            .string_literal => {
                try self.advance();
                const s = token.value[1 .. token.value.len - 1];
                return .{ .literal = .{ .string = try self.allocator.dupe(u8, s) } };
            },
.number_literal => {
                try self.advance();
                const n = std.fmt.parseFloat(f64, token.value) catch return error.UnexpectedToken;
                return .{ .literal = .{ .number = n } };
            },
            .boolean_literal => {
                try self.advance();
                return .{ .literal = .{ .boolean = std.mem.eql(u8, token.value, "true") } };
            },
            .null_literal => {
                try self.advance();
                return .{ .literal = .null_t };
            },
            .identifier => {
                try self.advance();
                return .{ .variable = .{ .name = try self.allocator.dupe(u8, token.value) } };
            },
            .lparen => {
                try self.advance();
                const node = try self.parseExpression();
                try self.expect(.rparen);
                return node;
            },
            else => return error.UnexpectedToken,
        }
    }
};
