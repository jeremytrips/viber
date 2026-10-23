---
name: ship
description: Commit the current work with a clear message, push the branch, and open a pull request against the base branch. Use when the change is ready for review.
---

# Ship this branch as a pull request

## 1. Review what will be shipped

1. `git status` and `git diff` (plus `git diff --staged`). Read the changes; do not ship blind.
2. Look for files that do not belong: build output, secrets or `.env` files, large binaries, scratch files, unrelated edits. If any are present, list them and ask the user what to include before committing.
3. If you are on the base branch itself (`main`/`master`), stop and ask whether to create a branch first.

## 2. Commit

1. Stage the intended files explicitly (`git add <paths>`); avoid `git add -A` when unexpected files exist.
2. Write a commit message: a short imperative subject (≤ 72 chars), a blank line, then a body explaining what changed and why. Follow the repo's existing style (check `git log --oneline -10`).
3. `git commit`. If a hook fails, fix the cause and commit again; never use `--no-verify`.
4. If there is nothing to commit but the branch has commits ahead of the base, continue with push.

## 3. Push

- No upstream (`git rev-parse --abbrev-ref @{u}` fails): `git push -u origin HEAD`.
- Otherwise: `git push`. If it is rejected, do not force-push; suggest running sync first.

## 4. Open the pull request

1. Base branch: `git symbolic-ref --short refs/remotes/origin/HEAD` (strip `origin/`), falling back to `main` or `master`.
2. If `gh pr view --json url` already finds a PR for this branch, report its URL and stop.
3. Otherwise run `gh pr create --base <base>` with a written `--title` and `--body` (summary, notable changes, how it was tested). `--fill` is fine for a single well-described commit.
4. Output the PR URL on its own line.

If `gh` is not installed or not authenticated, say so and give the compare URL instead, built from `git remote get-url origin`:
`https://github.com/<owner>/<repo>/compare/<base>...<branch>?expand=1`

If running in Viber (`VIBER_PANE_ID` is set), you may finish with `viber notify "PR opened"`.
