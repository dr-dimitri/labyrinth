import Testing
import simd
@testable import BlacksiteCore

struct SurfaceImpactTests {
    private func scene(world: [Obstacle] = [], player: PlayerState = PlayerState(position: SIMD3(0,0,3)),
                       enemies: [EnemyState] = [], terrain: TerrainProfile = .flat) -> CombatSimulation {
        CombatSimulation(seed: 1745, world: world, startingPlayer: player, startingEnemies: enemies,
                         startingWave: 3, terrain: terrain)
    }
    private func shoot(_ game: CombatSimulation) throws -> (GameEvent, [GameEvent]) {
        let ammo = game.weapons[game.activeWeapon]!.ammo
        #expect(game.fire())
        let events = game.drainEvents(), shots = events.filter { $0.kind == .shot }
        #expect(shots.count == 1)
        #expect(game.weapons[game.activeWeapon]!.ammo == ammo - 1)
        return (try #require(shots.first), events)
    }

    @Test func eachCoverMaterialCarriesItsFrontNormalAndStableOwner() throws {
        let kinds: [(ObstacleKind, SurfaceMaterial)] = [(.bunker,.concrete),(.barrier,.concrete),(.container,.metal),(.barrel,.metal),(.crate,.wood)]
        for (kind,material) in kinds {
            let box = Obstacle(id: 741, kind: kind, position: .zero, size: SIMD3(3,3,0.8))
            let game = scene(world: [box])
            let (shot,_) = try shoot(game)
            let hit = try #require(shot.surfaceImpact)
            #expect(hit.material == material && hit.obstacleID == 741)
            #expect(hit.position == shot.endPosition)
            #expect(abs(hit.position.z - 0.4) < 0.00001)
            #expect(simd_distance(hit.normal, SIMD3(0,0,1)) < 0.00001)
            #expect(abs(simd_length(hit.normal) - 1) < 0.00001)
            #expect(simd_dot(hit.normal, hit.position - game.eyePosition) < 0)
            #expect(shot.amount == 0)
        }
    }

    @Test func coverWinsBeforeAnEnemyAndNearMuzzleCoverWinsBeforeTheCameraTarget() throws {
        let enemy = EnemyState(id: 24, position: .zero)
        let wall = Obstacle(id: 83, kind: .container, position: SIMD3(0,0,1.5), size: SIMD3(3,3,0.2))
        let normalScene = scene(world: [wall], enemies: [enemy])
        let (normalShot,_) = try shoot(normalScene)
        #expect(normalShot.surfaceImpact?.obstacleID == 83)
        #expect(normalScene.enemies[0].health == 100)

        // The eye sees the enemy, but the offset muzzle crosses this thin edge.
        let edge = Obstacle(id: 96, kind: .barrier, position: SIMD3(0.22,0,2.56), size: SIMD3(0.12,3,0.06))
        let nearScene = scene(world: [edge], enemies: [enemy])
        #expect(nearScene.traceShot(origin: nearScene.eyePosition, direction: SIMD3(0,0,-1)).enemyIndex == 0)
        let (nearShot,_) = try shoot(nearScene)
        let nearHit = try #require(nearShot.surfaceImpact)
        #expect(nearHit.material == .concrete && nearHit.obstacleID == 96)
        #expect(nearHit.position == nearShot.endPosition)
        #expect(nearScene.enemies[0].health == 100)
        #expect(simd_dot(nearHit.normal, nearHit.position - nearScene.eyePosition) < 0)
    }

    @Test func lethalCoverHitRetainsItsSnapshotAndTheNextShotSkipsTheDestroyedOwner() throws {
        var front = Obstacle(id: 701, kind: .crate, position: SIMD3(0,0,5), size: SIMD3(3,3,0.5))
        front.health = 1
        let back = Obstacle(id: 903, kind: .barrier, position: .zero, size: SIMD3(3,3,0.5))
        let game = scene(world: [front,back], player: PlayerState(position: SIMD3(0,0,10)))
        let (first,events) = try shoot(game)
        let snapshot = try #require(first.surfaceImpact)
        #expect(game.obstacles[0].destroyed)
        #expect(snapshot.material == .wood && snapshot.obstacleID == 701)
        #expect(events.contains { $0.kind == .coverDestroyed && $0.id == snapshot.obstacleID })
        #expect(abs(snapshot.position.z - 5.25) < 0.00001)
        for _ in 0..<14 { game.step(deltaTime: 1.0/120, input: GameInput()) }
        let (second,_) = try shoot(game)
        #expect(second.surfaceImpact?.material == .concrete && second.surfaceImpact?.obstacleID == 903)
        #expect(abs(second.endPosition.z - 0.25) < 0.00001)
        #expect(first.surfaceImpact == snapshot)
    }

    @Test func terrainHitsDistinguishAsphaltAndSoilUsingTheRealSlopeNormal() throws {
        let terrain = TerrainProfile.battlefield
        for (x,material): (Float,SurfaceMaterial) in [(0,.asphalt),(16,.soil)] {
            var player = PlayerState(position: SIMD3(x,terrain.height(x:x,z:24),24))
            player.pitch = -1
            let game = scene(player: player, terrain: terrain)
            let (shot,_) = try shoot(game)
            let hit = try #require(shot.surfaceImpact)
            #expect(hit.material == material && hit.obstacleID == nil)
            #expect(abs(hit.position.y - terrain.height(x:hit.position.x,z:hit.position.z)) < 0.001)
            #expect(simd_distance(hit.normal, terrain.normal(x:hit.position.x,z:hit.position.z)) < 0.00001)
            #expect(simd_dot(hit.normal, hit.position - game.eyePosition) < 0)
        }
    }

    @Test func barrelChainDestructionPreservesOneShotAndItsOriginalMetalOwner() throws {
        var barrel = Obstacle(id: 990, kind: .barrel, position: .zero, size: SIMD3(1,2,1))
        barrel.health = 1
        let crate = Obstacle(id: 442, kind: .crate, position: SIMD3(0,0,-1.2), size: SIMD3(1,2,1))
        let game = scene(world: [barrel,crate], player: PlayerState(position: SIMD3(0,0,10)))
        let (shot,events) = try shoot(game)
        let hit = try #require(shot.surfaceImpact)
        #expect(hit.material == .metal && hit.obstacleID == 990)
        #expect(abs(hit.position.z - 0.5) < 0.00001)
        #expect(game.obstacles.allSatisfy { $0.destroyed })
        #expect(Set(events.filter { $0.kind == .coverDestroyed }.map(\.id)) == Set([990,442]))
        #expect(events.contains { $0.kind == .explosion })
        let destroyed = try #require(events.firstIndex { $0.kind == .coverDestroyed && $0.id == 990 })
        let emitted = try #require(events.firstIndex { $0.kind == .shot })
        #expect(destroyed < emitted)
    }

    @Test func airMissesAndEnemyHitsHaveNoEnvironmentPayload() throws {
        var player = PlayerState(position: SIMD3(0,0,3));player.pitch = 0.7
        let (miss,_) = try shoot(scene(player: player))
        #expect(miss.surfaceImpact == nil && miss.amount == 0)
        let game = scene(enemies: [EnemyState(id: 41, position: .zero)])
        let (hit,_) = try shoot(game)
        #expect(hit.surfaceImpact == nil && hit.amount > 0)
        #expect(game.enemies[0].health < 100)
        #expect(GameEvent(kind: .shot).surfaceImpact == nil)
    }
}
