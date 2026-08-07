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
tin status                          Show linked, missing, and broken files
tin heal                            Repair managed state safely
tin fonts                           Install fonts
tin recipe [name]                   List or run recipes
tin artifact                        Browse, validate, and export skills
tin methods list|show [name]        Browse the run-method catalog
tin workspace add|up|down ...       Register and run project workspaces
tin agent                           Launch the agent shell and manage replicas
tin web search|extract|fetch ...    Search, extract, or fetch web content
tin env                             Manage provider keys and model defaults
tin help                            Show usage
```

The command names `agent` and `web` are namespaces. Agent lifecycle belongs under
`tin agent`; web access belongs under `tin web`.

### Workspaces

A workspace is a project-specific composition of catalog methods. Register a
project, edit its generated YAML, validate it, then boot it in tmux:

```bash
tin workspace add myapp ~/workspace/myapp
# edit ~/.config/tin/workspaces/myapp.yml
tin workspace validate myapp
tin workspace up myapp
tin workspace status myapp
tin workspace down myapp
```

Example:

```yaml
name: myapp
path: ~/workspace/myapp
components:
  db:
    method: postgres
    params: { port: 5433 }
  api:
    method: node-dev
    params: { dir: services/api, script: dev }
topology:
  api:
    depends_on: { db: { condition: healthy } }
```

Tin discovers the project and proposes mappings; the workspace file is the
reviewed contract that tin executes.

### Methods

Methods are reusable run definitions in `~/.tin/methods/` (seed) and
`~/.config/tin/methods/` (user). A method declares a runtime, command or
container image, parameters, health checks, and installation requirements.
User methods shadow seed methods with the same ID.

```bash
tin methods list
tin methods show postgres
```

### Agent replicas

`tin agent chat` launches a persistent pi replica in its own tmux session. The
replica has its own conversation but records its parent session in the tin
registry.

```bash
id=$(tin agent chat "Research the project architecture")
tin agent watch <id>                 # stream output until idle
tin agent send <id> "Check the database path too"
tin agent wait <id>                  # wait for the done signal and retire it
tin agent stop <id>                  # explicit cleanup
tin agent list
tin agent status <id>
```

Open the hub with `Tab` to see sessions and replicas. The hub nests each
replica under the session that spawned it. Runtime state lives under
`~/.config/tin/agents/` and is not committed.

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

Run `tin heal` when managed state is degraded. It repairs symlinks, reports
catalog faults, and leaves judgment-heavy fixes to the agent. The `system/heal`
skill gives pi the full loop: diagnose, repair through tin, run the gates,
commit, and report.

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
<summary>Pi and agent skills</summary>

## Pi — AI orchestration

[Pi](https://pi.dev) is the default coding agent. Tin is the single source of
truth for the environment; Pi is how you drive it. Everything the agent knows
and can do is defined in YAML in `artifacts/`, exported to the agent's skill
directories, and taught to the agent via `~/.pi/agent/AGENTS.md`.

Any agent that reads the [Agent Skills](https://agentskills.io/specification)
standard gets the same ecosystem: Pi reads `~/.tin/.pi/skills/`
(see `assets/pi/settings.json`).

```
artifacts/
  skills/       ← workflows, procedures, composed skills
  rules/        ← reusable rule sets included by skills
assets/pi/      ← Pi config (AGENTS.md, settings.json) symlinked into ~/.pi/agent/
```

### Commands

```
tin artifact list                              List all skills
tin artifact --path=skills/develop/plan --format=md    Export as SKILL.md
tin artifact --path=skills/develop/plan --format=json  Export as JSON
tin artifact validate                          Check all references are valid
tin artifact export pi                    Export all to Pi's skill dir
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

### Exporting for Pi

```bash
tin artifact export pi
```

Converts all skills and rules to `~/.tin/.pi/skills/` as SKILL.md files (the [agentskills.io](https://agentskills.io) standard). Pi reads these via the paths in `assets/pi/settings.json`.

`bootstrap.sh` runs this automatically after `tin install`.

### Current skills

| Skill | What it does |
|-------|-------------|
| `/explore-feature` | Trace a feature end-to-end in an unfamiliar codebase |
| `/git-worktree` | Isolate risky experiments in temporary worktrees |
| `/memory-remember` | Record durable project and environment facts |
| `/meta-judge` | Score a skill against 8 quality dimensions |
| `/quality-humanize` | Remove AI writing patterns from text |
| `/review-pr` | Understand a PR you have no context on |
| `/system-heal` | Diagnose and repair degraded tin state |
| `/web-fetch` | Fetch and summarize URLs with curl |
| `/workspace-manage` | Register, map, boot, and manage workspaces |

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
