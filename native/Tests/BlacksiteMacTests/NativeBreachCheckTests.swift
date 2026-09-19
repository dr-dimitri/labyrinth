import Foundation
import Testing
import BlacksiteCore
@testable import BlacksiteMac

@MainActor
@Suite(.serialized)
struct NativeBreachCheckTests {
    @Test func standardGlassStopsItsOpeningHitsAndOnlyTheNextShotHitsTheCrate() throws {
        let intact = try NativeBreachCheck.makeScenario(scene: "breach-intact")
        #expect(intact.simulation.breaches.first?.damageStage == .intact)
        #expect(intact.events.allSatisfy { $0.kind != .shot && $0.kind != .breachOpened })
        let damaged = try NativeBreachCheck.makeScenario(scene: "breach-damaged")
        #expect(damaged.simulation.breaches.first?.damageStage == .damaged)
        #expect(damaged.simulation.obstacles.first { $0.id == NativeBreachCheck.ownerID }?.health == 17)
        #expect(damaged.metadata["acceptedShots"] as? Int == 1)
        #expect(damaged.metadata["targetHealthBefore"] as? Float == damaged.metadata["targetHealthAfter"] as? Float)
        let open = try NativeBreachCheck.makeScenario(scene: "breach-open")
        #expect(open.events.filter { $0.kind == .shot }.map { $0.surfaceImpact?.obstacleID } ==
            [NativeBreachCheck.ownerID, NativeBreachCheck.ownerID, NativeBreachCheck.targetID])
        #expect(open.events.filter { $0.kind == .breachOpened }.count == 1)
        #expect(open.metadata["acceptedShots"] as? Int == 3)
        #expect(JSONSerialization.isValidJSONObject(open.metadata))
    }

    @Test func panelStagesAndRealCrossingRetainFrameButNeverCreateAnInvisibleBlocker() throws {
        let damaged = try NativeBreachCheck.makeScenario(scene: "breach-damaged", kind: .lightPanel)
        #expect(damaged.simulation.breaches.first?.damageStage == .damaged)
        let open = try NativeBreachCheck.makeScenario(scene: "breach-open", kind: .lightPanel, walkThrough: true)
        #expect(open.simulation.player.position.z <= -3)
        #expect(open.metadata["walkedDistance"] as? Float ?? 0 > 9)
        #expect(open.metadata["retainedFrames"] as? Int == 3)
        #expect(open.simulation.player.health == 100)
        #expect(open.simulation.coverDebris.first { $0.sourceObstacleID == NativeBreachCheck.ownerID }?.solidObstacleID == nil)
        #expect(open.events.filter { $0.kind == .breachOpened }.count == 1)
        #expect(JSONSerialization.isValidJSONObject(open.metadata))
    }

    @Test func glassCrossingMakesMaterialFootstepsWithoutDamageAndFreshFixtureIsClosed() throws {
        let crossed = try NativeBreachCheck.makeScenario(scene: "breach-open", walkThrough: true)
        #expect(crossed.metadata["glassFootsteps"] as? Int ?? 0 > 0)
        #expect(crossed.simulation.player.health == 100 && crossed.simulation.player.position.z <= -3)
        let fresh = try NativeBreachCheck.makeScenario(scene: "breach-intact")
        #expect(fresh.simulation.coverDebris.isEmpty && fresh.simulation.breaches.first?.openedAt == nil)
        #expect(fresh.simulation.weapons[.rifle]?.ammo == WeaponKind.rifle.capacity)
        #expect(fresh.simulation.obstacles.first { $0.id == NativeBreachCheck.ownerID }?.health == 45)
    }
}
