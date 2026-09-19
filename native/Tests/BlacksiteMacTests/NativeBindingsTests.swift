import Foundation
import Testing
@testable import BlacksiteMac

struct NativeBindingsTests {
    @Test func defaultsPreserveAlternateMovementFireAimAndNormalizedModifiers() {
        let bindings = NativeBindings.defaults
        #expect(NativeInputAction.allCases.count == 19)
        #expect(bindings.inputs(for: .moveForward) == [.key(13),.key(126)])
        #expect(bindings.inputs(for: .moveBackward) == [.key(1),.key(125)])
        #expect(bindings.inputs(for: .fire) == [.mouse(0),.key(12)])
        #expect(bindings.inputs(for: .aim) == [.mouse(1),.key(6)])
        #expect(bindings.inputs(for: .prone) == [.key(8),.modifier(.control)])
        #expect(bindings.inputs(for: .sprint) == [.modifier(.shift)])
        #expect(bindings.inputs(for: .interact) == [.key(14)])
        #expect(bindings.inputs(for: .nextWeapon) == [.wheel(.up),.wheel(.down)])
        let inputs = NativeInputAction.allCases.flatMap { bindings.inputs(for: $0) }
        #expect(Set(inputs).count == inputs.count)
        #expect(NativeInputAction.allCases.allSatisfy { !bindings.inputs(for: $0).isEmpty && bindings.inputs(for: $0).count <= 2 })
    }

    @Test func conflictsLeaveBindingsUnchangedUntilExplicitAtomicSwap() {
        var bindings = NativeBindings.defaults
        let original = bindings
        let owner = NativeBindingConflict(action: .moveForward, slot: .primary)
        #expect(bindings.conflict(for: .key(13), action: .jump, slot: .primary) == owner)
        #expect(bindings.assign(.key(13), to: .jump, slot: .primary) == .conflict(owner))
        #expect(bindings == original)
        #expect(bindings.assign(.key(13), to: .jump, slot: .primary, swappingConflict: true) == .assigned)
        #expect(bindings.inputs(for: .jump) == [.key(13)])
        #expect(bindings.inputs(for: .moveForward) == [.key(49),.key(126)])
        #expect(bindings.assign(.key(13), to: .jump, slot: .primary) == .assigned)
        #expect(bindings.assign(nil, to: .jump, slot: .primary) == .assigned)
        #expect(bindings.inputs(for: .jump).isEmpty)
        #expect(bindings.assign(.key(13), to: .reload, slot: .secondary) == .assigned)
    }

    @Test func swapValidatesTheDisplacedBindingBeforeChangingEitherAction() {
        var bindings = NativeBindings.defaults
        let original = bindings
        // W could select a weapon, but swapping it would assign wheel-up to
        // forward movement. Reject the entire transaction, leaving both intact.
        #expect(bindings.assign(.key(13), to: .nextWeapon, slot: .primary, swappingConflict: true) == .rejected(.wheelRequiresDiscreteAction))
        #expect(bindings == original)
        // Swapping two alternatives of the same action is also well-defined.
        #expect(bindings.assign(.key(12), to: .fire, slot: .primary, swappingConflict: true) == .assigned)
        #expect(bindings.inputs(for: .fire) == [.key(12),.mouse(0)])
    }

    @Test func reservedUnsupportedAndImpulseInputsAreRejectedWithSpecificReasons() {
        var bindings = NativeBindings.defaults
        for code: UInt16 in [53,54,55,57,63,96] {
            #expect(bindings.assign(.key(code), to: .reload, slot: .primary) == .rejected(.reservedInput))
        }
        for code: UInt16 in [56,58,59,60,61,62,65535] {
            #expect(bindings.validationError(for: .key(code), action: .reload) == .unsupportedInput)
        }
        for number in [-1,5,100] { #expect(bindings.validationError(for: .mouse(number), action: .reload) == .unsupportedInput) }
        for action in [NativeInputAction.moveForward,.lookLeft,.interact,.aim,.sprint] {
            #expect(bindings.validationError(for: .wheel(.up), action: action) == .wheelRequiresDiscreteAction)
        }
        #expect(bindings.validationError(for: .wheel(.up), action: .fire) == nil)
        #expect(bindings.assign(.mouse(4), to: .reload, slot: .secondary) == .assigned)
        #expect(bindings.assign(.modifier(.option), to: .jump, slot: .secondary) == .assigned)
    }

    @Test func persistedBindingsRoundTripAndMissingActionsUseDefaults() throws {
        var bindings = NativeBindings.defaults
        bindings.assign(.key(17), to: .moveLeft, slot: .primary)
        bindings.assign(nil, to: .fire, slot: .secondary)
        bindings.assign(.mouse(4), to: .reload, slot: .secondary)
        let data = try JSONEncoder().encode(bindings)
        #expect(try JSONDecoder().decode(NativeBindings.self, from: data) == bindings)
        let missing = Data(#"{"version":1,"bindings":{}}"#.utf8)
        #expect(try JSONDecoder().decode(NativeBindings.self, from: missing) == .defaults)
    }

    @Test func malformedPersistenceCannotInstallConflictingOrReservedBindings() throws {
        let encoded = try JSONEncoder().encode(NativeBindings.defaults)
        var document = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var bindings = try #require(document["bindings"] as? [String: Any])
        let forward = try #require(bindings["moveForward"] as? [String: Any])
        var reload = try #require(bindings["reload"] as? [String: Any])
        reload["primary"] = forward["primary"]
        bindings["reload"] = reload; document["bindings"] = bindings
        let duplicate = try JSONSerialization.data(withJSONObject: document)
        #expect(throws: DecodingError.self) { _ = try JSONDecoder().decode(NativeBindings.self, from: duplicate) }
        reload["primary"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(NativeInputButton.key(53)))
        bindings["reload"] = reload; document["bindings"] = bindings
        let reserved = try JSONSerialization.data(withJSONObject: document)
        #expect(throws: DecodingError.self) { _ = try JSONDecoder().decode(NativeBindings.self, from: reserved) }
        document["version"] = 2
        let unknownVersion = try JSONSerialization.data(withJSONObject: document)
        #expect(throws: DecodingError.self) { _ = try JSONDecoder().decode(NativeBindings.self, from: unknownVersion) }
    }
}
