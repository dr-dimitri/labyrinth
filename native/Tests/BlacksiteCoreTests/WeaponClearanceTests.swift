import Testing
import simd
@testable import BlacksiteCore

struct WeaponClearanceTests {
    private func scene(world: [Obstacle] = [], terrain: TerrainProfile = .flat) -> CombatSimulation {
        CombatSimulation(world: world, startingPlayer: PlayerState(position: SIMD3(0,0,10)),
                         startingEnemies: [], startingWave: 3, terrain: terrain)
    }

    @Test func thinCoverStopsTheViewmodelIncludingPaddingAndInsideContacts() {
        let wall = Obstacle(id: 17, kind: .barrier, position: SIMD3(0,0,-0.4), size: SIMD3(2,2,0.02))
        let game = scene(world: [wall])
        let origin = SIMD3<Float>(0,1,0)
        #expect(abs(game.visualWallDistance(origin: origin, direction: SIMD3(0,0,-5)) - 0.33) < 0.00001)
        #expect(abs(game.visualWallDistance(origin: origin, direction: SIMD3(0,0,-1), padding: 0) - 0.39) < 0.00001)
        #expect(game.visualWallDistance(origin: SIMD3(0,1,-0.4), direction: SIMD3(0,0,1)) == 0)
        #expect(game.visualWallDistance(origin: origin, direction: SIMD3(0,0,1)) == 1.35)
        #expect(game.visualWallDistance(origin: origin, direction: SIMD3(0,0,-1), maximumDistance: 0.2) == 0.2)
    }

    @Test func destroyedCoverStopsRetractingTheWeaponImmediately() {
        let wall = Obstacle(id: 4, kind: .crate, position: SIMD3(0,0,-0.5), size: SIMD3(1,2,0.2))
        let game = scene(world: [wall]), origin = SIMD3<Float>(0,1,0), direction = SIMD3<Float>(0,0,-1)
        #expect(game.visualWallDistance(origin: origin, direction: direction) < 0.4)
        game.damageCover(index: 0, amount: 1000)
        #expect(game.obstacles[0].destroyed)
        #expect(game.visualWallDistance(origin: origin, direction: direction) == 1.35)
    }

    @Test func terrainClearanceUsesTheActualHillAndRespectsTheBoundedRange() {
        let terrain = TerrainProfile.battlefield, game = scene(terrain: terrain)
        let origin = SIMD3<Float>(16,terrain.height(x:16,z:24)+1,24)
        #expect(abs(game.visualWallDistance(origin: origin, direction: SIMD3(0,-100,0)) - 0.94) < 0.0001)
        #expect(game.visualWallDistance(origin: origin, direction: SIMD3(0,1,0), maximumDistance: 1000) == 4)
        #expect(game.visualWallDistance(origin: origin, direction: SIMD3(0,-1,0), maximumDistance: -1) == 0)
    }

    @Test func malformedAndHugeFiniteRaysStayFiniteWithoutChangingGameState() {
        let game = scene(), origin = SIMD3<Float>(0,1,0)
        _ = game.drainEvents()
        let position = game.player.position, ammo = game.weapons[.rifle]!.ammo, score = game.score, wave = game.wave
        for direction in [SIMD3<Float>.zero, SIMD3(.nan,0,0), SIMD3(0,.infinity,0), SIMD3(0,-Float.greatestFiniteMagnitude,0), SIMD3(0,-Float.leastNonzeroMagnitude,0)] {
            let distance = game.visualWallDistance(origin: origin, direction: direction)
            #expect(distance.isFinite && distance >= 0 && distance <= 1.35)
            if direction.y.isFinite && direction.y < 0 { #expect(abs(distance - 0.94) < 0.00001) }
        }
        #expect(game.visualWallDistance(origin: SIMD3(.nan,1,0), direction: SIMD3(0,0,-1), maximumDistance: .nan, padding: .nan) == 1.35)
        #expect(game.player.position == position && game.player.health == 100)
        #expect(game.weapons[.rifle]!.ammo == ammo && game.score == score && game.wave == wave)
        #expect(game.elapsed == 0 && game.enemies.isEmpty && game.grenades.isEmpty)
        #expect(game.drainEvents().isEmpty)
    }
}
