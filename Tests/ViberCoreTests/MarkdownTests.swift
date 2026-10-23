import XCTest
@testable import ViberCore

final class MarkdownTests: XCTestCase {
    private func plain(_ text: AttributedString) -> String { String(text.characters) }

    private func texts(_ blocks: [MarkdownBlock]) -> [String] {
        blocks.compactMap { if case .paragraph(let text) = $0 { return plain(text) } else { return nil } }
    }

    func testHeadingsKeepLevelsAndInlineStyling() {
        let blocks = Markdown.blocks("# Title\n\nSome **bold** text\n\n### Small")
        guard blocks.count == 3, case .heading(level: 1, let title) = blocks[0], case .paragraph(let body) = blocks[1],
              case .heading(level: 3, let small) = blocks[2] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(plain(title), "Title")
        XCTAssertEqual(plain(body), "Some bold text")
        XCTAssertEqual(plain(small), "Small")
        XCTAssertTrue(body.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    func testNestedLists() {
        let blocks = Markdown.blocks("1. First\n   - nested\n2. Second")
        guard blocks.count == 1, case .list(ordered: true, let items) = blocks[0] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(items.map(\.ordinal), [1, 2])
        XCTAssertEqual(texts(items[0].blocks), ["First"])
        guard items[0].blocks.count == 2, case .list(ordered: false, let inner) = items[0].blocks[1] else { return XCTFail("\(items)") }
        XCTAssertEqual(inner.map { texts($0.blocks) }, [["nested"]])
        XCTAssertEqual(texts(items[1].blocks), ["Second"])
    }

    func testTaskItemsBecomeCheckboxes() {
        guard case .list(ordered: false, let items)? = Markdown.blocks("- [ ] todo\n- [x] done\n- plain").first else { return XCTFail() }
        XCTAssertEqual(items.map(\.checked), [false, true, nil])
        XCTAssertEqual(items.map { texts($0.blocks) }, [["todo"], ["done"], ["plain"]])
    }

    func testTable() {
        let blocks = Markdown.blocks("| A | B |\n|:--|--:|\n| 1 | 2 |\n| 3 |  |")
        guard case .table(let alignments, let header, let rows)? = blocks.first else { return XCTFail("\(blocks)") }
        XCTAssertEqual(alignments, [.leading, .trailing])
        XCTAssertEqual(header.map(plain), ["A", "B"])
        XCTAssertEqual(rows.map { $0.map(plain) }, [["1", "2"], ["3", ""]])
    }

    func testCodeQuoteAndRule() {
        let blocks = Markdown.blocks("```swift\nlet x = 1\n```\n\n> quoted\n\n---")
        guard blocks.count == 3, case .quote(let inner) = blocks[1] else { return XCTFail("\(blocks)") }
        XCTAssertEqual(blocks[0], .code("let x = 1"))
        XCTAssertEqual(texts(inner), ["quoted"])
        XCTAssertEqual(blocks[2], .rule)
    }

    func testUnclosedFenceWhileStreaming() {
        let blocks = Markdown.blocks("Here:\n\n```bash\nswift build")
        XCTAssertEqual(texts(blocks), ["Here:"])
        XCTAssertEqual(blocks.last, .code("swift build"))
    }

    func testStreamingMatchesAFullParse() {
        // The finished part is split off at the last paragraph break outside the open fence.
        let text = "# Title\n\nDone paragraph.\n\n```swift\nlet a = 1\n\nlet b = 2"
        XCTAssertEqual(Markdown.streamingBlocks(text), Markdown.blocks(text))
        XCTAssertEqual(Markdown.streamingBlocks(text).last, .code("let a = 1\n\nlet b = 2"))
    }

    func testPlainAndEmpty() {
        XCTAssertEqual(Markdown.blocks(""), [])
        XCTAssertEqual(Markdown.blocks("  \n"), [])
        XCTAssertEqual(texts(Markdown.blocks("just text")), ["just text"])
    }
}
