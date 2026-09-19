import Foundation
import Testing
import BlacksiteCore
@testable import BlacksiteMac

@Suite(.serialized)
@MainActor
struct NativeDeviceCheckTests {
    @Test func generatorFixturesUseRealInputPreserveLoadoutAndDoNotSwitchBackWhileHeld() throws {
        let loadout = LoadoutDefinition(camouflage: .mineral)
        let on = try NativeDeviceCheck.makeScenario(scene: "device-generator-on", loadout: loadout)
        let off = try NativeDeviceCheck.makeScenario(scene: "device-generator-off", loadout: loadout)
        #expect(on.simulation.loadout == loadout && off.simulation.loadout == loadout)
        #expect(on.metadata["deviceActivations"] as? Int == 0)
        #expect(off.metadata["deviceActivations"] as? Int == 1)
        #expect(on.simulation.spotlights.allSatisfy { $0.enabled })
        #expect(off.simulation.spotlights.allSatisfy { !$0.enabled })
        #expect(off.simulation.noiseEmitters.allSatisfy { !$0.enabled })
        #expect(JSONSerialization.isValidJSONObject(off.metadata))
    }

    @Test func gateFixturesCaptureClosedMovingOpenAndActorBlockedStates() throws {
        for name in ["closed", "moving", "open", "blocked"] {
            let result = try NativeDeviceCheck.makeScenario(scene: "device-gate-\(name)")
            #expect(JSONSerialization.isValidJSONObject(result.metadata))
            let gate = try #require(result.simulation.devices.first { $0.kind == .serviceGate })
            if name == "blocked" {
                #expect(gate.blockedByActor && result.simulation.player.health == 100)
                #expect(result.events.contains { $0.kind == .gateBlocked })
            }
        }
    }

    @Test func manualFixtureWalksFromDisabledGeneratorToTheUsableGateControl() throws {
        let result = try NativeDeviceCheck.makeScenario(scene: "device-gate-manual")
        let gate = try #require(result.simulation.devices.first { $0.kind == .serviceGate })
        #expect(!gate.powered && gate.gateProgress == 1)
        #expect(result.metadata["deviceActivations"] as? Int == 2)
        #expect(result.events.contains { $0.kind == .footstep })
        #expect(result.simulation.elapsed > 8)
    }

    @Test func diagnosticLightMapsHaveRealOccludersAndKeepDirectSunWhenPowerIsRemoved() throws {
        for name in ["wall", "terrain", "daylight"] {
            let scene = "device-light-\(name)"
            let on = try NativeDeviceCheck.makeScenario(scene: scene)
            let off = try NativeDeviceCheck.makeScenario(scene: scene, generatorOff: true)
            try on.simulation.map.validateGameplay()
            #expect(on.metadata["unoccludedArtificialAtProbe"] as? Float ?? 0 > 0.05)
            #expect(off.metadata["artificialAtProbe"] as? Float == 0)
            #expect(on.metadata["directSunAfter"] as? Float == off.metadata["directSunAfter"] as? Float)
            if name != "daylight" { #expect(on.metadata["artificialAtProbe"] as? Float == 0) }
        }
        let soldier = try NativeDeviceCheck.makeScenario(scene: "device-light-soldier")
        #expect(soldier.simulation.enemies.contains { $0.id == 9850 && $0.health > 0 })
        #expect((soldier.metadata["artificialAtSoldierEye"] as? Float ?? 0) > 0.05)
    }
}
