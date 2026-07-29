import AppKit
import Carbon
import Foundation

/// Result of attempting to register a Carbon global hotkey.
enum GlobalHotKeyRegisterResult: Equatable {
    case success
    case disabled
    case conflict
    case failed(OSStatus)

    var isActive: Bool {
        if case .success = self { return true }
        return false
    }
}

/// User-configurable OTP global hotkey presets (stored in gui_settings.json).
enum OTPGlobalHotKeyOption: String, CaseIterable, Identifiable {
    case disabled = "off"
    case ctrlCmdO = "ctrl+cmd+o"
    case ctrlCmdC = "ctrl+cmd+c"
    case optionCmdO = "option+cmd+o"
    case ctrlOptionCmdO = "ctrl+option+cmd+o"

    var id: String { rawValue }

    static let `default`: OTPGlobalHotKeyOption = .ctrlCmdO

    var displayName: String {
        switch self {
        case .disabled: return "Off"
        case .ctrlCmdO: return "⌃⌘O"
        case .ctrlCmdC: return "⌃⌘C"
        case .optionCmdO: return "⌥⌘O"
        case .ctrlOptionCmdO: return "⌃⌥⌘O"
        }
    }

    var menuLabel: String {
        switch self {
        case .disabled: return "Disabled"
        default: return "\(displayName)"
        }
    }

    var keyCode: UInt32? {
        switch self {
        case .disabled: return nil
        case .ctrlCmdO, .optionCmdO, .ctrlOptionCmdO: return UInt32(kVK_ANSI_O)
        case .ctrlCmdC: return UInt32(kVK_ANSI_C)
        }
    }

    var carbonModifiers: UInt32? {
        switch self {
        case .disabled: return nil
        case .ctrlCmdO: return UInt32(controlKey | cmdKey)
        case .ctrlCmdC: return UInt32(controlKey | cmdKey)
        case .optionCmdO: return UInt32(optionKey | cmdKey)
        case .ctrlOptionCmdO: return UInt32(controlKey | optionKey | cmdKey)
        }
    }
}

/// System-wide hotkey via Carbon `RegisterEventHotKey`.
final class GlobalHotKey {
    /// Carbon: hotkey already taken by another registrant.
    static let eventHotKeyExistsErr: OSStatus = -9878

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = OSType(bitPattern: 0x4352_4F54) // 'CROT'
    private let hotKeyID: UInt32 = 1

    var onPressed: (() -> Void)?

    deinit {
        unregister()
    }

    @discardableResult
    func register(option: OTPGlobalHotKeyOption) -> GlobalHotKeyRegisterResult {
        unregister()

        guard let keyCode = option.keyCode, let modifiers = option.carbonModifiers else {
            return .disabled
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData else { return noErr }
                let box = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                var hkID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                if err == noErr, hkID.id == box.hotKeyID {
                    DispatchQueue.main.async { box.onPressed?() }
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard status == noErr else {
            NSLog("GlobalHotKey: InstallEventHandler failed: \(status)")
            return .failed(status)
        }

        let hkID = EventHotKeyID(signature: signature, id: hotKeyID)
        let reg = RegisterEventHotKey(
            keyCode,
            modifiers,
            hkID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard reg == noErr else {
            unregister()
            if reg == Self.eventHotKeyExistsErr {
                NSLog("GlobalHotKey: \(option.displayName) already in use (conflict)")
                return .conflict
            }
            NSLog("GlobalHotKey: RegisterEventHotKey failed: \(reg)")
            return .failed(reg)
        }
        return .success
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}
