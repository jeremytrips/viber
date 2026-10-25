---
name: cleanup
description: Check whether this session's branch is merged and its worktree is clean, then ask Viber to close the session and remove the worktree and branch. Use when the work in this worktree is done and merged.
---

# Clean up this worktree

Decide whether the current worktree can be thrown away safely. Only read state and report; never delete anything yourself.

Hard rules: never run `git worktree remove`, `rm`, `git branch -D`, `git clean`, `git reset --hard`, or anything with `--force`. Viber does the removal, and it refuses unsafe cases on its own.

## 1. Gather facts

Run these from the current directory:

1. `git rev-parse --abbrev-ref HEAD` (branch) and `git rev-parse --show-toplevel` (this worktree's top level).
2. `git fetch --prune`.
3. Base branch: `git symbolic-ref --short refs/remotes/origin/HEAD` (strip `origin/`). If that fails, use `main` if `origin/main` exists, else `master`.
4. Merged?
   - `git merge-base --is-ancestor HEAD origin/<base>` succeeds → merged. (`git branch -r --contains HEAD` shows which remote branches contain it.)
   - Otherwise, if `gh` is available, `gh pr view --json state,mergedAt,url`. `state` = `MERGED` → merged (squash or rebase merge).
   - Otherwise → not merged.
5. Uncommitted changes: `git status --porcelain` must be empty.
6. Unpushed commits: if `git rev-parse --abbrev-ref @{u}` works, `git log --oneline @{u}..` must be empty. With no upstream, the branch counts as clean only if it is merged.
7. Stashes: `git stash list` must be empty.

## 2. Report

Show a short checklist, one line each, with the evidence:

- [x] or [ ] Merged into `<base>` (how: ancestor / PR merged + URL / not merged)
- [x] or [ ] No uncommitted changes
- [x] or [ ] No unpushed commits
- [x] or [ ] No stashes

## 3. Act

**Not clean:** list exactly what blocks cleanup (files, commits, stashes, unmerged PR) and stop. Do not offer to discard anything.

**Clean, and running in Viber** (`VIBER_PANE_ID` is set), **in the worktree Viber made for this session**: run `viber worktree`. It prints the `path:` and `branch:` Viber recorded when it made this session's worktree, and exits 1 if it made none. This is Viber's worktree only if the command succeeds and its `path` is the top level from step 1. The worktree can be anywhere (a project's WorktreeCreate hook may put it outside `.claude/worktrees/`) and its branch can have any name. Then:

```
viber close --remove-worktree --delete-branch
```

Tell the user Viber will close this session and remove the worktree and branch after this reply. If the session is on an issue (`viber issue` prints it), Viber marks it done, since the branch is merged. If the project has a WorktreeRemove hook (such as one that stops the worktree's containers), Viber runs it to remove a worktree that a WorktreeCreate hook made. Viber deletes the branch it recorded (the `branch:` line), not whatever is checked out now; if the current branch is a different one, say that it stays. It only deletes a branch whose commits are in the branch it started from, the default branch or the main checkout's current branch, so a squash-merged branch may be kept; they can delete it later with `git branch -D <branch>` if they are sure.

**Clean, but not a Viber worktree** (`viber worktree` fails, or prints a different path): say it is clean and that Viber only removes worktrees it created. Do not run `viber close`.

**Clean, but not in Viber** (`VIBER_PANE_ID` unset): print the manual commands for the user to run from the main checkout, and do not run them:

```
git worktree remove <worktree path>
git branch -d <branch>
```
