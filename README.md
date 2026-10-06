# .tin

Your developer environment as code. Clone it, run it, you're you on any machine.

## Quickstart

One command bootstraps everything — installs the `tin` binary, clones this repo to `~/.tin`, and runs `tin install` (symlinks, fonts, tool recipes):

```bash
curl -fsSL https://raw.githubusercontent.com/tanvirtin/.tin/master/install.sh | sh
```

If you already have `tin`, just run the install steps directly:

```bash
tin install
```

## How it works

`tin` is a CLI that reads `tinrc.yml` and executes recipes. Everything about your environment — identity, symlinks, fonts, tools — is defined in YAML. The Zig binary is the engine; the YAML is the configuration.

`tinrc.yml` is personal and not committed — start from [`tinrc.example.yml`](tinrc.example.yml):

```
~/.tin/            ← this repo: the runtime. Core logic, nothing personal.
~/.config/tin/
  artifacts/       ← your skills, rules, dialects (your own git repo)
  agents/          ← per-agent state
```

The repo is runtime only. Your artifacts — the skills and rules `tin artifact
export` publishes — live outside it at `~/.config/tin/artifacts`, so they're
yours to version, share, or keep private. Set `TIN_ARTIFACTS` to point tin
somewhere else; the default is `~/.config/tin/artifacts`.

<details>
<summary>tinrc.yml configuration</summary>

## tinrc.yml

The single source of truth. Every section is optional.

### identity

Your name and email, available to recipes via `{{ identity.name }}` and `{{ identity.email }}`.

```yaml
identity:
  name: Your Name
  email: you@example.com
```

### symlinks

Config files to symlink from the repo to their expected locations. Grouped by category. `~` resolves to `$HOME`. Sources are relative to the repo root.

```yaml
symlinks:
  shell:
    - source: assets/.zshrc
      target: ~/.zshrc

    - source: assets/.tmux.conf
      target: ~/.tmux.conf

  editor:
    - source: nvim
      target: ~/.config/nvim

  terminal:
    - source: assets/alacritty.toml
      target: ~/.config/alacritty/alacritty.toml
```

Add a new symlink — just add an entry. Remove one — delete the entry. Run `tin link` to apply.

Add `copy: true` to install a real file instead of a symlink:

```yaml
    - source: assets/plugin/tool.ts
      target: ~/.config/plugin/tool.ts
      copy: true
```

Copies are refreshed in place when the source changes, and `tin unlink` deletes
them. Use this for files whose consumer resolves relative imports or otherwise
depends on the file's real location: a consumer that resolves from the real
path can't find packages installed next to the config directory if the file is
a symlink back into the repo.

### fonts

Path to a directory of `.ttf` files to install to the system font directory.

```yaml
fonts: assets/fonts
```

### recipes

Named groups of recipes. Each name maps to a file in `recipes/`.

```yaml
recipes:
  shell:
    - zsh
    - starship
    - zsh-autosuggestions

  dev:
    - git
    - rust
    - nvm
```

### install

Ordered list of what `tin install` does. Runs top to bottom.

```yaml
install:
  - link              # create symlinks
  - fonts             # install fonts
  - recipes: shell    # run all recipes in the shell group
  - recipes: dev      # run all recipes in the dev group
```


</details>

<details>
<summary>Recipes</summary>

## Recipes

YAML files in `recipes/`. Each defines a name and a list of steps.

```yaml
name: git
description: Configure git

steps:
  - name: Set user name
    run: git config --global user.name "{{ identity.name }}"

  - name: Set user email
    run: git config --global user.email {{ identity.email }}

  - name: Set editor
    run: git config --global core.editor nvim
```

### Step types

| Step | Usage | Description |
|------|-------|-------------|
| `run` | `run: <command>` | Execute a shell command |
| `install` | `install: <package>` | Install via brew (macOS) or apt (Linux) |
| `recipe` | `recipe: <name>` | Run another recipe |
| `link` | `link: all` | Create all symlinks from tinrc.yml |
| `fonts` | `fonts: all` | Install fonts from tinrc.yml |
| `mkdir` | `mkdir: <path>` | Create a directory (and parents) |
| `download` | `download: <url>` | Download a file (requires `to:` field) |
| `clone` | `clone: <repo>` | Git clone (requires `to:` field, skips if exists) |

`download` and `clone` require a `to:` field:

```yaml
steps:
  - mkdir: ~/.zsh

  - clone: https://github.com/zsh-users/zsh-autosuggestions
    to: ~/.zsh/zsh-autosuggestions

  - download: https://example.com/config.toml
    to: ~/.config/tool/config.toml
```

### Conditions

Steps can be skipped with `if:`.

```yaml
steps:
  - name: Install (macOS)
    install: ripgrep
    if: os == 'darwin'

  - name: Install (Linux)
    install: ripgrep
    if: os == 'linux'

  - name: Install rustup
    run: curl https://sh.rustup.rs -sSf | sh -s -- -y
    if: not exists ~/.rustup

  - name: Install homebrew
    run: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if: command_exists brew
```

| Condition | Example | True when |
|-----------|---------|-----------|
| `os ==` | `if: os == 'darwin'` | Running on macOS |
| `exists` | `if: exists ~/.rustup` | Path exists |
| `not exists` | `if: not exists ~/.nvm` | Path does not exist |
| `command_exists` | `if: command_exists brew` | Binary is on PATH |

### Templates

Recipes can reference `tinrc.yml` identity values with `{{ key }}`.

```yaml
steps:
  - run: git config --global user.name "{{ identity.name }}"
  - run: git config --global user.email {{ identity.email }}
```

Available variables: `{{ identity.name }}`, `{{ identity.email }}`.


</details>

## Commands

```
tin install                         Full environment setup from tinrc.yml
tin link                            Create managed symlinks
tin unlink                          Remove symlinks and restore backups
tin heal                            Inspect symlink state, then repair safely
tin fonts                           Install fonts
tin recipe [name]                   List or run recipes
tin artifact                        Browse, validate, and export skills
tin web search|extract|fetch ...    Search, extract, or fetch web content
tin help                            Show runtime command reference and index
```

`web` is a namespace: web access belongs under `tin web`.

### Tmux config

tmux is installed via the `tmux` recipe (`tin recipe tmux`, which also clones
tpm) and configured with a plain committed file at `assets/.tmux.conf` — symlinked
to `~/.tmux.conf` via `tin link`/`tinrc.yml` (see `symlinks: shell`). There is
no `tin tmux` command: the config is a checked-in tmux script, edited directly.

The current file uses a monokai status bar and the `tmux-sessionx` plugin
(bound to `L` in the prefix table) with the current session shown (not filtered
out) and prefixed with a `●` marker so it's easy to spot and avoid picking,
tree/window mode, git branches, and fzf colors.

After changing `assets/.tmux.conf`, re-apply with:
`tmux source-file ~/.tmux.conf`. The sessionx plugin must also re-run its
`sessionx.tmux` (as bash) to rebuild its `@sessionx-_built-*` args.

### Self-documenting CLI

Tin is runtime-discoverable. Query the live CLI as needed:

```bash
tin --help
tin help --index
tin help artifact
tin help schema tinrc
```

`tin help --index` is the compact machine-readable map. Topic and detail pages are generated from command metadata, schemas, and live catalogs.

### Web tools

Web access is a thin Zig CLI over Tavily search/extraction plus native raw
fetching:

```bash
tin web search "Zig HTTP client" --max 5
tin web extract https://example.com/docs
tin web fetch https://raw.githubusercontent.com/user/repo/main/README.md
```

`search` returns structured JSON with ranked results and extracted snippets;
`extract` reads a page in depth; `fetch` returns raw content when a page is
not suitable for extraction. `TAVILY_API_KEY` belongs in the gitignored
`~/.tin/.env`.

### Self-healing

Run `tin heal` when managed state is degraded. It repairs symlinks and surfaces
config faults; judgment-heavy fixes are left to the agent.

<details>
<summary>Adding tools</summary>

## Adding a new tool

1. Create `recipes/toolname.yml`:

```yaml
name: toolname
description: Install toolname

steps:
  - name: Install toolname
    install: toolname
```

2. Add it to a group in `tinrc.yml`:

```yaml
recipes:
  dev:
    - git
    - toolname
```

Done. `tin install` picks it up.


</details>

<details>
<summary>Adding config files</summary>

## Adding a new config file

1. Put the config in `assets/` (e.g., `assets/starship.toml`)

2. Add a symlink entry in `tinrc.yml`:

```yaml
symlinks:
  shell:
    - source: assets/starship.toml
      target: ~/.config/starship.toml
```

3. Run `tin link`.


</details>

<details>
<summary>Skills</summary>

## Skills — config, not orchestration

Tin does not launch or manage anything. It publishes YAML artifacts that a
runtime consumes: the CLI is the source of truth, and `tin artifact export`
writes its YAML artifacts to a skill directory in the format the runtime
expects.

Any agent that reads the [Agent Skills](https://agentskills.io/specification)
standard gets the same ecosystem. The runtime uses the same self-documenting
Tin CLI for deeper context.

```
~/.config/tin/artifacts/
  skills/       ← workflows, procedures, composed skills
  rules/        ← reusable rule sets included by skills
  dialects/     ← per-runtime MCP dialects
```

### Commands

```
tin artifact list                              List all skills
tin artifact --path=skills/develop/plan --format=md    Export as SKILL.md
tin artifact --path=skills/develop/plan --format=json  Export as JSON
tin artifact validate                          Check all references are valid
tin artifact export                            Export skills for a runtime
```

### Adding a skill

Create a YAML file in `~/.config/tin/artifacts/skills/`. The path becomes the ID.

`skills/develop/plan.yml` → skill ID: `develop/plan` → slash command: `/develop-plan`

A workflow skill (the AI follows a procedure):

```yaml
description: Design a testable scaffold from requirements.

include:
  - design

system: |
  Take requirements and design function signatures with empty bodies.

  ## Design Principles
  {{ design }}

  ## Output
  Types, function signatures, empty bodies. No implementation.
```

A skill that composes other skills:

```yaml
description: Find and fix code slop.

system: |
  Spawn 3 parallel sub-agents:
  - quality/review-clarity
  - quality/review-bloat
  - quality/review-design

  Collect findings. Fix by severity.

skills:
  - quality/review-clarity
  - quality/review-bloat
  - quality/review-design
```

Key fields:

| Field | Purpose |
|-------|---------|
| `description` | What the skill does and when to use it (required) |
| `system` | Instructions the AI follows (the prompt) |
| `skills` | Other skills this one composes |
| `include` | Rules whose content replaces `{{ rule_id }}` in system |
| `context` | Set to `fork` to run in a sub-agent context |

### Adding a rule

Create a YAML file in `~/.config/tin/artifacts/rules/`. Rules are reusable content blocks that get injected into skills via `{{ rule_id }}`.

`rules/clarity.yml` → rule ID: `clarity`

```yaml
description: Writing clarity rules

content: |
  - Use early returns over else blocks
  - Avoid nesting deeper than 2 levels
  - Use guard clauses at function entry
  - Name booleans as questions: isValid, hasPermission
```

A skill includes it:

```yaml
include:
  - clarity

system: |
  ## Writing Clarity
  {{ clarity }}
```

The `{{ clarity }}` placeholder is replaced with the rule's `content` at export time.

### Exporting for a runtime

```bash
tin artifact export all
```

Exports skills as `SKILL.md` files (the [agentskills.io](https://agentskills.io) standard) for the target runtime. Point the export at the skill directory your runtime reads; the `exports:` map in `tinrc.yml` records it.

Which skills exist is up to you — `tin artifact list` reports what your artifacts directory holds.

### Validation

```bash
tin artifact validate
```

Checks:
- Every skill reference (`skills:` field) points to an existing skill
- Every include (`include:` field) points to an existing rule
- No duplicate IDs
- Every skill has `description` and either `command` or `system`


</details>

## Building from source

Requires [Zig 0.15.2](https://ziglang.org/download/).

```bash
zig build
./zig-out/bin/tin help
```

## Running tests

```bash
zig build test                  # unit tests
bash tests/test.sh              # integration tests
```

## Supported platforms

- macOS (arm64, x86_64)
- Linux (x86_64, aarch64) — Debian/Ubuntu (apt)
