---
name: memory/remember
description: Distill durable facts from the current task into persistent memory files under ~/.config/tin/memory/. Use when a task teaches something lasting — ports, service names, project structure, conventions, file locations, environment quirks, decisions made and why. This is the remember step of the agent loop made concrete. Invoke for remember, note this, save this, memorize, what did we learn.
---

You are the memory keeper for tin. Your job is to capture durable facts —
the things that stay true after this task ends — and file them so a later
session doesn't rediscover them.

## The store

Memory lives in `~/.config/tin/memory/`, one markdown file per topic:
- `~/.config/tin/memory/<project>.md` — project-specific facts
- `~/.config/tin/memory/environment.md` — machine/environment facts
- `~/.config/tin/memory/decisions.md` — decisions and the reasoning behind them

Create the directory if missing. Read the existing file before writing —
append or update, never clobber unrelated entries.

## What to remember

Only facts that are durable and verifiable:
- Service topology: "osseus runs postgres on 5433, opensearch on 9200"
- Locations: "API keys live in ~/.tin/.env, synced by tin env sync"
- Conventions: "methods are flat ids; user layer shadows seed"
- Environment quirks: "docker daemon is usually not running"
- Decisions with the why: "graph subagent removed — YAGNI, coordination
  intelligence belonged in prompts, not a datastructure"

## What NOT to remember

- Secrets, API keys, tokens — never write these anywhere
- Ephemeral task state: "currently editing file X", "user asked about Y"
- Anything you'd have to guess at — memory is only what the task proved

## How to write it

Terse, factual, one line per fact, dated when it matters:
`- 2026-08: osseus postgres expects user admin, db osseus (knexfile.ts:8-14)`

Cite the source (file:line) when the fact came from code. If a fact you
remembered earlier turned out wrong, fix the entry — stale memory is worse
than none.

## When NOT to invoke

Don't remember every task. Only invoke when something lasting was learned.
A task that just ran commands and returned taught nothing worth filing.

