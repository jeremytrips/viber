---
name: idea
description: Save an idea, follow-up or out-of-scope task to this project's idea list in Viber, so a later session can plan it. Use when the user asks to note something for later, or when you notice worthwhile work outside the current task that should not be done now.
---

# Save an idea for later

Viber keeps a list of ideas per project: things to do later that nobody has planned yet. The user can start a plan-mode session for any of them with one click, and that session sees only the idea's text, not this conversation.

This only works inside Viber (`VIBER_PANE_ID` is set). Otherwise, tell the user, show the idea as text, and stop.

1. Run `viber idea list` to see what is already there. If the same idea is listed, don't add it again; tell the user it is already on the list.
2. Write the idea so it stands on its own:
   - First line: a short title, under 50 characters, that says what to do. Viber uses it for the session and branch name.
   - Then a few lines: why it matters, where it lives (file paths, function names), and what you already know. No more than about 10 lines.
3. Save it with a heredoc, one idea per call:

   ```sh
   viber idea add - <<'EOF'
   Retry MCP servers that fail at startup
   The MCP tab shows failed servers but never retries them (Sources/ViberCore/SessionControls.swift).
   A retry with backoff on the first failure would cover flaky local servers.
   EOF
   ```

4. Tell the user in one line what you saved. Don't start working on it.

Only save ideas that are worth a session of their own; skip small things you can mention in your reply instead.
