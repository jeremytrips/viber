---
name: handoff
description: Write a concise status note for this session so someone (or a later session) can pick the work up. Use before pausing, switching tasks, or handing work to someone else.
---

# Write a handoff note

Reply with a status note, nothing else. Base it on this conversation and on the repository state; check `git status`, `git diff --stat`, and `git log --oneline -10` so the facts are current.

Use exactly these sections, concise bullet points, no filler:

## Goal
What this session is trying to achieve, in one or two sentences.

## Done
What is finished and working. Mention commits or PRs by hash or URL.

## In progress
What is partially done, and the exact state it is in (uncommitted changes, failing tests, half-applied refactor).

## Next steps
Ordered, concrete actions. The first one should be doable immediately.

## Open questions
Decisions or unknowns that need the user's input. Write "None" if there are none.

## Files touched
Paths changed in this session, with a few words each.

Rules:

- Be specific: file paths, function names, commands, error messages.
- Do not invent progress. If something was not verified, say so.
- Keep it short enough to read in a minute.

If running in Viber (`VIBER_PANE_ID` is set), finish with `viber notify "Handoff note ready"`.
