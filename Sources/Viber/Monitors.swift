import AppKit
import Foundation
import UserNotifications
import ViberCore

/// Watches ~/.claude/projects for sessions Viber did not start (VS Code, terminals), using claude-cache's logic.
final class ExternalMonitor {
    private let queue = DispatchQueue(label: "viber.external")
    private let watcher = TranscriptWatcher(root: Paths.projects)
    private var store = SessionStore()
    private var bootstrapped = false

    /// Calls back on the main queue with recent sessions and whether this was the initial catch-up.
    func poll(_ completion: @escaping ([Session], Bool) -> Void) {
        queue.async { [self] in
            let now = Date()
            let scan = watcher.scan(fallbackTTL: 300)
            for event in scan.events.sorted(by: { $0.time < $1.time }) { store.apply(event) }
            store.prune(at: now)
            let bootstrap = !bootstrapped
            if !scan.catchingUp { bootstrapped = true }
            let recent = store.sessions.values
                .filter { $0.isRecent(at: now) && now.timeIntervalSince($0.lastActivity) < 6 * 3600 }
                .sorted { $0.lastActivity > $1.lastActivity }
            DispatchQueue.main.async { completion(Array(recent.prefix(12)), bootstrap) }
        }
    }
}

/// macOS notifications. Only works from the bundled app; `swift run` has no bundle identity.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((String) -> Void)?
    var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    func setUp() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(id: String, title: String, body: String, target: String, sound: Bool = true) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["target": target]
        content.threadIdentifier = target
        if sound { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func clear(target: String) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered.filter { $0.request.content.userInfo["target"] as? String == target }.map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let target = response.notification.request.content.userInfo["target"] as? String {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                self.onOpen?(target)
            }
        }
        completionHandler()
    }
}
