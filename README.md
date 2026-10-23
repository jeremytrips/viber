# Viber

Viber is a native macOS app that runs Claude Code sessions as chats. It drives the real `claude` CLI in stream-json mode (optionally through `clauth start <profile> -- …`), so sessions use your normal Claude Code login, settings, hooks, skills, and transcripts. Viber adds a sessions sidebar, chat UI, worktrees, cache and usage indicators, and notifications.

## Requirements

- macOS 14 or later
- Swift toolchain (Xcode 15.3+ or matching command line tools) to build
- The `claude` CLI on your PATH (`~/.local/bin`, Homebrew, npm and bun locations are searched too)
- Optional: `clauth` for multiple profiles and the usage bar. Run `clauth daemon` to keep usage fresh.
- Optional: `gh` for the `ship` and `cleanup` skills

## Build and install

```sh
Scripts/build-app.sh   # builds dist/Viber.app (ad-hoc signed)
Scripts/install.sh     # builds, then copies it to /Applications (quit Viber first)
```

The build is ad-hoc signed, not notarized. If macOS blocks it, try opening it once, then use System Settings > Privacy & Security > Open Anyway.

## First run

Launch Viber from /Applications and allow notifications when asked. Notifications only work from the bundled app, not from `swift run`.

## Features

- **Sessions sidebar**: every open session with its state (working, waiting for you, finished, failed). Sessions started outside Viber show up too.
- **Chat**: streamed replies, tool calls summarized inline, stop with ⌘.
- **Cards** for permission requests, questions from Claude (`AskUserQuestion`), and plans to approve (`ExitPlanMode`).
- **Slash commands**: type `/` for a menu. Commands that only exist in Claude Code's terminal UI are handled by Viber:
  - `/plan [prompt]` switches to plan mode (and sends the prompt, if any)
  - `/model [name]` switches model, or opens a picker
  - `/clear` starts a fresh conversation in the same session
  - `/resume` opens the resume picker
  - `/cost` shows tokens and cost for the session

  Everything else (skills, custom commands) is sent to the CLI as text. Viber's own skills work as `/cleanup` as well as `/viber:cleanup`.
- **Worktrees**: start a session in a new git worktree at `<repo>/.claude/worktrees/<slug>` on branch `viber/<slug>`. Closing can remove the worktree (refused if it has uncommitted changes) and delete the branch (`git branch -d` only, so unmerged branches are kept).
- **Cache ring**: time left on the prompt cache per session; Viber can warn before it expires.
- **Usage bar**: plan usage from `clauth` (start `clauth daemon` to keep it current).
- **Notifications** when a session finishes or needs you; clicking one opens that session.

### Shortcuts

| Keys | Action |
| --- | --- |
| ⌘N | New session |
| ⌘K | Jump to session |
| ⌘J | Next session waiting for you |
| ⌘1–⌘9 | Select session 1–9 |
| ⌘. | Stop Claude |
| ⌘⇧O | Open folder in VS Code |
| ⌘⇧W | Close session |
| ⌘⇧R | Resume a past session |

## The `viber` CLI and skills

Viber puts a small `viber` command on the PATH of every session it starts (with `VIBER_PANE_ID` set), and loads its plugin with `--plugin-dir`. Skills use the CLI to talk back to the app:

```sh
viber close [--remove-worktree] [--delete-branch]   # close this session after the current reply
viber notify <text…>                                # post a notification
viber rename <title…>                               # rename the session in the sidebar
```

Outside a Viber session it exits with status 2.

Skills in `plugin/skills`:

- `/cleanup`: checks that the branch is merged (including squash merges via `gh`), with no uncommitted changes, unpushed commits, or stashes, then asks Viber to remove the worktree and branch. It never deletes anything itself.
- `/ship`: reviews the diff, commits, pushes, and opens a PR.
- `/sync`: rebases onto the latest base branch and resolves conflicts carefully; never force-pushes without asking.
- `/handoff`: writes a status note (goal, done, in progress, next steps, open questions, files touched).

## Development

```sh
swift test
VIBER_PLUGIN_DIR=$PWD/plugin swift run Viber
```

`VIBER_PLUGIN_DIR` and `VIBER_BIN_DIR` override the plugin and `viber` CLI locations that are otherwise taken from the app bundle. For the CLI in dev, build it with `swift build --product viber-ctl` and point `VIBER_BIN_DIR` at a directory containing it named `viber`. Notifications need the bundled app (`Scripts/build-app.sh`).
