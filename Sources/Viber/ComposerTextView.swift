import AppKit
import SwiftUI

/// The message box's text area. SwiftUI's multi-line `TextField` measures all of its text on every keystroke,
/// so typing crawled once a long text was pasted; an `NSTextView` only lays out what changed.
/// It grows from one line to `maxLines`, then scrolls.
struct ComposerTextView: NSViewRepresentable {
    enum Key { case up, down, tab, escape }

    @Binding var text: String
    @Binding var height: CGFloat
    /// Whether the text view has the keyboard; it reports this, it doesn't take it.
    @Binding var focused: Bool
    /// Bump to give the text view the keyboard.
    var focusRequest: Int
    var maxLines = 10
    var onSubmit: () -> Void
    /// Up, Down, Tab and Esc; true when the composer used the key, else the text view handles it as usual.
    var onKey: (Key) -> Bool
    /// ⌘V and drops: true when the composer took what's on the pasteboard (files or an image).
    var onPaste: (NSPasteboard) -> Bool

    static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    static let lineHeight = NSLayoutManager().defaultLineHeight(for: font)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = InputTextView()
        textView.delegate = context.coordinator
        textView.owner = context.coordinator
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.string = text
        context.coordinator.shown = text

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        // The text view grows to fit its text; the box is that tall, up to maxLines.
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.frameChanged),
                                               name: NSView.frameDidChangeNotification, object: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = scrollView.documentView as? InputTextView else { return }
        // Sent, completed or cleared from outside. Goes through the text system so Undo still works.
        if text != coordinator.shown {
            coordinator.shown = text
            let all = NSRange(location: 0, length: (textView.string as NSString).length)
            if textView.shouldChangeText(in: all, replacementString: text) {
                textView.replaceCharacters(in: all, with: text)
                textView.didChangeText()
            }
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            textView.scrollRangeToVisible(textView.selectedRange())
        }
        if focusRequest != coordinator.focusRequest {
            coordinator.focusRequest = focusRequest
            textView.wantsFocus = true
            DispatchQueue.main.async { textView.takeFocus() }
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        /// The text last passed between the view and the binding.
        var shown = ""
        var focusRequest: Int

        init(_ parent: ComposerTextView) {
            self.parent = parent
            focusRequest = parent.focusRequest - 1
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // A native copy: SwiftUI compares the draft on every change, and comparing a bridged NSString
            // goes character by character (about 125 ms a keystroke with 50 KB in the box).
            var text = textView.string
            text.makeContiguousUTF8()
            guard text != shown else { return }
            shown = text
            parent.text = text
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.moveUp(_:)): return parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)): return parent.onKey(.down)
            // As in a text field: Tab moves on and Esc does nothing, where a text view types a tab and offers completions.
            case #selector(NSResponder.insertTab(_:)):
                if !parent.onKey(.tab) { textView.window?.selectNextKeyView(nil) }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                _ = parent.onKey(.escape)
                return true
            default: return false
            }
        }

        @objc func frameChanged(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let line = ComposerTextView.lineHeight
            let height = min(max(textView.frame.height, line), line * CGFloat(parent.maxLines)).rounded(.up)
            // Not during SwiftUI's update; the frame changes while it lays out.
            if height != parent.height { DispatchQueue.main.async { self.parent.height = height } }
        }

        func focusChanged(_ focused: Bool) {
            if parent.focused != focused { parent.focused = focused }
        }
    }
}

final class InputTextView: NSTextView {
    weak var owner: ComposerTextView.Coordinator?
    /// Take the keyboard once in a window.
    var wantsFocus = false

    func takeFocus() {
        guard let window else { return }
        wantsFocus = false
        window.makeFirstResponder(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsFocus { DispatchQueue.main.async { self.takeFocus() } }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { owner?.focusChanged(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { owner?.focusChanged(false) }
        return resigned
    }

    /// Shift-Return starts a new line, as Option-Return does; Return alone sends.
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .shift, [36, 76].contains(event.keyCode) {
            insertNewlineIgnoringFieldEditor(nil)
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        if owner?.parent.onPaste(.general) == true { return }
        pasteAsPlainText(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if owner?.parent.onPaste(sender.draggingPasteboard) == true { return true }
        return super.performDragOperation(sender)
    }
}
