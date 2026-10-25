import Foundation
import ViberCore

// `viber`: lets skills running inside a Viber session ask the app to do things.
// Requests are dropped as files into ViberPaths.requests and handled by the app.

let usage = """
usage: viber close [--remove-worktree] [--delete-branch]
       viber worktree
       viber notify <text...>
       viber rename <title...>
       viber issue [list | show <key> | add [--parent <key>] [--blocked-by <key,...>] <text...> | add -]
       viber issue update <key> [--status <status>] [--parent <key>|none] [--blocked-by <key,...>|none]
       viber issue comment <key> <text...> | comment <key> -
       viber issue done [<what shipped...> | -]
       viber issue failed <why...> | -
       viber issue shipped [<what landed...>]
       viber --help

Talks to the Viber app that runs this Claude Code session.
  close    Close this session once the current reply finishes.
           --remove-worktree  also remove its git worktree (refused if it has uncommitted changes)
           --delete-branch    also delete its branch if it is merged (kept if not)
  worktree Print the worktree Viber made for this session: its path, the branch it was created on
           (the one --delete-branch deletes), and the repository. Exits 1 if Viber made none.
  notify   Show a macOS notification for this session.
  rename   Set this session's title in the sidebar.
  issue    This project's issues: work to do, in progress, in review or done, each with a key like EST-12.
           (no arguments) print this session's own issue; exits 1 if it has none
           list           print the issues that are not done
           show <key>     print one issue in full, with its links and comments
           add <text...>  add an issue to do (`add -` reads it from stdin); the first line is its title
                          --parent <key> makes it a sub-issue; --blocked-by <key,...> says what must be done first
           update <key>   change an issue's status (todo, progress, review, done), parent or blockers
           comment <key>  add a note to an issue
           done [what]    mark this session's issue as done, saying what shipped
           failed <why>   say this session's issue got stuck and why; it stays in progress, linked to this session
           shipped [what] this session's issue is in review: the branch is pushed or ready to merge
           After done or failed, an autopilot run moves on to its next issue.
"""

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail(usage, code: 64) }
args.removeFirst()

if ["--help", "-h", "help"].contains(command) {
    print(usage)
    exit(0)
}

guard let paneID = ProcessInfo.processInfo.environment["VIBER_PANE_ID"], !paneID.isEmpty else {
    fail("viber: not running inside a Viber session (VIBER_PANE_ID is not set)", code: 2)
}

/// The project this session's issues are filed under.
func projectPath() -> String {
    guard let project = ProcessInfo.processInfo.environment["VIBER_PROJECT"], !project.isEmpty else {
        fail("viber: this session was started by an older Viber; restart it to use the project's issues", code: 2)
    }
    return project
}

/// The issue this session is for: the one it was started for, else the one its branch is named after.
func ownIssue(in list: IssueList) -> Issue? {
    if let issue = list.issue(startedIn: paneID) { return issue }
    let head = Shell.run("git", ["rev-parse", "--abbrev-ref", "HEAD"], timeout: 5)
    guard head.ok, head.output != "HEAD" else { return nil }
    return list.issue(forBranch: head.output, in: projectPath())
}

/// Text from the arguments, or from stdin when they are just `-`.
func text(from rest: [String]) -> String {
    (rest == ["-"] ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) : rest.joined(separator: " "))
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func checkLength(_ text: String, what: String) {
    guard text.count <= IssueList.maxLength else {
        fail("viber: the \(what) is \(text.count) characters; keep it under \(IssueList.maxLength)", code: 64)
    }
}

/// `--parent <key>` and `--blocked-by <a,b>` taken out of the arguments. "none" clears them for update.
func takeLinks(from rest: inout [String]) -> (parent: String?, blockedBy: [String]?) {
    var parent: String?, blockedBy: [String]?
    var kept: [String] = []
    var index = 0
    while index < rest.count {
        let arg = rest[index]
        if arg == "--parent" || arg == "--blocked-by", index + 1 < rest.count {
            let value = rest[index + 1]
            if arg == "--parent" { parent = value.lowercased() == "none" ? "" : value }
            else { blockedBy = value.lowercased() == "none" ? [] : value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            index += 2
        } else {
            kept.append(arg)
            index += 1
        }
    }
    rest = kept
    return (parent, blockedBy)
}

/// Fails unless every key names an issue in the project.
func checkKeys(_ keys: [String], in list: IssueList) {
    for key in keys where !key.isEmpty && list.issue(key, in: projectPath()) == nil {
        fail("viber: no issue \(key) in this project (`viber issue list` shows them)", code: 1)
    }
}

let request: ViberRequest
let confirmation: String

switch command {
case "close":
    var removeWorktree = false, deleteBranch = false
    for arg in args {
        switch arg {
        case "--remove-worktree": removeWorktree = true
        case "--delete-branch": deleteBranch = true
        default: fail("viber: unknown option for close: \(arg)\n\n\(usage)", code: 64)
        }
    }
    request = ViberRequest(paneID: paneID, command: .close, removeWorktree: removeWorktree, deleteBranch: deleteBranch)
    let extras: String
    switch (removeWorktree, deleteBranch) {
    case (true, true): extras = " (worktree and branch will be removed)"
    case (true, false): extras = " (worktree will be removed)"
    case (false, true): extras = " (branch will be deleted)"
    case (false, false): extras = ""
    }
    confirmation = "Viber will close this session when the current reply finishes\(extras)."
case "worktree":
    guard args.isEmpty else { fail("viber: worktree takes no arguments\n\n\(usage)", code: 64) }
    guard let info = RecordedSessions.worktree(paneID: paneID) else {
        fail("viber: Viber made no worktree for this session", code: 1)
    }
    print("path: \(info.path)")
    print("branch: \(info.branch.isEmpty ? "(none)" : info.branch)")
    print("repo: \(info.repo)")
    print("made by: \(info.madeByHook ? "the project's WorktreeCreate hook" : "git")")
    exit(0)
case "notify", "rename":
    let text = args.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { fail("viber: \(command) needs text\n\n\(usage)", code: 64) }
    if command == "notify" {
        request = ViberRequest(paneID: paneID, command: .notify, text: text)
        confirmation = "Viber will show a notification: \(text)"
    } else {
        request = ViberRequest(paneID: paneID, command: .rename, text: text)
        confirmation = "Viber will rename this session to: \(text)"
    }
case "issue", "idea":
    let list = IssueList.load()
    let action = args.first ?? "own"
    var rest = Array(args.dropFirst())
    switch action {
    case "own":
        guard let issue = ownIssue(in: list) else { fail("viber: this session has no issue of its own", code: 1) }
        print("\(issue.key) · \(issue.status.label): \(issue.title)")
        exit(0)
    case "list":
        let project = projectPath()
        print(IssueList.listing(list.pending(in: project), in: list, projectName: URL(fileURLWithPath: project).lastPathComponent))
        exit(0)
    case "show":
        guard let key = rest.first else { fail("viber: show needs an issue key\n\n\(usage)", code: 64) }
        guard let issue = list.issue(key, in: projectPath()) else { fail("viber: no issue \(key) in this project", code: 1) }
        print(list.detail(issue))
        exit(0)
    case "add":
        let links = takeLinks(from: &rest)
        let body = text(from: rest)
        guard !body.isEmpty else { fail("viber: issue add needs text\n\n\(usage)", code: 64) }
        checkLength(body, what: "issue")
        checkKeys([links.parent ?? ""] + (links.blockedBy ?? []), in: list)
        request = ViberRequest(paneID: paneID, command: .issueAdd, text: body, parent: links.parent, blockedBy: links.blockedBy)
        confirmation = "Viber will add the issue to this project's list in a few seconds."
    case "update":
        guard let key = rest.first else { fail("viber: update needs an issue key\n\n\(usage)", code: 64) }
        rest.removeFirst()
        guard let issue = list.issue(key, in: projectPath()) else { fail("viber: no issue \(key) in this project", code: 1) }
        let links = takeLinks(from: &rest)
        var status: String?
        if let index = rest.firstIndex(of: "--status") {
            guard index + 1 < rest.count, let parsed = Issue.Status.parse(rest[index + 1]) else {
                fail("viber: --status needs one of: todo, progress, review, done", code: 64)
            }
            status = parsed.rawValue
            rest.removeSubrange(index...index + 1)
        }
        guard rest.isEmpty else { fail("viber: unknown arguments for update: \(rest.joined(separator: " "))\n\n\(usage)", code: 64) }
        guard status != nil || links.parent != nil || links.blockedBy != nil else {
            fail("viber: update needs --status, --parent or --blocked-by", code: 64)
        }
        checkKeys([links.parent ?? ""] + (links.blockedBy ?? []), in: list)
        request = ViberRequest(paneID: paneID, command: .issueUpdate, key: issue.key, status: status, parent: links.parent, blockedBy: links.blockedBy)
        var changes: [String] = []
        if let status { changes.append("move it to \(Issue.Status(rawValue: status)?.label.lowercased() ?? status)") }
        if let parent = links.parent { changes.append(parent.isEmpty ? "take it out of its parent" : "make it part of \(parent.uppercased())") }
        if let blockers = links.blockedBy { changes.append(blockers.isEmpty ? "clear what blocks it" : "mark it blocked by \(blockers.joined(separator: ", ").uppercased())") }
        confirmation = "Viber will update \(issue.key): " + changes.joined(separator: ", ") + "."
    case "comment":
        guard let key = rest.first else { fail("viber: comment needs an issue key\n\n\(usage)", code: 64) }
        rest.removeFirst()
        guard let issue = list.issue(key, in: projectPath()) else { fail("viber: no issue \(key) in this project", code: 1) }
        let body = text(from: rest)
        guard !body.isEmpty else { fail("viber: comment needs text\n\n\(usage)", code: 64) }
        checkLength(body, what: "comment")
        request = ViberRequest(paneID: paneID, command: .issueComment, text: body, key: issue.key)
        confirmation = "Viber will add the comment to \(issue.key)."
    case "done", "failed", "shipped":
        let body = text(from: rest)
        if action == "failed", body.isEmpty { fail("viber: issue failed needs the reason\n\n\(usage)", code: 64) }
        checkLength(body, what: "report")
        guard let issue = ownIssue(in: list) else {
            // A project on Jira: the session's issue is the key in its branch, and Viber's autopilot reads the report.
            if TrackerList.load().tracker(for: projectPath()) != nil {
                let head = Shell.run("git", ["rev-parse", "--abbrev-ref", "HEAD"], timeout: 5)
                guard head.ok, let key = JiraIssue.key(inBranch: head.output) else {
                    fail("viber: this session's branch names no Jira issue, so there is none to report on", code: 1)
                }
                switch action {
                case "done": request = ViberRequest(paneID: paneID, command: .issueDone, text: body, key: key)
                case "failed": request = ViberRequest(paneID: paneID, command: .issueFailed, text: body, key: key)
                default: print("\(key) is in Jira; the project's skill moves it there."); exit(0)
                }
                confirmation = "Viber will note that \(key) \(action == "done" ? "landed" : "got stuck")."
                break
            }
            fail("viber: this session has no issue of its own (it wasn't started for one, and its branch names none), so there is none to mark", code: 1)
        }
        switch action {
        case "done":
            request = ViberRequest(paneID: paneID, command: .issueDone, text: body, key: issue.key)
            confirmation = "Viber will mark \(issue.key) “\(issue.title)” as done."
        case "failed":
            request = ViberRequest(paneID: paneID, command: .issueFailed, text: body, key: issue.key)
            confirmation = "Viber will mark \(issue.key) “\(issue.title)” as stuck, with your reason."
        default:
            request = ViberRequest(paneID: paneID, command: .issueShipped, text: body, key: issue.key)
            confirmation = "Viber will move \(issue.key) “\(issue.title)” to in review."
        }
    default:
        fail("viber: unknown issue action: \(action)\n\n\(usage)", code: 64)
    }
default:
    fail("viber: unknown command: \(command)\n\n\(usage)", code: 64)
}

do {
    try request.write()
} catch {
    fail("viber: could not send the request to Viber: \(error.localizedDescription)", code: 1)
}
print(confirmation)
