import CoreGraphics
import Foundation

/// One element of a device's accessibility tree, in screen points from the top-left.
public struct UIElement: Equatable, Sendable {
    /// e1, e2, … in document order, set by `UITree`.
    public var ref = ""
    /// "Button", "StaticText", "TextField"… (iOS roles without the AX prefix).
    public var role: String
    public var label: String?
    public var value: String?
    public var identifier: String?
    public var frame: CGRect
    public var enabled: Bool
    public var children: [UIElement]

    public init(role: String, label: String? = nil, value: String? = nil, identifier: String? = nil,
                frame: CGRect, enabled: Bool = true, children: [UIElement] = []) {
        self.role = role; self.label = label; self.value = value; self.identifier = identifier
        self.frame = frame; self.enabled = enabled; self.children = children
    }

    public var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    /// How the element is called in results: `Button "General"`.
    public var title: String {
        let name = label ?? value ?? identifier
        return name.map { "\(role) \"\(UITree.squash($0, limit: 80))\"" } ?? role
    }

    static let interactiveRoles: Set<String> = [
        "Button", "TextField", "SecureTextField", "SearchField", "TextArea", "Switch", "Toggle", "Slider", "CheckBox",
        "RadioButton", "PopUpButton", "ComboBox", "Link", "Cell", "Tab", "TabButton", "MenuItem", "Stepper", "Incrementor",
        "DisclosureTriangle", "SegmentedControl", "Picker", "PickerWheel", "Key",
    ]
    var isInteractive: Bool { Self.interactiveRoles.contains(role) }
    var hasContent: Bool { label != nil || value != nil || identifier != nil }
}

/// A snapshot of what is on a device's screen, with refs Claude can pass back to act on an element.
public struct UITree: Equatable, Sendable {
    public private(set) var root: UIElement
    /// The screen in points.
    public var screen: CGRect

    public init(root: UIElement, screen: CGRect? = nil) {
        var counter = 0
        func number(_ element: inout UIElement) {
            counter += 1
            element.ref = "e\(counter)"
            for i in element.children.indices { number(&element.children[i]) }
        }
        var root = root
        number(&root)
        self.root = root
        self.screen = screen ?? root.frame
    }

    /// Nothing on screen has a name or can be acted on.
    public var isEmpty: Bool { !elements.dropFirst().contains { $0.hasContent || $0.isInteractive } }

    /// The app in front, when the root is an application.
    public var app: String? { root.role == "Application" ? root.label : nil }

    /// Every element in document order, root included.
    public var elements: [UIElement] {
        var all: [UIElement] = []
        func walk(_ e: UIElement) { all.append(e); e.children.forEach(walk) }
        walk(root)
        return all
    }

    public func element(ref: String) -> UIElement? {
        let wanted = ref.trimmingCharacters(in: .whitespaces).lowercased()
        return elements.first { $0.ref == wanted }
    }

    /// The element best matching visible text: exact label, identifier or value first, then a label or value that contains it.
    /// Among equals, elements on screen, then interactive ones, then enabled ones win.
    public func find(_ text: String) -> UIElement? {
        let needle = Self.normalize(text)
        guard !needle.isEmpty else { return nil }
        let candidates = elements.dropFirst().filter { $0.frame.width >= 1 && $0.frame.height >= 1 }
        func rank(_ e: UIElement) -> Int? {
            let label = e.label.map(Self.normalize), value = e.value.map(Self.normalize), id = e.identifier.map(Self.normalize)
            if label == needle { return 0 }
            if id == needle { return 1 }
            if value == needle { return 2 }
            if label?.contains(needle) == true { return 3 }
            if value?.contains(needle) == true { return 4 }
            return nil
        }
        return candidates.enumerated().compactMap { index, e in rank(e).map { (e, $0, index) } }
            .min { a, b in
                let ka = (a.1, isOnScreen(a.0) ? 0 : 1, a.0.isInteractive ? 0 : 1, a.0.enabled ? 0 : 1, a.2)
                let kb = (b.1, isOnScreen(b.0) ? 0 : 1, b.0.isInteractive ? 0 : 1, b.0.enabled ? 0 : 1, b.2)
                return ka < kb
            }?.0
    }

    /// The innermost element at a point that has a name or can be acted on: the smallest such frame, the later one among equals.
    public func element(at point: CGPoint) -> UIElement? {
        elements.dropFirst().filter { ($0.hasContent || $0.isInteractive) && $0.frame.contains(point) }
            .enumerated()
            .min { a, b in
                let areaA = a.element.frame.width * a.element.frame.height, areaB = b.element.frame.width * b.element.frame.height
                return areaA != areaB ? areaA < areaB : a.offset > b.offset
            }?.element
    }

    public func isOnScreen(_ e: UIElement) -> Bool {
        screen.intersects(e.frame) && screen.contains(e.center)
    }

    /// An indented outline: one line per element worth naming. Unnamed containers are skipped and their children lifted.
    public func outline(maxChars: Int = 12000) -> String {
        var lines: [String] = []
        var used = 0, omitted = 0
        func emit(_ e: UIElement, depth: Int) {
            var childDepth = depth
            if e.hasContent || e.isInteractive {
                var line = String(repeating: "  ", count: depth) + "- \(e.role)"
                if let label = e.label { line += " \"\(Self.squash(label, limit: 120))\"" }
                if let value = e.value, value != e.label { line += " value=\"\(Self.squash(value, limit: 80))\"" }
                line += " [\(e.ref)]"
                if let id = e.identifier, id != e.label { line += " id=\(Self.squash(id, limit: 60))" }
                line += " (\(Int(e.frame.minX)),\(Int(e.frame.minY)) \(Int(e.frame.width))×\(Int(e.frame.height)))"
                if !e.enabled { line += " disabled" }
                if !isOnScreen(e) { line += " offscreen" }
                if used + line.count + 1 > maxChars {
                    omitted += 1
                } else {
                    lines.append(line)
                    used += line.count + 1
                }
                childDepth += 1
            }
            for child in e.children { emit(child, depth: childDepth) }
        }
        if root.role == "Application" { root.children.forEach { emit($0, depth: 0) } } else { emit(root, depth: 0) }
        if lines.isEmpty { lines.append("(nothing on screen exposes accessibility information)") }
        if omitted > 0 { lines.append("… \(omitted) more element\(omitted == 1 ? "" : "s") (pass a larger max_chars to see them)") }
        return lines.joined(separator: "\n")
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func squash(_ text: String, limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}
