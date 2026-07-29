import AppKit
import Foundation
import SwiftUI

@main
struct CorplinkGUIApp: App {
    @StateObject private var controller = VPNController()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Named window so menu bar can reopen it after the user closes with ✕
        Window("CorpLink RS", id: "main") {
            ContentView()
                .environmentObject(controller)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 400, height: 360)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(controller)
                .onAppear {
                    controller.startMonitoring()
                    appDelegate.controller = controller
                }
        } label: {
            Image(systemName: controller.isConnected ? "lock.shield.fill" : "lock.shield")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var controller: VPNController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Stay as accessory+regular so menu bar icon remains after window close.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Dock click / reopen — show main window.
        NotificationCenter.default.post(name: .corplinkShowMainWindow, object: nil)
        return true
    }
}

extension Notification.Name {
    static let corplinkShowMainWindow = Notification.Name("corplinkShowMainWindow")
}
