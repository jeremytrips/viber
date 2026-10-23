import Foundation

/// A block of Markdown, parsed with Foundation's GFM parser, for the chat to draw.
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(AttributedString)
    case heading(level: Int, AttributedString)
    case code(String)
    case quote([MarkdownBlock])
    case list(ordered: Bool, items: [MarkdownListItem])
    case table(alignments: [MarkdownAlignment], header: [AttributedString], rows: [[AttributedString]])
    case rule
}

public struct MarkdownListItem: Equatable, Sendable {
    public var ordinal: Int
    /// Set for task items (`- [ ]`, `- [x]`).
    public var checked: Bool?
    public var blocks: [MarkdownBlock]
}

public enum MarkdownAlignment: Equatable, Sendable { case leading, center, trailing }

public enum Markdown {
    private final class Box { let blocks: [MarkdownBlock]; init(_ blocks: [MarkdownBlock]) { self.blocks = blocks } }
    private static let cache: NSCache<NSString, Box> = { let cache = NSCache<NSString, Box>(); cache.countLimit = 300; return cache }()

    /// The blocks of `text`, memoized: chat rows ask again on every render.
    public static func blocks(_ text: String) -> [MarkdownBlock] {
        if let hit = cache.object(forKey: text as NSString) { return hit.blocks }
        let blocks = parse(text)
        cache.setObject(Box(blocks), forKey: text as NSString)
        return blocks
    }

    /// Blocks for text still streaming in. Everything before the last paragraph break outside a code fence
    /// is final, so it comes from the cache and each delta only parses the tail.
    public static func streamingBlocks(_ text: String) -> [MarkdownBlock] {
        var split = text.startIndex, inFence = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle() }
            else if !inFence, line.allSatisfy(\.isWhitespace) { split = line.startIndex }
        }
        return blocks(String(text[..<split])) + parse(String(text[split...]))
    }

    /// The text of one innermost block, with that block's intents from the outermost in.
    private struct Leaf {
        var path: [PresentationIntent.IntentType]
        var content: AttributedString
    }

    private typealias Group = (intent: PresentationIntent.IntentType?, leaves: ArraySlice<Leaf>)

    static func parse(_ text: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let document = try? AttributedString(markdown: text, options: options) else { return [.paragraph(AttributedString(text))] }
        let leaves = document.runs[\.presentationIntent].map { intent, range in
            var content = AttributedString(document[range])
            content.presentationIntent = nil
            return Leaf(path: Array((intent?.components ?? []).reversed()), content: content)
        }
        return build(leaves[...], depth: 0)
    }

    private static func build(_ leaves: ArraySlice<Leaf>, depth: Int) -> [MarkdownBlock] {
        groups(leaves, depth: depth).map { intent, group in
            switch intent?.kind {
            case .header(let level)?:
                return .heading(level: level, joined(group))
            case .codeBlock?:
                var code = String(joined(group).characters)
                if code.hasSuffix("\n") { code.removeLast() }
                return .code(code)
            case .thematicBreak?:
                return .rule
            case .blockQuote?:
                return .quote(build(group, depth: depth + 1))
            case .orderedList?:
                return .list(ordered: true, items: listItems(group, depth: depth + 1))
            case .unorderedList?:
                return .list(ordered: false, items: listItems(group, depth: depth + 1))
            case .table(let columns)?:
                return table(columns, group, depth: depth + 1)
            default:
                return .paragraph(joined(group))
            }
        }
    }

    /// A leading `[ ] ` or `[x] ` becomes a checkbox; Foundation leaves task markers as text.
    private static func listItems(_ leaves: ArraySlice<Leaf>, depth: Int) -> [MarkdownListItem] {
        groups(leaves, depth: depth).map { intent, item in
            let ordinal = if case .listItem(let n)? = intent?.kind { n } else { 1 }
            var blocks = build(item, depth: depth + 1)
            guard case .paragraph(var text)? = blocks.first,
                  let checked = ["[ ] ": false, "[x] ": true, "[X] ": true][String(text.characters.prefix(4))] else {
                return MarkdownListItem(ordinal: ordinal, checked: nil, blocks: blocks)
            }
            text.removeSubrange(text.startIndex..<text.index(text.startIndex, offsetByCharacters: 4))
            blocks[0] = .paragraph(text)
            return MarkdownListItem(ordinal: ordinal, checked: checked, blocks: blocks)
        }
    }

    private static func table(_ columns: [PresentationIntent.TableColumn], _ leaves: ArraySlice<Leaf>, depth: Int) -> MarkdownBlock {
        let empty = Array(repeating: AttributedString(), count: columns.count)
        var header = empty, rows: [[AttributedString]] = []
        for (rowIntent, row) in groups(leaves, depth: depth) {
            var cells = empty
            for (cellIntent, cell) in groups(row, depth: depth + 1) {
                if case .tableCell(let column)? = cellIntent?.kind, cells.indices.contains(column) { cells[column] = joined(cell) }
            }
            if case .tableHeaderRow? = rowIntent?.kind { header = cells } else { rows.append(cells) }
        }
        let alignments: [MarkdownAlignment] = columns.map {
            switch $0.alignment {
            case .center: return .center
            case .right: return .trailing
            default: return .leading
            }
        }
        return .table(alignments: alignments, header: header, rows: rows)
    }

    /// Consecutive leaves that belong to the same block at `depth`, with that block's intent.
    private static func groups(_ leaves: ArraySlice<Leaf>, depth: Int) -> [Group] {
        func intent(_ leaf: Leaf) -> PresentationIntent.IntentType? { depth < leaf.path.count ? leaf.path[depth] : nil }
        var result: [Group] = []
        var start = leaves.startIndex
        for index in leaves.indices.dropFirst() where intent(leaves[index])?.identity != intent(leaves[start])?.identity {
            result.append((intent(leaves[start]), leaves[start..<index]))
            start = index
        }
        if start < leaves.endIndex { result.append((intent(leaves[start]), leaves[start...])) }
        return result
    }

    private static func joined(_ leaves: ArraySlice<Leaf>) -> AttributedString {
        leaves.reduce(into: AttributedString()) { $0 += $1.content }
    }
}
