const std = @import("std");
const yaml = @import("yaml");

const ParserCmd = struct {
    name: []const u8,
    cmd: []const u8,
};

const Dataset = struct {
    name: []const u8,
    path: []const u8,
};

const Options = struct {
    is_parser_mode: bool,
    file_path: ?[]const u8,
    iterations: usize,
    parsers: []const ParserCmd,
};

fn parseArgs(args: [][:0]u8) Options {
    var is_parser_mode = false;
    var file_path: ?[]const u8 = null;
    var iterations: usize = 100;
    var parser_store: [32]ParserCmd = undefined;
    var parsers_len: usize = 0;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--parser-mode")) {
            is_parser_mode = true;
        } else if (std.mem.eql(u8, args[i], "-f")) {
            i += 1;
            if (i < args.len) file_path = args[i];
        } else if (std.mem.eql(u8, args[i], "-i")) {
            i += 1;
            if (i < args.len) {
                iterations = std.fmt.parseInt(usize, args[i], 10) catch 100;
            }
        } else if (std.mem.eql(u8, args[i], "--parsers")) {
            i += 1;
            if (i < args.len) {
                var it = std.mem.splitScalar(u8, args[i], ',');
                while (it.next()) |parser_str| {
                    if (parser_str.len == 0) continue;
                    var parts = std.mem.splitScalar(u8, parser_str, '=');
                    const name = parts.next() orelse continue;
                    const cmd = parts.next() orelse continue;
                    if (parsers_len < parser_store.len) {
                        parser_store[parsers_len] = .{ .name = name, .cmd = cmd };
                        parsers_len += 1;
                    }
                }
            }
        }
    }

    return .{
        .is_parser_mode = is_parser_mode,
        .file_path = file_path,
        .iterations = iterations,
        .parsers = parser_store[0..parsers_len],
    };
}

fn runParserMode(allocator: std.mem.Allocator, path: []const u8, iterations: usize) !void {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("Failed to open file: {}\n", .{err});
        std.process.exit(1);
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 50 * 1024 * 1024) catch |err| {
        std.debug.print("Failed to read file: {}\n", .{err});
        std.process.exit(1);
    };
    defer allocator.free(content);

    if (iterations == 0) {
        std.debug.print("0\n", .{});
        return;
    }

    var warmup_arena = std.heap.ArenaAllocator.init(allocator);
    defer warmup_arena.deinit();
    _ = yaml.parse(warmup_arena.allocator(), content) catch {};

    var timer = try std.time.Timer.start();
    var it: usize = 0;
    while (it < iterations) : (it += 1) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        _ = yaml.parse(arena.allocator(), content) catch {};
    }
    const total_time = timer.read();
    const avg_ns = total_time / iterations;
    std.debug.print("{d}\n", .{avg_ns});
}

fn buildSelfParserCmd(allocator: std.mem.Allocator) !ParserCmd {
    const self_exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_exe);
    const cmd = try std.fmt.allocPrint(allocator, "{s} --parser-mode", .{self_exe});
    return .{ .name = "tin", .cmd = cmd };
}

fn runChildParser(allocator: std.mem.Allocator, cmd_str: []const u8, path: []const u8) !u64 {
    var cmd_list: [32][]const u8 = undefined;
    var cmd_list_len: usize = 0;

    var cmd_it = std.mem.splitScalar(u8, cmd_str, ' ');
    while (cmd_it.next()) |part| {
        if (part.len > 0 and cmd_list_len < cmd_list.len) {
            cmd_list[cmd_list_len] = part;
            cmd_list_len += 1;
        }
    }
    if (cmd_list_len + 4 <= cmd_list.len) {
        cmd_list[cmd_list_len] = "-f";
        cmd_list[cmd_list_len + 1] = path;
        cmd_list[cmd_list_len + 2] = "-i";
        cmd_list[cmd_list_len + 3] = "100";
        cmd_list_len += 4;
    }

    var child = std.process.Child.init(cmd_list[0..cmd_list_len], allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    const output = child.stderr.?.readToEndAlloc(allocator, 4096) catch |err| {
        _ = child.kill() catch {};
        return err;
    };
    defer allocator.free(output);

    _ = try child.wait();

    const trimmed = std.mem.trim(u8, output, " \r\n\t");
    if (trimmed.len == 0) return error.EmptyOutput;
    return std.fmt.parseInt(u64, trimmed, 10);
}

fn printTableHeader(parsers: []const ParserCmd) void {
    std.debug.print("{s:<20}", .{"Dataset"});
    for (parsers) |p| {
        std.debug.print(" | {s:^21}", .{p.name});
    }
    std.debug.print("\n", .{});
    std.debug.print("{s:-<20}", .{""});
    for (parsers) |_| {
        std.debug.print("-|-{s:-<21}", .{""});
    }
    std.debug.print("\n", .{});
}

fn printTableFooter(parsers: []const ParserCmd, total_ns: []const u64) void {
    std.debug.print("{s:-<20}", .{""});
    for (parsers) |_| {
        std.debug.print("-|-{s:-<21}", .{""});
    }
    std.debug.print("\n", .{});
    std.debug.print("{s:<20}", .{"TOTAL SCORE"});
    for (parsers, 0..) |_, i| {
        const total_s = @as(f64, @floatFromInt(total_ns[i])) / 1_000_000_000.0;
        std.debug.print(" | {d:>18.3} s ", .{total_s});
    }
    std.debug.print("\n\n", .{});
    std.debug.print("To compare with other parsers, use: bench --parsers tin=\"bench --parser-mode\",other=\"./other_bench\"\n", .{});
}

fn runOrchestrator(allocator: std.mem.Allocator, user_parsers: []const ParserCmd) !void {
    var owned_self_cmd: ?[]const u8 = null;
    defer if (owned_self_cmd) |c| allocator.free(c);

    var parsers_list = std.ArrayListUnmanaged(ParserCmd){};
    defer parsers_list.deinit(allocator);

    if (user_parsers.len == 0) {
        const self_cmd = try buildSelfParserCmd(allocator);
        owned_self_cmd = self_cmd.cmd;
        try parsers_list.append(allocator, self_cmd);
    } else {
        try parsers_list.appendSlice(allocator, user_parsers);
    }
    const parsers = parsers_list.items;

    const datasets = [_]Dataset{
        .{ .name = "large_list.yml", .path = "bench/data/large_list.yml" },
        .{ .name = "large_map.yml", .path = "bench/data/large_map.yml" },
        .{ .name = "deeply_nested.yml", .path = "bench/data/deeply_nested.yml" },
        .{ .name = "large_recipe.yml", .path = "bench/data/large_recipe.yml" },
        .{ .name = "chaos.yml", .path = "bench/data/chaos.yml" },
    };

    std.debug.print("Running Benchmarks...\n\n", .{});

    printTableHeader(parsers);

    const total_ns_per_parser = try allocator.alloc(u64, parsers.len);
    defer allocator.free(total_ns_per_parser);
    @memset(total_ns_per_parser, 0);

    for (datasets) |ds| {
        const file = std.fs.cwd().openFile(ds.path, .{}) catch {
            std.debug.print("{s:<20} | [Missing]\n", .{ds.name});
            continue;
        };
        const stat = file.stat() catch |err| {
            file.close();
            std.debug.print("{s:<20} | stat error: {}\n", .{ ds.name, err });
            continue;
        };
        file.close();

        const size_mb = @as(f64, @floatFromInt(stat.size)) / (1024.0 * 1024.0);

        std.debug.print("{s:<20}", .{ds.name});

        for (parsers, 0..) |p, p_idx| {
            if (runChildParser(allocator, p.cmd, ds.path)) |avg_ns| {
                total_ns_per_parser[p_idx] += avg_ns;
                const avg_ms = @as(f64, @floatFromInt(avg_ns)) / 1_000_000.0;
                const ns_f = @as(f64, @floatFromInt(avg_ns));
                const throughput = if (ns_f <= 0.0) 0.0 else size_mb / (ns_f / 1_000_000_000.0);
                std.debug.print(" | {d:>8.2}ms {d:>6.1}MB/s", .{ avg_ms, throughput });
            } else |_| {
                std.debug.print(" | {s:>21}", .{"ERROR"});
            }
        }
        std.debug.print("\n", .{});
    }

    printTableFooter(parsers, total_ns_per_parser);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const opts = parseArgs(args);

    if (opts.is_parser_mode) {
        if (opts.file_path) |path| {
            try runParserMode(allocator, path, opts.iterations);
        } else {
            std.debug.print("Error: -f <file_path> required in --parser-mode\n", .{});
            std.process.exit(1);
        }
        return;
    }

    try runOrchestrator(allocator, opts.parsers);
}
