import Foundation
import ViberCore

// `viber`: lets skills running inside a Viber session ask the app to do things.
// Requests are dropped as files into ViberPaths.requests and handled by the app.

let usage = """
usage: viber close [--remove-worktree] [--delete-branch]
       viber worktree
       viber notify <text...>
       viber rename <title...>
       viber idea [list | add <text...> | add -]
       viber --help

Talks to the Viber app that runs this Claude Code session.
  close    Close this session once the current reply finishes.
           --remove-worktree  also remove its git worktree (refused if it has uncommitted changes)
           --delete-branch    also delete its branch with `git branch -d` (kept if not merged)
  worktree Print the worktree Viber made for this session: its path, the branch it was created on
           (the one --delete-branch deletes), and the repository. Exits 1 if Viber made none.
  notify   Show a macOS notification for this session.
  rename   Set this session's title in the sidebar.
  idea     This project's ideas: things to do later that nobody has planned yet.
           list           print the ideas that are not done (the default)
           add <text...>  add an idea (`add -` reads it from stdin); the first line is its title
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
case "idea":
    let action = args.first ?? "list"
    switch action {
    case "list":
        guard let project = ProcessInfo.processInfo.environment["VIBER_PROJECT"], !project.isEmpty else {
            fail("viber: this session was started by an older Viber; restart it to read the project's ideas", code: 2)
        }
        print(IdeaList.listing(IdeaList.load().pending(in: project), projectName: URL(fileURLWithPath: project).lastPathComponent))
        exit(0)
    case "add":
        let rest = Array(args.dropFirst())
        let text = rest == ["-"]
            ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            : rest.joined(separator: " ")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail("viber: idea add needs text\n\n\(usage)", code: 64)
        }
        guard text.count <= IdeaList.maxLength else {
            fail("viber: the idea is \(text.count) characters; keep it under \(IdeaList.maxLength)", code: 64)
        }
        request = ViberRequest(paneID: paneID, command: .idea, text: text)
        confirmation = "Viber will add the idea to this project's list in a few seconds."
    default:
        fail("viber: unknown idea action: \(action)\n\n\(usage)", code: 64)
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
