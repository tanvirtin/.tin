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
tinrc.yml         ← personal config — copy from tinrc.example.yml
tinrc.example.yml ← template
assets/           ← dotfiles (incl. .tmux.conf), terminal configs, fonts
recipes/          ← how to install and configure each tool
nvim/             ← neovim config
tin (binary)      ← runs it all
```

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

### Agent control

Tin connects OpenCode conversations to Neovim. A Git worktree can have its own
tmux window, with Neovim and an OpenCode coordinator side by side.

```sh
tin agent open "$PWD"            # current worktree's editor + conversation (boots the server in the background if needed)
tin agent open --new "$PWD"      # force a fresh coordinator instead of resuming the previous Control: session
tin agent worktree feature/auth   # separate editing task
tin help agent
```

In Neovim, `<leader>os` asks OpenCode about the current line or a visual range
through a composer; `<leader>oX` clears its draft; `<leader>o<Space>` toggles the paired OpenCode
pane: Neovim full-window with the pane hidden, or the 73/27 split restored, so
the chat behaves as if it were part of Neovim. Each worktree window is one
strict pair: a Neovim
instance can only communicate with the OpenCode pane beside it, and a moved
pane invalidates the pair immediately. Messages are delivered by session ID
through the OpenCode API, never by typing into a tmux pane.
See [the agent-control guide](nvim/AGENT_CONTROL.md) for setup, keybindings,
remote connections, and lifecycle details.

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

Tin is runtime-discoverable. Agents should load only the compact contract, then query the live CLI as needed:

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
<summary>Skills for agent runtimes</summary>

## Skills for agent runtimes — config, not orchestration

OpenCode is an agent runtime that consumes tin: the CLI is its source of
truth, and tin exports its YAML artifacts to the runtime's native skill
directory. Tin does not launch or manage agents. The shared compact agent
contract lives in `assets/agent/AGENTS.md` and is linked into the runtime.
Everything the agent knows and can do is defined in Tin's YAML artifacts,
exported to the runtime's native skill directory.

Any agent that reads the [Agent Skills](https://agentskills.io/specification)
standard gets the same ecosystem. Use `tin artifact export opencode` to refresh
the skill directory. The runtime uses the same self-documenting
Tin CLI for deeper context.

```
artifacts/
  skills/       ← workflows, procedures, composed skills
  rules/        ← reusable rule sets included by skills
assets/agent/   ← shared runtime contract
```

### Commands

```
tin artifact list                              List all skills
tin artifact --path=skills/develop/plan --format=md    Export as SKILL.md
tin artifact --path=skills/develop/plan --format=json  Export as JSON
tin artifact validate                          Check all references are valid
tin artifact export opencode                   Export skills for an agent runtime
```

### Adding a skill

Create a YAML file in `artifacts/skills/`. The path becomes the ID.

`artifacts/skills/develop/plan.yml` → skill ID: `develop/plan` → slash command: `/develop-plan`

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

Create a YAML file in `artifacts/rules/`. Rules are reusable content blocks that get injected into skills via `{{ rule_id }}`.

`artifacts/rules/clarity.yml` → rule ID: `clarity`

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

### Exporting for agent runtimes

```bash
tin artifact export all
```

Exports skills as `SKILL.md` files (the [agentskills.io](https://agentskills.io) standard) for agent runtimes. Use `tin artifact export opencode` to refresh the skill directory.

`install.sh` runs this automatically after `tin install`.

### Current skills

| Skill | What it does |
|-------|-------------|
| `/explore-feature` | Trace a feature end-to-end in an unfamiliar codebase |
| `/memory-remember` | Record durable project and environment facts |
| `/meta-judge` | Score a skill against 8 quality dimensions |
| `/quality-humanize` | Remove AI writing patterns from text |
| `/review-pr` | Understand a PR you have no context on |

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
