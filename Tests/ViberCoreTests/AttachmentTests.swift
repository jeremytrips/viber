import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ViberCore

final class AttachmentTests: XCTestCase {
    private func image(width: Int, height: Int, type: UTType) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, context.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    func testSmallPNGIsSentAsIs() throws {
        let data = image(width: 10, height: 10, type: .png)
        let attachment = try XCTUnwrap(ImageAttachment(data: data, label: "dot.png"))
        XCTAssertEqual(attachment.mediaType, "image/png")
        XCTAssertEqual(attachment.data, data)
        XCTAssertEqual(attachment.block["source"]?["data"]?.string, data.base64EncodedString())
    }

    func testTIFFAndOversizedImagesAreReencoded() throws {
        let tiff = try XCTUnwrap(ImageAttachment(data: image(width: 20, height: 10, type: .tiff), label: "Pasted image"))
        XCTAssertEqual(tiff.mediaType, "image/png", "the API does not take TIFF")

        let big = try XCTUnwrap(ImageAttachment(data: image(width: 4000, height: 1000, type: .png), label: "wide.png"))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(big.data as CFData, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyPixelWidth] as? Int, ImageAttachment.maxPixels)
        XCTAssertEqual(props?[kCGImagePropertyPixelHeight] as? Int, 500)
    }

    func testNotAnImage() {
        XCTAssertNil(ImageAttachment(data: Data("hello".utf8), label: "x"))
        XCTAssertNil(ImageAttachment(fileURL: URL(fileURLWithPath: "/etc/hosts")))
    }

    func testMessageWithImagesSendsBlocksThenText() {
        var chat = ChatTranscript()
        let png = ImageAttachment(label: "a.png", mediaType: "image/png", data: Data([1, 2, 3]))
        let message = chat.userMessage("what is this?", images: [png])
        let content = message["message"]?["content"]?.array
        XCTAssertEqual(content?.count, 2)
        XCTAssertEqual(content?[0]["type"]?.string, "image")
        XCTAssertEqual(content?[0]["source"]?["media_type"]?.string, "image/png")
        XCTAssertEqual(content?[0]["source"]?["data"]?.string, "AQID")
        XCTAssertEqual(content?[1], ["type": "text", "text": "what is this?"])
        XCTAssertEqual(chat.items.map(\.kind), [.attachments(["a.png"]), .user("what is this?")])

        var imageOnly = ChatTranscript()
        let alone = imageOnly.userMessage("", images: [png])
        XCTAssertEqual(alone["message"]?["content"]?.array?.count, 1)
        XCTAssertEqual(imageOnly.items.map(\.kind), [.attachments(["a.png"])])

        var plain = ChatTranscript()
        XCTAssertEqual(plain.userMessage("hi")["message"]?["content"], "hi", "text-only messages stay a plain string")
    }

    func testHistoryShowsImages() {
        var chat = ChatTranscript()
        let row: JSON = ["type": "user", "uuid": "u1", "message": ["role": "user", "content": [
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "AQID"]],
            ["type": "text", "text": "look"]]]]
        chat.loadHistory(Data(row.line().utf8))
        XCTAssertEqual(chat.items.map(\.kind), [.attachments(["Image"]), .user("look")])
    }

    func testFileSuggestionsRankNamesFirst() {
        let files = ["Sources/Viber/ChatView.swift", "Sources/ViberCore/Chat.swift", "Docs/chat-notes.md", "Tests/ChatTranscriptTests.swift"]
        XCTAssertEqual(FileIndex.suggestions("chat", in: files),
                       ["Sources/ViberCore/Chat.swift", "Docs/chat-notes.md", "Sources/Viber/ChatView.swift", "Tests/ChatTranscriptTests.swift"])
        XCTAssertEqual(FileIndex.suggestions("sources/viber/", in: files), ["Sources/Viber/ChatView.swift"])
        XCTAssertEqual(FileIndex.suggestions("", in: files, limit: 1), ["Docs/chat-notes.md"])
    }

    func testMentionQueryAndCompletion() {
        XCTAssertEqual(FileIndex.mentionQuery(in: "look at @Sour"), "Sour")
        XCTAssertEqual(FileIndex.mentionQuery(in: "@"), "")
        XCTAssertEqual(FileIndex.mentionQuery(in: "line one\n@Pack"), "Pack")
        XCTAssertNil(FileIndex.mentionQuery(in: "look at @Sources "))
        XCTAssertNil(FileIndex.mentionQuery(in: "mail me@example.com"))
        XCTAssertEqual(FileIndex.complete("look at @Sour", with: "Sources/a.swift"), "look at @Sources/a.swift ")
        XCTAssertEqual(FileIndex.complete("@my", with: "My Docs/a.md"), "@\"My Docs/a.md\" ")
    }

    func testFileListFromGit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("viber-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("src/a.swift"))
        try Data("ignored.txt\n".utf8).write(to: dir.appendingPathComponent(".gitignore"))
        try Data().write(to: dir.appendingPathComponent("ignored.txt"))
        XCTAssertEqual(Set(FileIndex.list(cwd: dir.path)), ["ignored.txt", "src/a.swift"], "outside a repo: a walk that skips hidden files")
        Shell.run("git", ["init", "-q"], cwd: dir.path)
        XCTAssertEqual(Set(FileIndex.list(cwd: dir.path)), [".gitignore", "src/a.swift"], "in a repo: git's view, ignores honored")
    }
}
