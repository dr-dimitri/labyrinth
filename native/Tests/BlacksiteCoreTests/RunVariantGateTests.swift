import Testing
import simd
@testable import BlacksiteCore

struct RunVariantGateTests {
    @Test func authoredGateOpeningsAgreeWithBodyAndShotCollisionAtInitialization() throws {
        for base in [MapDefinition.blacksite,.kessel9] {
            for variant in try RunVariantCatalog.variants(for: base) {
                let map = variant.map
                let game = CombatSimulation(world: map.obstacles,startingWave: 3,map: map)
                for definition in map.environment.devices where definition.kind == .serviceGate {
                    let authored = try #require(map.obstacles.first { $0.id == definition.ownerObstacleID })
                    let collider = try #require(game.obstacles.first { $0.id == definition.ownerObstacleID })
                    let state = try #require(game.devices.first { $0.id == definition.id })
                    let closed = map.grounded(authored.position)
                    let expected = closed + (definition.initiallyOpen ? definition.openOffset : .zero)
                    #expect(collider.position == expected && state.closedPosition == closed)
                    #expect(state.targetOpen == definition.initiallyOpen)
                    #expect(game.blocked(closed) != definition.initiallyOpen)
                    #expect(game.clearLine(closed+SIMD3(0,1.5,1),closed+SIMD3(0,1.5,-1)) == definition.initiallyOpen)
                }
            }
        }
    }

    @Test func reversedKesselStartBuildsTheCorrectNavigationAndFirstSwitchReversesIt() throws {
        let map = try RunVariantCatalog.variants(for: .kessel9)[2].map
        let game = CombatSimulation(world: map.obstacles,
            startingPlayer: PlayerState(position: map.grounded(Kessel9Definition.switchPoint)),startingWave: 3,map: map)
        let near = map.grounded(SIMD3<Float>(-6,0,8)), far = map.grounded(SIMD3<Float>(-6,0,0))
        func pathLength() -> Float {
            let points = [near]+game.findPath(from: near,to: far)
            return zip(points,points.dropFirst()).reduce(0) { $0+simd_distance($1.0,$1.1) }
        }
        let openLength = pathLength()
        #expect(game.clearLine(near+SIMD3(0,1.5,0),far+SIMD3(0,1.5,0)))
        #expect(game.runStatistics.openedGateIDs.isEmpty)
        var held = GameInput(); held.interact = true
        for _ in 0..<game.loadout.deviceInteractionTicks(manual: false) { game.step(deltaTime: 1.0/120,input: held) }
        for _ in 0..<245 { game.step(deltaTime: 1.0/120,input: GameInput()) }
        let controller = try #require(game.devices.first { $0.id == 2950 })
        #expect(!controller.enabled && controller.gateProgress == 0 && !controller.isMoving)
        #expect(game.devices.first { $0.id == 2951 }?.gateProgress == 0)
        #expect(game.devices.first { $0.id == 2952 }?.gateProgress == 1)
        #expect(!game.clearLine(near+SIMD3(0,1.5,0),far+SIMD3(0,1.5,0)))
        #expect(game.clearLine(map.grounded(SIMD3(8,1.5,8)),map.grounded(SIMD3(8,1.5,0))))
        #expect(pathLength() > openLength+8)
        #expect(game.runStatistics.maintenanceSwitches == 1 && game.runStatistics.openedGateIDs == [2952])
    }
}
