import Foundation
import Testing
import BlacksiteCore
@testable import BlacksiteMac

@MainActor
@Suite(.serialized)
struct NativeFjordCheckTests {
    @Test func authoredLandmarkViewsKeepNineRealGuardsAndGroundedCameras() throws {
        for scene in ["fjord-overview", "fjord-rocks", "fjord-modules", "fjord-radome", "fjord-coast"] {
            let result = try NativeFjordCheck.makeScenario(scene: scene)
            let game = result.simulation
            #expect(game.map.id == "nebelwacht" && game.enemies.count == 9)
            #expect(game.enemies.allSatisfy { $0.health > 0 })
            #expect(abs(game.player.position.y - game.terrain.height(x: game.player.position.x, z: game.player.position.z)) < 0.04)
            #expect(game.player.position.x > game.map.minimum.x && game.player.position.x < game.map.maximum.x)
            #expect(game.player.position.z > game.map.minimum.z && game.player.position.z < game.map.maximum.z)
            #expect(result.events.allSatisfy { $0.kind != .throwGrenade && $0.kind != .explosion })
            #expect(JSONSerialization.isValidJSONObject(result.metadata))
        }
    }

    @Test func warningAndSprayViewsUseTheSeededCoreScheduleAndOneIsolatedOffSwitch() throws {
        let warning = try NativeFjordCheck.makeScenario(scene: "fjord-warning")
        let source = try #require(warning.simulation.map.environment.smokeEmitters.first)
        let state = try #require(warning.simulation.smokeWarnings.first)
        #expect(state.startsAt == source.firstEmissionTime(seed: NativeFjordCheck.seed))
        #expect(warning.simulation.smokeVolumes.isEmpty)
        #expect(warning.events.filter { $0.kind == .smokeWarning }.count == 1)
        let spray = try NativeFjordCheck.makeScenario(scene: "fjord-spray")
        let off = try NativeFjordCheck.makeScenario(scene: "fjord-spray", noSpray: true)
        #expect(spray.simulation.smokeVolumes.count == 1)
        #expect(spray.metadata["opticalDepthToProbe"] as? Float ?? 0 > 0)
        #expect(off.simulation.smokeVolumes.isEmpty && off.simulation.smokeWarnings.isEmpty)
        #expect(off.events.allSatisfy { $0.kind != .smokeWarning && $0.kind != .smokeActivated })
        #expect(off.simulation.elapsed == spray.simulation.elapsed)
        #expect(off.simulation.player.position == spray.simulation.player.position)
        #expect(off.simulation.map.resources == spray.simulation.map.resources)
        #expect(off.simulation.map.obstacles.map(\.position) == spray.simulation.map.obstacles.map(\.position))
        #expect(off.simulation.map.obstacles.map(\.size) == spray.simulation.map.obstacles.map(\.size))
        #expect(off.simulation.map.spawns == spray.simulation.map.spawns)
        #expect(off.simulation.map.environment.sunDirection == spray.simulation.map.environment.sunDirection)
        for result in [spray, off] {
            let game = result.simulation
            let live = game.enemies.filter { $0.health > 0 }
            let arrivals = result.events.filter { $0.kind == .reinforcementsArrived && $0.alarmReportID != nil }
            #expect(live.filter { (9870...9878).contains($0.id) }.count == 9)
            #expect((9...11).contains(live.count) && arrivals.count <= 2)
            #expect(live.filter { !(9870...9878).contains($0.id) }.allSatisfy { soldier in arrivals.contains { $0.id == soldier.id } })
            #expect(result.metadata["initialLiveSoldiers"] as? Int == 9)
            #expect(result.metadata["liveAuthoredSoldiers"] as? Int == 9)
            #expect(result.metadata["liveSoldiers"] as? Int == live.count)
            #expect(result.metadata["alarmArrivalEvents"] as? Int == arrivals.count)
        }
        #expect(JSONSerialization.isValidJSONObject(spray.metadata))
    }

    @Test func aftermathRunsThreeRealFusesAndRetainsSelectedInventoryWithoutEventReplay() throws {
        let result = try NativeFjordCheck.makeScenario(scene: "fjord-aftermath")
        let explosions = result.events.filter { $0.kind == .explosion }
        #expect(result.events.filter { $0.kind == .throwGrenade }.count == 3)
        #expect(explosions.count == 3 && result.simulation.grenades.isEmpty)
        #expect(result.simulation.grenadeCount == result.simulation.loadout.fragmentationGrenades - 3)
        #expect(result.simulation.enemies.filter { $0.health > 0 }.count == 9)
        let times = explosions.compactMap { $0.hearing?.time }
        #expect(times.count == 3 && times[1] - times[0] > 0.7 && times[2] - times[1] > 0.7)
        #expect(result.simulation.elapsed - (times.last ?? 0) > 0.1)
        #expect(JSONSerialization.isValidJSONObject(result.metadata))
        #expect(throws: (any Error).self) {
            try NativeFjordCheck.makeScenario(scene: "fjord-aftermath",
                loadout: LoadoutDefinition(operatorClass: .recon, camouflage: .mineral))
        }
    }
}
