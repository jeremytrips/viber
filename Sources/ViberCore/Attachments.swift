import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image sent with a message, as an Anthropic `image` content block.
public struct ImageAttachment: Equatable, Sendable, Identifiable {
    public let id = UUID()
    public var label: String
    public var mediaType: String
    public var data: Data

    /// The media types the API accepts.
    public static let mediaTypes: [String: String] = [
        UTType.png.identifier: "image/png", UTType.jpeg.identifier: "image/jpeg",
        UTType.gif.identifier: "image/gif", UTType.webP.identifier: "image/webp"
    ]
    /// Longer sides are scaled down: the API resizes anything bigger anyway, and it keeps requests small.
    public static let maxPixels = 2000
    /// The API's limit is 5 MB of base64, about 3.75 MB of image.
    public static let maxBytes = 3_750_000

    public init(label: String, mediaType: String, data: Data) {
        self.label = label; self.mediaType = mediaType; self.data = data
    }

    /// An image from a file or the pasteboard, converted and scaled to what the API accepts. Nil if it is not an image.
    public init?(data: Data, label: String) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              CGImageSourceGetCount(source) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        if let mediaType = Self.mediaTypes[type], max(width, height) <= Self.maxPixels, data.count <= Self.maxBytes {
            self.init(label: label, mediaType: mediaType, data: data)
            return
        }
        // HEIC, TIFF (screenshots on the pasteboard) and oversized images are re-encoded.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: min(max(width, height, 1), Self.maxPixels)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        if let png = Self.encode(image, as: .png), png.count <= Self.maxBytes {
            self.init(label: label, mediaType: "image/png", data: png)
        } else if let jpeg = Self.encode(image, as: .jpeg, quality: 0.85), jpeg.count <= Self.maxBytes {
            self.init(label: label, mediaType: "image/jpeg", data: jpeg)
        } else {
            return nil
        }
    }

    /// An image file, or nil for anything else (those are mentioned by path instead).
    public init?(fileURL url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
              let data = try? Data(contentsOf: url) else { return nil }
        self.init(data: data, label: url.lastPathComponent)
    }

    public var block: JSON {
        ["type": "image", "source": ["type": "base64", "media_type": .string(mediaType), "data": .string(data.base64EncodedString())]]
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        let props = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(dest, image, props)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    public static func == (a: ImageAttachment, b: ImageAttachment) -> Bool { a.id == b.id }
}

/// Files of a project for `@` mentions in the composer.
public enum FileIndex {
    /// Tracked and untracked-but-not-ignored files from git, or a shallow walk outside a repo. Blocking.
    public static func list(cwd: String, limit: Int = 20_000) -> [String] {
        let git = Shell.run("git", ["ls-files", "--cached", "--others", "--exclude-standard"], cwd: cwd)
        if git.ok { return Array(git.stdout.split(separator: "\n").map(String.init).prefix(limit)) }
        var files: [String] = []
        // The real path, so the walk's URLs share its prefix (/var is a link to /private/var, and
        // Foundation's resolvingSymlinksInPath strips /private again).
        let real = realpath(cwd, nil).map { p in defer { free(p) }; return String(cString: p) } ?? cwd
        let root = URL(fileURLWithPath: real)
        let skip: Set<String> = ["node_modules", ".build", "build", "dist", "DerivedData", "Pods", "vendor"]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        for case let url as URL in walker {
            if walker.level > 4 || skip.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
            files.append(String(url.path.dropFirst(root.path.count + 1)))
            if files.count >= limit { break }
        }
        return files
    }

    /// Exact file names first, then name prefixes, path prefixes and substrings; shorter names first within each.
    public static func suggestions(_ query: String, in files: [String], limit: Int = 8) -> [String] {
        let q = query.lowercased()
        guard !q.isEmpty else { return Array(files.sorted { $0.count < $1.count }.prefix(limit)) }
        func rank(_ path: String) -> Int? {
            let p = path.lowercased()
            let name = (p as NSString).lastPathComponent
            if name == q || (name as NSString).deletingPathExtension == q { return 0 }
            if name.hasPrefix(q) { return 1 }
            if p.hasPrefix(q) { return 2 }
            if name.contains(q) { return 3 }
            if p.contains(q) { return 4 }
            return nil
        }
        let ranked: [(path: String, rank: Int)] = files.compactMap { path in rank(path).map { (path, $0) } }
        let sorted = ranked.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            let an = (a.path as NSString).lastPathComponent.count, bn = (b.path as NSString).lastPathComponent.count
            if an != bn { return an < bn }
            if a.path.count != b.path.count { return a.path.count < b.path.count }
            return a.path < b.path
        }
        return sorted.prefix(limit).map(\.path)
    }

    /// The `@` token being typed at the end of a draft, without the `@`.
    public static func mentionQuery(in draft: String) -> String? {
        let token = draft[tokenStart(draft)...]
        guard token.hasPrefix("@"), !token.dropFirst().hasPrefix("\"") else { return nil }
        return String(token.dropFirst())
    }

    /// Replaces the `@` token at the end of a draft with a mention of `path`, quoted when it has spaces.
    public static func complete(_ draft: String, with path: String) -> String {
        let mention = path.contains(" ") ? "@\"\(path)\"" : "@\(path)"
        return draft[..<tokenStart(draft)] + mention + " "
    }

    private static func tokenStart(_ draft: String) -> String.Index {
        draft.lastIndex(where: \.isWhitespace).map(draft.index(after:)) ?? draft.startIndex
    }
}
