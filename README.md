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
  - `/mcp`, `/context` (or `/usage`), `/permissions`, `/hooks` and `/settings` (or bare `/config`, `/effort`, `/output-style`) open the session's settings on that tab. With arguments, `/mcp reconnect all`, `/effort high` and `/config key=value` still go to the CLI, which handles them itself.

  Everything else (skills, custom commands) is sent to the CLI as text. Viber's own skills work as `/cleanup` as well as `/viber:cleanup`.
- **Session settings** (the sliders button in the session header, ⌥⌘, or the commands above) are the terminal panels for one conversation, drawn from the CLI's control requests:
  - **MCP**: every server with its status, tools and errors. Sign in (opens the browser; the row turns connected when you finish), retry, reconnect, sign out, and turn a server off or on. Like `/mcp` in the terminal, on/off is saved for the project. The header shows "MCP 5/7", orange when a server needs sign-in or failed.
  - **Context**: where the context window goes, by category, plus the session's cost. Compact now, with optional instructions.
  - **Permissions**: the rules in effect and where each comes from. Add or remove a rule for *this session* (kept across relaunches, gone when the session closes), *this project, just me* (`.claude/settings.local.json`, which Viber keeps out of git) or *this project, shared* (`.claude/settings.json`). Claude Code picks file changes up right away.
  - **Hooks**: every hook that runs, from settings files and plugins. Read-only; buttons open the settings files.
  - **Model**: model, effort and permission mode for this session; output style, saved for the project.
- **Settings** (⌘, or the gear at the bottom left of the sidebar) hold everything that is not about one conversation:
  - **General**: which notifications to post, how early to warn about cache expiry, and the permission mode new sessions start in.
  - **Permissions** and **Hooks** in `~/.claude/settings.json`, for every project.
  - **MCP** servers for every project (`claude mcp add/remove --scope user`).
  - **Model**: the model new sessions start with, and the default effort per model.

  Changes to these files apply to sessions started afterwards.
- **Messages between sessions**: start a message with `//` to send it to another open session instead of this one. A menu ranks the other sessions by what you typed (their title, project, branch and recent conversation), so `//the firmware endpoint is ready` goes to the session working on firmware. Start with a session's name (`//backend: …`) to pick it directly, or use ↑↓ to choose. The receiving session shows who it came from. If it is busy, the message waits until its current reply ends. When it finishes answering, its reply is posted back into the sender's chat (marked "Reply from …") so the sender's Claude can carry on; replies never ask for an answer, so sessions don't ping-pong.
- **Messages panel** (top of the sidebar, ⇧⌘M): every message between sessions, newest first, with who sent it to whom, whether it is queued, waiting for a reply or answered, and the reply itself. Filter by status, search, and click a session name to jump to it. Unread messages show a badge.
- **Ideas**: a list per project of things to do later that nobody has planned yet. Click the lightbulb next to a project name in the sidebar to jot one down or see that project's list (the number is how many are still to plan). The **Ideas** panel (top of the sidebar, ⇧⌘I) shows every project's ideas, filtered by *To plan*, *Started* or *Done*, with search. **Plan** starts a new session for an idea in plan mode, in a new worktree when the project is a git repo, with the idea as the first message. The idea is then marked started and links to that session. Tick an idea off when it's done, or right-click to edit, copy or delete it. Sessions can add ideas with `viber idea add` (the `/idea` skill), and each idea shows who added it. Ideas are stored by Viber, not in the repo. Project notes from earlier versions were turned into one idea each.
- **Worktrees**: start a session in a new git worktree at `<repo>/.claude/worktrees/<slug>` on branch `viber/<slug>`. Closing can remove the worktree (refused if it has uncommitted changes) and delete the branch (`git branch -d` only, so unmerged branches are kept).
- **Cache ring**: time left on the prompt cache per session; Viber can warn before it expires.
- **Usage bar**: plan usage from `clauth` (start `clauth daemon` to keep it current).
- **Notifications** when a session finishes or needs you; clicking one opens that session.

### Shortcuts

| Keys | Action |
| --- | --- |
| ⌘N | New session |
| ⌘K | Jump to session |
| ⇧⌘M | Show messages between sessions |
| ⇧⌘I | Show ideas |
| ⌘J | Next session waiting for you |
| ⌘1–⌘9 | Select session 1–9 |
| ⌘. | Stop Claude |
| ⌘⇧O | Open folder in VS Code |
| ⌘⇧W | Close session |
| ⌘⇧R | Resume a past session |
| ⌥⌘, | Session settings |
| ⌘, | Settings for all sessions |

## The `viber` CLI and skills

Viber puts a small `viber` command on the PATH of every session it starts (with `VIBER_PANE_ID` set), and loads its plugin with `--plugin-dir`. Skills use the CLI to talk back to the app:

```sh
viber close [--remove-worktree] [--delete-branch]   # close this session after the current reply
viber notify <text…>                                # post a notification
viber rename <title…>                               # rename the session in the sidebar
viber idea [list]                                   # print this project's ideas that are not done
viber idea add <text…> | add -                      # add an idea (`-` reads stdin); the first line is its title
```

Outside a Viber session it exits with status 2.

Skills in `plugin/skills`:

- `/cleanup`: checks that the branch is merged (including squash merges via `gh`), with no uncommitted changes, unpushed commits, or stashes, then asks Viber to remove the worktree and branch. It never deletes anything itself.
- `/ship`: reviews the diff, commits, pushes, and opens a PR.
- `/sync`: rebases onto the latest base branch and resolves conflicts carefully; never force-pushes without asking.
- `/handoff`: writes a status note (goal, done, in progress, next steps, open questions, files touched).
- `/idea`: saves an idea, follow-up or out-of-scope task to the project's idea list, written so a later session can plan it without this conversation. Claude also uses it on its own when it notices work outside the current task.

## Development

```sh
swift test
VIBER_PLUGIN_DIR=$PWD/plugin swift run Viber
```

`VIBER_PLUGIN_DIR` and `VIBER_BIN_DIR` override the plugin and `viber` CLI locations that are otherwise taken from the app bundle. For the CLI in dev, build it with `swift build --product viber-ctl` and point `VIBER_BIN_DIR` at a directory containing it named `viber`. Notifications need the bundled app (`Scripts/build-app.sh`).
