# .tin

Your developer environment as code. Clone it, run it, you're you on any machine.

```bash
curl -fsSL https://raw.githubusercontent.com/tanvirtin/.tin/master/bootstrap.sh | sh
tin install
```

## How it works

`tin` is a CLI that reads `tinrc.yml` and executes recipes. Everything about your environment — identity, symlinks, fonts, tools — is defined in YAML. The Zig binary is the engine; the YAML is the configuration.

```
tinrc.yml          ← what to set up
recipes/           ← how to set up each tool
assets/            ← dotfiles, terminal configs, fonts
nvim/              ← neovim config
tin (binary)       ← runs it all
```

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

## Commands

```
tin install        Full environment setup from tinrc.yml
tin link           Create symlinks
tin unlink         Remove symlinks (restores backups)
tin status         Show what's linked, missing, or broken
tin fonts          Install fonts
tin recipe <name>  Run a single recipe
tin recipe         List available recipes
tin help           Show usage
```

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

## Sn — AI Orchestration Engine

Sn (chemical symbol for tin) is the AI orchestration engine. Everything is a YAML skill. The filesystem is the registry — drop a file in the right directory and it's live.

```
sn/
  skills/       ← workflows, procedures, composed skills
  rules/        ← reusable rule sets included by skills
```

### Commands

```
tin sn list                              List all skills and rules
tin sn --path=skills/develop/plan --format=md   Export as SKILL.md
tin sn --path=skills/develop/plan --format=json Export as JSON
tin sn validate                          Check all references are valid
tin sn export claude                     Export all to .claude/skills/
```

### Adding a skill

Create a YAML file in `sn/skills/`. The path becomes the ID.

`sn/skills/develop/plan.yml` → skill ID: `develop/plan` → slash command: `/develop-plan`

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

Create a YAML file in `sn/rules/`. Rules are reusable content blocks that get injected into skills via `{{ rule_id }}`.

`sn/rules/clarity.yml` → rule ID: `clarity`

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

### Exporting to Claude Code

```bash
tin sn export claude
```

Converts all skills and rules to `.claude/skills/` as SKILL.md files (the [agentskills.io](https://agentskills.io) standard). Claude Code auto-discovers them as slash commands.

`bootstrap.sh` runs this automatically after `tin install`.

### Current skills

| Skill | What it does |
|-------|-------------|
| `/develop-plan` | Design testable scaffold — empty function signatures |
| `/develop-test` | Write tests for the scaffold — positive, negative, table-driven |
| `/develop-implement` | Fill one function at a time — minimal code to pass tests |
| `/quality-deslop` | Find and fix AI slop — spawns 3 parallel reviewers |
| `/quality-humanize` | Remove AI writing patterns from text |
| `/review-pr` | Understand a PR you have no context on — guided walkthrough |
| `/explore-feature` | Trace a feature end-to-end in an unfamiliar codebase |
| `/meta-judge` | Score a skill against 8 quality dimensions |

### Validation

```bash
tin sn validate
```

Checks:
- Every skill reference (`skills:` field) points to an existing skill
- Every include (`include:` field) points to an existing rule
- No duplicate IDs
- Every skill has `description` and either `command` or `system`

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
