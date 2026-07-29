import AppKit
import SwiftUI

/// Menu-bar dropdown: connect + mode/node + OTP copy.
struct MenuBarView: View {
    @EnvironmentObject private var controller: VPNController
    @Environment(\.openWindow) private var openWindow
    @AppStorage("otpVisible") private var otpVisible = true

    var body: some View {
        Text(controller.statusText)
            .foregroundStyle(.secondary)
        if let ip = controller.tunnelIP {
            Text(ip).font(.system(.caption, design: .monospaced))
        }

        Divider()

        // Live OTP
        if !controller.otpCode.isEmpty {
            if otpVisible {
                Text("OTP  \(controller.otpCode)  ·  \(controller.otpExpiresIn)s")
                    .font(.system(.body, design: .monospaced))
            } else {
                Text("OTP  ••••••  ·  \(controller.otpExpiresIn)s")
                    .font(.system(.body, design: .monospaced))
            }
            Button(otpVisible ? "Hide OTP" : "Show OTP") {
                otpVisible.toggle()
            }
            Button("Copy OTP") {
                controller.copyOTP()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
        } else {
            Text("OTP unavailable")
                .foregroundStyle(.secondary)
        }

        Divider()

        Button(controller.isConnected ? "Disconnect" : "Connect") {
            if controller.isConnected { controller.disconnect() }
            else { controller.connect() }
        }
        .disabled(controller.isBusy)

        if controller.awaitingConfirm {
            Button("SSO Steps…") { showMainWindow() }
            Button("Confirm Auth Done") { controller.confirmAuthDone() }
        }

        if controller.isBusy {
            Button("Cancel Busy") { controller.forceResetBusy() }
        }

        Divider()

        Menu("模式: \(controller.routeMode == .split ? "极速" : "全局")") {
            Button { controller.selectModeFromMenu(.split) } label: { modeLabel(.split) }
            Button { controller.selectModeFromMenu(.full) } label: { modeLabel(.full) }
        }
        .disabled(controller.isBusy)

        Menu("节点: \(shortNodeName(controller.selectedNode))") {
            Button { controller.selectNodeFromMenu(NodeChoice.auto) } label: { nodeLabel(NodeChoice.auto) }
            Button { controller.selectNodeFromMenu(NodeChoice.latency) } label: { nodeLabel(NodeChoice.latency) }
            Divider()
            ForEach(menuNodes, id: \.self) { name in
                Button { controller.selectNodeFromMenu(name) } label: { nodeLabel(name) }
            }
            Divider()
            Button("刷新延迟…") { controller.refreshLatencies() }
                .disabled(controller.isProbingLatency || controller.isBusy)
        }
        .disabled(controller.isBusy)

        if controller.isProbingLatency {
            Text("Measuring latency…")
                .foregroundStyle(.secondary)
        } else if let summary = latencyMenuHint {
            Text(summary)
                .foregroundStyle(.secondary)
        }

        if controller.isConnected {
            Button("Apply & Reconnect") { controller.applyNodeAndReconnect() }
                .disabled(controller.isBusy)
        }

        if controller.pendingApply {
            Text(controller.pendingApplyHint.isEmpty
                 ? "配置已改，需重连生效"
                 : controller.pendingApplyHint)
                .foregroundStyle(.orange)
        }

        Divider()

        Button("Open Window…") { showMainWindow() }
        Button("Open Log") { controller.openLog() }

        Divider()

        Button("Quit CorpLink RS") { NSApp.terminate(nil) }
    }

    private var menuNodes: [String] {
        Array(controller.nodesSortedByLatency.prefix(40))
    }

    private var latencyMenuHint: String? {
        guard !controller.nodeLatencies.isEmpty else { return nil }
        return "延迟: \(controller.latencySummary)"
    }

    private func shortNodeName(_ choice: String) -> String {
        switch choice {
        case NodeChoice.auto: return "自动"
        case NodeChoice.latency: return "延迟"
        default:
            if let ms = controller.nodeLatencies[choice] {
                return "\(choice) \(ms)ms"
            }
            return choice
        }
    }

    @ViewBuilder
    private func modeLabel(_ mode: RouteMode) -> some View {
        if controller.routeMode == mode {
            Label(mode == .split ? "极速 (split)" : "全局 (full)", systemImage: "checkmark")
        } else {
            Text(mode == .split ? "极速 (split)" : "全局 (full)")
        }
    }

    @ViewBuilder
    private func nodeLabel(_ name: String) -> some View {
        let title = controller.displayName(for: name)
        if controller.selectedNode == name {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            for window in NSApp.windows where window.title.contains("CorpLink") {
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
