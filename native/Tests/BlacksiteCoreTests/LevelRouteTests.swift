import Foundation
import Testing
import simd
@testable import BlacksiteCore

struct LevelRouteTests {
    private let terrain = TerrainProfile.battlefield
    private let mainRoutes: [[SIMD2<Float>]] = [
        [SIMD2(0,32),SIMD2(0,-35)],
        [SIMD2(0,32),SIMD2(-8,32),SIMD2(-18,32),SIMD2(-31,31),SIMD2(-32,22),SIMD2(-30,14),
         SIMD2(-32,4),SIMD2(-33,-6),SIMD2(-33,-20),SIMD2(-28,-25),SIMD2(-20,-26),SIMD2(-12,-28),SIMD2(-7,-32),SIMD2(0,-35)],
        [SIMD2(0,32),SIMD2(8,32),SIMD2(21,29),SIMD2(29,21),SIMD2(32,13),SIMD2(32,5),SIMD2(32,-3),
         SIMD2(29,-10),SIMD2(33,-18),SIMD2(33,-28),SIMD2(32,-37),SIMD2(22,-38),SIMD2(12,-38),SIMD2(0,-35)]
    ]

    private func scene(at start: SIMD2<Float>, stage: CoverDamageStage = .intact) -> CombatSimulation {
        let game = CombatSimulation(world: GameMap.obstacles,
                                    startingPlayer: PlayerState(position: SIMD3(start.x,0,start.y)),
                                    startingWave: 3, terrain: terrain)
        if stage != .intact {
            for id in game.obstacles.filter({ $0.health.isFinite }).map(\.id) {
                if let index = game.obstacles.firstIndex(where: { $0.id == id }) {
                    let amount: Float = stage == .damaged ? game.obstacles[index].maximumHealth*0.5 : 10_000
                    game.damageCover(index: index, amount: amount)
                }
            }
        }
        return game
    }

    private func walk(_ game: CombatSimulation, through points: [SIMD2<Float>]) -> Bool {
        for point in points {
            var reached = false
            for _ in 0..<3000 {
                let delta = point - SIMD2(game.player.position.x,game.player.position.z)
                if simd_length(delta) < 0.075 { reached = true; break }
                var input = GameInput(); input.moveForward = 1; input.yaw = atan2(-delta.x,-delta.y)
                game.step(deltaTime: 1.0/120, input: input)
                _ = game.drainEvents()
            }
            if !reached { return false }
        }
        return true
    }

    @Test func threeGroundRoutesAndMissionLandmarksSurviveCoverDamageAndCollapse() {
        for stage in CoverDamageStage.allCases {
            for (routeIndex, route) in mainRoutes.enumerated() {
                let game = scene(at: route[0], stage: stage)
                // Prove complete AI reachability while fresh solid debris is
                // still present, before the walking traversal advances its age.
                for target in [GameMap.dataSite,GameMap.radioSite,GameMap.extraction,GameMap.serviceApproach] {
                    #expect(game.hasReachableRoute(from: game.player.position, to: target), "stage=\(stage), target=\(target)")
                }
                #expect(walk(game, through: Array(route.dropFirst())), "route=\(routeIndex), stage=\(stage)")
                #expect(game.player.grounded && horizontalDistance(game.player.position, GameMap.extraction) < 0.1)
            }
        }
    }

    @Test func bothCombatZonesHaveAWorkingInnerAndOuterGroundConnection() {
        let routes: [[SIMD2<Float>]] = [
            [SIMD2(-8,32),SIMD2(-8,8)],
            [SIMD2(-8,32),SIMD2(-18,32),SIMD2(-31,31),SIMD2(-32,22),SIMD2(-30,14),SIMD2(-25,8),SIMD2(-8,8)],
            [SIMD2(8,32),SIMD2(8,16),SIMD2(9.2,10),SIMD2(9.2,3),SIMD2(8,-1),SIMD2(8,-12)],
            [SIMD2(8,32),SIMD2(21,29),SIMD2(29,21),SIMD2(32,13),SIMD2(32,5),SIMD2(32,-3),SIMD2(29,-10),SIMD2(24,-13),SIMD2(8,-12)]
        ]
        for (index, route) in routes.enumerated() {
            let game = scene(at: route[0])
            #expect(walk(game, through: Array(route.dropFirst())), "local route=\(index)")
        }
    }

    @Test func existingContainerRoofsRemainClimbableInBothCombatZones() throws {
        for (id, point, yaw) in [(4,SIMD3<Float>(-25,0,28.6),Float(0)),
                                 (2,SIMD3<Float>(-12.4,0,14),Float.pi/2),
                                 (3,SIMD3<Float>(15,0,-2.3),Float(0))] {
            var player = PlayerState(position: point); player.yaw = yaw
            let game = CombatSimulation(world: GameMap.obstacles, startingPlayer: player, startingWave: 3, terrain: terrain)
            let roof = try #require(game.obstacles.first { $0.id == id }).maximum.y
            #expect(game.mantle())
            var input = GameInput(); input.yaw = yaw
            for _ in 0..<100 { game.step(deltaTime: 1.0/120, input: input) }
            #expect(game.player.grounded && abs(game.player.position.y - roof) < 0.0001)
        }
    }

    @Test func independentlyGroundedServiceStagesReachTheNorthBunkerRoof() throws {
        for profile in [TerrainProfile.flat,.battlefield] {
            var player = PlayerState(position: GameMap.serviceApproach); player.yaw = -.pi/2
            let game = CombatSimulation(world: GameMap.obstacles, startingPlayer: player, startingWave: 3, terrain: profile)
            var input = GameInput(); input.yaw = -.pi/2
            for prop in [LevelProp.lowerServiceStep,.upperServiceStep] {
                let index = try #require(game.obstacles.firstIndex { $0.id == prop.rawValue })
                let step = game.obstacles[index]
                // The entire foundation lies below the triangulated terrain,
                // independently of the other stage's collision or support.
                for x in Int(floor(step.minimum.x))...Int(ceil(step.maximum.x)) {
                    for z in Int(floor(step.minimum.z))...Int(ceil(step.maximum.z)) {
                        #expect(step.minimum.y <= profile.height(x: Float(x), z: Float(z)))
                    }
                }
                game.damageCover(index: index, amount: 1_000_000)
                #expect(!game.obstacles[index].destroyed && game.obstacles[index].health == .infinity)
                #expect(game.mantle())
                for _ in 0..<100 { game.step(deltaTime: 1.0/120, input: input) }
                #expect(game.player.grounded && abs(game.player.position.y - step.maximum.y) < 0.0001)
            }
            input.moveForward = 1
            for _ in 0..<34 { game.step(deltaTime: 1.0/120, input: input) }
            input.moveForward = 0
            #expect(game.mantle())
            for _ in 0..<100 { game.step(deltaTime: 1.0/120, input: input) }
            let bunker = try #require(game.obstacles.first { $0.id == 1 })
            #expect(game.player.grounded && abs(game.player.position.y - bunker.maximum.y) < 0.0001)
            #expect(game.player.position.x > bunker.minimum.x && game.player.position.x < bunker.maximum.x)
            #expect(game.coverDebris.isEmpty && game.score == 0)
        }
    }

    @Test func roofEquipmentHasRealSupportAndBlocksMovementSightAndShots() throws {
        let game = scene(at: SIMD2(0,32))
        for (prop, bunkerID) in [(LevelProp.westRoofEquipment,0),(.northRoofEquipment,1)] {
            let index = try #require(game.obstacles.firstIndex { $0.id == prop.rawValue })
            let housing = game.obstacles[index]
            let bunker = try #require(game.obstacles.first { $0.id == bunkerID })
            #expect(abs(housing.minimum.y - bunker.maximum.y) < 0.0001)
            let centre = housing.position + SIMD3(0,0.5,0)
            let from = centre - SIMD3<Float>(3,0,0), to = centre + SIMD3<Float>(3,0,0)
            #expect(game.blocked(centre))
            #expect(!game.clearLine(from,to))
            #expect(game.clearLine(from + SIMD3(0,0.6,0),to + SIMD3(0,0.6,0)))
            let hit = game.traceShot(origin: from, direction: SIMD3(1,0,0))
            #expect(hit.obstacleIndex == index && abs(hit.distance - 1.75) < 0.0001)
            #expect(hit.normal == SIMD3<Float>(-1,0,0))
            game.damageCover(index: index, amount: 1_000_000)
            #expect(!game.obstacles[index].destroyed && game.obstacles[index].health == .infinity)
        }
        #expect(game.coverDebris.isEmpty && game.score == 0)
    }

    @Test func levelPropMetadataRemainsStableAfterGroundingAndRejectsReusedIDs() throws {
        let game = scene(at: SIMD2(0,32))
        #expect(GameMap.obstacles.count == 23 && Set(GameMap.obstacles.map(\.id)).count == 23)
        for prop in LevelProp.allCases {
            let grounded = try #require(game.obstacles.first { $0.id == prop.rawValue })
            #expect(GameMap.levelProp(for: grounded) == prop)
            let unrelated = Obstacle(id: prop.rawValue, kind: .crate, position: .zero, size: SIMD3(1,1,1))
            #expect(GameMap.levelProp(for: unrelated) == nil)
        }
    }
}
