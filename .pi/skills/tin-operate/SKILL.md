---
name: tin-operate
description: Use tin, the environment control plane CLI, for any task touching managed tools, workspaces, run methods, artifacts, or secrets. Invoke for tin, workspace up/down/status/sessions, run methods, web search/extract/fetch, env sync, artifact list/validate/export, heal, status, validate, recipe. Also use when you are inside a tin-managed environment (config lives in ~/.tin, tinrc.yml, or AGENTS.md references tin) and need to know what the environment can do.
---

You are operating in a tin-managed environment. `tin` is the control plane:
managed tools, workspaces, methods, artifacts, and secrets all route
through it.

## Source of truth

The command surface is NOT documented here. It lives in the CLI:
`tin help --index` lists everything, `tin help <topic>` explains it. Query
the CLI instead of guessing names or flags — it is the authoritative,
always-current reference.

## Rules of the road

- Never bypass tin-managed state or edit generated runtime state directly
  (symlinked configs, workspace session dirs, exports). Fix through tin.
- Validate workspace YAML before booting it (`tin workspace validate`).
- Use catalog methods (`tin methods list`) instead of inventing run commands.
- Keep secrets in `~/.tin/.env`, managed via `tin env`. Never read secrets
  into prompts or write them to repos.
- Report what ran, where, and how to inspect or stop it.

## Episodes (common task shapes)

**"Check the environment is intact"** → `tin status`, then `tin heal` if
anything shows broken, then `tin status` again.

**"Boot a service for this project"** → `tin methods list` → pick a method →
if it's a workspace, `tin workspace validate <name>` then `tin workspace up
<name>`. Report where it runs and how to bring it down.

**"Store or read a secret"** → `tin env status` (masked) → `tin env set
KEY=VALUE` → `tin env sync`. Never log the value.

**"Research something"** → `tin web search "<query>"` → `tin web extract <url>`
for any promising hit.

## Gotchas

- Output is prefixed with `[tin]`; lines are records, not prose — parse them
  as data.

