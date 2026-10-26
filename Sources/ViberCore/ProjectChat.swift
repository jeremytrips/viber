import Foundation

/// A read-only chat with a project: a session in its folder for questions and planning. Claude reads the code and runs
/// commands that change nothing; anything else asks. The tools that edit files are taken away at launch, and so is
/// plan mode, whose approval would switch the session to editing.
public enum ProjectChat {
    /// What a chat is called until its first message names it.
    public static let untitled = "Chat"

    /// What a chat can do, for its help texts.
    public static let summary = "A read-only chat: Claude reads the project and plans with you, but can't edit files. Commands that could change something ask you first, unless your settings already allow them."

    /// Removed with `--disallowedTools`, so Claude doesn't see them at all. MultiEdit is gone from current versions of
    /// Claude Code; older ones still have it.
    public static let disallowedTools = ["Edit", "MultiEdit", "Write", "NotebookEdit", "EnterPlanMode", "ExitPlanMode"]

    /// Keeping a plan as an issue on Viber's own list doesn't ask; each change shows in Viber and can be undone there.
    public static let issueRule = RuleEdit(behavior: "allow", rule: "Bash(viber issue:*)")

    /// A chat's title: the first line of its first message, cut to fit the sidebar. A command (`/model opus`) names
    /// nothing, so the question after it does.
    public static func title(from message: String) -> String {
        let line = message.split(whereSeparator: \.isNewline).lazy
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .first { !$0.isEmpty } ?? ""
        guard !line.isEmpty, !line.hasPrefix("/") else { return untitled }
        guard line.count > 50 else { return line }
        let cut = line.prefix(50)
        let words = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return words.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Added to Claude Code's system prompt. `tracker` is nil for Viber's own list.
    public static func systemPrompt(project: String, tracker: ProjectTracker?) -> String {
        let name = URL(fileURLWithPath: project).lastPathComponent
        let issues: String
        if let tracker {
            issues = """
            The project's issues are in Jira (\(tracker.site)); read them with the Atlassian tools. Change Jira only when \
            the user asks you to; each change asks them first.
            """
        } else {
            issues = """
            The project's issues are Viber's own list: `viber issue list` shows the ones not done and `viber issue show <key>` \
            one in full. When the user wants to keep a plan or an idea for later, add it as an issue (the issue skill says \
            how to write one); only when they ask. A session started from an issue sees its text, not this chat.
            """
        }
        return """
        # Read-only chat

        This conversation is a chat about \(name) (\(project)), opened from Viber for questions and planning. The user \
        isn't asking you to change anything here.

        - You can't edit or create files: Edit, Write and NotebookEdit are turned off, and so is plan mode. Don't work \
        around that with the shell (no redirects into files, `sed -i`, commits, checkouts, installs, or builds and \
        scripts that write).
        - Answer from the code, the docs and the git history, and say where things are (files, functions, commits).
        - Commands that only read run without asking; anything else asks the user, so run one only when the answer \
        needs it, and say why.
        - When the user plans something, work it out with them: what would change and where, in what order, the risks \
        and the open questions. Keep it concrete enough that a later session can do the work from it.
        - \(issues)
        - When the user wants the work done, say that a chat can't make changes: they can start a session for it from \
        the project, or from an issue.
        """
    }
}
