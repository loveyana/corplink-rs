import AppKit
import Foundation
import SwiftUI

enum RouteMode: String, CaseIterable, Identifiable {
    case split
    case full
    var id: String { rawValue }
}

enum NodeChoice {
    static let auto = "__auto__"
    static let latency = "__latency__"
}

@MainActor
final class VPNController: ObservableObject {
    @Published var routeMode: RouteMode = .split
    @Published var selectedNode: String = NodeChoice.auto
    @Published var knownNodes: [String] = []
    /// Node name → RTT in ms. Missing key means not probed yet.
    @Published var nodeLatencies: [String: Int] = [:]
    /// Node names that failed the last probe (timeout / auth / etc).
    @Published var nodeLatencyFailed: Set<String> = []
    @Published var isProbingLatency = false
    @Published var latencyUpdatedAt: Date?
    @Published var customNode: String = ""
    @Published var activeNode: String?
    @Published var pendingSSOURL: String?
    @Published var awaitingConfirm = false
    @Published var isConnected = false
    @Published var isStarting = false
    @Published var tunnelIP: String?
    @Published var statusText = "Disconnected"
    @Published var logTail = ""
    @Published var lastError: String?
    @Published var otpCode: String = ""
    @Published var otpExpiresIn: Int = 0
    /// True when mode/node was changed while connected; tunnel still uses old settings.
    @Published var pendingApply = false
    /// Short Chinese hint for the pending-apply banner.
    @Published var pendingApplyHint = ""
    /// Preferred global OTP hotkey (persisted in gui_settings.json).
    @Published var otpGlobalHotKey: OTPGlobalHotKeyOption = .default
    /// Last registration result for the OTP global hotkey.
    @Published var otpHotKeyStatus: GlobalHotKeyRegisterResult = .disabled
    /// Callback used by AppDelegate to (re)register Carbon hotkey after preference changes.
    var onOTPHotKeyPreferenceChanged: ((OTPGlobalHotKeyOption) -> Void)?

    let repoRoot: URL
    let binaryPath: String
    let configPath: String
    let logPath: String
    let nodeCachePath: String
    let latencyCachePath: String
    let guiSettingsPath: String
    let startScript: String
    let stopScript: String
    let runScript: String
    let authGatePath: String
    let otpBinaryPath: String
    let interfaceName: String

    private var monitorTimer: Timer?
    private var otpTimer: Timer?
    private var lastSeenSSOURL: String?
    private var suppressNodeWrite = false
    private let label = "local.corplink-rs-gui"

    init() {
        let guiDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        repoRoot = guiDir.deletingLastPathComponent()

        let env = ProcessInfo.processInfo.environment
        binaryPath = env["CORPLINK_BIN"]
            ?? repoRoot.appendingPathComponent("target/release/corplink-rs").path
        configPath = env["CORPLINK_CFG"]
            ?? repoRoot.appendingPathComponent("config/config.json").path
        logPath = env["CORPLINK_LOG"] ?? "/tmp/corplink-gui.log"
        nodeCachePath = repoRoot.appendingPathComponent("config/vpn_nodes_cache.json").path
        latencyCachePath = repoRoot.appendingPathComponent("config/vpn_latency_cache.json").path
        guiSettingsPath = repoRoot.appendingPathComponent("config/gui_settings.json").path
        startScript = repoRoot.appendingPathComponent("gui/scripts/vpn-start.sh").path
        stopScript = repoRoot.appendingPathComponent("gui/scripts/vpn-stop.sh").path
        runScript = repoRoot.appendingPathComponent("gui/scripts/vpn-run.sh").path
        authGatePath = env["CORPLINK_AUTH_GATE"] ?? "/tmp/corplink-gui-auth.gate"
        otpBinaryPath = env["CORPLINK_OTP_BIN"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/corplink-otp").path
        interfaceName = Self.readInterfaceName(from: configPath) ?? "utun12345"

        suppressNodeWrite = true
        routeMode = Self.readRouteMode(from: configPath) ?? .split
        selectedNode = Self.readSelectedNode(from: configPath)
        knownNodes = Self.loadNodeCache(path: nodeCachePath)
        if knownNodes.isEmpty { knownNodes = Self.seedNodes }
        applyLatencyCache(Self.loadLatencyCache(path: latencyCachePath))
        otpGlobalHotKey = Self.loadGUISettings(path: guiSettingsPath).otpGlobalHotKey
        suppressNodeWrite = false
    }

    var otpHotKeyStatusText: String {
        switch otpHotKeyStatus {
        case .success:
            return "Global \(otpGlobalHotKey.displayName)"
        case .disabled:
            return "Global hotkey off"
        case .conflict:
            return "\(otpGlobalHotKey.displayName) 冲突，请换一个"
        case .failed:
            return "Global hotkey failed"
        }
    }

    func setOTPGlobalHotKey(_ option: OTPGlobalHotKeyOption) {
        otpGlobalHotKey = option
        saveGUISettings()
        onOTPHotKeyPreferenceChanged?(option)
    }

    func updateOTPHotKeyStatus(_ result: GlobalHotKeyRegisterResult) {
        otpHotKeyStatus = result
        switch result {
        case .success:
            // Don't clobber VPN status lines unless we just changed the binding.
            break
        case .disabled:
            break
        case .conflict:
            statusText = "\(otpGlobalHotKey.displayName) 已被占用，请在菜单更换快捷键"
            lastError = "全局快捷键 \(otpGlobalHotKey.displayName) 与其他 App 冲突，未启用。可在菜单栏 → OTP Hotkey 中更换。"
        case .failed(let code):
            lastError = "全局快捷键注册失败 (OSStatus \(code))"
        }
    }

    private func saveGUISettings() {
        Self.writeGUISettings(
            GUISettings(otpGlobalHotKey: otpGlobalHotKey),
            path: guiSettingsPath
        )
    }

    private struct GUISettings {
        var otpGlobalHotKey: OTPGlobalHotKeyOption
    }

    nonisolated private static func loadGUISettings(path: String) -> GUISettings {
        // Prefer file; fall back to UserDefaults for older installs.
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = obj["otp_global_hotkey"] as? String,
           let opt = OTPGlobalHotKeyOption(rawValue: raw) {
            return GUISettings(otpGlobalHotKey: opt)
        }
        if let raw = UserDefaults.standard.string(forKey: "otpGlobalHotKey"),
           let opt = OTPGlobalHotKeyOption(rawValue: raw) {
            return GUISettings(otpGlobalHotKey: opt)
        }
        return GUISettings(otpGlobalHotKey: .default)
    }

    nonisolated private static func writeGUISettings(_ settings: GUISettings, path: String) {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let obj: [String: Any] = [
            "otp_global_hotkey": settings.otpGlobalHotKey.rawValue,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        UserDefaults.standard.set(settings.otpGlobalHotKey.rawValue, forKey: "otpGlobalHotKey")
    }

    var nodePickerOptions: [String] {
        var opts = [NodeChoice.auto, NodeChoice.latency] + nodesSortedByLatency
        if selectedNode != NodeChoice.auto,
           selectedNode != NodeChoice.latency,
           !knownNodes.contains(selectedNode) {
            opts.append(selectedNode)
        }
        return opts
    }

    /// Known nodes sorted by RTT ascending (unknown / failed last).
    var nodesSortedByLatency: [String] {
        knownNodes.sorted { a, b in
            let la = nodeLatencies[a]
            let lb = nodeLatencies[b]
            switch (la, lb) {
            case let (x?, y?):
                if x != y { return x < y }
                return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a < b
            }
        }
    }

    var latencySummary: String {
        if isProbingLatency { return "measuring…" }
        guard let updated = latencyUpdatedAt else { return "no data" }
        let ok = nodeLatencies.count
        let fail = nodeLatencyFailed.count
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        let when = fmt.localizedString(for: updated, relativeTo: Date())
        if fail > 0 { return "\(ok) ok · \(fail) fail · \(when)" }
        return "\(ok) nodes · \(when)"
    }

    var isBusy: Bool { isStarting }

    func startMonitoring() {
        refreshStatus()
        refreshLog()
        refreshOTP()
        reloadLatencyCacheFromDisk()
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatus()
                self?.refreshLog()
                self?.reloadLatencyCacheFromDisk()
            }
        }
        otpTimer?.invalidate()
        otpTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickOTP()
            }
        }
    }

    /// Probe all VPN nodes via `corplink-rs nodes` (no admin; uses existing cookies).
    func refreshLatencies() {
        guard !isProbingLatency else { return }
        isProbingLatency = true
        lastError = nil
        statusText = "Measuring node latency…"
        let binary = binaryPath
        let config = configPath
        let cachePath = latencyCachePath
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.runNodesProbe(binary: binary, config: config)
            DispatchQueue.main.async {
                self.isProbingLatency = false
                if let message = result.error {
                    self.lastError = message
                    self.statusText = self.isConnected
                        ? (self.activeNode.map { "Connected · \($0)" } ?? "Connected")
                        : "Latency probe failed"
                    return
                }
                let entries = result.entries
                self.applyLatencyEntries(entries)
                // Prefer disk cache written by the binary (includes updated_at).
                self.applyLatencyCache(Self.loadLatencyCache(path: cachePath))
                let names = entries.map(\.name)
                let merged = Array(Set(self.knownNodes + names)).sorted()
                if merged != self.knownNodes {
                    self.knownNodes = merged
                    Self.saveNodeCache(merged, path: self.nodeCachePath)
                }
                self.statusText = self.isConnected
                    ? (self.activeNode.map { "Connected · \($0)" } ?? "Connected")
                    : "Latency updated · \(self.nodeLatencies.count) nodes"
            }
        }
    }

    func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
        otpTimer?.invalidate()
        otpTimer = nil
    }

    /// Copy current OTP to the pasteboard.
    /// - Parameter fromGlobalHotKey: when true, give audible feedback if OTP is missing
    ///   (useful when the window / menu is not visible).
    @discardableResult
    func copyOTP(fromGlobalHotKey: Bool = false) -> Bool {
        guard !otpCode.isEmpty else {
            if fromGlobalHotKey {
                NSSound.beep()
                statusText = "OTP unavailable"
            }
            return false
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(otpCode, forType: .string)
        statusText = fromGlobalHotKey
            ? "OTP copied (\(otpGlobalHotKey.displayName))"
            : "OTP copied"
        return true
    }

    func connect() {
        lastError = nil
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            lastError = "Binary missing. Run: cargo build --release\n\(binaryPath)"
            return
        }
        guard !isStarting else { return }

        applyRouteMode(routeMode)
        applyNodeSelection(selectedNode)
        isStarting = true
        statusText = "Waiting for admin password…"
        pendingSSOURL = nil
        awaitingConfirm = false
        lastSeenSSOURL = nil
        activeNode = nil

        let cmd = privilegedStartCommand()
        Task {
            do {
                let out = try await Self.runAdminShell(cmd)
                await MainActor.run {
                    self.isStarting = false
                    self.statusText = "Started — wait for SSO link in log"
                    if !out.isEmpty { self.logTail += "\n" + out }
                    self.refreshStatus()
                    self.refreshLog()
                }
            } catch {
                await MainActor.run {
                    self.isStarting = false
                    self.statusText = "Connect failed / cancelled"
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    func disconnect() {
        lastError = nil
        guard !isStarting else { return }
        isStarting = true
        statusText = "Waiting for admin password…"

        let cmd = privilegedStopCommand()
        Task {
            do {
                _ = try await Self.runAdminShell(cmd)
                await MainActor.run {
                    self.isStarting = false
                    self.isConnected = false
                    self.tunnelIP = nil
                    self.activeNode = nil
                    self.clearPendingApply()
                    self.statusText = "Disconnected"
                    self.pendingSSOURL = nil
                    self.awaitingConfirm = false
                    self.lastSeenSSOURL = nil
                }
            } catch {
                await MainActor.run {
                    self.isStarting = false
                    self.lastError = error.localizedDescription
                    self.statusText = "Disconnect failed / cancelled"
                }
            }
        }
    }

    /// Explicit reconnect with current node/mode selection (never auto-triggered by window picker).
    func applyNodeAndReconnect() {
        applyNodeSelection(selectedNode)
        applyRouteMode(routeMode, announce: false)
        guard isConnected || Self.launchdJobExists(label) else {
            clearPendingApply()
            statusText = "Saved. Click Connect when ready."
            return
        }
        guard !isStarting else { return }
        lastError = nil
        isStarting = true
        clearPendingApply()
        statusText = "Applying changes (admin password)…"
        pendingSSOURL = nil
        awaitingConfirm = false
        lastSeenSSOURL = nil

        let stop = privilegedStopCommand()
        let start = privilegedStartCommand()
        Task {
            do {
                _ = try await Self.runAdminShell(stop)
                try await Task.sleep(nanoseconds: 700_000_000)
                let out = try await Self.runAdminShell(start)
                await MainActor.run {
                    self.isStarting = false
                    self.statusText = "Reconnecting — wait for SSO if needed"
                    if !out.isEmpty { self.logTail += "\n" + out }
                }
            } catch {
                await MainActor.run {
                    self.isStarting = false
                    self.lastError = error.localizedDescription
                    self.statusText = "Apply failed / cancelled"
                    // Config is already written; keep prompting to retry.
                    self.markPendingApply(hint: "上次重连失败，可再点「Apply 重连」")
                }
            }
        }
    }

    func saveNodeSelectionOnly() {
        guard !suppressNodeWrite else { return }
        applyNodeSelection(selectedNode)
        announceConfigChange(kind: "节点", detail: displayName(for: selectedNode))
    }

    func applyCustomNode() {
        let name = customNode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if !knownNodes.contains(name) {
            knownNodes.append(name)
            knownNodes.sort()
            Self.saveNodeCache(knownNodes, path: nodeCachePath)
        }
        suppressNodeWrite = true
        selectedNode = name
        suppressNodeWrite = false
        applyNodeSelection(name)
        customNode = ""
        announceConfigChange(kind: "节点", detail: name)
    }

    func applyRouteMode(_ mode: RouteMode, announce: Bool = true) {
        do {
            try Self.setJSONString(in: configPath, key: "route_mode", value: mode.rawValue)
            if announce {
                let label = mode == .split ? "极速 (split)" : "全局 (full)"
                announceConfigChange(kind: "模式", detail: label)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Window pickers only write config; live tunnel needs an explicit reconnect.
    private func announceConfigChange(kind: String, detail: String) {
        if isConnected || Self.launchdJobExists(label) {
            markPendingApply(hint: "\(kind)已改为 \(detail)，需重连后才会生效")
            statusText = "已保存 · 点「Apply 重连」生效"
        } else {
            clearPendingApply()
            statusText = "\(kind)已保存 · 下次 Connect 生效"
        }
    }

    private func markPendingApply(hint: String) {
        pendingApply = true
        pendingApplyHint = hint
    }

    private func clearPendingApply() {
        pendingApply = false
        pendingApplyHint = ""
    }

    func applyNodeSelection(_ choice: String) {
        do {
            switch choice {
            case NodeChoice.auto:
                try Self.setJSONNull(in: configPath, key: "vpn_server_name")
                try Self.setJSONNull(in: configPath, key: "vpn_select_strategy")
            case NodeChoice.latency:
                try Self.setJSONNull(in: configPath, key: "vpn_server_name")
                try Self.setJSONString(in: configPath, key: "vpn_select_strategy", value: "latency")
            default:
                try Self.setJSONString(in: configPath, key: "vpn_server_name", value: choice)
                try Self.setJSONNull(in: configPath, key: "vpn_select_strategy")
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func openPendingSSO() {
        guard let url = pendingSSOURL, let u = URL(string: url) else { return }
        NSWorkspace.shared.open(u)
        statusText = "Browser opened — finish SSO, then click Confirm"
    }

    /// Signal corplink-rs that the user finished browser login.
    func confirmAuthDone() {
        let path = authGatePath
        do {
            try "ok\n".write(toFile: path, atomically: true, encoding: .utf8)
            awaitingConfirm = false
            statusText = "Confirm sent — waiting for tunnel…"
            lastError = nil
        } catch {
            lastError = "Failed to write auth gate: \(error.localizedDescription)"
        }
    }

    func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    func revealConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: configPath)])
    }

    func forceResetBusy() {
        isStarting = false
        statusText = isConnected ? "Connected" : (awaitingConfirm ? "Waiting for SSO confirm" : "Disconnected")
        lastError = "Busy state cleared"
    }

    /// Menu-bar mode switch: save config; reconnect if already connected.
    /// Menu-bar mode switch: save config; reconnect immediately if already connected.
    func selectModeFromMenu(_ mode: RouteMode) {
        suppressNodeWrite = true
        routeMode = mode
        suppressNodeWrite = false
        applyRouteMode(mode, announce: false)
        if isConnected {
            applyNodeAndReconnect()
        } else {
            statusText = "Mode set to \(mode == .split ? "极速" : "全局"). Click Connect when ready."
        }
    }

    /// Menu-bar node switch: save config; reconnect immediately if already connected.
    func selectNodeFromMenu(_ node: String) {
        suppressNodeWrite = true
        selectedNode = node
        suppressNodeWrite = false
        applyNodeSelection(node)
        if isConnected {
            applyNodeAndReconnect()
        } else {
            statusText = "Node set to \(displayName(for: node)). Click Connect when ready."
        }
    }

    func displayName(for choice: String) -> String {
        switch choice {
        case NodeChoice.auto: return "自动 (第一个可用)"
        case NodeChoice.latency: return "延迟最低 (latency)"
        default:
            if let ms = nodeLatencies[choice] {
                return "\(choice)  ·  \(ms)ms"
            }
            if nodeLatencyFailed.contains(choice) {
                return "\(choice)  ·  timeout"
            }
            return choice
        }
    }

    func latencyText(for choice: String) -> String? {
        switch choice {
        case NodeChoice.auto, NodeChoice.latency: return nil
        default:
            if let ms = nodeLatencies[choice] { return "\(ms)ms" }
            if nodeLatencyFailed.contains(choice) { return "—" }
            return nil
        }
    }

    private func privilegedStartCommand() -> String {
        [
            "export CORPLINK_BIN=\(shellEscape(binaryPath))",
            "export CORPLINK_CFG=\(shellEscape(configPath))",
            "export CORPLINK_LOG=\(shellEscape(logPath))",
            "export CORPLINK_LABEL=\(shellEscape(label))",
            "export CORPLINK_AUTH_GATE=\(shellEscape(authGatePath))",
            "export CORPLINK_RUN_SH=\(shellEscape(runScript))",
            "chmod +x \(shellEscape(startScript)) \(shellEscape(stopScript)) \(shellEscape(runScript))",
            shellEscape(startScript),
        ].joined(separator: " && ")
    }

    private func privilegedStopCommand() -> String {
        [
            "export CORPLINK_BIN=\(shellEscape(binaryPath))",
            "export CORPLINK_LABEL=\(shellEscape(label))",
            shellEscape(stopScript),
        ].joined(separator: " && ")
    }

    private func refreshStatus() {
        // Strict: only treat as connected when TUN has an IPv4 address.
        let ip = Self.interfaceIPv4(interfaceName)
        isConnected = (ip != nil)
        tunnelIP = ip
        if isConnected {
            // Do not clear isStarting here — reconnect may still be stopping the tunnel
            // while the old IP is briefly still present.
            if !isStarting {
                if pendingApply {
                    statusText = "已保存 · 点「Apply 重连」生效"
                } else if let activeNode, !activeNode.isEmpty {
                    statusText = "Connected · \(activeNode)"
                    awaitingConfirm = false
                    pendingSSOURL = nil
                } else {
                    statusText = "Connected"
                    awaitingConfirm = false
                    pendingSSOURL = nil
                }
            }
        } else if Self.launchdJobExists(label) {
            if !isStarting {
                statusText = "Connecting / authenticating…"
            }
        } else if !isStarting {
            if pendingApply { clearPendingApply() }
            if !statusText.contains("已保存") {
                statusText = "Disconnected"
            }
        }
    }

    private func refreshLog() {
        guard let data = try? String(contentsOfFile: logPath, encoding: .utf8) else { return }
        let lines = data.split(separator: "\n", omittingEmptySubsequences: false)
        let tail = lines.suffix(60).joined(separator: "\n")
        if tail != logTail { logTail = tail }

        if let nodes = Self.extractVPNList(from: data), !nodes.isEmpty {
            let merged = Array(Set(knownNodes + nodes)).sorted()
            if merged != knownNodes {
                knownNodes = merged
                Self.saveNodeCache(merged, path: nodeCachePath)
            }
        }
        if let fromLog = Self.extractLatencies(from: data), !fromLog.isEmpty {
            // Merge progressive connect-time probes into the in-memory map.
            for (name, ms) in fromLog {
                nodeLatencies[name] = ms
                nodeLatencyFailed.remove(name)
            }
            if latencyUpdatedAt == nil {
                latencyUpdatedAt = Date()
            }
        }
        if let connected = Self.extractConnectedNode(from: data) {
            activeNode = connected.isEmpty ? "(unnamed)" : connected
        }

        // Detect SSO URL once — never auto-open browser; wait for user Confirm.
        if let url = Self.extractSSOURL(from: data), url != lastSeenSSOURL {
            lastSeenSSOURL = url
            pendingSSOURL = url
            awaitingConfirm = true
            if !isConnected {
                statusText = "SSO ready — Open Login, then Confirm"
            }
        }

        if data.contains("CORPLINK_GUI: SSO auth confirmed") || isConnected {
            awaitingConfirm = false
            pendingSSOURL = nil
        }
    }

    private func tickOTP() {
        if otpExpiresIn > 0 {
            otpExpiresIn -= 1
        }
        if otpExpiresIn <= 0 || otpCode.isEmpty {
            refreshOTP()
        }
    }

    private func refreshOTP() {
        let binary = otpBinaryPath
        DispatchQueue.global(qos: .utility).async {
            let result = Self.fetchOTP(binary: binary)
            DispatchQueue.main.async {
                if let result {
                    self.otpCode = result.code
                    self.otpExpiresIn = max(result.expiresIn, 1)
                }
            }
        }
    }

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated private static func fetchOTP(binary: String) -> (code: String, expiresIn: Int)? {
        guard FileManager.default.isExecutableFile(atPath: binary) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--json"]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = obj["code"] as? String else { return nil }
            let expires = (obj["expires_in"] as? Int)
                ?? (obj["expires_in"] as? NSNumber)?.intValue
                ?? 30
            return (code, expires)
        } catch {
            return nil
        }
    }

    // MARK: - Privileged exec (Process + osascript, never NSAppleScript)

    /// Run a shell command with admin privileges via /usr/bin/osascript.
    /// Safe off the main actor; password dialog is owned by osascript.
    nonisolated private static func runAdminShell(_ command: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try runAdminShellSync(command)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func runAdminShellSync(_ command: String) throws -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            let msg = err.trimmingCharacters(in: .whitespacesAndNewlines)
            let friendly: String
            if msg.contains("User canceled") || msg.contains("-128") {
                friendly = "已取消管理员授权"
            } else {
                friendly = msg.isEmpty ? "osascript exit \(process.terminationStatus)" : msg
            }
            throw NSError(domain: "CorplinkGUI", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: friendly,
            ])
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func launchdJobExists(_ label: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(label)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    nonisolated private static func interfaceIPv4(_ name: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        task.arguments = [name]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            for line in out.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("inet "), !trimmed.contains("inet6") {
                    let parts = trimmed.split(separator: " ")
                    if parts.count >= 2 { return String(parts[1]) }
                }
            }
        } catch {}
        return nil
    }

    nonisolated private static func extractSSOURL(from log: String) -> String? {
        let pattern = #"https://sso\.bytedance\.com[^\s\"]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(log.startIndex..<log.endIndex, in: log)
        guard let match = regex.matches(in: log, range: range).last,
              let r = Range(match.range, in: log) else { return nil }
        return String(log[r])
    }

    nonisolated private static func extractVPNList(from log: String) -> [String]? {
        guard let range = log.range(of: "details: [", options: .backwards) else { return nil }
        let from = range.upperBound
        guard let end = log[from...].firstIndex(of: "]") else { return nil }
        let inner = log[from..<end]
        var names: [String] = []
        for part in inner.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !trimmed.isEmpty { names.append(trimmed) }
        }
        return names.isEmpty ? nil : names
    }

    nonisolated private static func extractConnectedNode(from log: String) -> String? {
        let pattern = #"try connect to ([^,]*), address "#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(log.startIndex..<log.endIndex, in: log)
        guard let match = regex.matches(in: log, range: range).last,
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: log) else { return nil }
        return String(log[r]).trimmingCharacters(in: .whitespaces)
    }

    /// Parse `server name CN-LF3, latency 45ms` lines from corplink-rs logs.
    nonisolated private static func extractLatencies(from log: String) -> [String: Int]? {
        let pattern = #"server name ([^,]+), latency (\d+)ms"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(log.startIndex..<log.endIndex, in: log)
        var map: [String: Int] = [:]
        for match in regex.matches(in: log, range: range) {
            guard match.numberOfRanges >= 3,
                  let nr = Range(match.range(at: 1), in: log),
                  let mr = Range(match.range(at: 2), in: log),
                  let ms = Int(log[mr]) else { continue }
            let name = String(log[nr]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { map[name] = ms }
        }
        return map.isEmpty ? nil : map
    }

    private func reloadLatencyCacheFromDisk() {
        guard let cache = Self.loadLatencyCache(path: latencyCachePath) else { return }
        // Only apply if newer or we have nothing yet.
        if let existing = latencyUpdatedAt,
           let disk = cache.updatedAt,
           disk <= existing {
            return
        }
        applyLatencyCache(cache)
    }

    private func applyLatencyCache(_ cache: LatencyCache?) {
        guard let cache else { return }
        applyLatencyEntries(cache.nodes)
        if let ts = cache.updatedAt {
            latencyUpdatedAt = ts
        } else if latencyUpdatedAt == nil {
            latencyUpdatedAt = Date()
        }
    }

    private func applyLatencyEntries(_ entries: [LatencyEntry]) {
        var ok: [String: Int] = [:]
        var failed: Set<String> = []
        for e in entries {
            if let ms = e.latencyMs {
                ok[e.name] = ms
            } else {
                failed.insert(e.name)
            }
        }
        nodeLatencies = ok
        nodeLatencyFailed = failed
        if latencyUpdatedAt == nil { latencyUpdatedAt = Date() }
    }

    nonisolated private static func runNodesProbe(
        binary: String,
        config: String
    ) -> (entries: [LatencyEntry], error: String?) {
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            return ([], "corplink-rs binary not found: \(binary)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["nodes", config]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                let snippet = errText
                    .split(separator: "\n")
                    .suffix(3)
                    .joined(separator: " · ")
                return ([], snippet.isEmpty
                    ? "nodes probe failed (exit \(process.terminationStatus))"
                    : snippet)
            }
            // Prefer array JSON; fall back to {nodes:[...]} wrapper.
            if let arr = try? JSONSerialization.jsonObject(with: outData) as? [[String: Any]] {
                return (arr.compactMap(LatencyEntry.init(dict:)), nil)
            }
            if let obj = try? JSONSerialization.jsonObject(with: outData) as? [String: Any],
               let arr = obj["nodes"] as? [[String: Any]] {
                return (arr.compactMap(LatencyEntry.init(dict:)), nil)
            }
            return ([], "could not parse latency JSON from nodes command")
        } catch {
            return ([], error.localizedDescription)
        }
    }

    private struct LatencyEntry {
        let name: String
        let latencyMs: Int?

        init(name: String, latencyMs: Int?) {
            self.name = name
            self.latencyMs = latencyMs
        }

        init?(dict: [String: Any]) {
            guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
            let ms = (dict["latency_ms"] as? Int)
                ?? (dict["latency_ms"] as? NSNumber)?.intValue
            self.name = name
            self.latencyMs = ms
        }
    }

    private struct LatencyCache {
        let updatedAt: Date?
        let nodes: [LatencyEntry]
    }

    nonisolated private static func loadLatencyCache(path: String) -> LatencyCache? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["nodes"] as? [[String: Any]] else { return nil }
        let nodes = arr.compactMap(LatencyEntry.init(dict:))
        let updated: Date?
        if let secs = (obj["updated_at"] as? Int) ?? (obj["updated_at"] as? NSNumber)?.intValue {
            updated = Date(timeIntervalSince1970: TimeInterval(secs))
        } else {
            updated = nil
        }
        return LatencyCache(updatedAt: updated, nodes: nodes)
    }

    nonisolated private static let seedNodes: [String] = [
        "CN-LF3", "CN-LF2", "CN-LF-SP", "CN-LF-TCP", "CN-HL-TCP",
        "CNHK-1", "CNHK-2", "CN-IT-BJ", "CN-IT-BJ2", "CN-IT-SZ",
        "CN-TZ", "CN-LIMIT", "CN-LIMIT2", "CNTW-1", "CNTW-2",
        "JP-1", "JP-2", "JP-3", "SG-2", "SG-3", "SG-4", "SG-5", "SG-6", "SG-7",
        "KR-1", "KR-2", "US-MAL-VA1", "US-MAL-VA2",
        "DE-2", "DE-3", "DE-4", "UK-1", "UK-2", "UK-3", "UK-4", "BR-1",
    ]

    nonisolated private static func readInterfaceName(from path: String) -> String? {
        (readJSONObject(path)?["interface_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    nonisolated private static func readRouteMode(from path: String) -> RouteMode? {
        if let mode = readJSONObject(path)?["route_mode"] as? String {
            return RouteMode(rawValue: mode)
        }
        return .split
    }

    nonisolated private static func readSelectedNode(from path: String) -> String {
        guard let obj = readJSONObject(path) else { return NodeChoice.auto }
        if let name = obj["vpn_server_name"] as? String, !name.isEmpty { return name }
        if let strategy = obj["vpn_select_strategy"] as? String, strategy == "latency" {
            return NodeChoice.latency
        }
        return NodeChoice.auto
    }

    nonisolated private static func readJSONObject(_ path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    nonisolated private static func setJSONString(in path: String, key: String, value: String) throws {
        try mutateJSON(path) { $0[key] = value }
    }

    nonisolated private static func setJSONNull(in path: String, key: String) throws {
        try mutateJSON(path) { $0[key] = NSNull() }
    }

    nonisolated private static func mutateJSON(_ path: String, _ body: (inout [String: Any]) -> Void) throws {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "CorplinkGUI", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Config is not a JSON object",
            ])
        }
        body(&obj)
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: url, options: .atomic)
    }

    nonisolated private static func loadNodeCache(path: String) -> [String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return arr.filter { !$0.isEmpty }.sorted()
    }

    nonisolated private static func saveNodeCache(_ nodes: [String], path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONSerialization.data(withJSONObject: nodes, options: [.prettyPrinted]) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
