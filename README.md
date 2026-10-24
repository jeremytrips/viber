# Viber

Viber is a native macOS app that runs Claude Code sessions as chats. It drives the real `claude` CLI in stream-json mode (optionally through `clauth start <profile> -- …`), so sessions use your normal Claude Code login, settings, hooks, skills, and transcripts. Viber adds a sessions sidebar, chat UI, worktrees, cache and usage indicators, and notifications.

## Requirements

- macOS 14 or later
- Swift toolchain (Xcode 15.3+ or matching command line tools) to build
- The `claude` CLI on your PATH (`~/.local/bin`, Homebrew, npm and bun locations are searched too)
- Optional: `clauth` for multiple profiles and the usage bar. Run `clauth daemon` to keep usage fresh.
- Optional: `gh` for the `ship` and `cleanup` skills
- Optional: Xcode with an iOS simulator runtime for the device panel

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
- **Chat**: streamed replies, tool calls summarized inline, Claude's thinking folded into a row you can open, stop with ⌘.
- **Agents**: each subagent Claude starts gets a card. While it runs, the card shows its last step, tool count, tokens and time, and a Stop button. A background agent stays running after the turn that started it. When it ends, its report shows on the card, Markdown-formatted and cut to a preview you can expand. Open the card to see the prompt Claude gave it and every tool call it made. When a background agent finishes, Claude reads its report in a turn of its own, which shows as working. Permission requests from an agent say which agent asks. Resumed sessions rebuild the cards from the agents' own transcripts.
- **Checklist**: when Claude keeps a task list (`TaskCreate`/`TaskUpdate`, or `TodoWrite` on older setups), it stays pinned above the message box until everything on it is done. Claude Code only offers these tools to current models when `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` is set (for example under `env` in `~/.claude/settings.json`).
- **Rewind files**: hover a message you sent (or right-click it) and choose rewind to put files back the way they were before it, like Esc Esc → restore code in the terminal. Viber shows which files would change and asks first; the conversation itself is left as it is.
- **Images and files**: paste (⌘V), drop or attach (paperclip) images to send them with a message; they are scaled to at most 2000 px. Other files and folders are mentioned as `@path`, and typing `@` offers the project's files (from `git ls-files`).
- **Cards** for permission requests, questions from Claude (`AskUserQuestion`), plans to approve (`ExitPlanMode`), and MCP servers asking for input (a form built from the server's schema, or a page to open in the browser).
- **Slash commands**: type `/` for a menu. Commands that only exist in Claude Code's terminal UI are handled by Viber:
  - `/plan [prompt]` switches to plan mode (and sends the prompt, if any)
  - `/model [name]` switches model, or opens a picker
  - `/clear` starts a fresh conversation in the same session
  - `/resume` opens the resume picker
  - `/cost` shows tokens and cost for the session
  - `/tasks` (or `/bashes`) opens the session's background tasks
  - `/add-dir <path>` lets Claude work in another folder for this session (bare `/add-dir` opens Permissions)
  - `/mcp`, `/context` (or `/usage`), `/permissions`, `/hooks` and `/settings` (or bare `/config`, `/effort`, `/output-style`) open the session's settings on that tab. With arguments, `/mcp reconnect all`, `/effort high` and `/config key=value` still go to the CLI, which handles them itself.

  Everything else (skills, custom commands) is sent to the CLI as text. Viber's own skills work as `/cleanup` as well as `/viber:cleanup`.
- **Session settings** (the sliders button in the session header, ⌥⌘, or the commands above) are the terminal panels for one conversation, drawn from the CLI's control requests:
  - **MCP**: every server with its status, tools and errors. Sign in (opens the browser; the row turns connected when you finish), retry, reconnect, sign out, and turn a server off or on. Like `/mcp` in the terminal, on/off is saved for the project. The header shows "MCP 5/7", orange when a server needs sign-in or failed.
  - **Context**: where the context window goes, by category, plus the session's cost. Compact now, with optional instructions.
  - **Permissions**: the rules in effect and where each comes from. Add or remove a folder Claude can work in for this session (like `/add-dir`), and add or remove a rule for *this session* (kept across relaunches, gone when the session closes), *this project, just me* (`.claude/settings.local.json`, which Viber keeps out of git) or *this project, shared* (`.claude/settings.json`). Claude Code picks file changes up right away.
  - **Hooks**: every hook that runs, from settings files and plugins. Read-only; buttons open the settings files.
  - **Tasks**: shell commands Claude runs in the background, subagents and monitors, running and recently finished. Read a shell's output (kept current while open) or stop a task. The header shows "Tasks 2 running" while any run.
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
- **Browser preview** (the Safari button in the session header, ⇧⌘B): a browser beside the chat that you and Claude share, so Claude can check its own web work.
  - **Viber serves the tools itself.** They come from an MCP server built into Viber, over the same stdio channel, so there's nothing to install. Every session gets them.
  - **The tools:**
    - `preview_open` loads a dev server URL.
    - `preview_screenshot` captures the page. It first waits for the hot update after Claude's last edit (Vite, Next.js, webpack), then for the page to settle.
    - `preview_snapshot` gives an outline of the page with element refs.
    - `preview_console` returns console output, uncaught errors and failed requests.
    - `preview_click`, `preview_type`, `preview_eval` and `preview_wait` act on the page.
  - **Permissions:** looking never asks. Clicking, typing and scripts are approved automatically on local pages, and ask anywhere else. Both are configurable under Settings → General.
  - **Pick an element (⇧⌘C).** Click something in the page and it is attached to your next message, with its selector, HTML and, for React, Vue and Svelte dev builds, the component and source file. So "make this bigger" edits the right code.
  - **Handy extras:**
    - When a command prints a local URL (a dev server starting), its row offers *Open in preview*.
    - The console button shows errors since the last load.
    - The page keeps running while you look at other sessions, and the URL is restored after a relaunch.
- **Device panel** (the iPhone button in the session header, ⇧⌘D): an iOS simulator beside the chat that you and Claude share, so Claude can check its own app work.
  - **It runs inside Viber.** The simulator's screen streams into the panel. Click and drag to touch, scroll to swipe, and type when the screen has focus (⌘V pastes your Mac clipboard). Simulator.app doesn't need to be open. Pick a simulator from the menu at the top left; it boots if it is off. Simulators are shared, so two sessions can show the same one.
  - **The tools:**
    - `device_open` boots and shows a simulator; `device_list` lists them.
    - `device_install` and `device_launch` run a `.app` built for the simulator. `device_open_url` opens deep links and `exp://` URLs for Expo Go.
    - `device_screenshot` captures the screen, one pixel per point. `device_snapshot` gives an outline of the screen's accessibility tree with element refs.
    - `device_tap`, `device_swipe`, `device_type` and `device_press` (home, lock, Siri, volume) act on it. `device_wait` waits for text, and `device_logs` reads the log.
  - **Permissions:** looking never asks. Tapping, typing, installing and launching are approved automatically on simulators. Both are configurable under Settings → General.
  - **Pick an element** (the arrow button) attaches what you click to your next message, with its label, accessibility identifier and frame. The camera button attaches a screenshot.
  - **Run on device**: when a command's output shows a simulator build (`…-iphonesimulator/MyApp.app`) or an Expo URL, its row offers to run it in the panel.
  - **How it works:** the live screen, touches, keys and the accessibility tree use Apple's private CoreSimulator and SimulatorKit frameworks, loaded at runtime, in the way [idb](https://github.com/facebook/idb) (MIT) and [serve-sim](https://github.com/EvanBacon/serve-sim) (Apache-2.0) do; Viber's bridge follows their code. Everything else goes through `xcrun simctl`. If an Xcode update breaks the private part, the panel says so and Claude's tools fall back to `simctl` where they can. Xcode 27's simulators no longer accept this kind of input, so on Xcode 27 the screen shows but clicks and keys don't reach it yet.
- **Worktrees**: start a session in a new git worktree at `<repo>/.claude/worktrees/<slug>` on branch `viber/<slug>`. If the folder isn't a git repository yet, **Create One** in the New Session sheet runs `git init` and commits a README titled after the folder. Closing can remove the worktree (refused if it has uncommitted changes) and delete the branch (`git branch -d` only, so unmerged branches are kept).
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
| ⇧⌘B | Show or hide the browser preview |
| ⌘R | Reload the preview |
| ⇧⌘C | Pick an element in the preview |
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
