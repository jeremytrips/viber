---
name: ship
description: Commit the current work with a clear message, push the branch after asking, and open a pull request against the base branch (or give the link to open one). Use when the change is ready for review.
---

# Ship this branch as a pull request

Project rules come first. Before committing, look in `CLAUDE.md`, `AGENT.md` or `AGENTS.md` and the project's skills (`.claude/skills/*/SKILL.md`, such as a git or testing skill) for the commit format, branch names, required checks and push rules. Where they differ from this skill, follow them.

## 1. Review what will be shipped

1. `git status` and `git diff` (plus `git diff --staged`). Read the changes; do not ship blind.
2. Look for files that do not belong: build output, secrets or `.env` files, large binaries, scratch files, unrelated edits. If any are present, list them and ask the user what to include before committing.
3. Base branch: `git symbolic-ref --short refs/remotes/origin/HEAD` (strip `origin/`), falling back to `main` or `master`. If you are on the base branch itself, stop and ask whether to create a branch first.

## 2. Commit

1. Run the checks the project requires before a commit (for example `pnpm check`). If the project says long runs go to a subagent, run them in one and report what fails. Fix failures before committing.
2. Stage the intended files explicitly (`git add <paths>`); avoid `git add -A` when unexpected files exist.
3. Write the commit message in the project's format. Without one: a short imperative subject (≤ 72 chars), a blank line, then a body explaining what changed and why, in the repo's existing style (check `git log --oneline -10`).
4. `git commit`. If a hook fails, fix the cause and commit again; never use `--no-verify`.
5. If there is nothing to commit but the branch has commits ahead of the base, continue with push.

## 3. Push

1. Show what would go out: the branch, the remote (`git remote get-url origin`) and the commits (`git log --oneline @{u}..`, or `git log --oneline origin/<base>..` with no upstream). If the upstream already has them all, skip to section 4.
2. Ask the user before pushing, and push only on a yes.
3. No upstream (`git rev-parse --abbrev-ref @{u}` fails): `git push -u origin HEAD`. Otherwise: `git push`. If it is rejected, do not force-push; suggest running sync first.
4. Keep the push output: Bitbucket and GitLab print the link that opens the pull request.

## 4. Open the pull request

1. Take the host, `<owner>` and `<repo>` from `git remote get-url origin`, either SSH (`git@<host>:<owner>/<repo>.git`, `ssh://git@<host>/<owner>/<repo>.git`) or HTTPS (`https://<host>/<owner>/<repo>.git`). Drop any `user@`, port and trailing `.git`. `<owner>` is the workspace on Bitbucket and the group, subgroups included, on GitLab.
2. By host:
   - **GitHub** (`github.com`): if `gh pr view --json url` already finds a PR for this branch, report its URL and stop. Otherwise run `gh pr create --base <base>` with a written `--title` and `--body` (summary, notable changes, how it was tested); `--fill` is fine for a single well-described commit. If `gh` is missing or not signed in (`gh auth status`), give the compare URL: `https://github.com/<owner>/<repo>/compare/<base>...<branch>?expand=1`.
   - **Bitbucket** (`bitbucket.org`): there is no CLI. Give the pull-request link `git push` printed, else `https://bitbucket.org/<workspace>/<repo>/pull-requests/new?source=<branch>&t=1`.
   - **GitLab** (`gitlab.com`, or a self-hosted GitLab whose push printed a merge-request link): give that link, else `https://<host>/<group>/<repo>/-/merge_requests/new?merge_request[source_branch]=<branch>`.
   - **Anything else**: report the push and say the pull request has to be opened by hand.
3. If the push output links an existing pull or merge request ("View pull request", "View merge request"), report that one instead. When the user opens it themselves, give a title and description they can paste.
4. Output the PR URL or link on its own line.

If running in Viber (`VIBER_PANE_ID` is set), you may finish with `viber notify "PR opened"`, or `viber notify "Branch pushed"` when the user still has to open it.
