import Foundation

enum NativeInputAction: String, CaseIterable, Codable, Hashable, Sendable {
    case moveForward, moveBackward, moveLeft, moveRight
    case lookLeft, lookRight, lookUp, lookDown
    case sprint, fire, aim, jump, prone, interact, grenade, reload, rifle, sniper, nextWeapon

    var allowsWheel: Bool {
        switch self {
        case .fire, .jump, .prone, .grenade, .reload, .rifle, .sniper, .nextWeapon: return true
        default: return false
        }
    }
}

enum NativeInputModifier: String, CaseIterable, Codable, Hashable, Sendable { case shift, control, option }
enum NativeWheelDirection: String, Codable, Hashable, Sendable { case up, down }
enum NativeBindingSlot: String, CaseIterable, Codable, Hashable, Sendable { case primary, secondary }
enum NativeActionMode: String, CaseIterable, Codable, Hashable, Sendable { case hold, toggle }

/// Modifier inputs represent both physical sides together. AppKit's aggregate
/// modifier flags supply their transitions; raw modifier key codes are rejected.
enum NativeInputButton: Codable, Hashable, Sendable {
    case key(UInt16)
    case mouse(Int)
    case modifier(NativeInputModifier)
    case wheel(NativeWheelDirection)
}

struct NativeBindingConflict: Equatable, Sendable {
    let action: NativeInputAction
    let slot: NativeBindingSlot
}

enum NativeBindingError: Equatable, Sendable {
    case reservedInput, unsupportedInput, wheelRequiresDiscreteAction
}

enum NativeBindingAssignmentResult: Equatable, Sendable {
    case assigned
    case conflict(NativeBindingConflict)
    case rejected(NativeBindingError)
}

/// Exactly two optional bindings per action. Every bound input has one owner;
/// a conflicting assignment either fails unchanged or swaps explicitly.
struct NativeBindings: Codable, Equatable, Sendable {
    private struct Pair: Codable, Equatable, Sendable {
        var primary: NativeInputButton?
        var secondary: NativeInputButton?
    }
    private var storage: [NativeInputAction: Pair]
    static let defaults = NativeBindings()

    init() {
        storage = [
            .moveForward: Pair(primary: .key(13), secondary: .key(126)),
            .moveBackward: Pair(primary: .key(1), secondary: .key(125)),
            .moveLeft: Pair(primary: .key(0)), .moveRight: Pair(primary: .key(2)),
            .lookLeft: Pair(primary: .key(123)), .lookRight: Pair(primary: .key(124)),
            .lookUp: Pair(primary: .key(116)), .lookDown: Pair(primary: .key(121)),
            .sprint: Pair(primary: .modifier(.shift)),
            .fire: Pair(primary: .mouse(0), secondary: .key(12)),
            .aim: Pair(primary: .mouse(1), secondary: .key(6)),
            .jump: Pair(primary: .key(49)),
            .prone: Pair(primary: .key(8), secondary: .modifier(.control)),
            .interact: Pair(primary: .key(14)),
            .grenade: Pair(primary: .key(5)), .reload: Pair(primary: .key(15)),
            .rifle: Pair(primary: .key(18)), .sniper: Pair(primary: .key(19)),
            .nextWeapon: Pair(primary: .wheel(.up), secondary: .wheel(.down))
        ]
    }

    func button(for action: NativeInputAction, slot: NativeBindingSlot) -> NativeInputButton? {
        slot == .primary ? storage[action]?.primary : storage[action]?.secondary
    }

    func inputs(for action: NativeInputAction) -> [NativeInputButton] {
        [button(for: action, slot: .primary), button(for: action, slot: .secondary)].compactMap { $0 }
    }

    func validationError(for button: NativeInputButton, action: NativeInputAction) -> NativeBindingError? {
        switch button {
        case .key(let code):
            // Escape/F5 and macOS-only modifiers/media keys belong to the app
            // or operating system. The remaining set is normal keyboard input.
            if Self.reservedKeys.contains(code) { return .reservedInput }
            if !Self.supportedKeys.contains(code) { return .unsupportedInput }
        case .mouse(let number):
            if !(0...4).contains(number) { return .unsupportedInput }
        case .modifier:
            break
        case .wheel:
            if !action.allowsWheel { return .wheelRequiresDiscreteAction }
        }
        return nil
    }

    func conflict(for button: NativeInputButton, action: NativeInputAction, slot: NativeBindingSlot) -> NativeBindingConflict? {
        guard let owner = owner(of: button), owner.action != action || owner.slot != slot else { return nil }
        return owner
    }

    @discardableResult mutating func assign(_ button: NativeInputButton?, to action: NativeInputAction,
                                           slot: NativeBindingSlot, swappingConflict: Bool = false) -> NativeBindingAssignmentResult {
        if let button, let error = validationError(for: button, action: action) { return .rejected(error) }
        var candidate = self
        if let button, let previousOwner = conflict(for: button, action: action, slot: slot) {
            guard swappingConflict else { return .conflict(previousOwner) }
            let displaced = self.button(for: action, slot: slot)
            if let displaced, let error = validationError(for: displaced, action: previousOwner.action) {
                return .rejected(error)
            }
            candidate.set(displaced, for: previousOwner.action, slot: previousOwner.slot)
        }
        candidate.set(button, for: action, slot: slot)
        self = candidate
        return .assigned
    }

    func owner(of button: NativeInputButton) -> NativeBindingConflict? {
        for action in NativeInputAction.allCases {
            for slot in NativeBindingSlot.allCases where self.button(for: action, slot: slot) == button {
                return NativeBindingConflict(action: action, slot: slot)
            }
        }
        return nil
    }

    private mutating func set(_ button: NativeInputButton?, for action: NativeInputAction, slot: NativeBindingSlot) {
        var pair = storage[action] ?? Pair()
        if slot == .primary { pair.primary = button } else { pair.secondary = button }
        storage[action] = pair
    }

    private static let reservedKeys: Set<UInt16> = [53,54,55,57,63,72,73,74,96]
    private static let supportedKeys = Set<UInt16>(Array(0...51) + [
        64,65,67,69,71,75,76,78,79,80,81,82,83,84,85,86,87,88,89,90,91,92,93,94,95,
        97,98,99,100,101,102,103,104,105,106,107,109,111,113,114,115,116,117,118,119,
        120,121,122,123,124,125,126
    ])

    private enum CodingKeys: String, CodingKey { case version, bindings }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "Unsupported binding version")
        }
        let decoded = try container.decode([String: Pair].self, forKey: .bindings)
        var candidate = Self.defaults
        for action in NativeInputAction.allCases {
            if let pair = decoded[action.rawValue] { candidate.storage[action] = pair }
        }
        var used = Set<NativeInputButton>()
        for action in NativeInputAction.allCases {
            for button in candidate.inputs(for: action) {
                guard candidate.validationError(for: button, action: action) == nil, used.insert(button).inserted else {
                    throw DecodingError.dataCorruptedError(forKey: .bindings, in: container,
                                                          debugDescription: "Unsupported, reserved, or duplicate binding")
                }
            }
        }
        self = candidate
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .version)
        let entries = Dictionary(uniqueKeysWithValues: NativeInputAction.allCases.map { ($0.rawValue, storage[$0] ?? Pair()) })
        try container.encode(entries, forKey: .bindings)
    }
}
