---
name: sync
description: Rebase the current branch onto the latest base branch from origin, resolving conflicts carefully. Use when the branch is behind or before shipping.
---

# Sync with the base branch

## 1. Prepare

1. `git status --porcelain`. If there are uncommitted changes, ask the user whether to commit them or stash them first. Do not discard them.
2. `git fetch --prune origin`.
3. Base branch: `git symbolic-ref --short refs/remotes/origin/HEAD` (strip `origin/`), falling back to `main` or `master`.
4. `git log --oneline HEAD..origin/<base>`. If empty, report that the branch is already up to date and stop.

## 2. Rebase

`git rebase origin/<base>`

If it stops on conflicts, resolve them one file at a time:

1. `git status` to list conflicted files.
2. For each file, read both sides and understand what each change was trying to do (`git log -p origin/<base> -- <file>` helps).
3. Edit the file to keep both intents. Explain your choice in one or two sentences per file.
4. If the intent is ambiguous or the two changes truly contradict each other, stop and ask the user. Do not guess.
5. `git add <file>`, then `git rebase --continue` once all files are resolved.

If the rebase becomes a mess, `git rebase --abort` returns to the starting point; tell the user and ask how to proceed.

## 3. Verify

- If the project has an obvious test command (`swift test`, `npm test`, `pytest`, `cargo test`, `go test ./...`, `make test`), run it and report the result.
- Summarize: how many commits were pulled in, which conflicts were resolved and how, test status.

## 4. Push

If the branch was already pushed, the rebase rewrote its history and a normal push will be rejected. Never force-push without asking. Ask the user, and only on a yes run `git push --force-with-lease`.
