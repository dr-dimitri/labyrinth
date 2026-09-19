import Foundation
import Testing
import simd
import BlacksiteCore
@testable import BlacksiteMac

@Suite(.serialized)
@MainActor
struct NativeClassCheckTests {
    @Test func realReconObservationIsFrozenAndWalkingBehindSolidCoverHidesIt() throws {
        let kit = LoadoutDefinition(operatorClass: .recon, camouflage: .vegetation)
        let observed = try NativeClassCheck.makeScenario(scene: "class-recon", loadout: kit)
        let original = try #require(observed.events.first { $0.kind == .reconMarked }?.mark)
        #expect(observed.simulation.reconMarks == [original])
        #expect(observed.metadata["invalidPlacementOrAimRejected"] as? Bool == true)
        #expect(observed.metadata["duplicateAttemptRejected"] as? Bool == true)
        #expect(observed.simulation.visibleReconMarks.count == 1)
        let target = try #require(observed.simulation.enemies.first)
        #expect(simd_distance(target.position, SIMD3(0, 0, -6)) > 0.2)
        let hidden = try NativeClassCheck.makeScenario(scene: "class-recon", hideMark: true, loadout: kit)
        #expect(hidden.simulation.reconMarks.count == 1 && hidden.simulation.visibleReconMarks.isEmpty)
        #expect(hidden.simulation.player.position.x <= -6 && (hidden.metadata["walkedDistance"] as? Float ?? 0) >= 6)
        #expect(JSONSerialization.isValidJSONObject(hidden.metadata))
    }

    @Test func engineerPlacesOnePhysicalChargeAndItsRealExplosionRetainsSelfDamage() throws {
        let kit = LoadoutDefinition(operatorClass: .engineer, camouflage: .mineral)
        let attached = try NativeClassCheck.makeScenario(scene: "class-charge", loadout: kit)
        let charge = try #require(attached.simulation.breachCharges.first)
        #expect(charge.ownerObstacleID == NativeClassCheck.paneID && charge.attached && charge.fuse > 1.9)
        #expect(attached.simulation.breachChargeCount == 0 && attached.simulation.player.health == 100)
        #expect(attached.metadata["invalidPlacementOrAimRejected"] as? Bool == true)
        #expect(attached.metadata["duplicateAttemptRejected"] as? Bool == true)
        let escaped = try NativeClassCheck.makeScenario(scene: "class-charge", seconds: 3.2, retreat: true, loadout: kit)
        #expect(escaped.simulation.player.position.z >= 6 && (escaped.metadata["walkedDistance"] as? Float ?? 0) > 4.5)
        #expect(escaped.simulation.breachCharges.isEmpty && escaped.simulation.breaches.first?.isOpen == true)
        #expect(escaped.events.filter { $0.kind == .breachChargeDetonated }.count == 1)
        #expect(escaped.events.filter { $0.kind == .explosion }.count == 1)
        #expect(escaped.simulation.player.health > 0 && escaped.simulation.player.health < 100)
        let stayed = try NativeClassCheck.makeScenario(scene: "class-charge", seconds: 3.2, loadout: kit)
        #expect(stayed.simulation.state == .lost && stayed.simulation.player.health == 0)
        #expect(stayed.events.filter { $0.kind == .breachChargeDetonated }.count == 1)
        #expect(JSONSerialization.isValidJSONObject(escaped.metadata))
    }

    @Test func assaultActionUsesExistingSmokeAndMismatchedFixturesRejectWithoutChangingKits() throws {
        let kit = LoadoutDefinition(operatorClass: .assault, camouflage: .mineral)
        let result = try NativeClassCheck.makeScenario(scene: "class-smoke", loadout: kit)
        #expect(result.simulation.loadout == kit && result.simulation.smokeGrenadeCount == 1)
        #expect(result.simulation.smokeVolumes.count == 1 && result.simulation.smokeGrenades.isEmpty)
        #expect(result.simulation.player.health == 100 && result.simulation.grenadeCount == kit.fragmentationGrenades)
        #expect(!result.events.contains { $0.kind == .explosion || $0.kind == .damage })
        #expect(result.events.filter { $0.kind == .throwSmoke }.count == 1)
        #expect(JSONSerialization.isValidJSONObject(result.metadata))
        #expect(throws: (any Error).self) { try NativeClassCheck.makeScenario(scene: "class-recon", loadout: kit) }
        #expect(throws: (any Error).self) { try NativeClassCheck.makeScenario(scene: "class-charge", loadout: kit) }
    }
}
