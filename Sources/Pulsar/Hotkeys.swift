import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon's RegisterEventHotKey.
///
/// Deliberately *not* a CGEventTap: an event tap runs on every keystroke system-wide and is the
/// usual reason a window manager costs CPU while idle. Carbon hotkeys are registered with the
/// WindowServer and only wake us when one of ours actually fires.
final class Hotkeys {
    static let shared = Hotkeys()

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    static let signature: OSType = 0x4145_524C // 'AERL'

    private init() {}

    func register(_ key: Key, modifiers: UInt32, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        actions[id] = action
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Hotkeys.signature, id: id)
        let status = RegisterEventHotKey(UInt32(key.code), modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs.append(ref) }
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            let err = GetEventParameter(event,
                                        EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID),
                                        nil,
                                        MemoryLayout<EventHotKeyID>.size,
                                        nil,
                                        &hkID)
            guard err == noErr else { return OSStatus(eventNotHandledErr) }
            Hotkeys.shared.fire(hkID.id)
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Virtual key codes, spelled once so the binding table reads like the config file it replaces.
struct Key {
    let code: Int

    static func letter(_ c: Character) -> Key? {
        guard let code = Self.letters[c] else { return nil }
        return Key(code: code)
    }

    static func digit(_ n: Int) -> Key? {
        guard n >= 1, n <= 9 else { return nil }
        return Key(code: Self.digits[n]!)
    }

    static let minus = Key(code: kVK_ANSI_Minus)
    static let equal = Key(code: kVK_ANSI_Equal)
    static let slash = Key(code: kVK_ANSI_Slash)

    private static let letters: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
        "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
        "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
        "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
    ]

    private static let digits: [Int: Int] = [
        1: kVK_ANSI_1, 2: kVK_ANSI_2, 3: kVK_ANSI_3, 4: kVK_ANSI_4, 5: kVK_ANSI_5,
        6: kVK_ANSI_6, 7: kVK_ANSI_7, 8: kVK_ANSI_8, 9: kVK_ANSI_9,
    ]
}

enum Mod {
    static let option = UInt32(optionKey)
    static let optionShift = UInt32(optionKey | shiftKey)
}
