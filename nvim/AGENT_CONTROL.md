# Agent control with Tin, Neovim, and OpenCode

OpenCode is the conversation. Neovim is where you inspect activity and review
code. Tin owns the server connections and management commands used by both.

## Start a working group

The `tin-coordinator` primary agent is managed by `tin link`. Restart OpenCode
after installing or changing its definition.

There is no separate server step: the first command that needs the shared
OpenCode server boots it in the background automatically and waits for it
(pidfile `~/.tin/serve.pid`, logs `~/.tin/serve.log`). Concurrent starts
converge on a single server; a dead server recovers on the next call, and stale
listeners on the port are reaped before a fresh start. `tin` manages it — no
tmux required. `TIN_AUTO_SERVER=0` disables on-demand boot.

```sh
tin agent open "$PWD"        # boots the server if needed, then opens the editor window
tin agent serve --stop       # stop the background server when you want it done
```

Use `tin agent serve --foreground` to keep it in the current terminal instead
(Ctrl-c stops it); plain `tin agent serve` in a terminal reports reachability.

From a Git repository, open its current worktree:

```sh
tin agent open "$PWD"
```

Create a separate editing task on a new branch:

```sh
tin agent worktree feature/auth
```

Tin creates a sibling worktree from HEAD, or reuses a worktree already attached
to that branch. Existing branches are checked out rather than recreated.
Uncommitted edits stay in the original worktree.

The layout is one tmux session per repository and one window per worktree:

```text
project
├─ feature/auth
│  ├─ Neovim
│  └─ OpenCode: coordinator for feature/auth
└─ fix/search
   ├─ Neovim
   └─ OpenCode: coordinator for fix/search
```

Each window is a **group**: a strictly paired Neovim and OpenCode instance. The
Neovim pane can communicate only with the OpenCode pane beside it — the session
that pane is attached to — and never with any other session or worktree. Every
editor request carries the group binding (`window/coordinator`) taken from tmux
window options, and Tin re-verifies it against the current pane on every call.
Moving an editor pane to another window immediately invalidates the pair.

If you open Neovim outside a Tin group, the OpenCode composer and every editor
request refuse to send until you create or enter a group.

Reopening a group reuses its coordinator conversation and existing OpenCode pane.
Inside tmux, Tin switches to the group. Outside tmux, `tin agent groups` lists
the window IDs; enter one with `tmux attach -t @WINDOW_ID`.

Use `Ctrl-a o` to change panes and `Ctrl-a n` / `Ctrl-a p` to change windows.
The existing `Ctrl-a L` session picker still works.

## Give the coordinator work

Talk normally in the OpenCode pane. The coordinator tracks the goal, delegates
bounded tasks through OpenCode's native subagent tool, and reviews their results.
Its instructions live in `assets/opencode/agents/tin-coordinator.md`.

Use a worktree for an independent editing task. Research and review subagents
can share their coordinator's group. Separate worktrees isolate files and Git
state; they are not containers or separate machines.

When asked to manage other groups or remote sessions, the coordinator can use
the same `tin agent` commands as you. Tin provides those controls; delegation
and integration decisions belong to the coordinator.

## Ask about code from Neovim

Neovim composes messages through Tin's group-scoped transport:

| Key | Action |
| --- | --- |
| `<leader>os` | Ask OpenCode about the current line (visual mode: the selected range) |
| `<leader>oX` | Clear the OpenCode draft |
| `<leader>o<Space>` | Toggle the OpenCode chat pane: editor full-window (pane hidden) or back to 73/27 |

The composer targets the OpenCode session paired with this Neovim instance — the
OpenCode pane in this window — and nothing else. Context captures the buffer
contents, including unsaved edits. Messages are delivered by session ID through
the OpenCode API, never by typing into a tmux pane.

`Ctrl-s` sends; `Ctrl-t` re-targets within the same group; Escape leaves insert
mode, and another Escape closes the composer while retaining the draft.

If the editor pane moves to another worktree, reopening an existing composer
draft is refused with a hint to recompose, so a message can never leak to a
different group by accident.

`<leader>o<Space>` toggles the OpenCode pane in this window: press it with the
split visible and Neovim takes the full window (the OpenCode pane is hidden);
press it again and the 73/27 layout is restored with the pane back at the side.
The toggle is a tmux zoom on the editor pane, so the OpenCode pane is never
killed — from the OpenCode pane you can return with `Ctrl-a o` (selects the
Neovim pane, restoring 73/27) or `Ctrl-a z` (toggles zoom in place). Quitting
the OpenCode conversation closes only the chat pane, never the window.

## Supervision and quitting a group

Supervision happens at the conversation: drive the coordinator in the OpenCode
pane (the right 27% of the window; Neovim owns the left 73%), or attach the
full OpenCode TUI to any agent with `tin agent attach <session>` for its
messages, tool inputs/output, and tasks. Diffs come from OpenCode's session
snapshots (`tin agent diff <session>`); they are review material, not proof
that an agent exclusively owns every edit in a shared worktree. Use the
existing Git commands to stage and commit.

Quitting the group tears it down as a whole: closing the OpenCode pane or
exiting Neovim closes the sibling pane too, and the repository's tmux session
is removed once its last window is gone. The conversation itself persists on the
server and resumes when you reopen the worktree. If a tmux client was attached
to the session, it returns to your previous session instead of exiting.

## Connections and remote workers

Without configuration, Tin connects to `http://127.0.0.1:4096` in the current
directory. Optional named connections live in `tinrc.yml`:

```yaml
agents:
  - name: local
    url: http://127.0.0.1:4096
  - name: cloud
    url: http://127.0.0.1:4097
    directory: /srv/project
    password_env: CLOUD_OPENCODE_PASSWORD
```

For a remote machine, run OpenCode there, then forward its port:

```sh
ssh -N -L 4097:127.0.0.1:4096 user@host
```

The directory is a path on the server. Install Tin's coordinator agent on that
server too, or set `agent` to a primary agent installed there. Tin supports
OpenCode servers; a hosted agent from another provider needs its own adapter.

Keep passwords in `~/.tin/.env`; the YAML contains only environment-variable
names. Tin resolves that file before inherited environment variables. Prompts
and HTTP credentials travel through subprocess stdin or environment, not shell
interpolation or command-line arguments. `tin agent serve` loads managed secrets
into the server environment.

Live Tin tmux groups are included in `tin agent servers` alongside configured
connections. A scoped snapshot (`tin agent group` then `--group BINDING`)
contains only the group's coordinator and its native descendants, all in that
worktree; other repositories' sessions are never fetched from the editor. Group
discovery uses tmux metadata; OpenCode owns persistent conversation history.

`open` and `worktree` operate on local files. Remote connections support supervision, prompts, permissions, stopping, and diffs; remote provisioning and
worktree creation remain operations on that machine.

## CLI and lifecycle

`tin help agent` is the command reference. Most commands return JSON:

```sh
tin agent servers
tin agent groups
tin agent snapshot
tin agent inspect ses_ID
tin agent diff ses_ID
tin agent prompt ses_ID < task.md
tin agent stop ses_ID --tree
```

Commands accept `--server NAME` and `--directory /absolute/server/path`.
Editor and automation use `tin agent group` to resolve the pane's own group,
then pass its `group` binding so operations stay inside that group. Without a
binding (or outside tmux), commands operate unscoped -- useful from a terminal,
and unavailable to the editor.
`stop --tree` discovers descendants from the server, stops the parent first,
and reports partial failures with a nonzero exit status.

Closing the OpenCode pane or worktree window retains the worktree and conversation.
Stop model/tool execution with `tin agent stop`; closing the UI only detaches.
Stop the background server with `tin agent serve --stop` (or `Ctrl-c` on a
`--foreground` server). Remove a finished
worktree with the normal Git worktree workflow after reviewing its changes.

## Development checks

```sh
zig build
zig build test-agent
make -C nvim test-file FILE=lua/core/agents_spec.lua
zig build install-tin --prefix "$HOME/.tin"
```

The CLI tests use a local fake OpenCode server and an isolated tmux socket.
They exercise real Git worktree creation in a temporary clone, with inert
editor/agent processes. No model requests are made.
