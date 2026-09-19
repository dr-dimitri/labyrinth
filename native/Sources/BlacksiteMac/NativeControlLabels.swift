import AppKit
import Carbon
import BlacksiteCore

/// The persisted binding is a physical key. Its label follows the active macOS
/// keyboard layout, so a German Y/Z layout is described as it is actually used.
@MainActor
enum NativeControlLabels {
    nonisolated static let unboundLabel = "NICHT BELEGT"
    private static var layoutIdentifier = ""
    private static var keyLabels: [UInt16: String] = [:]

    static func label(for action: NativeInputAction, bindings: NativeBindings) -> String {
        let names = bindings.inputs(for: action).map { label(for: $0) }
        return names.isEmpty ? unboundLabel : names.joined(separator: " / ")
    }

    static func label(for button: NativeInputButton) -> String {
        switch button {
        case .mouse(let number): return "MAUS \(number + 1)"
        case .modifier(let modifier):
            switch modifier { case .shift: return "SHIFT"; case .control: return "STRG"; case .option: return "ALT" }
        case .wheel(let direction): return direction == .up ? "RAD ↑" : "RAD ↓"
        case .key(let code): return keyLabel(code)
        }
    }

    static func modeLabel(_ mode: NativeActionMode) -> String { mode == .hold ? "HALTEN" : "UMSCHALTEN" }

    static func help(settings: NativeSettings) -> String {
        func key(_ action: NativeInputAction) -> String { label(for: action, bindings: settings.bindings) }
        func mode(_ action: NativeInputAction, _ value: NativeActionMode) -> String {
            settings.bindings.inputs(for: action).isEmpty ? unboundLabel : "\(key(action)) · \(modeLabel(value))"
        }
        let interaction = settings.bindings.inputs(for: .interact).isEmpty ? "Interagieren in Einstellungen belegen" : "\(key(.interact)) · Auftrag oder Gerät: HALTEN; sonst an Kanten Klettern"
        return [
            "Bewegen: \(key(.moveForward)) vor · \(key(.moveBackward)) zurück · \(key(.moveLeft)) links · \(key(.moveRight)) rechts",
            "Umsehen: Maus oder \(key(.lookLeft)) / \(key(.lookRight)) / \(key(.lookUp)) / \(key(.lookDown))",
            "Sprinten: \(mode(.sprint, settings.sprintMode))     Springen: \(key(.jump))",
            "Hinlegen / Aufstehen: \(key(.prone))",
            "Interagieren: \(interaction)",
            "Schießen: \(key(.fire))",
            "Zielen / Zielfernrohr: \(mode(.aim, settings.aimMode))",
            "Sturmgewehr: \(key(.rifle))     Scharfschütze: \(key(.sniper))",
            "Waffe wechseln: \(key(.nextWeapon))",
            "Nachladen: \(key(.reload))     Granate: \(key(.grenade))",
            "Geräuschköder: \(key(.decoy)) · begrenzter Vorrat",
            "Rauchgranate: \(key(.smoke)) · 1,5 s Zündung · kein Explosionsschaden",
            "Glas: durchsichtig; erst nach Bruch durchschießbar und begehbar.",
            "ESC: Pause     F5: Leistungsanzeige"
        ].joined(separator: "\n")
    }

    static func actionName(_ action: NativeInputAction) -> String {
        switch action {
        case .moveForward: return "Vorwärts"
        case .moveBackward: return "Rückwärts"
        case .moveLeft: return "Nach links"
        case .moveRight: return "Nach rechts"
        case .lookLeft: return "Blick nach links"
        case .lookRight: return "Blick nach rechts"
        case .lookUp: return "Blick nach oben"
        case .lookDown: return "Blick nach unten"
        case .sprint: return "Sprinten"
        case .fire: return "Schießen"
        case .aim: return "Zielen / Zielfernrohr"
        case .jump: return "Springen"
        case .prone: return "Hinlegen / Aufstehen"
        case .interact: return "Interagieren / Klettern"
        case .grenade: return "Granate"
        case .decoy: return "Geräuschköder"
        case .smoke: return "Rauchgranate"
        case .reload: return "Nachladen"
        case .rifle: return "Sturmgewehr"
        case .sniper: return "Scharfschützengewehr"
        case .nextWeapon: return "Waffe wechseln"
        }
    }

    private static func keyLabel(_ code: UInt16) -> String {
        let special: [UInt16: String] = [36: "ENTER", 48: "TAB", 49: "LEER", 51: "⌫", 53: "ESC",
            71: "CLEAR", 76: "NUM ENTER", 115: "POS 1", 116: "BILD ↑", 117: "ENTF", 119: "ENDE",
            121: "BILD ↓", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
            100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13",
            107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"]
        if let name = special[code] { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return "TASTE \(code)" }
        let identifier: String
        if let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            identifier = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        } else { identifier = "" }
        if identifier != layoutIdentifier { layoutIdentifier = identifier; keyLabels.removeAll(keepingCapacity: true) }
        if let cached = keyLabels[code] { return cached }
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "TASTE \(code)" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return "TASTE \(code)" }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKey: UInt32 = 0, length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKey, characters.count, &length, &characters)
        let translated = status == noErr ? String(utf16CodeUnits: characters, count: length).uppercased() : ""
        let name = translated.isEmpty || translated.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            ? "TASTE \(code)" : translated
        keyLabels[code] = name
        return name
    }
}

/// Only the modifier which generated flagsChanged is updated. This avoids
/// resurrecting another modifier held through a pause when a fresh key changes.
enum NativeModifierInput {
    static func change(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> (NativeInputButton, Bool)? {
        switch keyCode {
        case 56, 60: return (.modifier(.shift), flags.contains(.shift))
        case 59, 62: return (.modifier(.control), flags.contains(.control))
        case 58, 61: return (.modifier(.option), flags.contains(.option))
        default: return nil
        }
    }
}

/// Aggregate left/right modifiers have one binding. Synchronization remembers
/// keys held across reset without pressing them; they must go neutral first.
struct NativeModifierBridge {
    private var held = Set<NativeInputModifier>()
    mutating func synchronize(flags: NSEvent.ModifierFlags) {
        held.removeAll(keepingCapacity: true)
        if flags.contains(.shift) { held.insert(.shift) }
        if flags.contains(.control) { held.insert(.control) }
        if flags.contains(.option) { held.insert(.option) }
    }
    mutating func change(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> (NativeInputButton, Bool)? {
        guard let (button, down) = NativeModifierInput.change(keyCode: keyCode, flags: flags), case .modifier(let modifier) = button else { return nil }
        let wasDown = held.contains(modifier)
        if down { held.insert(modifier) } else { held.remove(modifier) }
        return wasDown == down ? nil : (button, down)
    }
}
