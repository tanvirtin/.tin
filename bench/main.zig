const std = @import("std");
const yaml = @import("yaml");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var is_parser_mode = false;
    var file_path: ?[]const u8 = null;
    var iterations: usize = 100;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--parser-mode")) {
            is_parser_mode = true;
        } else if (std.mem.eql(u8, args[i], "-f")) {
            i += 1;
            if (i < args.len) file_path = args[i];
        } else if (std.mem.eql(u8, args[i], "-i")) {
            i += 1;
            if (i < args.len) iterations = std.fmt.parseInt(usize, args[i], 10) catch 100;
        }
    }

    if (is_parser_mode) {
        if (file_path) |path| {
            try runParserMode(allocator, path, iterations);
        } else {
            std.debug.print("Error: -f <file_path> required in --parser-mode\n", .{});
            std.process.exit(1);
        }
        return;
    }

    try runOrchestrator(allocator, args);
}

fn runParserMode(allocator: std.mem.Allocator, path: []const u8, iterations: usize) !void {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("Failed to open file: {}\n", .{err});
        std.process.exit(1);
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 50 * 1024 * 1024);
    defer allocator.free(content);

    // Warmup
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        _ = yaml.parse(arena.allocator(), content) catch {};
    }

    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        _ = yaml.parse(arena.allocator(), content) catch {};
    }
    const total_time = timer.read();
    const avg_ns = total_time / iterations;
    std.debug.print("{d}\n", .{avg_ns});
}

const ParserCmd = struct {
    name: []const u8,
    cmd: []const u8,
};

fn runOrchestrator(allocator: std.mem.Allocator, args: [][:0]u8) !void {
    var parsers: [32]ParserCmd = undefined;
    var parsers_len: usize = 0;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--parsers")) {
            i += 1;
            if (i < args.len) {
                var it = std.mem.splitScalar(u8, args[i], ',');
                while (it.next()) |parser_str| {
                    var parts = std.mem.splitScalar(u8, parser_str, '=');
                    const name = parts.next() orelse continue;
                    const cmd = parts.next() orelse continue;
                    if (parsers_len < parsers.len) {
                        parsers[parsers_len] = .{ .name = name, .cmd = cmd };
                        parsers_len += 1;
                    }
                }
            }
        }
    }

    var self_cmd_alloc: ?[]const u8 = null;
    defer if (self_cmd_alloc) |p| allocator.free(p);

    if (parsers_len == 0) {
        const self_exe = try std.fs.selfExePathAlloc(allocator);
        defer allocator.free(self_exe);
        self_cmd_alloc = try std.fmt.allocPrint(allocator, "{s} --parser-mode", .{self_exe});
        parsers[parsers_len] = .{ .name = "tin", .cmd = self_cmd_alloc.? };
        parsers_len += 1;
    }
    
    const active_parsers = parsers[0..parsers_len];

    const datasets = [_][]const u8{
        "large_list.yml",
        "large_map.yml",
        "deeply_nested.yml",
        "large_recipe.yml",
        "chaos.yml",
    };

    std.debug.print("Running Benchmarks...\n\n", .{});

    std.debug.print("{s:<20}", .{"Dataset"});
    for (active_parsers) |p| {
        std.debug.print(" | {s:^21}", .{p.name});
    }
    std.debug.print("\n", .{});
    
    std.debug.print("{s:-<20}", .{""});
    for (active_parsers) |_| {
        std.debug.print("-|-{s:-<21}", .{""});
    }
    std.debug.print("\n", .{});

    var total_ns_per_parser = try allocator.alloc(u64, active_parsers.len);
    defer allocator.free(total_ns_per_parser);
    @memset(total_ns_per_parser, 0);

    for (datasets) |ds| {
        const path = try std.fmt.allocPrint(allocator, "bench/data/{s}", .{ds});
        defer allocator.free(path);

        const file = std.fs.cwd().openFile(path, .{}) catch {
            std.debug.print("{s:<20} | [Missing]\n", .{ds});
            continue;
        };
        const stat = try file.stat();
        file.close();
        const size_mb = @as(f64, @floatFromInt(stat.size)) / (1024.0 * 1024.0);

        std.debug.print("{s:<20}", .{ds});

        for (active_parsers, 0..) |p, p_idx| {
            var cmd_list: [32][]const u8 = undefined;
            var cmd_list_len: usize = 0;

            var cmd_it = std.mem.splitScalar(u8, p.cmd, ' ');
            while (cmd_it.next()) |part| {
                if (part.len > 0 and cmd_list_len < cmd_list.len) {
                    cmd_list[cmd_list_len] = part;
                    cmd_list_len += 1;
                }
            }
            if (cmd_list_len + 4 <= cmd_list.len) {
                cmd_list[cmd_list_len] = "-f";
                cmd_list[cmd_list_len+1] = path;
                cmd_list[cmd_list_len+2] = "-i";
                cmd_list[cmd_list_len+3] = "100";
                cmd_list_len += 4;
            }

            var child = std.process.Child.init(cmd_list[0..cmd_list_len], allocator);
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Pipe;
            try child.spawn();

            const output = try child.stderr.?.readToEndAlloc(allocator, 1024);
            defer allocator.free(output);
            
            _ = try child.wait();

            const trimmed = std.mem.trim(u8, output, " \r\n");
            if (std.fmt.parseInt(u64, trimmed, 10)) |avg_ns| {
                total_ns_per_parser[p_idx] += avg_ns;
                const avg_ms = @as(f64, @floatFromInt(avg_ns)) / 1_000_000.0;
                const throughput = size_mb / (@as(f64, @floatFromInt(avg_ns)) / 1_000_000_000.0);
                std.debug.print(" | {d:>8.2}ms {d:>6.1}MB/s", .{avg_ms, throughput});
            } else |_| {
                std.debug.print(" | {s:>21}", .{"ERROR"});
            }
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("{s:-<20}", .{""});
    for (active_parsers) |_| {
        std.debug.print("-|-{s:-<21}", .{""});
    }
    std.debug.print("\n", .{});
    
    std.debug.print("{s:<20}", .{"TOTAL SCORE"});
    for (active_parsers, 0..) |p, p_idx| {
        _ = p;
        const total_s = @as(f64, @floatFromInt(total_ns_per_parser[p_idx])) / 1_000_000_000.0;
        std.debug.print(" | {d:>18.3} s ", .{total_s});
    }
    std.debug.print("\n\n", .{});
    std.debug.print("To compare with other parsers, use: bench --parsers tin=\"bench --parser-mode\",other=\"./other_bench\"\n", .{});
}
