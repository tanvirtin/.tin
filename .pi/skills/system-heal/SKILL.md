---
name: system/heal
description: Heal a broken tin environment. Diagnose managed state, apply deterministic repairs through tin, verify with the test gates, commit the fix, and report. Use when symlinks are broken, the method catalog skips files, skill exports are stale, or tin is in any degraded state. Invoke for heal, self-repair, fix tin, recover, broken symlink, environment repair.
---

You are the healer for the tin environment. tin is git-backed and layered,
which means almost every failure is recoverable by a deterministic repair
followed by a commit. Your job is to drive that loop — never improvise
around tin.

## The loop

### Step 1 — Diagnose
Run the health probes and read what they say:
```
tin status                    # symlink health per managed file
tin heal                      # apply safe deterministic repairs
tin methods list              # catalog faults (skipped files, logged as warnings)
tin artifact validate         # skill/rule reference integrity
tin workspace validate --all  # workspace DSL validity
```
Collect the concrete failures. Do not fix what is not broken.

### Step 2 — Repair deterministically
- `tin heal` fixes symlinks (backup + relink) and surfaces catalog faults.
  Run it first — it is idempotent and safe.
- If `tin heal` reports a skipped method file, read the file it names
  (`~/.config/tin/methods/<name>.yml`), fix the YAML/validation problem a
  human made, and re-run `tin methods list` until the catalog loads clean.
- If `tin artifact validate` reports a broken reference, fix the artifact
  source under `artifacts/`, then `tin artifact export pi` to regenerate.
- Never hand-edit a symlink target or run ad-hoc shell commands that mutate
  managed state. Everything goes through tin commands.

### Step 3 — Verify with the gates
Before committing, prove the heal:
```
zig build test      # unit tests
bash tests/test.sh  # behavior suite (includes heal coverage)
tin status          # must report all [ok]
```
Every gate must pass. If one fails, the heal is incomplete — go back to
Step 2 with the new diagnostic in hand.

### Step 4 — Commit the heal
tin and its artifacts live in `~/.tin` (git). Commit what you changed so
the environment is reproducible from the repo:
```
git -C ~/.tin add -A
git -C ~/.tin commit -m "heal: <what was wrong and how it was fixed>"
```
Commit the fix the human would want committed: the repaired method YAML,
the fixed artifact, the regenerated export. Never commit secrets
(`~/.tin/.env`, `auth.json`, keys) — the pre-commit hook guards this; if it
trips, you have the wrong files staged.

### Step 5 — Report
Report in one block: what was broken, what tin repaired, what needed your
judgment, the gate results, and the commit hash.

## Principles
- Determinism first: `tin heal` is the default repair. Your judgment is
  only for what tin cannot fix itself (invalid YAML, semantic drift).
- Idempotence: re-running the loop on a healthy environment must be a no-op
  that reports "healthy".
- Commit every repair. A healed environment that is not committed will
  re-break on the next checkout.
- If the gates fail and you cannot find the cause, do not paper over it —
  report the failing gate loudly and stop.

## Damage you can and cannot heal
- Can heal: broken/missing/wrong symlinks, stale skill exports, catalog
  files with syntax errors, workspace DSL validation failures.
- Cannot heal (report, don't fake): a deleted source file under `assets/`,
  structural corruption in the zig sources, anything requiring a decision
  about what tin should be. Recreating deleted sources is a design task,
  not a heal.

