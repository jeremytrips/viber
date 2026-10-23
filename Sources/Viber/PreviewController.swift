import AppKit
import Observation
import ViberCore
import WebKit

/// One session's browser preview: a web view the user looks at and Claude drives through the preview tools.
/// The view outlives the SwiftUI views showing it; while no pane shows it, it waits in an offscreen window
/// so the page keeps running, hot updates keep landing and screenshots still work.
@MainActor @Observable
final class PreviewController: NSObject, PreviewDriver {
    private(set) var pageURL: URL?
    private(set) var pageTitle = ""
    private(set) var isLoading = false
    private(set) var progress: Double = 0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// Why the last load failed, shown over the page until the next one starts.
    private(set) var failure: String?
    var console = ConsoleLog()
    private(set) var picking = false
    /// The preview tool Claude is running, for the toolbar.
    var activity: String?

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored var onReveal: (() -> Void)?
    @ObservationIgnored var onURLChange: ((URL) -> Void)?
    @ObservationIgnored var onPick: ((JSON) -> Void)?
    @ObservationIgnored private let readAccess: URL
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var loadWaiters: [UUID: CheckedContinuation<String?, Never>] = [:]
    @ObservationIgnored private var parking: NSWindow?

    init(url: URL?, readAccess: String) {
        self.readAccess = URL(fileURLWithPath: readAccess)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.isElementFullscreenEnabled = true
        // Keep timers and rendering going while the preview is hidden, so hot updates land and screenshots are current.
        config.preferences.inactiveSchedulingPolicy = .none
        config.userContentController.addUserScript(WKUserScript(source: PreviewScripts.bootstrap, injectionTime: .atDocumentStart,
                                                                forMainFrameOnly: true, in: .page))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        super.init()
        config.userContentController.add(MessageProxy(self), contentWorld: .page, name: PreviewScripts.handler)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        observations = [
            webView.observe(\.url) { [weak self] view, _ in MainActor.assumeIsolated { self?.urlChanged(view.url) } },
            webView.observe(\.title) { [weak self] view, _ in MainActor.assumeIsolated { self?.pageTitle = view.title ?? "" } },
            webView.observe(\.isLoading) { [weak self] view, _ in MainActor.assumeIsolated { self?.isLoading = view.isLoading } },
            webView.observe(\.estimatedProgress) { [weak self] view, _ in MainActor.assumeIsolated { self?.progress = view.estimatedProgress } },
            webView.observe(\.canGoBack) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoBack = view.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoForward = view.canGoForward } },
        ]
        park()
        if let url { navigate(url) }
    }

    func tearDown() {
        observations = []
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.removeFromSuperview()
        parking?.close()
        parking = nil
        for waiter in loadWaiters.values { waiter.resume(returning: "The preview was closed") }
        loadWaiters = [:]
    }

    // MARK: Where the web view lives

    func attach(to container: NSView) {
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        parking?.orderOut(nil)
    }

    /// Called when a pane stops showing the preview. Moves the web view offscreen unless another pane already took it.
    func detach(from container: NSView) {
        guard webView.superview === container else { return }
        park()
    }

    private func park() {
        let size = webView.frame.size.width > 100 ? webView.frame.size : NSSize(width: 1024, height: 768)
        let window = parking ?? {
            let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.isExcludedFromWindowsMenu = true
            window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
            parking = window
            return window
        }()
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        webView.removeFromSuperview()
        webView.frame = NSRect(origin: .zero, size: size)
        webView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(webView)
        window.orderBack(nil)
    }

    private var isParked: Bool { webView.window == nil || webView.window === parking }

    // MARK: Navigation

    /// From the address field: "localhost:3000", a full URL or a file path.
    func go(_ text: String) {
        guard let url = PreviewURL.normalize(text) else {
            failure = "\(text) is not a URL the preview can open."
            return
        }
        navigate(url)
    }

    func navigate(_ url: URL) {
        failure = nil
        if url.isFileURL {
            let root = url.path.hasPrefix(readAccess.path + "/") ? readAccess : url.deletingLastPathComponent()
            webView.loadFileURL(url, allowingReadAccessTo: root)
        } else {
            webView.load(URLRequest(url: url))
        }
        if pageURL == nil { pageURL = url }
    }

    func reload() {
        failure = nil
        if webView.url == nil, let pageURL { navigate(pageURL) } else { webView.reload() }
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func stop() { webView.stopLoading() }

    func openExternally() {
        if let url = webView.url ?? pageURL { NSWorkspace.shared.open(url) }
    }

    private func urlChanged(_ url: URL?) {
        guard let url, url.absoluteString != "about:blank" else { return }
        pageURL = url
        onURLChange?(url)
    }

    // MARK: Element picker

    func togglePicking() {
        if picking { stopPicking() } else { startPicking() }
    }

    func startPicking() {
        guard webView.url != nil else { return }
        picking = true
        webView.window?.makeFirstResponder(webView)
        Task { _ = try? await evaluate("window.__viber.pick.start()", arguments: [:]) }
    }

    func stopPicking() {
        picking = false
        Task { _ = try? await evaluate("window.__viber.pick.stop()", arguments: [:]) }
    }

    fileprivate func received(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "console":
            console.add(ConsoleLog.Level(page: message["level"] as? String ?? "log"), message["text"] as? String ?? "")
        case "pick":
            // Only while picking, so a page cannot fill the composer by posting picks on its own.
            guard picking else { return }
            picking = false
            onPick?(JSON(any: message["payload"]))
        case "pickEnd":
            picking = false
        default: break
        }
    }

    // MARK: PreviewDriver

    func reveal() { onReveal?() }

    func load(_ url: URL?) async -> String? {
        if let url {
            // A change of #fragment only is a same-document navigation: there is no load to wait for.
            if let current = webView.url, current.absoluteString.split(separator: "#").first == url.absoluteString.split(separator: "#").first,
               url.fragment != nil {
                _ = try? await webView.callAsyncJavaScript("location.href = href", arguments: ["href": url.absoluteString], in: nil, contentWorld: .page)
                return nil
            }
            navigate(url)
        } else {
            reload()
        }
        return await waitForLoad(timeout: 15)
    }

    func evaluate(_ body: String, arguments: [String: JSON]) async throws -> JSON {
        if isLoading { _ = await waitForLoad(timeout: 15) }
        do {
            let value = try await webView.callAsyncJavaScript(PreviewScripts.bootstrap + "\n" + body,
                                                              arguments: arguments.mapValues(\.any), in: nil, contentWorld: .page)
            return JSON(any: value)
        } catch {
            throw PreviewError.script(Self.scriptMessage(error))
        }
    }

    func capture(rect: CGRect?) async throws -> (data: Data, width: Int, height: Int) {
        if isLoading { _ = await waitForLoad(timeout: 15) }
        if webView.window == nil { park() }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        if let rect {
            let scale = webView.pageZoom * webView.magnification
            var r = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            if !webView.isFlipped { r.origin.y = webView.bounds.height - r.maxY }
            config.rect = r
        }
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: config) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: PreviewError.capture(error?.localizedDescription ?? "The preview could not take a screenshot.")) }
            }
        }
        return try Self.jpeg(image)
    }

    /// Scales to at most 1280 points wide and about 1.15 megapixels, which is what the model can use, then encodes JPEG.
    static func jpeg(_ image: NSImage, maxWidth: CGFloat = 1280, maxPixels: CGFloat = 1_150_000) throws -> (data: Data, width: Int, height: Int) {
        let size = image.size
        guard size.width >= 1, size.height >= 1 else { throw PreviewError.capture("The screenshot came back empty.") }
        var scale = min(1, maxWidth / size.width)
        if size.width * scale * size.height * scale > maxPixels { scale = (maxPixels / (size.width * size.height)).squareRoot() }
        let width = max(1, Int(size.width * scale)), height = max(1, Int(size.height * scale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { throw PreviewError.capture("Could not encode the screenshot.") }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else {
            throw PreviewError.capture("Could not encode the screenshot.")
        }
        return (data, width, height)
    }

    private func waitForLoad(timeout: TimeInterval) async -> String? {
        let id = UUID()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.finishWaiter(id, "it did not finish loading within \(Int(timeout)) seconds")
        }
        return await withCheckedContinuation { loadWaiters[id] = $0 }
    }

    private func finishWaiter(_ id: UUID, _ result: String?) {
        loadWaiters.removeValue(forKey: id)?.resume(returning: result)
    }

    private func finishLoads(_ result: String?) {
        let waiters = loadWaiters
        loadWaiters = [:]
        for waiter in waiters.values { waiter.resume(returning: result) }
    }

    static func scriptMessage(_ error: Error) -> String {
        let ns = error as NSError
        var message = ns.userInfo["WKJavaScriptExceptionMessage"] as? String ?? ns.localizedDescription
        if message.hasPrefix("Error: ") { message.removeFirst("Error: ".count) }
        return message
    }

    /// While Claude is acting, or nobody can see the page, dialogs are answered and logged instead of shown.
    private var answersDialogs: Bool { activity != nil || isParked || webView.window?.isVisible != true }
}

extension PreviewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        failure = nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        console.navigated(to: webView.url)
        picking = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoads(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    private func failed(_ error: Error) {
        let ns = error as NSError
        // Cancelled: another navigation replaced this one, and the waiters wait for that one instead.
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        let message = ns.domain == "WebKitErrorDomain" && ns.code == 102
            ? "The preview cannot show this kind of file" : ns.localizedDescription
        failure = message
        console.add(.error, "Navigation failed: \(message) (\(ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String ?? pageURL?.absoluteString ?? ""))")
        finishLoads(message)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        console.add(.error, "The page's web content process crashed; reloading.")
        webView.reload()
    }
}

extension PreviewController: WKUIDelegate {
    /// target=_blank and window.open load in the preview itself.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard !answersDialogs, let window = webView.window else {
            console.add(.warn, "alert(): \(message)")
            return completionHandler()
        }
        let alert = NSAlert()
        alert.messageText = message
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard !answersDialogs, let window = webView.window else {
            console.add(.warn, "confirm() answered OK: \(message)")
            return completionHandler(true)
        }
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard !answersDialogs, let window = webView.window else {
            console.add(.warn, "prompt() answered with its default: \(prompt)")
            return completionHandler(defaultText)
        }
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.begin { completionHandler($0 == .OK ? panel.urls : nil) }
    }
}

/// WKUserContentController keeps its handlers alive; this keeps it from keeping the controller alive.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: PreviewController?
    init(_ target: PreviewController) { self.target = target }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { target?.received(body) }
    }
}
