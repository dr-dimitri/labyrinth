import Testing
import Foundation
import BlacksiteCore
@testable import BlacksiteMac

@MainActor
struct NativeSmokePresentationTests {
    @Test func legacyKeyOwnerSurvivesMigrationAndRepeatedInputDoesNotDuplicateTheGadget() throws {
        var original = NativeBindings.defaults
        original.assign(nil, to: .smoke, slot: .primary)
        original.assign(.key(9), to: .reload, slot: .primary)
        var document = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var bindings = try #require(document["bindings"] as? [String: Any])
        bindings.removeValue(forKey: "smoke"); document["bindings"] = bindings
        let restored = try JSONDecoder().decode(NativeBindings.self, from: JSONSerialization.data(withJSONObject: document))
        #expect(restored.inputs(for: .reload) == [.key(9)] && restored.inputs(for: .smoke).isEmpty)
        #expect(restored.inputs(for: .grenade) == NativeBindings.defaults.inputs(for: .grenade))
        var input = NativeInputState()
        #expect(input.press(.key(9)) == [.smoke])
        #expect(input.press(.key(9)).isEmpty && input.press(.key(9), isRepeat: true).isEmpty)
        input.clear()
        #expect(input.press(.key(9), isRepeat: true).isEmpty)
        let game = CombatSimulation(world: [])
        let initial = game.smokeGrenadeCount
        #expect(game.throwSmokeGrenade())
        let shown = NativeSmokePresentation(simulation: game, bindings: restored)
        #expect(shown.stockText.contains("\(initial - 1)") && shown.stockText.contains(NativeControlLabels.unboundLabel))
        #expect(shown.accessibilityText.contains("Geworfen:") && game.grenadeCount == game.loadout.fragmentationGrenades)
    }
}
