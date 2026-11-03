import AppKit
import IOSurface
import SimulatorBridge
import SwiftUI
import ViberCore

/// The device panel beside a session's chat: the user and Claude look at and use the same simulator or emulator.
struct DevicePanel: View {
    let pane: Pane
    let hub: DeviceHub

    private var controller: (any DeviceController)? { pane.deviceID.flatMap { hub.controllers[$0] } }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
                .overlay(alignment: .bottom) { overlay }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // Keep the list (and which devices are running) current while the panel shows.
        .task {
            while !Task.isCancelled {
                _ = try? await hub.refresh(maxAge: 2)
                if let id = pane.deviceID, let device = hub.device(id), hub.controllers[id] == nil { _ = hub.controller(for: device) }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            devicePicker
            Spacer(minLength: 4)
            if let controller, controller.device.isBooted {
                ForEach(controller.toolbarButtons, id: \.self) { button in
                    Button { Task { try? await controller.press(button) } } label: { Image(systemName: Self.icon(button)) }
                        .help(Self.help(button))
                }
                Button { pane.attachDeviceScreenshot() } label: { Image(systemName: "camera") }
                    .disabled(!controller.isStreaming)
                    .help("Attach a screenshot to your message")
                Button { pane.toggleDevicePicking() } label: {
                    Image(systemName: "cursorarrow.rays").foregroundStyle(controller.picking ? Color.accentColor : Color.primary)
                }
                .disabled(!controller.isStreaming)
                .help("Pick an element to attach to your message")
            }
            Menu {
                if let controller {
                    if let title = controller.externalApp { Button(title) { controller.openExternally() } }
                    Button("Copy Screenshot") { controller.copyScreenshot() }.disabled(!controller.isStreaming)
                    if controller.canPowerCycle {
                        Divider()
                        if controller.device.isBooted {
                            Button("Shut Down \(controller.device.name)") { Task { await controller.shutdown(); _ = try? await hub.refresh() } }
                        } else {
                            Button("Boot \(controller.device.name)") { Task { try? await controller.boot(); _ = try? await hub.refresh() } }
                        }
                    }
                }
                Button("Refresh Device List") { Task { _ = try? await hub.refresh() } }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuIndicator(.hidden)
                .fixedSize()
            Button { pane.showDevice = false } label: { Image(systemName: "sidebar.right") }
                .help("Hide the device (⇧⌘D)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private var devicePicker: some View {
        Menu {
            let running = hub.devices.filter(\.isBooted)
            if !running.isEmpty {
                Section("Running") { ForEach(running) { device in pickButton(device) } }
            }
            let byOS = Dictionary(grouping: hub.devices.filter { !$0.isBooted }, by: \.os)
            ForEach(byOS.keys.sorted { $0.localizedStandardCompare($1) == .orderedDescending }, id: \.self) { os in
                Section(os) { ForEach(byOS[os] ?? []) { device in pickButton(device) } }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: Self.icon(controller?.device))
                Text(controller?.device.name ?? "Choose a device").lineLimit(1)
                if let controller, !controller.device.isBooted { Text("off").foregroundStyle(.secondary) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("The device this session shows and Claude's device tools use")
    }

    private func pickButton(_ device: DeviceInfo) -> some View {
        Button { pane.chooseDevice(device, boot: true) } label: { Label(device.label, systemImage: Self.icon(device)) }
    }

    static func icon(_ device: DeviceInfo?) -> String {
        guard let device else { return "iphone" }
        if device.platform == .ios { return device.isPhone ? "iphone" : "ipad" }
        return device.kind == .physical ? "cable.connector" : "smartphone"
    }

    /// The command line tool behind a device's apps, logs and screenshots.
    static func tool(_ device: DeviceInfo) -> String {
        device.platform == .android ? "adb" : device.isVirtual ? "simctl" : "devicectl"
    }

    static func icon(_ button: DeviceButton) -> String {
        switch button {
        case .home: return "house"
        case .lock: return "lock"
        case .back: return "chevron.backward"
        case .app_switch: return "square.on.square"
        case .siri: return "mic"
        case .volume_up: return "speaker.plus"
        case .volume_down: return "speaker.minus"
        }
    }

    static func help(_ button: DeviceButton) -> String {
        switch button {
        case .home: return "Home (⇧⌘H)"
        case .lock: return "Lock"
        case .back: return "Back"
        case .app_switch: return "Recent apps"
        case .siri: return "Siri"
        case .volume_up: return "Volume up"
        case .volume_down: return "Volume down"
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let controller {
            let device = controller.device
            if controller.booting {
                PreviewMessage(icon: Self.icon(device), title: "Booting \(device.name)…",
                               detail: device.platform == .android ? "Android emulators take up to a minute." : "This takes a few seconds, longer the first time.") {
                    ProgressView().controlSize(.small)
                }
            } else if !device.isBooted {
                if controller.canPowerCycle {
                    PreviewMessage(icon: "iphone.slash", title: "\(device.name) is off", detail: controller.failure ?? "\(device.os). Boot it to see it here, or ask Claude to open it.") {
                        Button("Boot") { Task { try? await controller.boot(); _ = try? await hub.refresh() } }.keyboardShortcut(.defaultAction)
                    }
                } else {
                    PreviewMessage(icon: "cable.connector.slash", title: "\(device.name) is not ready",
                                   detail: controller.failure ?? (device.platform == .android ? "Connect it with USB, unlock it and allow USB debugging."
                                                                                              : "Connect it with USB, or unlock it on the same Wi-Fi, and trust this Mac.")) {
                        Button("Retry") { Task { try? await controller.boot(); _ = try? await hub.refresh() } }.keyboardShortcut(.defaultAction)
                    }
                }
            } else if let failure = controller.failure, !controller.isStreaming {
                PreviewMessage(icon: "exclamationmark.triangle", title: "The live screen is not available",
                               detail: failure + "\n\nClaude's device tools still work through \(Self.tool(device)) where they can.") {
                    Button("Retry") { controller.startStream() }
                    if let title = controller.externalApp { Button(title) { controller.openExternally() } }
                }
            } else {
                DeviceScreenHost(controller: controller)
            }
        } else if let error = hub.listError, hub.devices.isEmpty {
            PreviewMessage(icon: "exclamationmark.triangle", title: "No devices", detail: error) {
                Button("Retry") { Task { _ = try? await hub.refresh() } }
            }
        } else {
            PreviewMessage(icon: "iphone", title: "Device",
                           detail: "Choose a simulator or emulator to show here, or ask Claude to open one. Claude can install and launch your app, take screenshots, read the screen and tap through it, on the screen you see.") {
                ForEach(hub.devices.prefix(3)) { device in
                    Button(device.isBooted ? "Show \(device.name)" : "Boot \(device.name)") { pane.chooseDevice(device, boot: true) }
                }
            }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        // Only with something to say: padding and a capsule around nothing still draw an empty pill.
        if let (text, icon) = overlayNote {
            Label { Text(text).lineLimit(3) } icon: { if let icon { Image(systemName: icon) } }
                .font(.caption).padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(.regularMaterial)).padding(10)
        }
    }

    private var overlayNote: (String, String?)? {
        if let activity = pane.deviceActivity { return ("Claude: \(activity)", "sparkles") }
        if let note = controller?.busyNote { return (note, "hourglass") }
        if controller?.picking == true { return ("Click an element to attach it to your message.", nil) }
        if let note = controller?.inputFailure { return (note, "hand.raised") }
        return nil
    }
}

/// Puts the controller's long-lived screen view into whichever container is on screen.
struct DeviceScreenHost: NSViewRepresentable {
    let controller: any DeviceController

    func makeNSView(context: Context) -> DeviceScreenContainer {
        let container = DeviceScreenContainer()
        container.controller = controller
        container.adopt()
        return container
    }

    func updateNSView(_ container: DeviceScreenContainer, context: Context) {
        container.controller = controller
        if container.window != nil { container.adopt() }
    }
}

final class DeviceScreenContainer: NSView {
    weak var controller: (any DeviceController)?

    func adopt() {
        guard let view = controller?.screenView, view.superview !== self else { return }
        // Another device's screen shown here before: let it go, so its stream counts as unwatched.
        for old in subviews where old !== view { old.removeFromSuperview() }
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let controller else { return }
        if window == nil {
            if controller.screenView.superview === self { controller.screenView.removeFromSuperview() }
        } else {
            adopt()
            controller.startStream()
        }
    }
}

/// The device's screen: an IOSurface as layer contents, redrawn on every frame, and the user's mouse and keys as touches.
final class DeviceScreenView: NSView {
    weak var controller: (any DeviceController)?
    private let content = CALayer()
    private var pixelSize = CGSize(width: 1206, height: 2622)
    private var scrollEnd: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        content.contentsGravity = .resize
        content.masksToBounds = true
        content.backgroundColor = NSColor.black.cgColor
        content.cornerCurve = .continuous
        layer?.addSublayer(content)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Shows a surface (a new one per frame for decoded video). Lays out again only when the size changes.
    func show(_ surface: IOSurface?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.contents = surface
        content.isHidden = surface == nil
        CATransaction.commit()
        if let surface {
            let size = CGSize(width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface))
            if size != pixelSize {
                pixelSize = size
                needsLayout = true
            }
        }
    }

    /// The simulator drew into the same surface: tell Core Animation the contents changed.
    func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let selector = NSSelectorFromString("setContentsChanged")
        if content.responds(to: selector) {
            content.perform(selector)
        } else {
            let contents = content.contents
            content.contents = nil
            content.contents = contents
        }
        CATransaction.commit()
    }

    /// Where the screen is drawn: aspect-fit with a margin.
    private var screenRect: CGRect {
        let area = bounds.insetBy(dx: 12, dy: 12)
        guard area.width > 0, area.height > 0, pixelSize.width > 0 else { return .zero }
        let scale = min(area.width / pixelSize.width, area.height / pixelSize.height)
        let size = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = screenRect
        content.frame = rect
        // Roughly the corner radius of current iPhones (about 55 pt on a 402 pt wide screen); Pixel corners are smaller.
        let portrait = pixelSize.width < pixelSize.height
        content.cornerRadius = controller?.device.platform == .android
            ? min(rect.width, rect.height) * 0.08 : rect.width * (portrait ? 0.135 : 0.06)
        CATransaction.commit()
    }

    private func ratio(_ event: NSEvent, clamp: Bool) -> CGPoint? {
        let p = convert(event.locationInWindow, from: nil)
        let rect = screenRect
        guard rect.width > 0 else { return nil }
        if !clamp && !rect.contains(p) { return nil }
        return CGPoint(x: min(max((p.x - rect.minX) / rect.width, 0), 1), y: min(max((p.y - rect.minY) / rect.height, 0), 1))
    }

    private var touching = false

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let controller, let r = ratio(event, clamp: false) else { return }
        if controller.picking { controller.pick(at: r); return }
        touching = true
        controller.userTouch(.down, at: r)
    }

    override func mouseDragged(with event: NSEvent) {
        guard touching, let r = ratio(event, clamp: true) else { return }
        controller?.userTouch(.move, at: r)
    }

    override func mouseUp(with event: NSEvent) {
        guard touching, let r = ratio(event, clamp: true) else { return }
        touching = false
        controller?.userTouch(.up, at: r)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let controller, event.momentumPhase.isEmpty, let r = ratio(event, clamp: false) else { return }
        // Trackpads give points; a mouse wheel gives lines.
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        controller.userScroll(dx: event.scrollingDeltaX * factor, dy: event.scrollingDeltaY * factor, at: r, ended: ended)
        if event.phase.isEmpty {
            // A mouse wheel has no phases: lift the finger once it stops.
            scrollEnd?.cancel()
            let work = DispatchWorkItem { [weak controller] in controller?.userScroll(dx: 0, dy: 0, at: r, ended: true) }
            scrollEnd = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }

    override func keyDown(with event: NSEvent) {
        // ⌘ shortcuts stay Viber's (paste arrives as paste(_:)).
        if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
        if event.keyCode == 0x35, controller?.picking == true { controller?.picking = false; return }
        controller?.userKey(event, down: true)
    }

    override func keyUp(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { return }
        controller?.userKey(event, down: false)
    }

    override func flagsChanged(with event: NSEvent) {
        let flag: NSEvent.ModifierFlags?
        switch event.keyCode {
        case 0x38, 0x3C: flag = .shift
        case 0x3B, 0x3E: flag = .control
        case 0x3A, 0x3D: flag = .option
        default: flag = nil
        }
        guard let flag else { return }
        controller?.userKey(event, down: event.modifierFlags.contains(flag))
    }

    @objc func paste(_ sender: Any?) { controller?.pasteFromMac() }

    @objc func copy(_ sender: Any?) { controller?.copyScreenshot() }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for button in controller?.toolbarButtons ?? [] {
            let item = menu.addItem(withTitle: DevicePanel.help(button).replacingOccurrences(of: " (⇧⌘H)", with: ""),
                                    action: #selector(pressButton(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = button.rawValue
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        menu.addItem(withTitle: "Copy Screenshot", action: #selector(copy(_:)), keyEquivalent: "").target = self
        return menu
    }

    @objc private func pressButton(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let button = DeviceButton(rawValue: raw) else { return }
        Task { @MainActor in try? await controller?.press(button) }
    }
}
