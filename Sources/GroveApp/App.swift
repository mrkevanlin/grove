import AppKit
import GroveCore
import ServiceManagement
import SwiftUI

@main
struct GroveMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var sup = Supervisor.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(sup)
        } label: {
            let n = sup.activeCount
            if sup.hasProblems {
                Image(systemName: "exclamationmark.triangle.fill")
            } else if let icon = MenuBarIcon.image {
                Image(nsImage: icon)
            } else {
                Image(systemName: "tree") // running via `swift run`, outside the .app bundle
            }
            if n > 0 { Text("\(n)") }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Supervisor.shared.stopAll() }
    }
}

enum MenuBarIcon {
    /// Grove.png / Grove@2x.png from the app bundle, as a template so macOS tints it for the menu bar.
    static let image: NSImage? = {
        guard let img = NSImage(named: "Grove") else { return nil }
        img.isTemplate = true
        img.size = NSSize(width: 18, height: 18)
        return img
    }()
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Sys.notify("Grove", "Couldn't change launch at login: \(error.localizedDescription)")
        }
    }
}
