// Features the official app doesn't have: macOS notifications and "EQ per app" rules.
import AppKit
import UserNotifications

struct AppEQRule: Codable, Hashable, Identifiable {
    var bundleID: String
    var name: String
    var mode: UInt8
    var id: String { bundleID }

    private static let key = "a30.appRules"
    static func load() -> [AppEQRule] {
        guard let d = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([AppEQRule].self, from: d)) ?? []
    }
    static func save(_ rules: [AppEQRule]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(rules), forKey: key)
    }
}

struct SavedEQ: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var bands: [Int]
}

/// EQ + mic + balance bundle, like the official app's "Game"/"Media" profiles.
struct Profile: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var eqMode: UInt8
    var bands: [Int]
    var sidetone: [UInt8: Int]
    var noiseGate: [UInt8: UInt8]
    var balance: Int?
}

/// JSON in UserDefaults for the small lists the app keeps on this Mac.
enum Store {
    static func load<T: Decodable>(_ key: String) -> [T] {
        guard let d = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: d)) ?? []
    }
    static func save<T: Encodable>(_ v: [T], _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(v), forKey: key)
    }
}

/// Modal name prompt (rename headset, save preset/profile).
@MainActor
enum Ask {
    static func name(_ title: String, initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue.trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }
}

enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

@MainActor
enum Extras {
    static func watchFrontmostApp(_ m: HeadsetModel) {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak m] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { m?.appActivated(app?.bundleIdentifier) }
        }
    }

    /// Pick an app from /Applications and add it to the EQ rules.
    static func pickApp(_ m: HeadsetModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url, let b = Bundle(url: url), let id = b.bundleIdentifier else { return }
        let name = (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (b.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
        m.addAppRule(bundleID: id, name: name)
    }
}
