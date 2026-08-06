const std = @import("std");

pub fn main() !void {
    try generateLargeList("bench/data/large_list.yml", 50000);
    try generateLargeMap("bench/data/large_map.yml", 50000);
    try generateDeeplyNested("bench/data/deeply_nested.yml", 1000);
    try generateLargeRecipe("bench/data/large_recipe.yml", 5000);
    try generateChaos("bench/data/chaos.yml");
}

fn generateChaos(path: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    
    try file.writeAll(
        \\# Chaos
        \\---
        \\chaos: yes
        \\anchors:
        \\  - &v1 h
        \\  - *v1
        \\  - &val1 h
        \\  - *val1
        \\quotes:
        \\  - "Double quoted: \n \t \x41"
        \\  - 'Single quoted: ''quote'''
        \\scalars:
        \\  l: |
        \\    line 1
        \\    line 2
        \\  f: >
        \\    word 1
        \\    word 2
        \\flow:
        \\  - [a, b, {c: d}]
        \\  - {e: [f, g], h: i}
        \\complex:
        \\  ? key
        \\  : value
        \\nesting:
    );

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try file.writeAll("\n  - level1:");
        var j: usize = 0;
        while (j < 10) : (j += 1) {
            try file.writeAll("\n      - item");
        }
    }
}

fn generateLargeRecipe(path: []const u8, step_count: usize) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    
    try file.writeAll("name: large-recipe\ndescription: A very large recipe for benchmarking\n\nsteps:\n");
    var i: usize = 0;
    while (i < step_count) : (i += 1) {
        var buf: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "  - name: Step {d}\n    run: echo \"running step {d}\"\n    if: os == 'linux'\n", .{ i, i });
        try file.writeAll(line);
    }
}

fn generateLargeList(path: []const u8, count: usize) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    
    try file.writeAll("items:\n");
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var buf: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "  - item_{d}\n", .{ i });
        try file.writeAll(line);
    }
}

fn generateLargeMap(path: []const u8, count: usize) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var buf: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "key_{d}: value_{d}\n", .{ i, i });
        try file.writeAll(line);
    }
}

fn generateDeeplyNested(path: []const u8, depth: usize) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        var j: usize = 0;
        while (j < i) : (j += 1) try file.writeAll("  ");
        var buf: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "level_{d}:\n", .{ i });
        try file.writeAll(line);
    }
    var j: usize = 0;
    while (j < depth) : (j += 1) try file.writeAll("  ");
    try file.writeAll("leaf: value\n");
}
