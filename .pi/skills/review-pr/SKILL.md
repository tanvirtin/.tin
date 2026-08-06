---
name: review-pr
description: Understand a PR you have no context on. Spawns 4 parallel sub-agents to classify files, map dependencies, gather prerequisites, and check test coverage. Then walks you through file-by-file in dependency order. Use when assigned a review on unfamiliar code. Takes a PR number as argument. Invoke for PR review, understand PR, review context.
---

You are helping ME understand a PR. You are NOT reviewing it.
Do NOT post comments, approve, or request changes.
Your job is to give me enough context to review it myself.

The PR number is provided as the argument. Use `gh` CLI for all data.

## Step 1: Gather PR data

Run these commands to get the raw data:

```
gh pr view <NUMBER> --json title,body,author,labels,baseRefName,headRefName,additions,deletions,changedFiles,commits
gh pr diff <NUMBER> --name-only
gh pr view <NUMBER> --comments
```

Read the PR description and linked issues (grep for #NNN in the body).
If the PR description is empty or unclear, tell me — I may need to ask
the author for context before proceeding.

## Step 2: Parallel analysis

Once you have the list of changed files, spawn ALL of these sub-agents
in PARALLEL. Do NOT run them sequentially.

### Sub-agent A: File classifier
Takes the list of changed files. For each file:
- Classify into layer: infrastructure | data/schema | core/domain |
  integration/API | UI/presentation | tests
- Run `git log --oneline -5 -- <file>` to get recent history
- Return: file path, layer, last 5 commits, likely owner (most frequent author)

### Sub-agent B: Dependency mapper
Takes the list of changed files (excluding tests and config). For each:
- Read the file's imports (what it depends on)
- Grep the codebase for who imports this file (what depends on it)
- Return: file path, upstream deps, downstream dependents

### Sub-agent C: Prerequisite gatherer
Takes the full diff (`gh pr diff <NUMBER>`). For each changed hunk:
- Read the UNCHANGED code surrounding the diff (the types, structs,
  interfaces the changed code operates on)
- Trace callers of changed functions (`rg "functionName(" -l`)
- Check `git blame` on the changed lines to understand WHY the
  original code existed
- Return: list of prerequisite knowledge items, each with a brief
  explanation and file:line reference

### Sub-agent D: Test coverage analyzer
Takes the list of changed files. For each non-test file:
- Find related test files (same name with _test, _spec, test_ prefix,
  or in a tests/ directory)
- Check if the PR includes changes to those test files
- Return: file path, related test files, whether tests were updated

## Step 3: Synthesize and present overview

Once ALL sub-agents return, merge their results into:

**PR Summary** (3-5 sentences):
- What does this PR do? (from description + actual changes)
- How many files changed, in which layers?
- What's the dependency impact?

**Key Concepts** (from sub-agent C):
"Before diving into the code, understand these concepts:"
- Each prerequisite with brief explanation + file:line
- Only things NOT obvious from the diff
- Focus on the insight that makes the changes click

**Change Groups** (from sub-agents A + B):
Group changed files by logical purpose, not just by layer.
For each group:
- Name and purpose (what this group accomplishes)
- Files in the group
- **Depends on:** which groups must be understood first
- **Enables:** what other groups need this

**Recommended review sequence:**
Numbered list of groups in dependency order:
1. Start with [group] because [reason]
2. Then [group] because [reason]
3. ...

**Gotchas and Non-Obvious Details:**
- Things that look wrong but are intentional
- Implicit assumptions in the code
- Tricky parts that might confuse a first-time reader

Then say: "Ready to walk through file 1?"

## Step 4: Guided file-by-file walkthrough

Present ONE file at a time. For each file, show:

- **Module** — one sentence about what this file owns
- **Why it changed** — from commits and PR description
- **Context** — prerequisites specific to this file (from sub-agent C):
  types it operates on, who calls it, git history of changed lines
- **What to look for** — apply these checks to this file's diff:

  **Changed signatures:**
- Did function parameters change? Check every caller.
- Did return types change? Check every consumer.
- Did error types change? Check every error handler.

**Edge cases:**
- New code paths: what happens with nil, empty, zero, max values?
- Boundary conditions: off-by-one in loops, ranges, slices?
- Concurrency: is shared state accessed from multiple threads?

**Deleted code:**
- Is the deleted code still referenced elsewhere?
- Was it the only implementation of an interface?
- Did it handle an edge case that the new code doesn't?

**New dependencies:**
- New imports: are they necessary? Do they add weight?
- New external calls: network, filesystem, database — are they behind boundaries?
- New parameters: are they threaded through too many layers?

**Error handling:**
- Can new code fail? Is the failure handled?
- Are errors swallowed silently?
- Are error messages specific enough to diagnose?

**Test coverage:**
- Does the PR change behavior? Are tests updated?
- Are new code paths exercised by tests?
- Are error paths tested, not just happy paths?

**Blast radius:**
- What else in the codebase depends on the changed code?
- Could downstream consumers break from this change?
- Are there implicit contracts (ordering, timing, format) that changed?


  Also watch for these anti-patterns:

  **God Object:**
A single file doing too much. Diff signal: one file with many unrelated changes,
imported everywhere, 500+ lines and growing.
Fix: extract responsibilities into focused modules.

**Shotgun Surgery:**
One logical change scattered across many files. Diff signal: 10+ files changed
for one feature, same edit repeated everywhere.
Fix: consolidate. If one change touches many files, the boundaries are wrong.

**Feature Envy:**
A function that uses another module's data more than its own. Diff signal: heavy
cross-module imports, reaching deep into another object's properties.
Fix: move the function closer to the data it uses.

**Premature Abstraction:**
Abstracting before there are multiple cases. Diff signal: interface with one
implementor, factory creating one type, generic solution for one problem.
Fix: wait for the third use case (Rule of Three).

**Copy-Paste Programming:**
Duplicated code with minor variations. Diff signal: similar blocks in multiple
places differing by a parameter or two.
Fix: extract shared logic, parameterize the differences.

**Magic Numbers/Strings:**
Unexplained literals. Diff signal: `if (retries > 3)`, string keys, hardcoded
timeouts without names.
Fix: named constants that explain the WHY, not the WHAT.

**Long Method:**
Functions doing too much. Diff signal: new functions over 40 lines, multiple
nesting levels, requires scrolling.
Fix: extract sub-steps into named functions. One thing per function.

**Excessive Comments:**
Comments explaining WHAT, not WHY. Diff signal: `// increment counter`,
large blocks before straightforward code, commented-out code left in.
Fix: better naming makes comments unnecessary. Comments for intent only.


- **Test status** — are tests updated? What's not covered? (from sub-agent D)

Then STOP and ask: "Ready for the next file?"

Do NOT present the next file until I say to proceed.
If I have questions about the current file, answer them first.
If I want to skip a file, skip it.

## Step 5: Questions for the author

After all files, present questions based on gaps across the ENTIRE PR:
- Changes with no corresponding test updates (from sub-agent D)
- Behavior changes not mentioned in the PR description
- Downstream dependents that might need updating (from sub-agent B)
- Historical context that suggests caution (from sub-agent C git blame)

Present as questions I can copy-paste to the PR author.

## Rules

- Spawn sub-agents A, B, C, D in PARALLEL — do not serialize them
- Do NOT dump all files at once — one at a time, wait for me
- Do NOT show the diff — I can read the diff myself
- Do NOT review the code — tell me what to LOOK FOR
- Keep each file briefing scannable — bullets, not paragraphs
- Bottom-up order: schemas → core → integration → UI → tests → config
- If PR has >30 changed files, present the overview and ask: "This is a
  large PR. Want me to focus on a specific area? (e.g., 'the API changes'
  or 'the database migrations')"
- Focus on understanding, not describing — explain WHY, not just WHAT
- Highlight "aha moments" — what insight makes the changes click?
- Skip trivial changes (import reordering, formatting) entirely

