const std = @import("std");
const ast = @import("ast.zig");
const context = @import("../../context.zig");
const diag = @import("../../diagnostic.zig");
const ir = @import("../../ir.zig");

const Node = ast.Node;
const ContextEnv = context.ContextEnv;
const Diagnostic = diag.Diagnostic;
const Schema = ir.Schema;

pub const TypeChecker = struct {
    allocator: std.mem.Allocator,
    env: ?*const ContextEnv,
    diagnostics: *std.ArrayListUnmanaged(Diagnostic),
    span: diag.Span,

    pub fn check(self: *TypeChecker, node: *const Node) anyerror!*const Schema {
        switch (node.*) {
            .literal => |l| return self.checkLiteral(l),
            .variable => |v| return self.checkVariable(v),
            .unary => |u| return self.checkUnary(u),
            .binary => |b| return self.checkBinary(b),
            .index => |i| return self.checkIndex(i),
            .call => |c| return self.checkCall(c),
        }
    }

    fn checkLiteral(self: *TypeChecker, l: Node.Literal) !*const Schema {
        const primitive: ir.Primitive = switch (l) {
            .string => .string,
            .number => .number,
            .boolean => .boolean,
            .null_t => .null_t,
        };
        const s = try self.allocator.create(Schema);
        s.* = Schema{ .span = undefined, .kind = .{ .primitive = primitive }, .refinements = &.{}, .contexts = null };
        return s;
    }

    fn checkVariable(self: *TypeChecker, v: Node.Variable) !*const Schema {
        if (self.env) |e| {
            if (e.lookup(v.name)) |s| return s;
        }
        try self.emit("undefined_context", try std.fmt.allocPrint(self.allocator, "undefined context: {s}", .{v.name}));
        return self.anySchema();
    }

    fn checkUnary(self: *TypeChecker, u: Node.Unary) !*const Schema {
        _ = try self.check(u.expr);
        // Logical NOT returns boolean
        return self.primitiveSchema(.boolean);
    }

    fn checkBinary(self: *TypeChecker, b: Node.Binary) !*const Schema {
        _ = try self.check(b.left);
        _ = try self.check(b.right);
        // All current binary ops return boolean (comparison or logical)
        return self.primitiveSchema(.boolean);
    }

    fn checkIndex(self: *TypeChecker, i: Node.Index) !*const Schema {
        const expr_schema = try self.check(i.expr);
        
        // If expr is an object, and index is a string literal, we can look up the field
        if (i.index.* == .literal and i.index.literal == .string) {
            const field_name = i.index.literal.string;
            if (expr_schema.kind == .object) {
                var found_field: ?*Schema = null;
                for (expr_schema.kind.object.fields) |f| {
                    if (std.mem.eql(u8, f.name, field_name)) {
                        found_field = f.schema;
                        break;
                    }
                }
                if (found_field) |fs| return fs;
                try self.emit("undefined_property", try std.fmt.allocPrint(self.allocator, "undefined property: {s}", .{field_name}));
            }
        }

        return self.anySchema();
    }

    fn checkCall(self: *TypeChecker, c: Node.Call) !*const Schema {
        for (c.args) |*arg| _ = try self.check(arg);
        // Functions usually return any/string for now
        return self.anySchema();
    }

    fn anySchema(self: *TypeChecker) !*const Schema {
        return self.primitiveSchema(.any);
    }

    fn primitiveSchema(self: *TypeChecker, p: ir.Primitive) !*const Schema {
        const s = try self.allocator.create(Schema);
        s.* = Schema{ .span = undefined, .kind = .{ .primitive = p }, .refinements = &.{}, .contexts = null };
        return s;
    }

    fn emit(self: *TypeChecker, code: []const u8, message: []const u8) !void {
        try self.diagnostics.append(self.allocator, .{
            .severity = .err,
            .span = self.span,
            .code = try self.allocator.dupe(u8, code),
            .message = message,
            .related = &.{},
            .suggestions = &.{},
        });
    }
};
