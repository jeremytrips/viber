// Copied from claude-cache/Sources/CompanionCore/VSCodeLink.swift. Keep in sync by hand.
import Foundation

public enum VSCodeLink {
    /// Only local absolute project paths are accepted; never interpret transcript text as a URL.
    public static func url(for projectPath: String) -> URL? {
        guard projectPath.hasPrefix("/"),
              projectPath.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        var components = URLComponents()
        components.scheme = "vscode"
        components.host = "file"
        // The trailing slash explicitly identifies a folder, including names ending in :digits.
        components.path = projectPath.hasSuffix("/") ? projectPath : projectPath + "/"
        // Without this VS Code swaps the folder into the last active window, closing what was there
        // (e.g. the main checkout when opening a worktree). A folder that is already open is still just focused.
        components.queryItems = [URLQueryItem(name: "windowId", value: "_blank")]
        return components.url
    }
}
