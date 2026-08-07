---
name: git-worktree
description: Use git worktrees for isolated experimental changes — work in a separate directory on a throwaway branch without touching the main working tree. Use for risky refactors, parallel branches, testing a change without stashing, or any destructive experiment. Invoke for worktree, isolated branch, safe experiment, parallel branch.
---

You use `git worktree` to isolate changes instead of stashing or branching
in-place. A worktree is a second working directory on its own branch — the
main tree stays untouched.

## The pattern

```
# create an isolated worktree on a new branch
git worktree add ../<repo>-exp -b exp/<name>

# work there (cd ../<repo>-exp), commit freely
# when done, review the diff against the main branch
git -C ../<repo>-exp diff main

# merge or cherry-pick what you want, then clean up
git worktree remove ../<repo>-exp
git branch -D exp/<name>   # only if truly discarded
```

## Rules

- Never run `git worktree remove` with unmerged work you'd regret losing —
  check `git -C <wt> status` first.
- Keep experiments short-lived: a worktree that survives the day is a
  branch, not an experiment.
- The main working tree is sacred: no edits there while experimenting.
- Name worktrees and branches after the intent (`exp/rename-catalog`), not
  `tmp` or `test1`.

## When NOT to use

A two-line fix doesn't need a worktree. Use it when the change is risky,
destructive, or needs to run in parallel with the main tree intact (e.g.
building a subagent test fixture without disturbing the repo).

