const std = @import("std");
const value_mod = @import("value.zig");

const Value = value_mod.Value;
const ParseError = value_mod.ParseError;

pub const DecodeError = error{
    InvalidYaml,
    OutOfMemory,
    TypeMismatch,
    MissingField,
};

pub fn decode(comptime T: type, allocator: std.mem.Allocator, val: Value) DecodeError!T {
    const info = @typeInfo(T);

    if (info == .optional) {
        return decode(info.optional.child, allocator, val) catch return null;
    }

    if (T == []const u8) {
        const s = val.getString() orelse return DecodeError.TypeMismatch;
        return allocator.dupe(u8, s) catch return DecodeError.OutOfMemory;
    }

    if (T == bool) {
        const s = val.getString() orelse return DecodeError.TypeMismatch;
        if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "yes") or std.mem.eql(u8, s, "on")) return true;
        if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "no") or std.mem.eql(u8, s, "off")) return false;
        return DecodeError.TypeMismatch;
    }

    if (info == .int) {
        const s = val.getString() orelse return DecodeError.TypeMismatch;
        return std.fmt.parseInt(T, s, 10) catch return DecodeError.TypeMismatch;
    }

    if (info == .float) {
        const s = val.getString() orelse return DecodeError.TypeMismatch;
        return std.fmt.parseFloat(T, s) catch return DecodeError.TypeMismatch;
    }

    if (info == .@"enum") {
        const s = val.getString() orelse return DecodeError.TypeMismatch;
        return std.meta.stringToEnum(T, s) orelse return DecodeError.TypeMismatch;
    }

    if (info == .pointer and info.pointer.size == .slice and info.pointer.is_const) {
        const Child = info.pointer.child;

        if (Child == u8) {
            const s = val.getString() orelse return DecodeError.TypeMismatch;
            return allocator.dupe(u8, s) catch return DecodeError.OutOfMemory;
        }

        const seq = val.getSequence() orelse return DecodeError.TypeMismatch;
        var items: std.ArrayListUnmanaged(Child) = .{};
        defer items.deinit(allocator);
        
        for (seq) |item| {
            const decoded = try decode(Child, allocator, item);
            try items.append(allocator, decoded);
        }
        return items.toOwnedSlice(allocator) catch return DecodeError.OutOfMemory;
    }

    if (info == .@"struct") {
        var result: T = undefined;

        inline for (info.@"struct".fields) |field| {
            const field_val = val.getMapping(field.name);

            if (field_val) |fv| {
                @field(result, field.name) = try decode(field.type, allocator, fv);
            } else if (@typeInfo(field.type) == .optional) {
                @field(result, field.name) = null;
            } else if (field.default_value_ptr) |ptr| {
                const default = @as(*const field.type, @ptrCast(@alignCast(ptr)));
                @field(result, field.name) = default.*;
            } else {
                return DecodeError.MissingField;
            }
        }

        return result;
    }

    return DecodeError.TypeMismatch;
}
