import Testing
import simd
@testable import BlacksiteCore

@Suite(.serialized)
struct EnemyTerrainTests {
    private func advance(_ game: CombatSimulation, seconds: Double, input: GameInput = GameInput()) {
        for _ in 0..<Int((seconds * 120).rounded()) { game.step(deltaTime: 1.0 / 120, input: input) }
    }
    private func scenario(player: SIMD3<Float> = SIMD3(0, 0, 15), enemies: [EnemyState] = [],
                          world: [Obstacle] = [], terrain: TerrainProfile = .flat) -> CombatSimulation {
        CombatSimulation(world: world, startingPlayer: PlayerState(position: player),
                         startingEnemies: enemies, startingWave: 3, terrain: terrain)
    }
    private var lowCover: Obstacle {
        Obstacle(id: 1, kind: .barrier, position: .zero, size: SIMD3(6, 1.05, 0.85))
    }

    @Test func mainMapUsesTerrainWhileExplicitScenariosRemainFlat() {
        let game = CombatSimulation()
        #expect(game.terrain == .battlefield)
        #expect(game.obstacles.allSatisfy { abs($0.position.y - game.terrain.height(x: $0.position.x, z: $0.position.z)) < 0.0001 })
        #expect(game.obstacles.contains { $0.position.y > 1 })
        #expect(game.extractionPosition.y == game.terrain.height(x: game.extractionPosition.x, z: game.extractionPosition.z))
        let flat = scenario(player: SIMD3(16, 0, 24))
        #expect(flat.terrain == .flat)
        #expect(flat.player.position.y == 0)
    }

    @Test func walkingClimbsHillsAndJumpingReturnsToNegativeValleyFloor() {
        let uphill = scenario(player: SIMD3(7, 0, 24), terrain: .battlefield)
        var input = GameInput(); input.moveRight = 1
        advance(uphill, seconds: 2, input: input)
        #expect(uphill.player.position.x > 16)
        #expect(uphill.player.position.y > 4)
        #expect(uphill.player.grounded)
        #expect(abs(uphill.player.position.y - uphill.terrain.height(x: uphill.player.position.x, z: uphill.player.position.z)) < 0.001)
        let valley = scenario(player: SIMD3(-30, 0, -31), terrain: .battlefield)
        let floor = valley.player.position.y
        #expect(floor < -1.5)
        #expect(valley.jump())
        advance(valley, seconds: 0.3)
        #expect(valley.player.position.y > floor + 1)
        #expect(!valley.player.grounded)
        advance(valley, seconds: 0.7)
        #expect(valley.player.grounded)
        #expect(abs(valley.player.position.y - floor) < 0.001)
    }

    @Test func navigationAndWaveSpawnsUseActualTerrainElevations() {
        let game = CombatSimulation()
        let path = game.findPath(from: SIMD3(8, 0, 24), to: SIMD3(24, 0, 24))
        #expect(!path.isEmpty)
        #expect(path.allSatisfy { abs($0.y - game.terrain.height(x: $0.x, z: $0.z)) < 0.0001 })
        #expect(path.contains { $0.y > 2 })
        game.spawnWave()
        #expect(game.aliveCount == 5)
        #expect(game.enemies.allSatisfy { abs($0.position.y - game.terrain.height(x: $0.position.x, z: $0.position.z)) < 0.0001 })
        for index in game.enemies.indices { game.damageEnemy(index: index, amount: 1000) }
        #expect(game.supplies.count == 1)
        #expect(game.supplies.allSatisfy { abs($0.position.y - game.terrain.height(x: $0.position.x, z: $0.position.z)) < 0.0001 })
    }

    @Test func terrainBlocksHitscanAndEnemySightAcrossNearbyHill() {
        let game = scenario(player: SIMD3(7, 0, 24), enemies: [EnemyState(id: 1, position: SIMD3(29, 0, 24))], terrain: .battlefield)
        let target = EnemyPose(game.enemies[0]).headCenter
        let ray = simd_normalize(target - game.eyePosition)
        let trace = game.traceShot(origin: game.eyePosition, direction: ray)
        #expect(trace.hitGround)
        #expect(trace.enemyIndex == nil)
        #expect(trace.distance < simd_distance(game.eyePosition, target))
        advance(game, seconds: 0.5)
        #expect(!game.enemies[0].seesPlayer)
        #expect(!game.enemies[0].isMoving)
        #expect(game.isHidden)
    }

    @Test func crouchingChangesActualHeadAndBodyHitboxes() {
        let standing = EnemyState(id: 1, position: .zero)
        var ducking = standing; ducking.crouchAmount = 1
        let upright = scenario(enemies: [standing]), crouched = scenario(enemies: [ducking])
        let high = SIMD3<Float>(0, 1.73, 10), forward = SIMD3<Float>(0, 0, -1)
        #expect(upright.traceShot(origin: high, direction: forward).headshot)
        #expect(crouched.traceShot(origin: high, direction: forward).enemyIndex == nil)
        #expect(crouched.traceShot(origin: SIMD3(0, 1.08, 10), direction: forward).headshot)
        #expect(EnemyPose(ducking).totalHeight < EnemyPose(standing).totalHeight - 0.6)
    }

    @Test func terrainRidgeOccludesGrenadeBlastEvenWithinDamageRadius() {
        let enemy = EnemyState(id: 1, position: SIMD3(37, 0, -30))
        let sheltered = scenario(enemies: [enemy], terrain: .battlefield)
        let origin = SIMD3<Float>(31, sheltered.terrain.height(x: 31, z: -30) + 0.09, -30)
        #expect(simd_distance(origin, EnemyPose(sheltered.enemies[0]).bodyCenter) < 8)
        sheltered.explode(at: origin)
        #expect(sheltered.enemies[0].health == 100)
        let exposed = scenario(enemies: [enemy])
        exposed.explode(at: SIMD3(31, 0.09, -30))
        #expect(exposed.enemies[0].health < 60)
    }

    @Test func pursuingEnemyTraversesNegativeTerrainWithoutFloating() {
        let game = scenario(player: SIMD3(0, 0, -12), enemies: [EnemyState(id: 1, position: SIMD3(-30, 0, -31))], terrain: .battlefield)
        let start = game.enemies[0].position
        #expect(start.y < -1.5)
        game.damageEnemy(index: 0, amount: 1)
        var ran = false
        for _ in 0..<600 {
            game.step(deltaTime: 1.0 / 120, input: GameInput())
            let enemy = game.enemies[0]
            ran = ran || enemy.isRunning
            let floor = game.terrain.height(x: enemy.position.x, z: enemy.position.z)
            #expect(enemy.position.y >= floor - 0.001)
            if enemy.grounded { #expect(abs(enemy.position.y - floor) < 0.001) }
        }
        #expect(ran)
        #expect(horizontalDistance(start, game.enemies[0].position) > 5)
    }

    @Test func hurtSoldierDucksBehindLowCoverThenPeeks() {
        let game = scenario(player: SIMD3(0, 0, 10), enemies: [EnemyState(id: 1, position: SIMD3(0, 0, -1.2))], world: [lowCover])
        game.damageEnemy(index: 0, amount: 20)
        advance(game, seconds: 0.5)
        #expect(game.enemies[0].crouchAmount > 0.95)
        #expect(!game.enemies[0].isMoving)
        #expect(game.enemies[0].windup == 0)
        #expect(!game.drainEvents().contains { $0.kind == .enemyShot })
        advance(game, seconds: 3.2)
        #expect(game.enemies[0].crouchAmount < 0.2)
        #expect(game.enemies[0].windup > 0)
    }

    @Test func threatenedSoldierRunsToNearbyCoverAndSettlesIntoCrouch() {
        let game = scenario(enemies: [EnemyState(id: 1, position: SIMD3(5, 0, -4))], world: [lowCover])
        let start = game.enemies[0].position
        game.damageEnemy(index: 0, amount: 10)
        var sawRun = false, sawCoverCrouch = false
        for _ in 0..<360 {
            game.step(deltaTime: 1.0 / 120, input: GameInput())
            let enemy = game.enemies[0]
            sawRun = sawRun || enemy.isRunning
            if horizontalDistance(enemy.position, SIMD3(0, 0, -1.175)) < 0.9 && enemy.crouchAmount > 0.9 { sawCoverCrouch = true }
        }
        #expect(sawRun)
        #expect(horizontalDistance(game.enemies[0].position, start) > 3)
        #expect(sawCoverCrouch)
    }

    @Test func soldierStopsAimsExactlyAndFiresFromSharedVisibleMuzzle() {
        let game = scenario(player: SIMD3(3, 0, 15), enemies: [EnemyState(id: 1, position: .zero)])
        advance(game, seconds: 2.2)
        let enemy = game.enemies[0], pose = EnemyPose(enemy)
        #expect(enemy.windup > 0)
        #expect(!enemy.isMoving && !enemy.isRunning)
        #expect(enemy.aimBlend > 0.95)
        #expect(simd_dot(pose.aimDirection, simd_normalize(game.eyePosition - pose.gunRoot)) > 0.99999)
        let transformedMuzzle = pose.gunTransform * SIMD4<Float>(0, 0, 0.72, 1)
        #expect(simd_distance(SIMD3(transformedMuzzle.x, transformedMuzzle.y, transformedMuzzle.z), pose.muzzlePosition) < 0.00001)
        var shot: GameEvent?
        for _ in 0..<90 {
            game.step(deltaTime: 1.0 / 120, input: GameInput())
            shot = game.drainEvents().first { $0.kind == .enemyShot }
            if shot != nil { break }
        }
        #expect(shot != nil)
        if let shot {
            #expect(simd_distance(shot.position, EnemyPose(game.enemies[0]).muzzlePosition) < 0.0001)
            #expect(game.enemies[0].recoil > 0.9)
            #expect(!game.enemies[0].isMoving)
        }
    }

    @Test func soldierJumpsLowBarrierAndLandsWithoutRepeatedBunnyHops() {
        let barrier = Obstacle(id: 1, kind: .barrier, position: SIMD3(0, 0, 1), size: SIMD3(6, 1.05, 0.85))
        let game = scenario(player: SIMD3(0, 0, -38), enemies: [EnemyState(id: 1, position: SIMD3(0, 0, 4))], world: [barrier])
        var jumps = 0, wasGrounded = true, highest: Float = 0
        for _ in 0..<360 {
            game.step(deltaTime: 1.0 / 120, input: GameInput())
            let enemy = game.enemies[0]
            // Leaving the far edge after landing on the barrier is a fall,
            // not another jump. Count only active upward impulses.
            if wasGrounded && !enemy.grounded && enemy.verticalVelocity > 0 { jumps += 1 }
            wasGrounded = enemy.grounded; highest = max(highest, enemy.position.y)
        }
        #expect(jumps == 1)
        #expect(highest > 1.1)
        #expect(game.enemies[0].position.z < 0.2)
        #expect(game.enemies[0].grounded)
        let flat = scenario(player: SIMD3(0, 0, -35), enemies: [EnemyState(id: 1, position: .zero)])
        for _ in 0..<180 {
            flat.step(deltaTime: 1.0 / 120, input: GameInput())
            #expect(flat.enemies[0].grounded)
        }
        #expect(flat.enemies[0].position.z < -5)
    }

    @Test func navigationRoutesAroundCratesAboveTheJumpLimit() {
        let crate = Obstacle(id: 1, kind: .crate, position: .zero, size: SIMD3(6, 1.2, 2))
        let game = scenario(world: [crate])
        let path = game.findPath(from: SIMD3(0, 0, -10), to: SIMD3(0, 0, 10))
        #expect(!path.isEmpty)
        #expect(path.contains { abs($0.x) >= 4 })
        #expect(path.allSatisfy { !game.blocked($0, height: 1.96, radius: 0.38) })
    }

    @Test func grenadeBouncesFromUphillTerrainAndStaysAboveItsSurface() {
        let game = scenario(player: SIMD3(7, 0, 24), terrain: .battlefield)
        var input = GameInput(); input.yaw = -.pi / 2; input.pitch = -0.5
        game.step(deltaTime: 1.0 / 120, input: input)
        #expect(game.throwGrenade())
        var bounced = false
        for _ in 0..<180 {
            let before = game.grenades[0].velocity
            game.step(deltaTime: 1.0 / 120, input: input)
            let grenade = game.grenades[0]
            #expect(grenade.position.y >= game.terrain.height(x: grenade.position.x, z: grenade.position.z) + 0.089)
            if grenade.velocity.x < before.x - 0.1 { bounced = true }
        }
        #expect(bounced)
        #expect(game.grenades[0].position.x < 16)
    }
}
