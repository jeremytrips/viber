import Darwin
import Foundation

/// `.gitignore`-syntax matching, as the `ignore` package Claude Code uses does it: last matching pattern wins,
/// a path under an ignored directory is ignored, case doesn't matter, and directories are written with a trailing `/`.
public struct GitignoreMatcher {
    struct Rule {
        var regex: NSRegularExpression
        var negated: Bool
    }

    let rules: [Rule]

    public init(_ text: String) {
        rules = text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).compactMap { Self.rule(String($0)) }
    }

    public var isEmpty: Bool { rules.isEmpty }

    /// Whether `path` (relative, `/`-separated, a trailing `/` for a directory) matches.
    public func ignores(_ path: String) -> Bool {
        let isDirectory = path.hasSuffix("/")
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return false }
        for depth in 1..<parts.count where test(parts[0..<depth].joined(separator: "/") + "/") { return true }
        return test(parts.joined(separator: "/") + (isDirectory ? "/" : ""))
    }

    private func test(_ path: String) -> Bool {
        var ignored = false
        let range = NSRange(path.startIndex..., in: path)
        for rule in rules where rule.regex.firstMatch(in: path, range: range) != nil { ignored = !rule.negated }
        return ignored
    }

    static func rule(_ line: String) -> Rule? {
        var pattern = line
        // Trailing spaces go unless escaped with a backslash.
        while pattern.hasSuffix(" ") && !pattern.hasSuffix("\\ ") { pattern.removeLast() }
        if pattern.hasSuffix("\\ ") { pattern = String(pattern.dropLast(2)) + " " }
        guard !pattern.isEmpty, !pattern.hasPrefix("#") else { return nil }
        var negated = false
        if pattern.hasPrefix("!") { negated = true; pattern.removeFirst() }
        else if pattern.hasPrefix("\\!") || pattern.hasPrefix("\\#") { pattern.removeFirst() }
        let directoryOnly = pattern.hasSuffix("/")
        while pattern.hasSuffix("/") { pattern.removeLast() }
        guard !pattern.isEmpty else { return nil }
        // A slash at the start or in the middle anchors the pattern to the root; otherwise it matches at any depth.
        let anchored = pattern.contains("/")
        if pattern.hasPrefix("/") { pattern.removeFirst() }
        var body = ""
        var rest = Substring(pattern)
        if rest.hasPrefix("**/") { body = "(?:.*/)?"; rest = rest.dropFirst(3) }
        else if rest == "**" { body = ".*"; rest = "" }
        while let c = rest.first {
            if rest.hasPrefix("/**/") { body += "(?:/[^/]+)*/"; rest = rest.dropFirst(4); continue }
            if rest == "/**" { body += "/.+"; rest = ""; continue }
            rest = rest.dropFirst()
            switch c {
            case "*":
                while rest.first == "*" { rest = rest.dropFirst() }
                body += "[^/]*"
            case "?":
                body += "[^/]"
            case "\\":
                if let next = rest.first { body += NSRegularExpression.escapedPattern(for: String(next)); rest = rest.dropFirst() }
            case "[":
                if let close = rest.firstIndex(of: "]"), close != rest.startIndex {
                    var set = String(rest[..<close])
                    rest = rest[rest.index(after: close)...]
                    if set.hasPrefix("!") || set.hasPrefix("^") { set = "^" + set.dropFirst() }
                    body += "[" + set.replacingOccurrences(of: "[", with: "\\[") + "]"
                } else {
                    body += "\\["
                }
            default:
                body += NSRegularExpression.escapedPattern(for: String(c))
            }
        }
        let start = anchored ? "^" : "(?:^|/)"
        let end = directoryOnly ? "/$" : "/?$"
        guard let regex = try? NSRegularExpression(pattern: start + body + end, options: [.caseInsensitive]) else { return nil }
        return Rule(regex: regex, negated: negated)
    }
}

/// `.worktreeinclude`: gitignored files (such as `.env`) that Claude Code copies into each worktree it makes with git.
public enum WorktreeInclude {
    public static let fileName = ".worktreeinclude"

    /// Which files to copy, given `git ls-files --others --ignored --exclude-standard --directory` (ignored
    /// directories listed whole, with a trailing `/`). A file is copied when a pattern matches it; an ignored
    /// directory is looked into only when a pattern could reach inside it. Returns the files, and the
    /// directories to list again file by file.
    public static func select(ignored: [String], text: String) -> (files: [String], expand: [String]) {
        let patterns = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !patterns.isEmpty else { return ([], []) }
        let matcher = GitignoreMatcher(text)
        let files = ignored.filter { !$0.hasSuffix("/") && matcher.ignores($0) }
        let expand = ignored.filter { $0.hasSuffix("/") }.filter { dir in
            patterns.contains { reaches($0, into: dir) } || matcher.ignores(String(dir.dropLast())) || matcher.ignores(dir)
        }
        return (files, expand)
    }

    /// Whether `pattern` could match something inside the ignored directory `dir` (which ends in `/`).
    static func reaches(_ pattern: String, into dir: String) -> Bool {
        let p = pattern.hasPrefix("/") ? String(pattern.dropFirst()) : pattern
        if p.hasPrefix(dir) { return true }
        if let glob = p.firstIndex(where: { "*?[".contains($0) }), glob != p.startIndex, dir.hasPrefix(p[..<glob]) { return true }
        // `**/name/…`: only when that first name is one of the directory's own path components.
        var tail = Substring(p)
        while tail.hasPrefix("**/") { tail = tail.dropFirst(3) }
        guard tail.count != p.count else { return false }
        let first = tail.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let glob = first.firstIndex(where: { "*?[".contains($0) })
        let name = String(glob.map { first[..<$0] } ?? first).replacingOccurrences(of: "\\", with: "").lowercased()
        guard !name.isEmpty else { return false }
        let components = dir.dropLast().split(separator: "/").map { $0.lowercased() }
        return glob == nil ? components.contains(name) : components.contains { $0.hasPrefix(name) }
    }

    /// Copies the matching gitignored files from the checkout at `root` into the new worktree, as Claude Code does
    /// after `git worktree add`. Symlinks are skipped, and so is anything a symlink would send outside the worktree.
    /// Returns the copied paths. Blocking: call it off the main thread.
    @discardableResult
    public static func copy(from root: String, to worktree: String) -> [String] {
        guard let text = try? String(contentsOfFile: (root as NSString).appendingPathComponent(fileName), encoding: .utf8) else { return [] }
        func ignoredPaths(_ extra: [String]) -> [String] {
            let r = Shell.run("git", ["-C", root, "ls-files", "-z", "--others", "--ignored", "--exclude-standard"] + extra)
            return r.ok ? r.stdout.split(separator: "\u{0}").map(String.init) : []
        }
        let listed = ignoredPaths(["--directory"])
        guard !listed.isEmpty else { return [] }
        // Other worktrees live inside the checkout too; their files are never this worktree's to copy.
        let own = listed.filter { !$0.hasPrefix(Worktree.directory + "/") }
        var (files, expand) = select(ignored: own, text: text)
        if !expand.isEmpty {
            let matcher = GitignoreMatcher(text)
            files += ignoredPaths(["--"] + expand).filter { matcher.ignores($0) }
        }
        guard let worktreeReal = realpath(worktree) else { return [] }
        var copied: [String] = []
        let fm = FileManager.default
        for path in Set(files).sorted() {
            let source = (root as NSString).appendingPathComponent(path)
            let target = (worktree as NSString).appendingPathComponent(path)
            var info = stat()
            guard lstat(source, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            guard staysInside(target, root: worktreeReal) else { continue }
            do {
                try fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                let staged = target + ".viber-\(UUID().uuidString.prefix(8))"
                try fm.copyItem(atPath: source, toPath: staged)
                guard rename(staged, target) == 0 else { try? fm.removeItem(atPath: staged); continue }
                copied.append(path)
            } catch {
                continue
            }
        }
        return copied
    }

    /// Whether `path`, once its existing parent folders are resolved, is inside `root` (a resolved path).
    static func staysInside(_ path: String, root: String) -> Bool {
        var probe = (path as NSString).deletingLastPathComponent
        while !FileManager.default.fileExists(atPath: probe), probe != "/" { probe = (probe as NSString).deletingLastPathComponent }
        guard let resolved = realpath(probe) else { return false }
        var info = stat()
        if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK { return false }
        return resolved == root || resolved.hasPrefix(root + "/")
    }

    static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
