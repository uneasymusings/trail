import Carbon.HIToolbox
import SwiftUI

/// A system-wide shortcut via the Carbon hot-key API — no Accessibility permission needed.
final class HotKey {
    private var reference: EventHotKeyRef?
    private var handlerReference: EventHandlerRef?
    private let action: () -> Void

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType,
                            Unmanaged.passUnretained(self).toOpaque(), &handlerReference)
        let id = EventHotKeyID(signature: OSType(0x5452_4C31), id: 1) // "TRL1"
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &reference)
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handlerReference { RemoveEventHandler(handlerReference) }
    }
}

/// The shortcuts offered in Settings.
enum HotKeyChoice: String, CaseIterable, Identifiable {
    case optionSpace, controlOptionSpace, commandShiftSpace, optionT

    var id: String { rawValue }

    var label: String {
        switch self {
        case .optionSpace: "⌥ Space"
        case .controlOptionSpace: "⌃⌥ Space"
        case .commandShiftSpace: "⇧⌘ Space"
        case .optionT: "⌥ T"
        }
    }

    var keyCode: UInt32 {
        self == .optionT ? UInt32(kVK_ANSI_T) : UInt32(kVK_Space)
    }

    var carbonModifiers: UInt32 {
        switch self {
        case .optionSpace, .optionT: UInt32(optionKey)
        case .controlOptionSpace: UInt32(controlKey | optionKey)
        case .commandShiftSpace: UInt32(cmdKey | shiftKey)
        }
    }

    var menuKey: KeyEquivalent { self == .optionT ? "t" : .space }

    var menuModifiers: SwiftUI.EventModifiers {
        switch self {
        case .optionSpace, .optionT: .option
        case .controlOptionSpace: [.control, .option]
        case .commandShiftSpace: [.command, .shift]
        }
    }
}
