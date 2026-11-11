import SwiftUI
import AppKit

@main
struct A30ControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = HeadsetModel.shared

    init() { HeadsetModel.shared.start() }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(model: model)
        } label: {
            Image(nsImage: MenuBarIcon.image(model.menuBadges))
            Text(model.menuTitle)
        }
        .menuBarExtraStyle(.window)

        Window("A30 Control", id: "main") {
            MainWindow(model: model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)   // menu-bar app: the window opens only from the panel
    }
}

/// Menu-bar app that shows a Dock icon only while its window is open.
/// Quitting from the Dock (or ⌘Q) just closes the window; the menu-bar app keeps running.
/// Only the panel's Quit button, logout, restart or shutdown really terminate it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var reallyQuit = false

    static func quitForReal() {
        reallyQuit = true
        NSApp.terminate(nil)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // Fixed-size window: no resize handle, green button can't enter full screen.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            guard let w = note.object as? NSWindow, Self.isMainWindow(w) else { return }
            w.styleMask.remove(.resizable)
            w.collectionBehavior.remove(.fullScreenPrimary)
            w.collectionBehavior.insert(.fullScreenNone)
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let w = note.object as? NSWindow, Self.isMainWindow(w) else { return }
            DispatchQueue.main.async {   // after the window is gone
                if !NSApp.windows.contains(where: { Self.isMainWindow($0) && $0.isVisible }) {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A quit Apple Event carrying a reason = logout / restart / shutdown: let it through.
        let reason = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))
        if Self.reallyQuit || reason != nil { return .terminateNow }
        for w in NSApp.windows where Self.isMainWindow(w) { w.close() }
        NSApp.setActivationPolicy(.accessory)
        return .terminateCancel
    }

    /// Dock icon clicked while the window was closed: bring it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let w = NSApp.windows.first(where: { Self.isMainWindow($0) }) { w.makeKeyAndOrderFront(nil) }
        return true
    }

    private static func isMainWindow(_ w: NSWindow) -> Bool {
        w.identifier?.rawValue.hasPrefix("main") == true
    }
}
