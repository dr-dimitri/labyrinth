import Foundation
import Testing
import BlacksiteCore
@testable import BlacksiteMac

@Suite(.serialized)
@MainActor
struct NativeOperationCheckTests {
    @Test func blacksiteObjectiveUsesRealHeldInteractionAndLeavesPreparationOptional() throws {
        let loadout = LoadoutDefinition(camouflage: .vegetation)
        let before = try NativeOperationCheck.makeScenario(scene: "operation-preparation", loadout: loadout)
        let after = try NativeOperationCheck.makeScenario(scene: "operation-exits", loadout: loadout)
        #expect(before.simulation.map.id == MapDefinition.blacksite.id)
        #expect(before.simulation.missionStatus.phase == .prepareOperation)
        #expect(after.simulation.missionStatus.phase == .extract)
        #expect(after.simulation.operationStatus?.extractions.allSatisfy { $0.unlocked } == true)
        #expect(after.metadata["deviceActivations"] as? Int == 0)
        #expect(after.simulation.loadout == loadout)
        #expect(JSONSerialization.isValidJSONObject(after.metadata))
    }

    @Test func walkingBetweenDiagnosticExitsResetsProgressAndCompletesOnlyTheSelectedExit() throws {
        let result = try NativeOperationCheck.makeScenario(scene: "operation-route")
        try result.simulation.map.validateGameplay()
        #expect(result.metadata["progressAfterLeaving"] as? Float == 0)
        #expect(result.metadata["walkedDistance"] as? Float ?? 0 > 15)
        #expect(result.simulation.operationStatus?.selectedExtractionID == "service")
        try complete(result)
    }

    @Test func physicallyBlockedAlternativeLeavesAWorkingFallbackWithoutMovingActorsBetweenPhases() throws {
        let result = try NativeOperationCheck.makeScenario(scene: "operation-route", blockedService: true)
        let blocked = try #require(result.simulation.operationStatus?.extractions.first { $0.id == "service" })
        #expect(blocked.blocked && blocked.progress == 0)
        #expect(result.simulation.operationStatus?.activeExtractionID == "north")
        #expect(result.metadata["progressAfterLeaving"] as? Float == 0)
        #expect(JSONSerialization.isValidJSONObject(result.metadata))
        try complete(result)
    }

    private func complete(_ result: NativeOperationCheck.Result) throws {
        let game = result.simulation
        var input = GameInput(); input.yaw = game.player.yaw; input.pitch = game.player.pitch
        var events: [GameEvent] = []
        for _ in 0..<400 {
            game.step(deltaTime: 1.0 / 120, input: input)
            events.append(contentsOf: game.drainEvents())
        }
        #expect(game.state == .won)
        #expect(events.filter { $0.kind == .win }.count == 1)
        #expect(events.filter { $0.missionPhase == .completed }.count == 1)
    }
}
