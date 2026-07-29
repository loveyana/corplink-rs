import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: VPNController
    @AppStorage("otpVisible") private var otpVisible = true
    @State private var logExpanded = false
    @State private var showSSOSheet = false

    var body: some View {
        ZStack {
            background

            VStack(alignment: .leading, spacing: 14) {
                brandHeader
                otpHero
                controls
                if let err = controller.lastError, !err.isEmpty {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(CLTheme.danger.opacity(0.95))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                if logExpanded {
                    logPanel
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(16)
        }
        .frame(width: 400)
        .fixedSize(horizontal: true, vertical: true)
        .preferredColorScheme(.dark)
        .onAppear {
            controller.startMonitoring()
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onChange(of: controller.awaitingConfirm) { _, waiting in
            showSSOSheet = waiting
        }
        .onChange(of: controller.isConnected) { _, connected in
            if connected { showSSOSheet = false }
        }
        .sheet(isPresented: $showSSOSheet) {
            SSOStepSheet()
                .environmentObject(controller)
                .preferredColorScheme(.dark)
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [CLTheme.slateDeep, CLTheme.slate, CLTheme.slateDeep.opacity(0.92)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            // Soft teal glow echoing the icon arc — atmosphere, not decoration noise.
            Circle()
                .fill(CLTheme.teal.opacity(0.12))
                .frame(width: 220, height: 220)
                .blur(radius: 50)
                .offset(x: 140, y: -80)
        )
        .ignoresSafeArea()
    }

    private var brandHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.25))
                    .frame(width: 28, height: 28)
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                    .shadow(color: statusColor.opacity(0.7), radius: 4)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("CorpLink")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(CLTheme.mist)
                    Text("RS")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(CLTheme.teal)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(CLTheme.tealSoft))
                }
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let ip = controller.tunnelIP {
                Text(ip)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
            }
        }
    }

    private var subtitle: String {
        if controller.pendingApply, controller.isConnected {
            return "待重连生效"
        }
        if let node = controller.activeNode, controller.isConnected {
            return "Connected · \(node)"
        }
        return controller.statusText
    }

    private var otpHero: some View {
        CLPanel(padding: 14) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("OTP")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .tracking(1.2)
                            .foregroundStyle(CLTheme.teal)
                        Text("飞连")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.35))
                    }

                    Text(otpDisplayText)
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .kerning(otpVisible ? 5 : 2)
                        .foregroundStyle(CLTheme.mist)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.2), value: controller.otpCode)

                    // Expiry as a thin teal progress, not a loud countdown block.
                    GeometryReader { geo in
                        let total: CGFloat = 30
                        let ratio = min(max(CGFloat(controller.otpExpiresIn) / total, 0), 1)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule()
                                .fill(controller.otpExpiresIn <= 5 ? CLTheme.warn : CLTheme.teal)
                                .frame(width: geo.size.width * ratio)
                        }
                    }
                    .frame(height: 3)
                    .frame(maxWidth: 160)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 8) {
                    Text("\(controller.otpExpiresIn)s")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(controller.otpExpiresIn <= 5 ? CLTheme.warn : Color.white.opacity(0.4))

                    HStack(spacing: 6) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { otpVisible.toggle() }
                        } label: {
                            Image(systemName: otpVisible ? "eye.slash" : "eye")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.7))
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Color.white.opacity(0.07)))
                        }
                        .buttonStyle(.plain)
                        .help(otpVisible ? "隐藏" : "显示")

                        Button("Copy") { controller.copyOTP() }
                            .buttonStyle(CLGhostButtonStyle())
                            .disabled(controller.otpCode.isEmpty)
                            .opacity(controller.otpCode.isEmpty ? 0.4 : 1)
                    }
                }
            }
        }
    }

    private var controls: some View {
        CLPanel(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    sectionLabel("MODE")
                    Spacer()
                    sectionLabel(controller.routeMode == .split ? "SPLIT" : "FULL")
                }

                Picker("", selection: $controller.routeMode) {
                    Text("极速").tag(RouteMode.split)
                    Text("全局").tag(RouteMode.full)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(controller.isBusy)
                .onChange(of: controller.routeMode) { _, newValue in
                    controller.applyRouteMode(newValue)
                }

                sectionLabel("NODE")
                    .padding(.top, 2)

                HStack(alignment: .center, spacing: 8) {
                    Picker("", selection: $controller.selectedNode) {
                        ForEach(controller.nodePickerOptions, id: \.self) { name in
                            Text(controller.displayName(for: name)).tag(name)
                        }
                    }
                    .labelsHidden()
                    .disabled(controller.isBusy || controller.isProbingLatency)
                    .onChange(of: controller.selectedNode) { _, _ in
                        controller.saveNodeSelectionOnly()
                    }

                    Button {
                        controller.refreshLatencies()
                    } label: {
                        if controller.isProbingLatency {
                            ProgressView()
                                .controlSize(.small)
                                .tint(CLTheme.teal)
                        } else {
                            Text("Ping")
                        }
                    }
                    .buttonStyle(CLGhostButtonStyle())
                    .disabled(controller.isBusy || controller.isProbingLatency)
                    .help("Measure RTT to every VPN node")
                }

                Text(controller.latencySummary)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.38))

                if controller.pendingApply {
                    pendingApplyBanner
                }

                Divider().overlay(CLTheme.hairline).padding(.vertical, 2)

                HStack(spacing: 8) {
                    Button(controller.isConnected ? "Disconnect" : "Connect") {
                        if controller.isConnected { controller.disconnect() }
                        else { controller.connect() }
                    }
                    .buttonStyle(CLPrimaryButtonStyle(enabled: !controller.isBusy && !controller.pendingApply))
                    .disabled(controller.isBusy)

                    if controller.pendingApply {
                        Button("Apply 重连") { controller.applyNodeAndReconnect() }
                            .buttonStyle(CLPrimaryButtonStyle(enabled: !controller.isBusy))
                            .disabled(controller.isBusy)
                    } else if controller.isConnected {
                        Button("Reconnect") { controller.applyNodeAndReconnect() }
                            .buttonStyle(CLGhostButtonStyle())
                            .disabled(controller.isBusy)
                    }

                    if controller.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .tint(CLTheme.teal)
                        Button("Cancel") { controller.forceResetBusy() }
                            .buttonStyle(CLGhostButtonStyle())
                    }

                    Spacer(minLength: 4)

                    Button(logExpanded ? "Log ▴" : "Log ▾") {
                        withAnimation(.easeInOut(duration: 0.18)) { logExpanded.toggle() }
                    }
                    .buttonStyle(CLGhostButtonStyle())
                }
            }
        }
    }

    private var logPanel: some View {
        ScrollView {
            Text(controller.logTail.isEmpty ? "Waiting for events…" : controller.logTail)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(height: 120)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.28))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(CLTheme.hairline, lineWidth: 1)
                )
        )
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(1.1)
            .foregroundStyle(Color.white.opacity(0.32))
    }

    private var pendingApplyBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(CLTheme.warn)
                .frame(width: 7, height: 7)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text("配置已保存，当前连接尚未切换")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CLTheme.warn)
                Text(controller.pendingApplyHint.isEmpty
                     ? "点下方「Apply 重连」后生效（需管理员密码）"
                     : controller.pendingApplyHint)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(CLTheme.warn.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(CLTheme.warn.opacity(0.35), lineWidth: 1)
                )
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var otpDisplayText: String {
        if controller.otpCode.isEmpty { return "······" }
        return otpVisible ? controller.otpCode : "••••••"
    }

    private var statusColor: Color {
        if controller.isConnected { return CLTheme.ok }
        if controller.isBusy || controller.awaitingConfirm { return CLTheme.warn }
        return Color.white.opacity(0.35)
    }
}

struct SSOStepSheet: View {
    @EnvironmentObject private var controller: VPNController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            CLTheme.slateDeep.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "person.badge.key.fill")
                        .foregroundStyle(CLTheme.teal)
                    Text("SSO")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(CLTheme.mist)
                }

                Text("浏览器完成登录后点确认，隧道才会继续建立。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 8) {
                    Button {
                        controller.openPendingSSO()
                    } label: {
                        Label("Open Login Page", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(CLPrimaryButtonStyle())

                    Button {
                        controller.confirmAuthDone()
                        dismiss()
                    } label: {
                        Label("Confirm Auth Done", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(CLGhostButtonStyle())
                    .keyboardShortcut(.defaultAction)
                }

                Button("稍后") { dismiss() }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .buttonStyle(.plain)
            }
            .padding(22)
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }
}
