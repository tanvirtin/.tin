const tmux_cli = @import("tmux.zig");

/// Stable multiplexer contract used by tin's agent and workspace runtimes.
/// The current backend is tmux_cli. A future zmux backend implements these
/// same operations without changing callers.

pub const Backend = enum { tmux_cli };
pub const backend: Backend = .tmux_cli;

pub const available = tmux_cli.available;
pub const hasSession = tmux_cli.hasSession;
pub const hasWindow = tmux_cli.hasWindow;
pub const paneDead = tmux_cli.paneDead;
pub const killSession = tmux_cli.killSession;
pub const createSession = tmux_cli.createSession;
pub const createSessionSimple = tmux_cli.createSessionSimple;
pub const createWindow = tmux_cli.createWindow;
pub const capturePane = tmux_cli.capturePane;
pub const pasteBuffer = tmux_cli.pasteBuffer;
pub const currentSession = tmux_cli.currentSession;
pub const windowCount = tmux_cli.windowCount;

