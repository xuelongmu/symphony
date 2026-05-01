---
name: babysit
description:
  Keep a pull request healthy without merging it; use when asked to babysit,
  shepherd, monitor, address feedback, fix CI, or keep a PR ready for merge.
---

# Babysit

## Goals

- Keep the current branch PR conflict-free, reviewed, and green.
- Address actionable review feedback and CI failures.
- Run the same 10-minute post-green feedback wait as `land`.
- Stop with a readiness report and merge command.
- Never merge, squash-merge, delete branches, or enable auto-merge.

## Preconditions

- `gh` CLI is authenticated.
- You are on the PR branch.

## Steps

1. Locate the PR for the current branch with `gh pr view`.
2. If the working tree has uncommitted changes, commit with the `commit` skill
   and push with the `push` skill before monitoring.
3. Check mergeability and whether the PR is behind its base branch.
4. If behind or conflicting, use the `pull` skill to merge `origin/main`,
   resolve conflicts, then use the `push` skill.
5. Run the watcher:
   ```sh
   python3 .codex/skills/land/land_watch.py
   ```
6. If the watcher exits `2`, fetch top-level comments, inline review comments,
   review summaries, unresolved threads when available, latest checks, and bot
   feedback. Classify each item, address actionable feedback, commit with the
   `commit` skill, push with the `push` skill, and rerun the watcher.
7. If the watcher exits `3`, inspect failing checks with `gh pr checks` and
   `gh run view --log`, fix the failure when concrete, commit, push, and rerun
   the watcher.
8. If the watcher exits `4`, refresh local state from the remote branch and
   rerun the watcher.
9. When the watcher succeeds, do not merge. Report the PR as ready and include:
   ```sh
   gh pr merge <number> --squash
   ```

## Review Handling

- Treat human review feedback as blocking until addressed or explicitly pushed
  back with rationale.
- Treat Codex review feedback as actionable when it raises a correctness,
  validation, or scope issue.
- Use the same `[codex]` reply convention as `land` when writing GitHub
  comments.
- Do not over-expand the PR scope. If a review asks for unrelated work, explain
  the deferral and suggest a follow-up.

## Output

```
PR #<number>: <title>
Status: <what was handled this cycle>
Ready: <yes/no>
Merge: gh pr merge <number> --squash
Blocking: <remaining blocker or "none">
```
