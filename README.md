# .tin

Your developer environment as code. Clone it, run it, you're you on any machine.

## Quickstart

```bash
curl -fsSL https://raw.githubusercontent.com/tanvirtin/.tin/master/install.sh | sh
tin install
```

The installer puts the `tin` binary and this repo in `~/.tin`. It does **not**
apply your environment — `tin install` does that. Install mode is explicit:

```bash
# Prebuilt release only (no compiler); fails if no release exists
curl -fsSL https://raw.githubusercontent.com/tanvirtin/.tin/master/install.sh | sh -s -- --from-binary

# Build from source (requires Zig)
curl -fsSL https://raw.githubusercontent.com/tanvirtin/.tin/master/install.sh | sh -s -- --from-source

# Pin a release
curl -fsSL https://raw.githubusercontent.com/tanvirtin/.tin/master/install.sh | sh -s -- --version v0.1.0
```

Update later with `tin upgrade` (`tin upgrade --check` checks without applying).

## How it works

`tin` reads `tinrc.yml` and applies it — identity, symlinks, fonts, tools. The
Zig binary is the engine; the YAML is the configuration.

A default `tinrc.yml` ships at `~/.tin/tinrc.yml`. A personal copy at
`~/.config/tin/tinrc.yml` **replaces** it (no field merging).

```
~/.tin/                    runtime + shared defaults (incl. tinrc.yml)
~/.config/tin/
  tinrc.yml                personal override (wins)
  artifacts/               your skills, rules, dialects, MCP servers
  recipes/                 personal recipes (shadow the repo's)
```

`tin init` writes a neutral `~/.config/tin/tinrc.yml`, a sample skill, and the
Zed export target. It never overwrites files or applies anything.

Overrides: `TIN_DIR`, `TIN_ARTIFACTS`, `TIN_RECIPES`, `TIN_REPO_URL`,
`TIN_RELEASE_BASE_URL`, `TIN_INSTALLER_URL`, `TIN_API_BASE_URL`.

## tinrc.yml

The single source of truth. Every section is optional.

### identity

```yaml
identity:
  name: Your Name
  email: you@example.com
```

Available to recipes as `{{ identity.name }}` and `{{ identity.email }}`.

### symlinks

Config files to symlink into place, grouped by category. `~` resolves to
`$HOME`; sources are relative to the repo root.

```yaml
symlinks:
  shell:
    - source: environment/config/.zshrc
      target: ~/.zshrc
```

Add `copy: true` to install a real file instead of a symlink (refreshed in
place; `tin unlink` removes it). Use it when the consumer resolves relative
imports from the file's real path.

### fonts

```yaml
fonts: environment/config/fonts   # directory of .ttf files
```

### recipes

Named groups, each mapping to files in `environment/recipes/`.

```yaml
recipes:
  shell: [zsh, starship, zsh-autosuggestions]
  dev: [git, gh]
```

### install

Ordered steps `tin install` runs top to bottom.

```yaml
install:
  - link
  - fonts
  - recipes: shell
  - recipes: dev
```

## Recipes

YAML in `environment/recipes/`. Each defines a name and a list of steps.

```yaml
name: git
description: Configure git
steps:
  - name: Set user name
    run: git config --global user.name "{{ identity.name }}"
```

Recipes resolve personal-first: `~/.config/tin/recipes/` shadows
`{tin_dir}/environment/recipes/`. `tin recipe` tags each entry `[config]` or `[repo]`.

### Step types

| Step | Usage |
|------|-------|
| `run` | `run: <command>` — shell command |
| `install` | `install: <package>` — brew (macOS) or apt (Linux) |
| `recipe` | `recipe: <name>` — run another recipe |
| `link` | `link: true` — create all symlinks |
| `fonts` | `fonts: true` — install fonts |
| `mkdir` | `mkdir: <path>` — create a directory (and parents) |
| `download` | `download: <url>` — requires `to:` |
| `clone` | `clone: <repo>` — requires `to:`, skips if it exists |

### Conditions

Skip a step with `if:`.

| Condition | True when |
|-----------|-----------|
| `os == 'darwin'` / `'linux'` | running on that OS |
| `exists <path>` / `not exists <path>` | path exists / does not exist |
| `command_exists <bin>` | binary is on PATH |

```yaml
  - name: Install Zed
    run: brew install --cask zed
    if: not exists /Applications/Zed.app
```

### Templates

`{{ identity.name }}` and `{{ identity.email }}` interpolate into `run` commands.

## Commands

```
tin install       Full environment setup from tinrc.yml
tin init          Create personal config without applying it
tin config path   Show the effective tinrc.yml and its origin
tin status        Read-only environment state (--check-updates adds update state)
tin upgrade       Check for and install a newer release
tin link          Create managed symlinks
tin unlink        Remove symlinks and restore backups
tin heal          Inspect symlink state, then repair safely
tin fonts         Install fonts
tin recipe [name] List or run recipes
tin artifact      Browse, validate, inspect, and export skills
tin mcp           Project MCP servers into runtime configs
tin help          Command reference and discovery index
```

`tin help --index` is the machine-readable map; `tin help <topic>` documents topics.

tmux has no dedicated command: `environment/config/.tmux.conf` is a committed
script, symlinked to `~/.tmux.conf`. Edit it directly and re-apply with
`tmux source-file ~/.tmux.conf`.

## Skills and rules

`tin` publishes YAML artifacts; it does not launch or manage agents.
`tin artifact export` writes `SKILL.md` files (the
[agentskills.io](https://agentskills.io/specification) standard) to a runtime's
skill directory.

```
~/.config/tin/artifacts/
  skills/     workflows, procedures, composed skills
  rules/      reusable content blocks included by skills
  dialects/   per-runtime MCP dialects
  mcp/        MCP server declarations
```

A skill's path becomes its ID: `skills/develop/plan.yml` → `develop/plan`.

```yaml
description: Design a testable scaffold from requirements.
include: [design]
system: |
  Design function signatures with empty bodies.

  ## Design Principles
  {{ design }}
```

| Field | Purpose |
|-------|---------|
| `description` | What the skill does and when to use it (required) |
| `system` | Instructions the AI follows |
| `skills` | Other skills this one composes |
| `include` | Rules whose content replaces `{{ rule_id }}` in system |
| `context` | Set to `fork` to run in a sub-agent context |

A rule at `rules/clarity.yml`:

```yaml
description: Writing clarity rules
content: |
  - Use early returns over else blocks
  - Name booleans as questions: isValid, hasPermission
```

Export to a runtime (the target is recorded in `tinrc.yml`):

```yaml
exports:
  zed:
    dir: ~/.agents/skills
```

```bash
tin artifact export all
tin artifact validate   # references, duplicate IDs, required fields
```

Export is non-destructive: it rewrites only the folders it wrote before
(tracked in a `.tin-skills` manifest inside the target directory), so skills
other tools placed there are left alone. Removed skills are pruned on the next
export.

## MCP servers

Declare a server once in `artifacts/mcp/`, describe a runtime's format once in
`artifacts/dialects/`, and point `runtimes:` at the target file — tin renders
and merges.

```yaml
# artifacts/mcp/mem0.yml
type: http
url: https://mcp.mem0.ai/mcp
headers:
  Authorization: MEM0_API_KEY
secrets:
  - headers.Authorization
```

```yaml
# tinrc.yml
runtimes:
  cursor:
    mcp: ~/.cursor/mcp.json
    dialect: cursor
  codex:
    mcp: ~/.codex/config.toml
    dialect: codex
```

```
tin mcp list                List declared servers and configured runtimes
tin mcp diff [runtime]      Show the projected config without writing
tin mcp apply [runtime]     Merge servers into runtime configs (backs up to <path>.tin.bak)
```

`apply` preserves unrelated keys and is idempotent. `~/` resolves to `$HOME`;
other relative paths resolve against the current directory.

## Extending

- **New tool:** add `environment/recipes/<name>.yml`, then list it in a
  `recipes:` group in `tinrc.yml`.
- **Personal-only tool:** the same file under `~/.config/tin/recipes/`; naming it
  after a shipped recipe shadows that recipe on your machine only.
- **New config file:** put it in `environment/config/`, add a `symlinks:` entry,
  and run `tin link`.

## Repo layout

```
tinrc.yml      default config (override at ~/.config/tin/tinrc.yml)
engine/        the tin CLI: build.zig, src/, tests/, bench/
environment/   what tin applies: recipes/, config/ (dotfiles), examples/
install.sh     bootstrap script
```

## Building and testing

Requires [Zig 0.15.2](https://ziglang.org/download/).

```bash
cd engine
zig build              # build
zig build test         # default suite: unit, integration, flow, expressions (local only)
zig build test-unit    # unit tests only
zig build bench        # performance benchmarks
bash tests/installer.sh   # installer regression suite (offline)
```

The YAML spec suite needs the official corpus at the pinned revision and is
never fetched implicitly:

```bash
cd engine
zig build test-yaml -- /path/to/yaml-test-suite
```

Provision it at the revision in `engine/tests/yaml-suite-revision.txt`. The
runner exits 1 for an empty or wrong-layout corpus, a revision mismatch, or a
compliance failure.

## Supported platforms

- macOS (arm64, x86_64)
- Linux (x86_64, aarch64) — Debian/Ubuntu (apt)
