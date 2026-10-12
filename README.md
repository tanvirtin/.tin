# .tin

Your developer environment as code. Clone it, run it, you're you on any machine.

## Install

```bash
# bootstrap: installs the CLI into ~/.tin, then applies your environment
curl -fsSL https://raw.githubusercontent.com/tanvirtin/.tin/master/install.sh | sh
tin install
```

```bash
# Homebrew (macOS, Linux)
brew tap tanvirtin/tin https://github.com/tanvirtin/.tin
brew install tanvirtin/tin/tin
```

Both routes install a checksum-verified prebuilt release and neither applies your
settings until `tin install`. Update with `tin upgrade`, or `brew upgrade tin`
under Homebrew.

<details>
<summary>Other install options</summary>

```bash
# build from source (requires Zig)
curl -fsSL https://raw.githubusercontent.com/tanvirtin/.tin/master/install.sh | sh -s -- --from-source

# prebuilt only (no compiler); fails if no release exists
curl -fsSL https://raw.githubusercontent.com/tanvirtin/.tin/master/install.sh | sh -s -- --from-binary

# pin a release
curl -fsSL https://raw.githubusercontent.com/tanvirtin/.tin/master/install.sh | sh -s -- --version v0.1.0
```

The Homebrew formula (`Formula/tin.rb`) installs the platform's prebuilt release
plus its runtime files under the Cellar, and adds a `tin` wrapper that points
`TIN_DIR` at them, so `~/.config/tin/tinrc.yml` still overrides the shipped
default. If the tap reads as untrusted, run `brew trust tanvirtin/tin`.

</details>

## How it works

`tin` reads `tinrc.yml` and applies it — identity, symlinks, fonts, tools. The
Zig binary is the engine; the YAML is the configuration. A personal config at
`~/.config/tin/tinrc.yml` **replaces** the shipped default (no merging).

```
~/.tin/                runtime + shared defaults (incl. tinrc.yml)
~/.config/tin/
  tinrc.yml            personal override (wins)
  artifacts/           skills, rules, dialects, MCP servers
  recipes/             personal recipes (shadow the repo's)
```

`tin init` writes a neutral `~/.config/tin/tinrc.yml`, a sample skill, and the
Zed export target — without overwriting or applying anything.

Env overrides: `TIN_DIR`, `TIN_ARTIFACTS`, `TIN_RECIPES`, `TIN_REPO_URL`,
`TIN_RELEASE_BASE_URL`, `TIN_INSTALLER_URL`, `TIN_API_BASE_URL`.

## tinrc.yml

The single source of truth; every section is optional. `~` resolves to `$HOME`
and symlink sources are relative to the repo root.

```yaml
identity:                                 # available as {{ identity.name }}
  name: Your Name
  email: you@example.com

symlinks:                                 # linked into place (add copy: true for a real file)
  shell:
    - source: environment/config/.zshrc
      target: ~/.zshrc

fonts: environment/config/fonts           # a directory of .ttf files

recipes:
  shell: [zsh, starship, zsh-autosuggestions]

install:                                  # ordered steps `tin install` runs top to bottom
  - link
  - fonts
  - recipes: shell
```

Add `copy: true` to a symlink to install a real file instead of a link — use it
when the consumer resolves relative imports from the file's real path.

## Recipes

YAML in `environment/recipes/`; `~/.config/tin/recipes/` shadows the repo's, and
`tin recipe` tags each entry `[config]` or `[repo]`.

```yaml
name: git
description: Configure git
steps:
  - name: Set user name
    run: git config --global user.name "{{ identity.name }}"
```

Steps: `run` (shell command), `install` (brew/apt), `recipe` (nested recipe),
`link`, `fonts`, `mkdir`, `download` (needs `to:`), `clone` (needs `to:`, skipped
if present). Guard any step with `if:` — `os == 'darwin'` / `'linux'`,
`exists <path>` / `not exists <path>`, `command_exists <bin>`.

```yaml
  - name: Install Zed
    run: brew install --cask zed
    if: not exists /Applications/Zed.app
```

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

`tin help --index` is the machine-readable map; `tin help <topic>` documents
topics. tmux has no dedicated command — `environment/config/.tmux.conf` is
symlinked to `~/.tmux.conf`; edit it and run `tmux source-file ~/.tmux.conf`.

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

A skill's path is its ID: `skills/develop/plan.yml` → `develop/plan`.

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

Export to a runtime (target recorded in `tinrc.yml`, e.g. `exports: { zed: { dir: ~/.agents/skills } }`):

```bash
tin artifact export all
tin artifact validate   # references, duplicate IDs, required fields
```

Export is non-destructive: it rewrites only folders it wrote before (tracked in a
`.tin-skills` manifest), so skills other tools placed there are left alone;
removed skills are pruned on the next export.

## MCP servers

Declare a server once in `artifacts/mcp/`, describe a runtime's format in
`artifacts/dialects/`, and point `runtimes:` at the target file — tin renders and
merges.

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
Formula/       Homebrew formula
packaging/     release packaging scripts (formula generator)
install.sh     bootstrap script
```

<details>
<summary>Building and testing</summary>

Requires [Zig 0.15.2](https://ziglang.org/download/).

```bash
cd engine
zig build              # build
zig build test         # default suite: unit, integration, flow, expressions (local only)
zig build test-unit    # unit tests only
zig build bench        # performance benchmarks
bash tests/installer.sh   # installer regression suite (offline)
```

The YAML spec suite needs the official corpus at the pinned revision and is never
fetched implicitly. Provision it at the revision in
`engine/tests/yaml-suite-revision.txt`, then:

```bash
cd engine
zig build test-yaml -- /path/to/yaml-test-suite
```

The runner exits 1 for an empty or wrong-layout corpus, a revision mismatch, or a
compliance failure.

Supported platforms: macOS (arm64, x86_64) · Linux (x86_64, aarch64 — Debian/Ubuntu, apt).

</details>
