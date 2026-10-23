import Foundation
import ViberCore

// `viber`: lets skills running inside a Viber session ask the app to do things.
// Requests are dropped as files into ViberPaths.requests and handled by the app.

let usage = """
usage: viber close [--remove-worktree] [--delete-branch]
       viber notify <text...>
       viber rename <title...>
       viber --help

Talks to the Viber app that runs this Claude Code session.
  close    Close this session once the current reply finishes.
           --remove-worktree  also remove its git worktree (refused if it has uncommitted changes)
           --delete-branch    also delete its branch with `git branch -d` (kept if not merged)
  notify   Show a macOS notification for this session.
  rename   Set this session's title in the sidebar.
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
default:
    fail("viber: unknown command: \(command)\n\n\(usage)", code: 64)
}

do {
    try request.write()
} catch {
    fail("viber: could not send the request to Viber: \(error.localizedDescription)", code: 1)
}
print(confirmation)
