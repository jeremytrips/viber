import CoreGraphics
import Foundation

/// Android's view hierarchy as a `UITree`: from `uiautomator dump` (XML) or the Android CLI's `android layout` (JSON).
/// Frames come in device pixels and are turned into dp, the unit Android's layouts and the device tools use.
public enum AndroidTree {
    /// `uiautomator dump` output: `<hierarchy><node class= text= content-desc= resource-id= bounds="[x1,y1][x2,y2]" …>`.
    /// `scale` is pixels per dp (density / 160).
    public static func parseUIAutomator(_ xml: Data, scale: CGFloat, screen: CGSize? = nil) -> UITree? {
        let reader = HierarchyReader(scale: scale)
        let parser = XMLParser(data: xml)
        parser.delegate = reader
        guard parser.parse(), reader.sawHierarchy else { return nil }
        let frame = screen.map { CGRect(origin: .zero, size: $0) } ?? reader.roots.first?.frame ?? .zero
        let root = UIElement(role: "Application", label: reader.package, frame: frame, children: reader.roots)
        return UITree(root: root, screen: frame)
    }

    /// The XML in `uiautomator dump`'s output, which may start with a status line.
    public static func xml(in output: Data) -> Data? {
        guard let start = output.range(of: Data("<?xml".utf8)) ?? output.range(of: Data("<hierarchy".utf8)) else { return nil }
        return output.subdata(in: start.lowerBound..<output.endIndex)
    }

    /// `android layout` output: an array of windows (`type`, `active`, `window-title`, `content`) whose nodes have
    /// `class`, `text`, `content-desc`, `resource-id`, `bounds`, `interactions` (CLICKABLE, CHECKABLE, EDITABLE…),
    /// `state` (CHECKED, FOCUSED…) and `children`. Only the active app window is kept, as uiautomator does.
    public static func parseLayout(_ json: Data, scale: CGFloat, screen: CGSize? = nil) -> UITree? {
        guard let start = json.firstIndex(where: { $0 == UInt8(ascii: "[") }),
              let windows = try? JSONSerialization.jsonObject(with: json.subdata(in: start..<json.endIndex)) as? [[String: Any]] else { return nil }
        let apps = windows.filter { $0["type"] as? String == "APPLICATION" }
        guard let window = apps.first(where: { $0["active"] as? Bool == true }) ?? apps.first else { return nil }
        let content = window["content"] as? [[String: Any]] ?? []
        var packages: [String: Int] = [:]
        func element(_ node: [String: Any]) -> UIElement {
            let interactions = Set(node["interactions"] as? [String] ?? [])
            let state = Set(node["state"] as? [String] ?? [])
            let id = node["resource-id"] as? String
            if let id, let range = id.range(of: ":id/") { packages[String(id[..<range.lowerBound]), default: 0] += 1 }
            return makeElement(className: node["class"] as? String ?? "", text: node["text"] as? String,
                               description: node["content-desc"] as? String, resourceID: id, hint: nil,
                               bounds: node["bounds"] as? String, scale: scale,
                               clickable: interactions.contains("CLICKABLE") || interactions.contains("LONG_CLICKABLE"),
                               checkable: interactions.contains("CHECKABLE"), checked: state.contains("CHECKED"),
                               editable: interactions.contains("EDITABLE"), password: state.contains("PASSWORD"),
                               scrollable: interactions.contains("SCROLLABLE"), enabled: !state.contains("DISABLED"),
                               children: (node["children"] as? [[String: Any]] ?? []).map(element))
        }
        let children = content.map(element)
        let windowFrame = frame(window["bounds"] as? String, scale: scale) ?? .zero
        let frame = screen.map { CGRect(origin: .zero, size: $0) } ?? windowFrame
        // The window title is what the user sees ("Settings"); the package names the app like uiautomator's tree does.
        let package = packages.filter { $0.key != "android" }.max { $0.value < $1.value }?.key
        let title = (window["window-title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let root = UIElement(role: "Application", label: package ?? title, frame: frame, children: children)
        return UITree(root: root, screen: frame)
    }

    /// "[0,153][1080,342]" in pixels → a rect in dp.
    public static func frame(_ bounds: String?, scale: CGFloat) -> CGRect? {
        guard let bounds else { return nil }
        let numbers = bounds.split(whereSeparator: { !$0.isNumber && $0 != "-" }).compactMap { Double($0) }
        guard numbers.count == 4, scale > 0 else { return nil }
        return CGRect(x: numbers[0] / scale, y: numbers[1] / scale,
                      width: max(0, numbers[2] - numbers[0]) / scale, height: max(0, numbers[3] - numbers[1]) / scale)
    }

    /// The role `UITree` uses (iOS's names, so outlines and `isInteractive` read the same on both platforms).
    public static func role(className: String, clickable: Bool, checkable: Bool, editable: Bool, password: Bool, scrollable: Bool) -> String {
        let name = String(className.split(separator: ".").last ?? Substring(className))
        let simple = String(name.split(separator: "$").last ?? Substring(name))
        if editable || simple.hasSuffix("EditText") || simple.hasSuffix("AutoCompleteTextView") || simple == "SearchAutoComplete" {
            return password ? "SecureTextField" : "TextField"
        }
        if simple.hasSuffix("Switch") || simple == "SwitchCompat" || simple == "SwitchMaterial" || simple == "ToggleButton" { return "Switch" }
        if simple.hasSuffix("CheckBox") { return "CheckBox" }
        if simple.hasSuffix("RadioButton") { return "RadioButton" }
        if simple.hasSuffix("Button") || simple == "Chip" { return "Button" }
        if simple.hasSuffix("SeekBar") || simple == "Slider" || simple == "RangeSlider" || simple == "RatingBar" { return "Slider" }
        if simple.hasSuffix("Spinner") { return "PopUpButton" }
        if simple.hasSuffix("TabView") { return "Tab" }
        if simple == "WebView" { return "WebView" }
        if simple.hasSuffix("ProgressBar") { return "ProgressIndicator" }
        if checkable { return "CheckBox" }
        if clickable { return "Button" }
        if simple.hasSuffix("TextView") { return "StaticText" }
        if simple.hasSuffix("ImageView") { return "Image" }
        if scrollable || simple.hasSuffix("ScrollView") || simple.hasSuffix("RecyclerView") || simple == "ListView" || simple == "GridView"
            || simple.hasPrefix("ViewPager") { return "ScrollView" }
        return "Group"
    }

    static func makeElement(className: String, text: String?, description: String?, resourceID: String?, hint: String?,
                            bounds: String?, scale: CGFloat, clickable: Bool, checkable: Bool, checked: Bool, editable: Bool,
                            password: Bool, scrollable: Bool, enabled: Bool, children: [UIElement]) -> UIElement {
        func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }
        let role = role(className: className, clickable: clickable, checkable: checkable, editable: editable, password: password, scrollable: scrollable)
        let text = nonEmpty(text), description = nonEmpty(description)
        var label: String?, value: String?
        switch role {
        case "TextField", "SecureTextField":
            label = description ?? nonEmpty(hint)
            value = text
        case "Switch", "CheckBox", "RadioButton":
            label = description ?? text
            value = checked ? "1" : "0"
        default:
            label = description ?? text
            if let description, let text, text != description { value = text }
        }
        // "com.example:id/save_button" → "save_button". Android names nearly every layout container; outlines list only
        // the ids of things worth finding (controls, text, lists).
        let named = label != nil || value != nil || !["Group", "Image"].contains(role)
        let identifier = named ? nonEmpty(resourceID).map { id in id.range(of: ":id/").map { String(id[$0.upperBound...]) } ?? id } : nil
        return UIElement(role: role, label: label, value: value, identifier: identifier,
                         frame: frame(bounds, scale: scale) ?? .zero, enabled: enabled, children: children)
    }

    private final class HierarchyReader: NSObject, XMLParserDelegate {
        let scale: CGFloat
        var roots: [UIElement] = []
        var package: String?
        var sawHierarchy = false
        private var stack: [(attributes: [String: String], children: [UIElement])] = []

        init(scale: CGFloat) { self.scale = scale }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            if name == "hierarchy" { sawHierarchy = true }
            guard name == "node" else { return }
            if package == nil, let p = attributes["package"], !p.isEmpty { package = p }
            stack.append((attributes, []))
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard name == "node", let (a, children) = stack.popLast() else { return }
            func flag(_ key: String) -> Bool { a[key] == "true" }
            let element = AndroidTree.makeElement(
                className: a["class"] ?? "", text: a["text"], description: a["content-desc"], resourceID: a["resource-id"],
                hint: a["hint"], bounds: a["bounds"], scale: scale, clickable: flag("clickable") || flag("long-clickable"),
                checkable: flag("checkable"), checked: flag("checked"), editable: false, password: flag("password"),
                scrollable: flag("scrollable"), enabled: a["enabled"] != "false", children: children)
            if stack.isEmpty { roots.append(element) } else { stack[stack.count - 1].children.append(element) }
        }
    }
}
