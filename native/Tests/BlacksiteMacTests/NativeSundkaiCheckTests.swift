import Foundation
import Testing
import simd
import BlacksiteCore
@testable import BlacksiteMac

@MainActor
@Suite(.serialized)
struct NativeSundkaiCheckTests {
    @Test func contactDiagnosisUsesRealWetFeetDryShoreAndPhysicalContainerTop() throws {
        let result = try NativeSundkaiCheck.makeScenario(scene: "sundkai-contact")
        let game = result.simulation
        #expect(game.enemies.count == 3 && game.enemies.allSatisfy { $0.health > 0 && $0.grounded })
        let wet = try #require(game.enemies.first { $0.id == 9880 })
        let shore = try #require(game.enemies.first { $0.id == 9881 })
        let roofSoldier = try #require(game.enemies.first { $0.id == 9882 })
        let roof = try #require(game.obstacles.first { $0.id == 2810 })
        #expect(game.waterContact(at: wet.position, grounded: wet.grounded)?.depth ?? 0 > 0.15)
        #expect(game.waterContact(at: shore.position, grounded: shore.grounded) == nil)
        #expect(game.waterContact(at: roofSoldier.position, grounded: roofSoldier.grounded) == nil)
        #expect(abs(roofSoldier.position.y - roof.position.y - roof.size.y) < 0.02)
        #expect(abs(shore.position.y - game.terrain.height(x: shore.position.x,z: shore.position.z)) < 0.02)
        #expect(abs(game.elapsed - 0.25) < 0.01)
        #expect(JSONSerialization.isValidJSONObject(result.metadata))
    }

    @Test func realMapViewsKeepGroundedCamerasNineNormalGuardsAndSelectedKit() throws {
        let loadout=LoadoutDefinition(operatorClass:.recon,camouflage:.vegetation)
        for scene in ["sundkai-overview","sundkai-shore"] {
            let result=try NativeSundkaiCheck.makeScenario(scene:scene,loadout:loadout)
            let game=result.simulation
            #expect(game.map.id=="sundkai" && game.loadout==loadout)
            #expect(game.enemies.filter { $0.health>0 }.count==9)
            #expect(game.grenadeCount==loadout.fragmentationGrenades && game.noiseDecoyCount==loadout.noiseDecoys)
            #expect(abs(game.player.position.y-game.terrain.height(x:game.player.position.x,z:game.player.position.z))<0.04)
            #expect(JSONSerialization.isValidJSONObject(result.metadata))
        }
    }

    @Test func walkingUsesRealWetContactAndTheOffCopyChangesOnlyWaterDefinitions() throws {
        let wet=try NativeSundkaiCheck.makeScenario(scene:"sundkai-wade")
        let dry=try NativeSundkaiCheck.makeScenario(scene:"sundkai-wade",noWater:true)
        let water=try #require(wet.simulation.waterContact(at:wet.simulation.player.position))
        #expect(water.depth>=0.15 && water.depth<=0.351)
        #expect(wet.simulation.elapsed>dry.simulation.elapsed)
        #expect(simd_distance(wet.simulation.player.position,dry.simulation.player.position)<0.12)
        let steps=wet.events.filter { $0.kind == .footstep && $0.hearing?.source == .player && $0.hearing?.surface == .water }
        #expect(!steps.isEmpty)
        #expect(steps.allSatisfy { abs(($0.hearing?.position.y ?? 0)-(water.surfaceHeight+0.06))<0.01 })
        #expect(dry.events.allSatisfy { $0.hearing?.surface != .water && $0.waterImpact == nil })
        #expect(wet.simulation.map.resources==dry.simulation.map.resources)
        #expect(wet.simulation.map.obstacles.map(\.position)==dry.simulation.map.obstacles.map(\.position))
        #expect(wet.simulation.map.spawns==dry.simulation.map.spawns)
        #expect(wet.simulation.map.environment.sunDirection==dry.simulation.map.environment.sunDirection)
        #expect(dry.simulation.map.environment.shallowWaterZones.isEmpty)
        #expect(JSONSerialization.isValidJSONObject(wet.metadata) && JSONSerialization.isValidJSONObject(dry.metadata))
    }

    @Test func actualJumpLandsAudiblyAndTheNextBulletCrossesWaterBeforePhysicalBed() throws {
        let landing=try NativeSundkaiCheck.makeScenario(scene:"sundkai-landing")
        #expect(landing.metadata["acceptedJumps"] as? Int==1)
        #expect((landing.metadata["airborneTicks"] as? Int ?? 0)>10)
        #expect(landing.metadata["airborneFootsteps"] as? Int==0)
        #expect(landing.events.filter { $0.kind == .land && $0.hearing?.source == .player && $0.hearing?.surface == .water }.count==1)
        let shot=try NativeSundkaiCheck.makeScenario(scene:"sundkai-impact")
        let event=try #require(shot.events.first { $0.kind == .shot })
        let impact=try #require(event.waterImpact)
        let surface=try #require(event.surfaceImpact)
        #expect(event.endPosition.y<impact.position.y)
        #expect(simd_distance(surface.position,event.endPosition)<0.001)
        #expect(shot.simulation.weapons[.rifle]?.ammo==29)
        #expect(JSONSerialization.isValidJSONObject(landing.metadata) && JSONSerialization.isValidJSONObject(shot.metadata))
    }

    @Test func bothRelayOrdersUseHeldInteractionAndPhysicalWalkingBeforeDataUnlocksBothExits() throws {
        for reverse in [false,true] {
            let kit=LoadoutDefinition(operatorClass:.engineer,camouflage:.mineral)
            let result=try NativeSundkaiCheck.makeScenario(scene:"sundkai-relays",reverseRelays:reverse,loadout:kit)
            #expect(result.simulation.map.id=="diagnostic-sundkai-relays")
            #expect(result.simulation.loadout==kit)
            #expect((result.metadata["walkedDistance"] as? Float ?? 0)>5)
            #expect(result.metadata["firstRelayCompletedIDs"] as? [String]==[reverse ? "east":"west"])
            #expect(result.metadata["exitsLockedAfterFirstRelay"] as? Bool==true)
            let order=result.events.compactMap(\.operationObjective).map(\.id)
            #expect(order == (reverse ? ["east","west","data"]:["west","east","data"]))
            #expect(result.simulation.missionStatus.phase == .extract)
            #expect(result.simulation.operationStatus?.extractions.filter { $0.unlocked }.count==2)
            #expect(result.simulation.breachChargeCount==kit.breachCharges)
            #expect(result.events.allSatisfy { $0.kind != .win })
            #expect(JSONSerialization.isValidJSONObject(result.metadata))
        }
    }

    @Test func aftermathUsesThreeActualFragsWithDistinctFuseTimesAndRealWaterCrossings() throws {
        let result = try NativeSundkaiCheck.makeScenario(scene: "sundkai-aftermath")
        let explosions = result.events.filter { $0.kind == .explosion }
        #expect(result.metadata["acceptedGrenadeThrows"] as? Int == 3)
        #expect(result.events.filter { $0.kind == .throwGrenade }.count == 3)
        #expect(explosions.count == 3 && result.simulation.grenades.isEmpty)
        #expect(result.simulation.grenadeCount == result.simulation.loadout.fragmentationGrenades - 3)
        #expect(abs(result.simulation.elapsed - 4.45) < 0.01)
        let times = explosions.compactMap(\.hearing).map(\.time)
        #expect(times.count == 3)
        if times.count == 3 {
            #expect(abs(times[1] - times[0] - 0.75) < 0.02)
            #expect(abs(times[2] - times[1] - 0.75) < 0.02)
        }
        #expect(explosions.contains { $0.waterImpact != nil })
        #expect(result.simulation.enemies.filter { $0.health > 0 && (9880...9888).contains($0.id) }.count == 9)
        #expect(JSONSerialization.isValidJSONObject(result.metadata))
        #expect(throws: (any Error).self) {
            try NativeSundkaiCheck.makeScenario(scene: "sundkai-aftermath",
                loadout: LoadoutDefinition(operatorClass: .recon, camouflage: .vegetation))
        }
    }
}
