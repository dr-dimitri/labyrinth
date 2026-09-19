import Testing
import simd
@testable import BlacksiteCore

@Suite(.serialized)
struct CombatSimulationTests {
    private func simulation(world: [Obstacle] = [], position: SIMD3<Float> = SIMD3(0, 0, 20),
                            enemies: [EnemyState] = [], wave: Int = 3) -> CombatSimulation {
        CombatSimulation(world: world, startingPlayer: PlayerState(position: position), startingEnemies: enemies, startingWave: wave)
    }
    private func advance(_ game: CombatSimulation, _ seconds: Double, input: GameInput = GameInput()) {
        let ticks = Int((seconds * 120).rounded())
        for _ in 0..<ticks { game.step(deltaTime: 1.0 / 120.0, input: input) }
    }
    private func obstacle(_ id: Int = 0, _ kind: ObstacleKind = .container,
                          at position: SIMD3<Float> = .zero, size: SIMD3<Float> = SIMD3(4, 3.1, 8)) -> Obstacle {
        Obstacle(id: id, kind: kind, position: position, size: size)
    }

    @Test func testFixedStepGivesSameMovementAtThirtyAndOneTwentyFrames() {
        let lowRate = simulation(), highRate = simulation()
        var input = GameInput(); input.moveForward = 1; input.moveRight = 1
        for _ in 0..<30 { lowRate.step(deltaTime: 1.0 / 30, input: input) }
        advance(highRate, 1, input: input)
        #expect(abs((lowRate.player.position.x) - (highRate.player.position.x)) <= 0.0001)
        #expect(abs((lowRate.player.position.z) - (highRate.player.position.z)) <= 0.0001)
        #expect(abs((horizontalDistance(highRate.player.position, SIMD3(0, 0, 20))) - (4.7)) <= 0.002)
    }

    @Test func testInvalidClocksAndInputCannotPoisonSimulation() {
        let game = simulation()
        for delta in [Double.nan, .infinity, -.infinity, -1, 0] { game.step(deltaTime: delta, input: GameInput()) }
        #expect((game.elapsed) == (0))
        var input = GameInput(); input.yaw = .nan; input.pitch = .infinity
        input.moveForward = .nan; input.moveRight = .infinity
        game.step(deltaTime: 60, input: input)
        #expect(abs((game.elapsed) - (0.15)) <= 0.0001)
        #expect((game.player.position) == (SIMD3(0, 0, 20)))
        #expect(game.player.yaw.isFinite)
        #expect(game.player.pitch.isFinite)
    }

    @Test func testPlayerStopsAtCoverAndArenaBoundary() {
        let game = simulation(world: [obstacle()], position: SIMD3(0, 0, 6))
        var input = GameInput(); input.moveForward = 1; input.sprint = true
        advance(game, 2, input: input)
        #expect((game.player.position.z) >= (4.3))
        #expect(!(game.blocked(game.player.position)))
        let edge = simulation(position: SIMD3(37, 0, 0))
        input.moveForward = 0; input.moveRight = 1
        advance(edge, 1, input: input)
        #expect((edge.player.position.x) <= (37.68))
        #expect((edge.player.position.x) > (37.5))
    }

    @Test func testJumpRequiresGroundAndLandsWithoutTunnelling() {
        let game = simulation()
        #expect(game.jump()); #expect(!(game.jump()))
        advance(game, 0.35)
        #expect((game.player.position.y) > (1))
        #expect(!(game.player.grounded))
        advance(game, 0.6)
        #expect(game.player.grounded); #expect((game.player.position.y) == (0))
        #expect(game.drainEvents().contains { $0.kind == .land })
    }

    @Test func testProneLowersCameraAndDisablesSprint() {
        let game = simulation()
        game.toggleProne()
        var input = GameInput(); input.moveForward = 1; input.sprint = true
        advance(game, 0.5, input: input)
        #expect(game.player.prone); #expect(!(game.isSprinting))
        #expect((game.eyePosition.y) < (0.5))
        #expect(abs((game.player.position.z) - (20 - 1.65 * 0.5)) <= 0.002)
        #expect(!(game.jump()))
        #expect(!(game.player.prone))
        #expect(game.player.grounded)
    }

    @Test func testSprintConsumesStaminaAndAimSlowsMovement() {
        let runner = simulation(), aiming = simulation()
        var input = GameInput(); input.moveForward = 1; input.sprint = true
        advance(runner, 1, input: input)
        #expect(abs((runner.player.stamina) - (81)) <= 0.01)
        #expect(abs((runner.player.position.z) - (12.5)) <= 0.01)
        input.aim = true
        advance(aiming, 1, input: input)
        #expect(aiming.isAiming); #expect(!(aiming.isSprinting))
        #expect(abs((aiming.player.position.z) - (17.2)) <= 0.01)
    }

    @Test func testMantleClimbsContainerAndDestroyedSupportFalls() {
        let game = simulation(world: [obstacle()], position: SIMD3(0, 0, 5))
        #expect(game.mantleAvailable); #expect(game.mantle())
        #expect(!(game.jump()))
        advance(game, 0.9)
        #expect((game.climbProgress) == nil)
        #expect(abs((game.player.position.y) - (3.1)) <= 0.01)
        #expect(game.player.grounded)
        game.damageCover(index: 0, amount: 1000)
        advance(game, 1)
        #expect(abs((game.player.position.y) - (0)) <= 0.001)
        #expect(game.player.grounded)
    }

    @Test func testDestroyedMantleTargetCancelsClimbSafely() {
        let game = simulation(world: [obstacle()], position: SIMD3(0, 0, 5))
        #expect(game.mantle())
        advance(game, 0.3)
        game.damageCover(index: 0, amount: 1000)
        advance(game, 1)
        #expect((game.climbProgress) == nil)
        #expect((game.player.position.y) == (0))
        #expect(!(game.blocked(game.player.position)))
    }

    @Test func testSniperAimedHeadshotAwardsBonusAndConsumesAmmo() {
        let game = simulation(position: SIMD3(0, 0, 10), enemies: [EnemyState(id: 1, position: .zero)])
        game.selectWeapon(.sniper)
        var input = GameInput(); input.aim = true; input.fire = true
        advance(game, 1.0 / 120, input: input)
        #expect((game.kills) == (1)); #expect((game.score) == (150))
        #expect((game.weapons[.sniper]?.ammo) == (4))
        #expect((game.enemies[0].deathTime) != nil)
        #expect(game.drainEvents().contains { $0.kind == .kill && $0.headshot })
    }

    @Test func testCoverBlocksShotsAndCanBeDestroyed() {
        let box = obstacle(0, .crate, at: SIMD3(0, 0, 5), size: SIMD3(3, 3, 1))
        let game = simulation(world: [box], position: SIMD3(0, 0, 10), enemies: [EnemyState(id: 1, position: .zero)])
        game.selectWeapon(.sniper)
        var input = GameInput(); input.aim = true; input.fire = true
        advance(game, 1.0 / 120, input: input)
        #expect((game.enemies[0].health) == (100))
        #expect((game.obstacles[0].health) == (5))
        advance(game, 1.2, input: input)
        #expect(game.obstacles[0].destroyed)
        #expect((game.enemies[0].health) == (100))
        let exposedHead = game.enemies[0].position + SIMD3<Float>(0, 1.73, 0)
        let trace = game.traceShot(origin: game.eyePosition, direction: simd_normalize(exposedHead - game.eyePosition))
        #expect(trace.enemyIndex == 0)
    }

    @Test func testAutomaticFireRateReloadAndWeaponSwitchAreIndependent() {
        let game = simulation()
        var input = GameInput(); input.fire = true
        advance(game, 0.5, input: input)
        #expect((game.weapons[.rifle]?.ammo) == (25))
        #expect(game.reload()); #expect(!(game.reload()))
        game.selectWeapon(.sniper)
        advance(game, 0.2, input: input)
        #expect((game.weapons[.sniper]?.ammo) == (4))
        advance(game, 1.7)
        #expect((game.weapons[.rifle]?.ammo) == (30))
        #expect((game.weapons[.rifle]?.reserve) == (205))
        #expect((game.activeWeapon) == (.sniper))
    }

    @Test func testGrenadeFuseIsDelayedAndThrowCooldownPreventsSpam() {
        let game = simulation(position: SIMD3(0, 0, 30))
        #expect(game.throwGrenade()); #expect(!(game.throwGrenade()))
        #expect((game.grenadeCount) == (3))
        advance(game, 2.75)
        #expect((game.grenades.count) == (1))
        #expect(!(game.drainEvents().contains { $0.kind == .explosion }))
        advance(game, 0.1)
        #expect(game.grenades.isEmpty)
        #expect((game.drainEvents().filter { $0.kind == .explosion }.count) == (1))
    }

    @Test func testGrenadeBouncesOffSolidWall() {
        let wall = obstacle(0, .bunker, at: SIMD3(0, 0, 6), size: SIMD3(10, 10, 1))
        let game = simulation(world: [wall], position: SIMD3(0, 0, 10))
        #expect(game.throwGrenade())
        advance(game, 0.3)
        #expect((game.grenades[0].velocity.z) > (0))
        #expect((game.grenades[0].position.z) > (6.5))
    }

    @Test func testExplosionsRespectCoverAndCauseSelfDamage() {
        let wall = obstacle(0, .bunker, at: .zero, size: SIMD3(10, 5, 1))
        let sheltered = simulation(world: [wall], position: SIMD3(0, 0, 3), enemies: [EnemyState(id: 1, position: SIMD3(0, 0, -3))])
        sheltered.explode(at: SIMD3(0, 0.1, -2))
        #expect((sheltered.player.health) == (100))
        #expect((sheltered.kills) == (1))
        #expect(!(sheltered.obstacles[0].destroyed))
        let exposed = simulation(position: SIMD3(0, 0, 3))
        exposed.explode(at: SIMD3(0, 0.1, 0))
        #expect((exposed.player.health) < (20))
    }

    @Test func testBarrelChainsDetonateEachBarrelOnce() {
        let barrels = [obstacle(1, .barrel, at: SIMD3(0, 0, 0), size: SIMD3(0.8, 1.15, 0.8)),
                       obstacle(2, .barrel, at: SIMD3(3, 0, 0), size: SIMD3(0.8, 1.15, 0.8)),
                       obstacle(3, .crate, at: SIMD3(6, 0, 0), size: SIMD3(1, 1, 1))]
        let game = simulation(world: barrels)
        game.damageCover(index: 0, amount: 60)
        #expect(game.obstacles.allSatisfy { $0.destroyed })
        #expect((game.score) == (75))
        #expect((game.drainEvents().filter { $0.kind == .explosion }.count) == (2))
        game.damageCover(index: 1, amount: 100)
        #expect(game.drainEvents().isEmpty)
    }

    @Test func testBlastOcclusionIsEvaluatedBeforeCoverDestruction() {
        let shield = obstacle(0, .container, at: .zero, size: SIMD3(8, 4, 1))
        let hiddenCrate = obstacle(1, .crate, at: SIMD3(0, 0, 2), size: SIMD3(1, 1, 1))
        let game = simulation(world: [shield, hiddenCrate])
        game.explode(at: SIMD3(0, 0.1, -1))
        #expect(game.obstacles[0].destroyed)
        #expect((game.obstacles[1].health) == (110))
    }

    @Test func testRegenerationWaitsAndResetsWhenHitAgain() {
        let game = simulation()
        game.damagePlayer(amount: 50, from: .zero)
        advance(game, 5)
        #expect((game.player.health) == (50))
        game.damagePlayer(amount: 10, from: .zero)
        advance(game, 5)
        #expect((game.player.health) == (40))
        advance(game, 1.5)
        #expect(abs((game.player.health) - (48)) <= 0.1)
    }

    @Test func testPathfindingRoutesAroundCoverAndRefreshesAfterDestruction() {
        let wall = obstacle(0, .container, at: .zero, size: SIMD3(14, 3.1, 4))
        let game = simulation(world: [wall])
        let from = SIMD3<Float>(0, 0, -10), to = SIMD3<Float>(0, 0, 10)
        let before = game.findPath(from: from, to: to)
        #expect(!(before.isEmpty))
        #expect(before.allSatisfy { !game.blocked($0, height: 1.9, radius: 0.48) })
        #expect(before.contains { abs($0.x) >= 8 })
        game.damageCover(index: 0, amount: 1000)
        let after = game.findPath(from: from, to: to)
        #expect((after.count) < (before.count))
        #expect(after.allSatisfy { $0.x == 0 })
    }

    @Test func testUnawareEnemyCannotTrackThroughWallsButCanHearGunfire() {
        let wall = obstacle(0, .bunker, at: .zero, size: SIMD3(10, 6, 2))
        let game = simulation(world: [wall], position: SIMD3(0, 0, 10), enemies: [EnemyState(id: 1, position: SIMD3(0, 0, -10))])
        advance(game, 0.5)
        #expect(!(game.enemies[0].seesPlayer))
        #expect((game.enemies[0].position) == (SIMD3(0, 0, -10)))
        #expect(game.isHidden)
        var input = GameInput(); input.fire = true
        advance(game, 1.0 / 120, input: input)
        #expect(!(game.isHidden))
        advance(game, 0.6)
        #expect((horizontalDistance(game.enemies[0].position, SIMD3(0, 0, -10))) > (0.5))
        #expect(!(game.enemies[0].seesPlayer))
    }

    @Test func testEnemyAttackTelegraphsBeforeShooting() {
        let game = simulation(position: SIMD3(0, 0, 15), enemies: [EnemyState(id: 1, position: .zero)])
        advance(game, 2.2)
        #expect((game.enemies[0].windup) > (0))
        #expect(!(game.drainEvents().contains { $0.kind == .enemyShot }))
        advance(game, 0.6)
        #expect(game.drainEvents().contains { $0.kind == .enemyShot })
    }

    @Test func testThreeWavesThenExtractionCompletesMission() {
        let game = simulation(position: GameMap.extraction, wave: 0)
        advance(game, 1.5)
        #expect((game.wave) == (1)); #expect((game.aliveCount) == (5))
        #expect(game.enemies.allSatisfy { horizontalDistance($0.position, game.player.position) > 12 })
        for expectedWave in 2...3 {
            for index in game.enemies.indices { game.damageEnemy(index: index, amount: 1000) }
            advance(game, 7.2)
            #expect((game.wave) == (expectedWave))
            #expect((game.aliveCount) == (3 + expectedWave * 2))
        }
        for index in game.enemies.indices { game.damageEnemy(index: index, amount: 1000) }
        #expect(game.extractionReady)
        advance(game, 2.5)
        #expect((game.state) == (.active))
        advance(game, 0.6)
        #expect((game.state) == (.won))
        #expect((game.kills) == (21))
        #expect((game.score) == (2600))
        #expect((game.drainEvents().filter { $0.kind == .win }.count) == (1))
    }

    @Test func testDeathStopsClockMovementAndActions() {
        let game = simulation()
        game.damagePlayer(amount: 200, from: .zero)
        #expect((game.state) == (.lost))
        let position = game.player.position
        var input = GameInput(); input.moveForward = 1; input.fire = true
        advance(game, 1, input: input)
        #expect((game.player.position) == (position)); #expect((game.elapsed) == (0))
        #expect(!(game.jump())); #expect(!(game.throwGrenade())); #expect(!(game.reload()))
        #expect((game.drainEvents().filter { $0.kind == .lose }.count) == (1))
    }
}
