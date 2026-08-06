const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // program name
    _ = args.next() orelse return error.MissingTinPath;
    const spec_runner_path = args.next() orelse return error.MissingSpecRunnerPath;
    const bench_path = args.next() orelse return error.MissingBenchPath;
    const unit_test_path = args.next() orelse return error.MissingUnitTestPath;
    const flow_test_path = args.next() orelse return error.MissingFlowTestPath;

    var reporter = Reporter.init(allocator);
    defer reporter.deinit();

    try reporter.header("TIN NATIVE TEST SUITE");

    // 1. Unit Tests
    try reporter.startGroup("Unit Tests");
    const unit_success = try runAndStream(allocator, &.{ unit_test_path });
    try reporter.endGroup(unit_success);

    // 2. Integration Tests
    try reporter.startGroup("Integration Tests");
    const integ_success = try runAndStream(allocator, &.{ "./tests/test.sh" });
    try reporter.endGroup(integ_success);

    // 3. YAML Spec Compliance
    try reporter.startGroup("YAML Spec Compliance");
    const spec_success = try runAndStream(allocator, &.{ "./tests/test_yaml_suite.sh", spec_runner_path });
    try reporter.endGroup(spec_success);

    // 4. Flow Parsing Tests
    try reporter.startGroup("Flow Parsing Tests");
    const flow_success = try runAndStream(allocator, &.{ flow_test_path });
    try reporter.endGroup(flow_success);

    // 5. Performance Benchmarks
    try reporter.startGroup("Performance Benchmarks");
    const bench_success = try runAndStream(allocator, &.{ bench_path });
    try reporter.endGroup(bench_success);

    try reporter.finalReport();

    if (reporter.failed_groups > 0) std.process.exit(1);
}

const Reporter = struct {
    allocator: std.mem.Allocator,
    passed_groups: usize = 0,
    failed_groups: usize = 0,
    current_group: ?[]const u8 = null,

    fn init(allocator: std.mem.Allocator) Reporter {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Reporter) void {
        if (self.current_group) |g| self.allocator.free(g);
    }

    fn header(self: *Reporter, title: []const u8) !void {
        _ = self;
        std.debug.print("=== {s} ===\n\n", .{title});
    }

    fn startGroup(self: *Reporter, name: []const u8) !void {
        if (self.current_group) |g| self.allocator.free(g);
        self.current_group = try self.allocator.dupe(u8, name);
        std.debug.print("--- {s} ---\n", .{name});
    }

    fn endGroup(self: *Reporter, success: bool) !void {
        const name = self.current_group orelse "Unknown Group";
        if (success) {
            std.debug.print("  PASS: {s}\n\n", .{name});
            self.passed_groups += 1;
        } else {
            std.debug.print("  FAIL: {s}\n\n", .{name});
            self.failed_groups += 1;
        }
    }

    fn finalReport(self: *Reporter) !void {
        std.debug.print("=== RESULTS: {d} passed, {d} failed ===\n", .{ self.passed_groups, self.failed_groups });
        if (self.failed_groups == 0) {
            std.debug.print("ALL TESTS PASSED\n", .{});
        } else {
            std.debug.print("SOME TESTS FAILED\n", .{});
        }
    }
};

fn runAndStream(allocator: std.mem.Allocator, argv: []const []const u8) !bool {
    var proc = std.process.Child.init(argv, allocator);
    // Inherit stdout/stderr to stream directly to terminal
    proc.stdout_behavior = .Inherit;
    proc.stderr_behavior = .Inherit;

    const term = try proc.spawnAndWait();
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}
