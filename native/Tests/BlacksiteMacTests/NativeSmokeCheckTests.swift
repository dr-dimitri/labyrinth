import Foundation
import Testing
import BlacksiteCore
@testable import BlacksiteMac

@MainActor
@Suite(.serialized)
struct NativeSmokeCheckTests {
    @Test func realEmitterLifecycleAndClearAlternativeViewsUseActualOpticalSamples() throws {
        let growing = try NativeSmokeCheck.makeScenario(scene: "smoke-through", seconds: 0.2)
        let dense = try NativeSmokeCheck.makeScenario(scene: "smoke-through")
        let expired = try NativeSmokeCheck.makeScenario(scene: "smoke-through", seconds: 11)
        #expect(growing.metadata["opticalDepthToProbe"] as? Float ?? 0 < dense.metadata["opticalDepthToProbe"] as? Float ?? 0)
        #expect(dense.metadata["opaqueToProbe"] as? Bool == true)
        #expect(expired.simulation.smokeVolumes.isEmpty)
        #expect(expired.metadata["expiredSmokeEvents"] as? Int == 1)
        let above = try NativeSmokeCheck.makeScenario(scene: "smoke-through", above: true)
        let edge = try NativeSmokeCheck.makeScenario(scene: "smoke-edge")
        #expect(above.metadata["opticalDepthToProbe"] as? Float == 0)
        #expect(edge.metadata["opticalDepthToProbe"] as? Float == 0)
        let inside = try NativeSmokeCheck.makeScenario(scene: "smoke-inside", aiming: true)
        #expect(inside.metadata["cameraDensity"] as? Float ?? 0 > 0)
        #expect(inside.simulation.activeWeapon == .sniper && inside.simulation.isAiming)
        #expect(JSONSerialization.isValidJSONObject(inside.metadata))
    }

    @Test func realManualGateRouteChangesTheSameEmitterClippingWithoutTeleport() throws {
        let closed = try NativeSmokeCheck.makeScenario(scene: "smoke-wall")
        let open = try NativeSmokeCheck.makeScenario(scene: "smoke-wall", gateOpen: true)
        #expect(closed.metadata["densityBehindWall"] as? Float == 0)
        #expect(open.metadata["densityBehindWall"] as? Float ?? 0 > 0)
        #expect(open.metadata["walkedDistance"] as? Float ?? 0 > 13)
        #expect(open.events.filter { $0.kind == .deviceActivated && $0.id == 9802 }.count == 1)
        #expect(closed.events.filter { $0.kind == .deviceActivated }.isEmpty)
        #expect(abs(open.simulation.player.position.x) < 0.08 && abs(open.simulation.player.position.z - 8) < 0.08)
        #expect(open.simulation.smokeVolumes.count == 1 && closed.simulation.smokeVolumes.count == 1)
        #expect(JSONSerialization.isValidJSONObject(open.metadata))
    }

    @Test func twoRealThrowsFillRemainingSlotsPauseAndExpireWithoutExtendingOtherClouds() throws {
        let flying = try NativeSmokeCheck.makeScenario(scene: "smoke-overlap", seconds: 0.2)
        let fuse = try #require(flying.simulation.smokeGrenades.first?.fuse)
        let elapsed = flying.simulation.elapsed
        flying.simulation.step(deltaTime: 0, input: GameInput())
        #expect(flying.simulation.elapsed == elapsed && flying.simulation.smokeGrenades.first?.fuse == fuse)
        let full = try NativeSmokeCheck.makeScenario(scene: "smoke-overlap")
        #expect(full.simulation.smokeVolumes.count == 4 && full.simulation.smokeGrenades.isEmpty)
        #expect(full.simulation.smokeGrenadeCount == 0)
        #expect(full.events.filter { $0.kind == .throwSmoke }.count == 2)
        #expect(full.metadata["acceptedSmokeThrows"] as? Int == 2)
        let expired = try NativeSmokeCheck.makeScenario(scene: "smoke-overlap", seconds: 13)
        #expect(expired.simulation.smokeVolumes.isEmpty && expired.simulation.smokeGrenades.isEmpty)
        #expect(expired.metadata["expiredSmokeEvents"] as? Int == 4)
    }
}
