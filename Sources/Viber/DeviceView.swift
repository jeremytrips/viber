import AppKit
import IOSurface
import SimulatorBridge
import SwiftUI
import ViberCore

/// The device panel beside a session's chat: the user and Claude look at and use the same simulator.
struct DevicePanel: View {
    let pane: Pane
    let hub: DeviceHub

    private var controller: SimulatorController? { pane.deviceID.flatMap { hub.controllers[$0] } }

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
                Button { Task { try? await controller.press(.home) } } label: { Image(systemName: "house") }
                    .help("Home (⇧⌘H)")
                Button { Task { try? await controller.press(.lock) } } label: { Image(systemName: "lock") }
                    .help("Lock")
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
                    Button("Open in Simulator") { DevicePanel.openInSimulator(controller.device.id) }
                    Button("Copy Screenshot") { controller.copyScreenshot() }.disabled(!controller.isStreaming)
                    Divider()
                    if controller.device.isBooted {
                        Button("Shut Down \(controller.device.name)") { Task { await controller.shutdown(); _ = try? await hub.refresh() } }
                    } else {
                        Button("Boot \(controller.device.name)") { Task { try? await controller.boot(); _ = try? await hub.refresh() } }
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
                Image(systemName: "iphone")
                Text(controller?.device.name ?? "Choose a device").lineLimit(1)
                if let controller, !controller.device.isBooted { Text("off").foregroundStyle(.secondary) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("The device this session shows and Claude's device tools use")
    }

    private func pickButton(_ device: DeviceInfo) -> some View {
        Button(device.label) { pane.chooseDevice(device, boot: true) }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let controller {
            if controller.booting {
                PreviewMessage(icon: "iphone", title: "Booting \(controller.device.name)…", detail: "This takes a few seconds, longer the first time.") {
                    ProgressView().controlSize(.small)
                }
            } else if !controller.device.isBooted {
                PreviewMessage(icon: "iphone.slash", title: "\(controller.device.name) is off", detail: controller.failure ?? "\(controller.device.os). Boot it to see it here, or ask Claude to open it.") {
                    Button("Boot") { Task { try? await controller.boot(); _ = try? await hub.refresh() } }.keyboardShortcut(.defaultAction)
                }
            } else if let failure = controller.failure, !controller.isStreaming {
                PreviewMessage(icon: "exclamationmark.triangle", title: "The live screen is not available", detail: failure + "\n\nClaude's device tools still work through simctl where they can.") {
                    Button("Retry") { controller.startStream() }
                    Button("Open in Simulator") { DevicePanel.openInSimulator(controller.device.id) }
                }
            } else {
                DeviceScreenHost(controller: controller)
            }
        } else if let error = hub.listError, hub.devices.isEmpty {
            PreviewMessage(icon: "exclamationmark.triangle", title: "No simulators", detail: error) {
                Button("Retry") { Task { _ = try? await hub.refresh() } }
            }
        } else {
            PreviewMessage(icon: "iphone", title: "Device",
                           detail: "Choose a simulator to show here, or ask Claude to open one. Claude can install and launch your app, take screenshots, read the screen and tap through it, on the screen you see.") {
                ForEach(hub.devices.prefix(3)) { device in
                    Button(device.isBooted ? "Show \(device.name)" : "Boot \(device.name)") { pane.chooseDevice(device, boot: true) }
                }
            }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        Group {
            if let activity = pane.deviceActivity {
                Label("Claude: \(activity)", systemImage: "sparkles")
            } else if controller?.picking == true {
                Text("Click an element to attach it to your message.")
            } else if let note = controller?.inputFailure {
                Label(note, systemImage: "hand.raised").lineLimit(3)
            }
        }
        .font(.caption).padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(.regularMaterial)).padding(10)
    }

    static func openInSimulator(_ udid: String) {
        Task.detached { Shell.run("open", ["-a", "Simulator", "--args", "-CurrentDeviceUDID", udid]) }
    }
}

/// Puts the controller's long-lived screen view into whichever container is on screen.
struct DeviceScreenHost: NSViewRepresentable {
    let controller: SimulatorController

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
    weak var controller: SimulatorController?

    func adopt() {
        guard let view = controller?.screenView, view.superview !== self else { return }
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

/// The simulator's screen: its IOSurface as layer contents, redrawn on every frame, and the user's mouse and keys as touches.
final class DeviceScreenView: NSView {
    weak var controller: SimulatorController?
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

    func show(_ surface: IOSurface?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.contents = surface
        if let surface { pixelSize = CGSize(width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface)) }
        content.isHidden = surface == nil
        CATransaction.commit()
        needsLayout = true
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
        // Roughly the corner radius of current iPhones (about 55 pt on a 402 pt wide screen).
        content.cornerRadius = rect.width * (pixelSize.width < pixelSize.height ? 0.135 : 0.06)
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
        controller?.userKey(macKeyCode: event.keyCode, down: true)
    }

    override func keyUp(with event: NSEvent) {
        if event.modifierFlags.contains(.command) { return }
        controller?.userKey(macKeyCode: event.keyCode, down: false)
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
        controller?.userKey(macKeyCode: event.keyCode, down: event.modifierFlags.contains(flag))
    }

    @objc func paste(_ sender: Any?) { controller?.pasteFromMac() }

    @objc func copy(_ sender: Any?) { controller?.copyScreenshot() }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Home", action: #selector(home), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Lock", action: #selector(lock), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy Screenshot", action: #selector(copy(_:)), keyEquivalent: "").target = self
        return menu
    }

    @objc private func home() { Task { @MainActor in try? await controller?.press(.home) } }
    @objc private func lock() { Task { @MainActor in try? await controller?.press(.lock) } }
}
