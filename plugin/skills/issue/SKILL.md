---
name: issue
description: Save an idea, follow-up or out-of-scope task as an issue in this project's list in Viber, so a later session can plan it. Use when the user asks to note something for later, when you notice worthwhile work outside the current task that should not be done now, or when the user asks what is on the list.
---

# Save an issue for later

Viber keeps a list of issues per project: work to do, in progress, in review and done, each with a key like `EST-12`. The user can start a plan-mode session for any issue to do with one click, and that session sees only the issue's text and notes, not this conversation.

This only works inside Viber (`VIBER_PANE_ID` is set). Otherwise, tell the user, show the issue as text, and stop.

1. Run `viber issue list` to see what is already there. If the same work is listed, don't add it again; tell the user its key.
2. Write the issue so it stands on its own:
   - First line: a short title, under 50 characters, that says what to do. Viber uses it for the session and branch name.
   - Then a few lines: why it matters, where it lives (file paths, function names), and what you already know. No more than about 10 lines.
3. Save it with a heredoc, one issue per call. `--parent <key>` makes it a part of a bigger issue; `--blocked-by <key,...>` says what has to be done first (such as this session's own issue, which `viber issue` prints):

   ```sh
   viber issue add --blocked-by EST-12 - <<'EOF'
   Retry MCP servers that fail at startup
   The MCP tab shows failed servers but never retries them (Sources/ViberCore/SessionControls.swift).
   A retry with backoff on the first failure would cover flaky local servers.
   EOF
   ```

4. Tell the user in one line what you saved. Don't start working on it.

Only save issues that are worth a session of their own; skip small things you can mention in your reply instead.

Other commands: `viber issue show <key>` prints an issue with its notes, `viber issue comment <key> <text>` adds a note (for example what you found out about it), and `viber issue update <key> --status todo|progress|review|done` moves one. `viber issue done "<what shipped>"` and `viber issue shipped "<what landed>"` are for this session's own issue; /ship runs the latter.
