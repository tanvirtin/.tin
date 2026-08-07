const std = @import("std");
const output = @import("../lib/output.zig");
const process = @import("../lib/process.zig");
const tmux = @import("../core/mux.zig");

const helpers = @import("agent/helpers.zig");
const signal = @import("agent/signal.zig");
const watch = @import("agent/watch.zig");
const spawn_mod = @import("agent/spawn.zig");
const manage = @import("agent/manage.zig");

pub const meta = .{
    .name = "agent",
    .description = "Launch pi and manage subagents (tin agent [chat|watch|wait|list|status|results|send|stop])",
};

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len == 0) {
        launchAgentShell(allocator);
        return;
    }
    const sub = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, sub, "chat")) {
        spawn_mod.chatSubagent(allocator, rest);
    } else if (std.mem.eql(u8, sub, "watch")) {
        watch.watchSubagent(allocator, rest);
    } else if (std.mem.eql(u8, sub, "list")) {
        manage.listJobs(allocator);
    } else if (std.mem.eql(u8, sub, "status")) {
        manage.statusJob(allocator, rest);
    } else if (std.mem.eql(u8, sub, "results")) {
        manage.resultsJob(allocator, rest);
    } else if (std.mem.eql(u8, sub, "send")) {
        manage.sendJob(allocator, rest);
    } else if (std.mem.eql(u8, sub, "stop")) {
        manage.stopJob(allocator, rest);
    } else if (std.mem.eql(u8, sub, "wait")) {
        signal.waitForSignal(allocator, rest);
    } else {
        output.err("usage: tin agent <chat|watch|wait|list|status|results|send|stop>", .{});
    }
}

fn launchAgentShell(allocator: std.mem.Allocator) void {
    // The agent shell: a persistent tmux session running pi. Reuse if alive.
    if (!tmux.hasSession(allocator, "tin-a")) {
        tmux.createSession(allocator, "tin-a", ".", "pi") catch {
            output.err("failed to launch agent shell", .{});
            return;
        };
    }
    output.success("agent shell: tin-a (attach: tmux attach -t tin-a)", .{});
}

// keep helpers referenced so the dispatch module consts aren't dead
comptime {
    _ = helpers;
    _ = spawn_mod;
    _ = watch;
    _ = manage;
}
