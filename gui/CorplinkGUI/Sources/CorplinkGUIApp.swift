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
                    appDelegate.bind(controller: controller)
                }
        } label: {
            Image(systemName: controller.isConnected ? "lock.shield.fill" : "lock.shield")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var controller: VPNController?
    private let otpHotKey = GlobalHotKey()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Stay as accessory+regular so menu bar icon remains after window close.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        otpHotKey.unregister()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .corplinkShowMainWindow, object: nil)
        return true
    }

    /// Wire controller + (re)register the configured global OTP hotkey.
    @MainActor
    func bind(controller: VPNController) {
        self.controller = controller
        controller.onOTPHotKeyPreferenceChanged = { [weak self] option in
            self?.registerOTPHotKey(option)
        }
        registerOTPHotKey(controller.otpGlobalHotKey)
    }

    @MainActor
    private func registerOTPHotKey(_ option: OTPGlobalHotKeyOption) {
        otpHotKey.onPressed = { [weak self] in
            Task { @MainActor in
                self?.controller?.copyOTP(fromGlobalHotKey: true)
            }
        }
        let result = otpHotKey.register(option: option)
        controller?.updateOTPHotKeyStatus(result)
        switch result {
        case .success:
            NSLog("GlobalHotKey: registered \(option.displayName) for Copy OTP")
        case .disabled:
            NSLog("GlobalHotKey: disabled")
        case .conflict:
            NSLog("GlobalHotKey: conflict on \(option.displayName) — not armed")
        case .failed(let code):
            NSLog("GlobalHotKey: failed OSStatus=\(code)")
        }
    }
}

extension Notification.Name {
    static let corplinkShowMainWindow = Notification.Name("corplinkShowMainWindow")
}
