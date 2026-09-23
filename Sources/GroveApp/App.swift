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
            Image(systemName: sup.hasProblems ? "exclamationmark.triangle.fill" : "server.rack")
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
