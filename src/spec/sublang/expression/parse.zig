const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");

const Node = ast.Node;
const Token = lexer.Token;
const TokenTag = lexer.TokenTag;
const Lexer = lexer.Lexer;

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: Lexer,
    current_token: Token,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        var p = Parser{
            .allocator = allocator,
            .lexer = Lexer.init(source),
            .current_token = undefined,
        };
        p.current_token = p.lexer.next();
        return p;
    }

    fn advance(self: *Parser) void {
        self.current_token = self.lexer.next();
    }

    fn match(self: *Parser, tag: TokenTag) bool {
        if (self.current_token.tag == tag) {
            self.advance();
            return true;
        }
        return false;
    }

    fn expect(self: *Parser, tag: TokenTag) !void {
        if (!self.match(tag)) return error.UnexpectedToken;
    }

    pub fn parse(self: *Parser) !Node {
        const node = try self.parseExpression();
        try self.expect(.eof);
        return node;
    }

    fn parseExpression(self: *Parser) anyerror!Node {
        return self.parseOr();
    }

    fn parseOr(self: *Parser) anyerror!Node {
        var left = try self.parseAnd();
        while (self.match(.or_op)) {
            const right = try self.parseAnd();
            const left_ptr = try self.allocator.create(Node);
            left_ptr.* = left;
            const right_ptr = try self.allocator.create(Node);
            right_ptr.* = right;
            left = .{ .binary = .{ .op = .or_op, .left = left_ptr, .right = right_ptr } };
        }
        return left;
    }

    fn parseAnd(self: *Parser) anyerror!Node {
        var left = try self.parseEquality();
        while (self.match(.and_op)) {
            const right = try self.parseEquality();
            const left_ptr = try self.allocator.create(Node);
            left_ptr.* = left;
            const right_ptr = try self.allocator.create(Node);
            right_ptr.* = right;
            left = .{ .binary = .{ .op = .and_op, .left = left_ptr, .right = right_ptr } };
        }
        return left;
    }

    fn parseEquality(self: *Parser) anyerror!Node {
        var left = try self.parseComparison();
        while (true) {
            const op: ?ast.Node.BinaryOp = if (self.match(.equal)) .eq else if (self.match(.not_equal)) .neq else null;
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

    fn parseComparison(self: *Parser) anyerror!Node {
        var left = try self.parseUnary();
        while (true) {
            const op: ?ast.Node.BinaryOp = if (self.match(.less)) .lt else if (self.match(.less_equal)) .lte else if (self.match(.greater)) .gt else if (self.match(.greater_equal)) .gte else null;
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

    fn parseUnary(self: *Parser) anyerror!Node {
        if (self.match(.exclamation)) {
            const expr = try self.parseUnary();
            const expr_ptr = try self.allocator.create(Node);
            expr_ptr.* = expr;
            return .{ .unary = .{ .op = .not, .expr = expr_ptr } };
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) anyerror!Node {
        var node = try self.parseOperand();
        while (true) {
            if (self.match(.dot)) {
                const id = self.current_token;
                try self.expect(.identifier);
                const node_ptr = try self.allocator.create(Node);
                node_ptr.* = node;
                const index_node = try self.allocator.create(Node);
                index_node.* = .{ .literal = .{ .string = try self.allocator.dupe(u8, id.value) } };
                node = .{ .index = .{ .expr = node_ptr, .index = index_node } };
            } else if (self.match(.lbracket)) {
                const idx = try self.parseExpression();
                try self.expect(.rbracket);
                const node_ptr = try self.allocator.create(Node);
                node_ptr.* = node;
                const index_node = try self.allocator.create(Node);
                index_node.* = idx;
                node = .{ .index = .{ .expr = node_ptr, .index = index_node } };
            } else if (self.match(.lparen)) {
                // Call
                if (node != .variable) return error.InvalidCall;
                var args = std.ArrayListUnmanaged(Node){};
                if (self.current_token.tag != .rparen) {
                    while (true) {
                        try args.append(self.allocator, try self.parseExpression());
                        if (!self.match(.comma)) break;
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

    fn parseOperand(self: *Parser) anyerror!Node {
        const token = self.current_token;
        switch (token.tag) {
            .string_literal => {
                self.advance();
                // strip quotes
                const s = token.value[1 .. token.value.len - 1];
                return .{ .literal = .{ .string = try self.allocator.dupe(u8, s) } };
            },
            .number_literal => {
                self.advance();
                const n = try std.fmt.parseFloat(f64, token.value);
                return .{ .literal = .{ .number = n } };
            },
            .boolean_literal => {
                self.advance();
                return .{ .literal = .{ .boolean = std.mem.eql(u8, token.value, "true") } };
            },
            .null_literal => {
                self.advance();
                return .{ .literal = .null_t };
            },
            .identifier => {
                self.advance();
                return .{ .variable = .{ .name = try self.allocator.dupe(u8, token.value) } };
            },
            .lparen => {
                self.advance();
                const node = try self.parseExpression();
                try self.expect(.rparen);
                return node;
            },
            else => return error.UnexpectedToken,
        }
    }
};
