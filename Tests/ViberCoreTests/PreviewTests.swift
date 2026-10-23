import CoreGraphics
import XCTest
@testable import ViberCore

final class SdkMcpTests: XCTestCase {
    func testIncomingParsesOnlyMcpMessages() {
        let frame: JSON = ["type": "control_request", "request_id": "r1",
                           "request": ["subtype": "mcp_message", "server_name": "viber", "message": ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]]]
        let incoming = SdkMcp.Incoming(frame)
        XCTAssertEqual(incoming?.requestID, "r1")
        XCTAssertEqual(incoming?.server, "viber")
        XCTAssertEqual(incoming?.message["method"], "tools/list")
        XCTAssertNil(SdkMcp.Incoming(["type": "control_request", "request_id": "r2", "request": ["subtype": "can_use_tool"]]))
    }

    func testReplyAndInitializeShapes() {
        let reply = SdkMcp.reply(requestID: "r1", response: ["jsonrpc": "2.0", "id": 1, "result": [:]])
        XCTAssertEqual(reply["type"], "control_response")
        XCTAssertEqual(reply["response"]?["request_id"], "r1")
        XCTAssertEqual(reply["response"]?["response"]?["mcp_response"]?["id"], 1)
        let fields = SdkMcp.initializeFields(["viber": ["timeout": 60000]])
        XCTAssertEqual(fields["sdkMcpServers"], ["viber"])
        XCTAssertEqual(fields["sdkMcpServerConfigs"]?["viber"]?["timeout"], 60000)
    }

    @MainActor
    func testServerHandlesTheHandshakeAndTools() async {
        let server = SdkMcpServer(name: "viber", instructions: "Use it.", tools: [McpTool(name: "ping", description: "Ping", inputSchema: ["type": "object"], readOnly: true)])
        var calls: [String] = []
        let call: (String, JSON) async -> McpToolResult = { name, args in
            calls.append(name)
            return McpToolResult([.text("pong \(args["word"]?.string ?? "")"), .image(Data([1, 2]), mimeType: "image/png")])
        }

        let initialize = await server.handle(["jsonrpc": "2.0", "id": 0, "method": "initialize", "params": ["protocolVersion": "2025-11-25"]], call: call)
        XCTAssertEqual(initialize["result"]?["protocolVersion"], "2025-11-25")
        XCTAssertEqual(initialize["result"]?["instructions"], "Use it.")
        XCTAssertEqual(initialize["result"]?["serverInfo"]?["name"], "viber")

        let ack = await server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"], call: call)
        XCTAssertEqual(ack["result"], [:])

        let list = await server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"], call: call)
        XCTAssertEqual(list["result"]?["tools"]?[0]?["name"], "ping")
        XCTAssertEqual(list["result"]?["tools"]?[0]?["annotations"]?["readOnlyHint"], true)

        let result = await server.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "ping", "arguments": ["word": "hi"]]], call: call)
        XCTAssertEqual(result["id"], 2)
        XCTAssertEqual(result["result"]?["content"]?[0]?["text"], "pong hi")
        XCTAssertEqual(result["result"]?["content"]?[1]?["data"], "AQI=")
        XCTAssertEqual(result["result"]?["content"]?[1]?["mimeType"], "image/png")
        XCTAssertNil(result["result"]?["isError"])

        let unknown = await server.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "nope"]], call: call)
        XCTAssertEqual(unknown["result"]?["isError"], true)
        XCTAssertEqual(calls, ["ping"])

        let missing = await server.handle(["jsonrpc": "2.0", "id": 4, "method": "resources/list"], call: call)
        XCTAssertEqual(missing["error"]?["code"], -32601)
    }
}

final class PreviewURLTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(PreviewURL.normalize("localhost:5173")?.absoluteString, "http://localhost:5173")
        XCTAssertEqual(PreviewURL.normalize("http://0.0.0.0:3000/app")?.absoluteString, "http://localhost:3000/app")
        XCTAssertEqual(PreviewURL.normalize("127.0.0.1:8080")?.absoluteString, "http://127.0.0.1:8080")
        XCTAssertEqual(PreviewURL.normalize("example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(PreviewURL.normalize("/tmp/page.html")?.isFileURL, true)
        XCTAssertNil(PreviewURL.normalize("javascript:alert(1)"))
        XCTAssertNil(PreviewURL.normalize("  "))
    }

    func testIsLocal() {
        for local in ["http://localhost:5173", "http://127.0.0.1", "http://192.168.1.20:3000", "http://10.0.0.2", "http://172.20.1.1",
                      "http://app.localhost", "http://myapp.test", "file:///tmp/a.html", "http://[::1]:3000"] {
            XCTAssertTrue(PreviewURL.isLocal(URL(string: local)), local)
        }
        for remote in ["https://github.com", "http://172.32.0.1", "http://8.8.8.8"] {
            XCTAssertFalse(PreviewURL.isLocal(URL(string: remote)), remote)
        }
        XCTAssertFalse(PreviewURL.isLocal(nil))
    }

    func testDetectFindsDevServerURLs() {
        let vite = "\u{1B}[32m  VITE v6.0.0\u{1B}[39m  ready in 300 ms\n\n  ➜  \u{1B}[1mLocal\u{1B}[22m:   \u{1B}[36mhttp://localhost:\u{1B}[1m5173\u{1B}[22m/\u{1B}[39m\n  ➜  Network: use --host to expose"
        XCTAssertEqual(PreviewURL.detect(in: vite).map(\.absoluteString), ["http://localhost:5173/"])
        let next = "- Local:        http://localhost:3000\n- Network:      http://192.168.1.5:3000\nready at http://localhost:3000."
        XCTAssertEqual(PreviewURL.detect(in: next).map(\.absoluteString), ["http://localhost:3000"])
        XCTAssertEqual(PreviewURL.detect(in: "Serving on http://0.0.0.0:8000/docs").map(\.absoluteString), ["http://localhost:8000/docs"])
        XCTAssertTrue(PreviewURL.detect(in: "see https://github.com/x").isEmpty)
    }

    func testShort() {
        XCTAssertEqual(PreviewURL.short(URL(string: "http://localhost:5173/")), "localhost:5173")
        XCTAssertEqual(PreviewURL.short(URL(string: "https://example.com/a/b")), "example.com/a/b")
    }
}

final class ConsoleLogTests: XCTestCase {
    func testFoldingUnseenAndBadge() {
        var log = ConsoleLog()
        log.navigated(to: URL(string: "http://localhost:5173/"))
        log.add(.log, "hello")
        log.add(.error, "boom")
        log.add(.error, "boom")
        XCTAssertEqual(log.entries.count, 3)
        XCTAssertEqual(log.entries.last?.count, 2)
        XCTAssertEqual(log.errorsThisPage, 2)
        XCTAssertEqual(log.unseenErrorCount, 1)
        log.markSeen()
        XCTAssertTrue(log.unseen.isEmpty)
        log.add(.error, "boom")
        XCTAssertEqual(log.unseen.map(\.text), ["boom"], "a repeat of a seen line counts as new")
        log.navigated(to: URL(string: "http://localhost:5173/about"))
        XCTAssertEqual(log.errorsThisPage, 0)
        XCTAssertTrue(ConsoleLog.format(log.unseen).contains("[error] boom (×3)"))
        XCTAssertTrue(ConsoleLog.format(log.unseen).contains("--- Loaded localhost:5173/about ---"))
    }

    func testLimitAndClear() {
        var log = ConsoleLog(limit: 3)
        for n in 1...5 { log.add(.log, "line \(n)") }
        XCTAssertEqual(log.entries.map(\.text), ["line 3", "line 4", "line 5"])
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
        log.add(.log, "after")
        XCTAssertEqual(log.unseen.map(\.text), ["after"])
    }

    func testHotUpdates() {
        XCTAssertEqual(HotUpdate.classify("[vite] hot updated: /src/App.tsx"), .applied)
        XCTAssertEqual(HotUpdate.classify("[vite] css hot updated: /src/index.css"), .applied)
        XCTAssertEqual(HotUpdate.classify("[vite] page reload src/main.ts"), .applied)
        XCTAssertNil(HotUpdate.classify("[vite] connected."))
        XCTAssertEqual(HotUpdate.classify("[Fast Refresh] rebuilding"), .started)
        XCTAssertEqual(HotUpdate.classify("[Fast Refresh] done in 104ms"), .applied)
        XCTAssertEqual(HotUpdate.classify("[HMR] Updated modules:"), .applied)
        XCTAssertNil(HotUpdate.classify("hello"))

        var log = ConsoleLog()
        let start = Date()
        log.navigated(to: URL(string: "http://localhost:3000"), at: start)
        let edit = start.addingTimeInterval(5)
        XCTAssertFalse(log.updated(after: edit))
        log.add(.log, "[Fast Refresh] rebuilding", at: edit.addingTimeInterval(0.2))
        XCTAssertTrue(log.rebuilding)
        XCTAssertFalse(log.updated(after: edit), "still rebuilding")
        log.add(.log, "[Fast Refresh] done in 90ms", at: edit.addingTimeInterval(0.4))
        XCTAssertTrue(log.updated(after: edit))
    }
}

final class ElementReferenceTests: XCTestCase {
    let cwd = "/Users/me/app"

    func testDecodeAndFormat() throws {
        let payload: JSON = ["url": "http://localhost:5173/", "selector": "#root > div > button.counter", "tag": "button",
                             "text": "count is   0", "html": "<button class=\"counter\">count is 0</button>",
                             "rect": ["x": 10, "y": 200, "width": 120, "height": 40], "styles": ["color": "rgb(0, 0, 0)"],
                             "components": ["Counter", "App"], "file": "/Users/me/app/src/Counter.tsx", "line": 12]
        let ref = try XCTUnwrap(ElementReference(payload: payload, cwd: cwd))
        XCTAssertEqual(ref.file, "src/Counter.tsx")
        XCTAssertEqual(ref.label, "button \"count is 0\" · Counter · Counter.tsx:12")
        XCTAssertEqual(ref.block, """
            <preview-element url="http://localhost:5173/" selector="#root > div > button.counter">
            <button class="counter">count is 0</button>
            component: Counter < App (src/Counter.tsx:12)
            box: 120×40 at 10,200 · color: rgb(0, 0, 0)
            </preview-element>
            """)
        let message = ElementReference.compose("make this bigger", with: [ref])
        XCTAssertTrue(message.hasPrefix("make this bigger\n\n<preview-element"))
        XCTAssertEqual(ElementReference.displayText(message), "make this bigger\n\n◎ #root > div > button.counter")
        XCTAssertEqual(ElementReference.compose("plain", with: []), "plain")
        XCTAssertNil(ElementReference(payload: ["tag": "div"], cwd: cwd))
    }

    func testRelativePaths() {
        XCTAssertEqual(ElementReference.relativePath("http://localhost:5173/src/App.tsx?t=1712", cwd: cwd), "src/App.tsx")
        XCTAssertEqual(ElementReference.relativePath("/@fs/Users/me/app/src/App.tsx", cwd: cwd), "src/App.tsx")
        XCTAssertEqual(ElementReference.relativePath("webpack://_N_E/./app/page.tsx", cwd: cwd), "app/page.tsx")
        XCTAssertEqual(ElementReference.relativePath("/src/main.ts", cwd: cwd), "src/main.ts")
        XCTAssertEqual(ElementReference.relativePath("components/Nav.vue", cwd: cwd), "components/Nav.vue")
    }
}

/// A page that answers the scripts the tools run, without WebKit.
@MainActor
final class FakeDriver: PreviewDriver {
    var pageURL: URL?
    var pageTitle = "Demo"
    var console = ConsoleLog()
    var revealed = false
    var loadFailure: String?
    var scripts: [String] = []
    var answers: [String: JSON] = [:]
    var thrown: [String: String] = [:]

    func reveal() { revealed = true }

    func load(_ url: URL?) async -> String? {
        if let loadFailure { return loadFailure }
        if let url { pageURL = url }
        console.navigated(to: pageURL)
        return nil
    }

    func evaluate(_ body: String, arguments: [String: JSON]) async throws -> JSON {
        scripts.append(body)
        if body.contains("__viber.quiet()") { return ["ready": "complete", "inflight": 0, "idle": 1000] }
        if body.contains("__viber.overlay()") { return answers["overlay"] ?? "" }
        for (needle, message) in thrown where body.contains(needle) { throw PreviewError.script(message) }
        for (needle, answer) in answers where body.contains(needle) { return answer }
        return .null
    }

    func capture(rect: CGRect?) async throws -> (data: Data, width: Int, height: Int) {
        (Data([0xFF, 0xD8]), Int(rect?.width ?? 800), Int(rect?.height ?? 600))
    }
}

@MainActor
final class PreviewToolboxTests: XCTestCase {
    func testToolsNeedAPageExceptOpen() async {
        let driver = FakeDriver()
        let result = await PreviewToolbox.call("preview_screenshot", [:], driver: driver, lastEdit: nil)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("preview_open"))
    }

    func testOpen() async {
        let driver = FakeDriver()
        let opened = await PreviewToolbox.call("preview_open", ["url": "localhost:5173"], driver: driver, lastEdit: nil)
        XCTAssertFalse(opened.isError)
        XCTAssertTrue(driver.revealed)
        XCTAssertEqual(driver.pageURL?.absoluteString, "http://localhost:5173")
        XCTAssertTrue(opened.text.contains("Opened http://localhost:5173 \"Demo\""))

        let path = await PreviewToolbox.call("preview_open", ["url": "/about"], driver: driver, lastEdit: nil)
        XCTAssertFalse(path.isError)
        XCTAssertEqual(driver.pageURL?.absoluteString, "http://localhost:5173/about")

        driver.loadFailure = "Could not connect to the server."
        let failed = await PreviewToolbox.call("preview_open", ["url": "http://localhost:4000"], driver: driver, lastEdit: nil)
        XCTAssertTrue(failed.isError)
        XCTAssertTrue(failed.text.contains("start the dev server"))
    }

    func testScreenshotReturnsAnImageAndStatus() async {
        let driver = FakeDriver()
        driver.pageURL = URL(string: "http://localhost:5173/")
        driver.console.navigated(to: driver.pageURL)
        driver.console.add(.error, "TypeError: x is undefined")
        driver.answers["overlay"] = "Vite error overlay: Failed to resolve import"
        let result = await PreviewToolbox.call("preview_screenshot", [:], driver: driver, lastEdit: nil)
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content.first, .image(Data([0xFF, 0xD8]), mimeType: "image/jpeg"))
        XCTAssertTrue(result.text.contains("1 new console error"))
        XCTAssertTrue(result.text.contains("Vite error overlay"))

        driver.answers["__viber.rect"] = ["x": 10, "y": 20, "width": 100, "height": 50, "viewportWidth": 800, "viewportHeight": 600]
        let element = await PreviewToolbox.call("preview_screenshot", ["ref": "e3"], driver: driver, lastEdit: nil)
        XCTAssertTrue(element.text.contains("of the element"))
        XCTAssertTrue(element.text.contains("(116×66)"), element.text)
    }

    func testScreenshotNotesAMissingHotUpdate() async {
        let driver = FakeDriver()
        driver.pageURL = URL(string: "http://localhost:5173/")
        driver.console.navigated(to: driver.pageURL, at: Date().addingTimeInterval(-60))
        let result = await PreviewToolbox.call("preview_screenshot", [:], driver: driver, lastEdit: Date().addingTimeInterval(-30))
        XCTAssertTrue(result.text.contains("No hot update or reload seen since your last file edit"), result.text)

        driver.console.add(.debug, "[vite] hot updated: /src/App.tsx")
        let after = await PreviewToolbox.call("preview_screenshot", [:], driver: driver, lastEdit: Date().addingTimeInterval(-1))
        XCTAssertFalse(after.text.contains("No hot update"), after.text)
    }

    func testConsoleShowsWhatIsNew() async {
        let driver = FakeDriver()
        driver.pageURL = URL(string: "http://localhost:5173/")
        driver.console.add(.warn, "deprecated")
        driver.console.add(.error, "boom")
        let errors = await PreviewToolbox.call("preview_console", ["level": "error"], driver: driver, lastEdit: nil)
        XCTAssertTrue(errors.text.contains("[error] boom"))
        XCTAssertFalse(errors.text.contains("deprecated"))
        let again = await PreviewToolbox.call("preview_console", [:], driver: driver, lastEdit: nil)
        XCTAssertTrue(again.text.contains("Nothing new"))
        let all = await PreviewToolbox.call("preview_console", ["all": true], driver: driver, lastEdit: nil)
        XCTAssertTrue(all.text.contains("[warn] deprecated"))
    }

    func testClickAndTypeNeedATarget() async {
        let driver = FakeDriver()
        driver.pageURL = URL(string: "http://localhost:5173/")
        let missing = await PreviewToolbox.call("preview_click", [:], driver: driver, lastEdit: nil)
        XCTAssertTrue(missing.isError)
        driver.answers["__viber.click"] = "Clicked button \"Save\"."
        let clicked = await PreviewToolbox.call("preview_click", ["text": "Save"], driver: driver, lastEdit: nil)
        XCTAssertTrue(clicked.text.hasPrefix("Clicked button \"Save\"."))
        let noText = await PreviewToolbox.call("preview_type", ["ref": "e1"], driver: driver, lastEdit: nil)
        XCTAssertTrue(noText.isError)
    }

    func testEvalFallsBackToAFunctionBody() async {
        let driver = FakeDriver()
        driver.pageURL = URL(string: "http://localhost:5173/")
        driver.thrown["(async () => (\n"] = "SyntaxError: Unexpected keyword 'const'"
        driver.answers["(async () => {\n"] = "42"
        let result = await PreviewToolbox.call("preview_eval", ["expression": "const a = 41; return a + 1"], driver: driver, lastEdit: nil)
        XCTAssertEqual(result.text, "42")
        XCTAssertEqual(driver.scripts.filter { $0.contains("const a = 41") }.count, 2)
    }

    func testPolicy() {
        let local = URL(string: "http://localhost:5173")
        let remote = URL(string: "https://github.com")
        XCTAssertTrue(PreviewPolicy.autoAllow(tool: "mcp__viber__preview_screenshot", pageURL: remote, actionsOnLocalPages: false))
        XCTAssertTrue(PreviewPolicy.autoAllow(tool: "mcp__viber__preview_click", pageURL: local, actionsOnLocalPages: true))
        XCTAssertFalse(PreviewPolicy.autoAllow(tool: "mcp__viber__preview_click", pageURL: local, actionsOnLocalPages: false))
        XCTAssertFalse(PreviewPolicy.autoAllow(tool: "mcp__viber__preview_eval", pageURL: remote, actionsOnLocalPages: true))
        XCTAssertFalse(PreviewPolicy.autoAllow(tool: "mcp__other__preview_screenshot", pageURL: local, actionsOnLocalPages: true))
    }

    func testToolListMatchesThePolicy() {
        for tool in PreviewToolbox.tools {
            XCTAssertEqual(tool.readOnly, PreviewPolicy.readOnly.contains(tool.name), tool.name)
        }
    }
}

final class PreviewChatTests: XCTestCase {
    func testDisplayNames() {
        XCTAssertEqual(ToolSummary.displayName("mcp__viber__preview_click"), "Preview · click")
        XCTAssertEqual(ToolSummary.displayName("mcp__plugin_posthog_posthog__query"), "plugin_posthog_posthog · query")
        XCTAssertEqual(ToolSummary.displayName("Bash"), "Bash")
    }

    func testFileEditsAreTimed() {
        var chat = ChatTranscript()
        _ = chat.userMessage("edit")
        chat.apply(["type": "assistant", "message": ["id": "m1", "role": "assistant", "content": [
            ["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "/a"]],
            ["type": "tool_use", "id": "t2", "name": "Edit", "input": ["file_path": "/a"]],
        ]]])
        let now = Date(timeIntervalSince1970: 1000)
        chat.apply(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": "x"]]]], now: now)
        XCTAssertNil(chat.lastFileEditAt)
        chat.apply(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t2", "content": "ok"]]]], now: now)
        XCTAssertEqual(chat.lastFileEditAt, now)
    }
}
