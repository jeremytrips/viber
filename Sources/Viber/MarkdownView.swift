import SwiftUI
import ViberCore

/// Markdown drawn as blocks: headings, lists, quotes, tables and code boxes, with inline styling.
struct MarkdownText: View {
    let text: String
    /// Text still arriving: only its unfinished tail is parsed again on each change.
    var streaming = false

    var body: some View {
        MarkdownBlocks(blocks: streaming ? Markdown.streamingBlocks(text) : Markdown.blocks(text), depth: 0)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlocks: View {
    let blocks: [MarkdownBlock]
    /// List nesting, for alternating bullets.
    let depth: Int
    var spacing: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, depth: depth)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let depth: Int

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(text).font(.body)
        case .heading(let level, let text):
            Text(text).font(Self.font(level)).padding(.top, level <= 2 ? 4 : 0)
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(.callout, design: .monospaced)).padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        case .quote(let blocks):
            MarkdownBlocks(blocks: blocks, depth: depth)
                .foregroundStyle(.secondary)
                .padding(.leading, 13)
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(.separator).frame(width: 3) }
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        marker(ordered: ordered, item: item).frame(minWidth: 16, alignment: .trailing)
                        MarkdownBlocks(blocks: item.blocks, depth: depth + 1, spacing: 4)
                    }
                }
            }
        case .table(let alignments, let header, let rows):
            MarkdownTable(alignments: alignments, header: header, rows: rows)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    @ViewBuilder private func marker(ordered: Bool, item: MarkdownListItem) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square" : "square").foregroundStyle(.secondary)
        } else {
            Text(ordered ? "\(item.ordinal)." : depth % 2 == 0 ? "•" : "◦").monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private static func font(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.bold()
        case 2: return .title3.weight(.semibold)
        case 3: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }
}

private struct MarkdownTable: View {
    let alignments: [MarkdownAlignment]
    let header: [AttributedString]
    let rows: [[AttributedString]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow { cells(header, bold: true) }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow { cells(row, bold: false) }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        }
    }

    private func cells(_ row: [AttributedString], bold: Bool) -> some View {
        ForEach(row.indices, id: \.self) { column in
            Text(row[column])
                .fontWeight(bold ? .semibold : nil)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .gridCellAnchor(anchor(column))
        }
    }

    private func anchor(_ column: Int) -> UnitPoint {
        switch alignments[column] {
        case .leading: return .topLeading
        case .center: return .top
        case .trailing: return .topTrailing
        }
    }
}
