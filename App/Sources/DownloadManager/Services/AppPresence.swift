import AppKit
import ServiceManagement

extension Notification.Name {
    /// Ask the SwiftUI scene layer to open (or bring forward) the main window.
    static let showMainWindow = Notification.Name("MCShowMainWindow")
}

/// Keeps the app living in the menu bar: the Dock icon is shown only while a regular window is
/// open, the main window stays closed at launch, and quitting happens from the menu bar icon.
/// The app is declared `LSUIElement` so a login launch never bounces the Dock or steals focus.
final class AppPresence {
    static let shared = AppPresence()
    private let settings = AppSettings.shared
    private var observers: [NSObjectProtocol] = []

    /// Whether this launch should leave the main window closed (first launch always shows it for onboarding).
    var startsHidden: Bool { settings.startInMenuBar && settings.onboardingDone }

    /// Called from `applicationWillFinishLaunching`, before any window exists.
    func prepareLaunch() {
        if !(settings.hideDockIcon && startsHidden) {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let w = n.object as? NSWindow, Self.isRegularWindow(w) else { return }
            self.showInDock()
        })
        observers.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let closing = n.object as? NSWindow, Self.isRegularWindow(closing) else { return }
            DispatchQueue.main.async { self.hideFromDockIfNoWindows(excluding: closing) }
        })
    }

    /// Called from `applicationDidFinishLaunching`; fallback for systems without `defaultLaunchBehavior` (macOS < 15).
    func finishLaunch() {
        if startsHidden, #unavailable(macOS 15.0) {
            for w in NSApp.windows where Self.isMainWindow(w) { w.close() }
        }
        hideFromDockIfNoWindows()
    }

    /// Opens the main window (via the SwiftUI scene) and brings the app forward with its Dock icon.
    func showMainWindow() {
        showInDock()
        // The always-alive menu bar label owns a SwiftUI `openWindow`; it opens or fronts the scene window.
        NotificationCenter.default.post(name: .showMainWindow, object: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showInDock() {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        // After switching from accessory to regular the menu bar only appears once the app is (re)activated.
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }

    func hideFromDockIfNoWindows(excluding: NSWindow? = nil) {
        guard settings.hideDockIcon else { return }
        let open = NSApp.windows.contains { $0 !== excluding && $0.isVisible && Self.isRegularWindow($0) }
        if !open, NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Re-evaluate after the user toggles "hide Dock icon" in Settings.
    func applyDockPreference() {
        if settings.hideDockIcon { hideFromDockIfNoWindows() } else { showInDock() }
    }

    static func isMainWindow(_ w: NSWindow) -> Bool {
        w.identifier?.rawValue.contains("main") == true
    }

    /// Titled, user-facing windows: the main window, Settings, wizard, download detail windows.
    static func isRegularWindow(_ w: NSWindow) -> Bool {
        guard w.styleMask.contains(.titled), !(w is NSPanel) else { return false }
        let cls = String(describing: type(of: w))
        return !cls.contains("StatusBar") && !cls.contains("Popover") && !cls.contains("MenuWindow")
    }
}

/// "Open at login" via SMAppService (macOS 13+). Enabled once by default after the first-run setup.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    /// Registers the app as a login item the first time the setup is completed, so browser extensions
    /// find the bridge running after a reboot without the user opening the app. Only for an installed
    /// copy (an .app under /Applications or ~/Applications); build folders would leave stale login items.
    static func registerByDefaultIfNeeded() {
        let settings = AppSettings.shared
        guard settings.onboardingDone, !settings.loginItemAutoRegistered else { return }
        let path = Bundle.main.bundleURL.path
        guard path.hasSuffix(".app"),
              path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/") else { return }
        if SMAppService.mainApp.status == .notRegistered {
            // Kayıt başarısız olursa bayrağı işaretleme: sonraki açılışta yeniden denenir.
            guard (try? SMAppService.mainApp.register()) != nil else { return }
        }
        settings.loginItemAutoRegistered = true
    }
}
