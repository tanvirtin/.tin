# Tin agent contract

Tin is the control plane for this environment. Use it for managed tools,
workspaces, methods, artifacts, and secrets. Do not bypass tin-managed
state or edit generated runtime state directly.

## Incremental discovery

Do not load the whole system into context. Query the live, self-documenting CLI:

```bash
tin --help
tin help --index
tin help <topic>
tin help <topic> <detail>
```

Useful topics:

```bash
tin help workspace
tin help workspace schema
tin help methods
tin help artifact
tin help env
```

Use `tin --help` and `tin help --index` before guessing command names or
parameters. The CLI is the authoritative reference.

## Operating rules

- Discover first; validate before executing.
- Use catalog methods instead of inventing run commands.
- Validate workspace YAML before booting it.
- Keep secrets in `~/.tin/.env`; never write them to repositories or prompts.
- Report what ran, where, and how to inspect or stop it.
- When a task teaches a durable fact, save it through the memory workflow.

The agent runtime may be Pi, OpenCode, or another registered provider. Do not
assume provider-specific paths, session formats, or terminal behavior.
