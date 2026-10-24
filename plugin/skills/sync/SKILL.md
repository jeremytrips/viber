---
name: sync
description: Bring the current branch up to date with the latest base branch from origin (rebase if it was never pushed, merge if it was), resolving conflicts carefully. Use when the branch is behind or before shipping.
---

# Sync with the base branch

Project rules come first. Look in `CLAUDE.md`, `AGENT.md` or `AGENTS.md` and the project's skills (`.claude/skills/*/SKILL.md`, such as a git or testing skill) for how to update a branch, which checks to run and push rules. Where they differ from this skill, follow them.

## 1. Prepare

1. `git status --porcelain`. If there are uncommitted changes, ask the user whether to commit them or stash them first. Do not discard them.
2. `git fetch --prune origin`.
3. Base branch: `git symbolic-ref --short refs/remotes/origin/HEAD` (strip `origin/`), falling back to `main` or `master`.
4. `git log --oneline HEAD..origin/<base>`. If empty, report that the branch is already up to date and stop.

## 2. Rebase or merge

1. Has the branch been pushed? Take its upstream (`git rev-parse --abbrev-ref @{u}`, else `origin/<branch>` if it exists). It has been pushed if `git log --oneline origin/<base>..<upstream>` lists any commits. No upstream, or an empty list: not pushed.
2. Not pushed: `git rebase origin/<base>`.
3. Pushed: merge, so pushed commits are not rewritten: `git merge --no-edit -m "Merge <base> into <branch>" origin/<base>`. Rebase a pushed branch only if the project's rules say so or the user approves.
4. If you are unsure which applies, ask the user.

If it stops on conflicts, resolve them one file at a time:

1. `git status` to list conflicted files.
2. For each file, read both sides and understand what each change was trying to do (`git log -p origin/<base> -- <file>` helps).
3. Edit the file to keep both intents. Explain your choice in one or two sentences per file.
4. If the intent is ambiguous or the two changes truly contradict each other, stop and ask the user. Do not guess.
5. `git add <file>`. Once all files are resolved, `git rebase --continue` for a rebase, or `git commit -m "Merge <base> into <branch>"` for a merge.

If it becomes a mess, `git rebase --abort` or `git merge --abort` returns to the starting point; tell the user and ask how to proceed.

## 3. Verify

- Find the project's check command: in `CLAUDE.md` / `AGENT.md`, the project's skills, then package scripts (`package.json` `check` or `test`, a `Makefile` target). Without one, use an obvious test command (`swift test`, `npm test`, `pytest`, `cargo test`, `go test ./...`, `make test`).
- Run it and report the result. If the project says long runs go to a subagent, run it in one and report the failures it finds.
- Summarize: how many commits were pulled in, rebase or merge, which conflicts were resolved and how, check status.

## 4. Push

- After a merge, a plain `git push` updates the branch. Ask before pushing.
- After a rebase of a branch that was never pushed, there is nothing to update.
- If a pushed branch was rebased, its history was rewritten and a normal push will be rejected. Never force-push without asking. Ask the user, and only on a yes run `git push --force-with-lease`.
