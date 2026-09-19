import Testing
import simd
@testable import BlacksiteCore

@Suite(.serialized)
struct EnemyAwarenessTests {
    private func game(player: SIMD3<Float> = SIMD3(0, 0, 15), enemy: SIMD3<Float> = .zero,
                      yaw: Float = 0, world: [Obstacle] = []) -> CombatSimulation {
        var guardState = EnemyState(id: 1, position: enemy); guardState.yaw = yaw
        return CombatSimulation(seed: 41, world: world, startingPlayer: PlayerState(position: player),
                                startingEnemies: [guardState], startingWave: 3)
    }
    private func advance(_ game: CombatSimulation, _ seconds: Double, input: GameInput = GameInput()) {
        for _ in 0..<Int((seconds * 120).rounded()) { game.step(deltaTime: 1.0 / 120, input: input) }
    }
    private var wall: Obstacle {
        Obstacle(id: 7, kind: .bunker, position: .zero, size: SIMD3(60, 6, 2))
    }

    @Test func frontDetectionHasReactionPhaseAndOnlyOneAlertPerContact() {
        let simulation = game()
        advance(simulation, 0.2)
        #expect(simulation.enemies[0].awareness == .watching)
        #expect(simulation.enemies[0].detectionProgress > 0 && simulation.enemies[0].detectionProgress < 1)
        #expect(!simulation.enemies[0].seesPlayer)
        #expect(simulation.enemies[0].windup == 0)
        #expect(!simulation.drainEvents().contains { $0.kind == .enemyShot || $0.kind == .enemyAlert })
        advance(simulation, 0.6)
        #expect(simulation.enemies[0].awareness == .engaged)
        #expect(simulation.enemies[0].seesPlayer)
        #expect(simulation.drainEvents().filter { $0.kind == .enemyAlert }.count == 1)
        advance(simulation, 1.4)
        #expect(simulation.enemies[0].windup > 0)
        #expect(!simulation.drainEvents().contains { $0.kind == .enemyAlert || $0.kind == .enemyShot })
        advance(simulation, 0.5)
        #expect(simulation.drainEvents().contains { $0.kind == .enemyShot })
    }

    @Test func sideAndRearStayUnseenUntilGuardTurnsButGuardsRemainActive() {
        for position in [SIMD3<Float>(15, 0, 0), SIMD3<Float>(0, 0, -12)] {
            let simulation = game(player: position)
            advance(simulation, 0.3)
            #expect(simulation.enemies[0].detectionProgress == 0)
            #expect(!simulation.enemies[0].seesPlayer)
            var detected = false
            for _ in 0..<1200 {
                simulation.step(deltaTime: 1.0 / 120, input: GameInput())
                detected = detected || simulation.enemies[0].seesPlayer
            }
            #expect(detected)
        }
        let quiet = game(player: SIMD3(-35, 0, -35), enemy: SIMD3(30, 0, 30))
        advance(quiet, 8)
        #expect(quiet.enemies[0].awareness == .watching)
        #expect(quiet.enemies[0].walkCycle > 3)
        #expect(horizontalDistance(quiet.enemies[0].position, SIMD3(30, 0, 30)) > 1)
    }

    @Test func hearingStoresTheShotLocationWithoutFollowingHiddenMovement() {
        let stationary = game(player: SIMD3(0, 0, 10), enemy: SIMD3(0, 0, -10), world: [wall])
        let relocating = game(player: SIMD3(0, 0, 10), enemy: SIMD3(0, 0, -10), world: [wall])
        var shot = GameInput(); shot.fire = true
        advance(stationary, 1.0 / 120, input: shot); advance(relocating, 1.0 / 120, input: shot)
        #expect(stationary.enemies[0].awareness == .investigating)
        var walk = GameInput(); walk.moveRight = 1
        advance(stationary, 4); advance(relocating, 4, input: walk)
        #expect(relocating.player.position.x > 18)
        #expect(!stationary.enemies[0].seesPlayer && !relocating.enemies[0].seesPlayer)
        #expect(simd_distance(stationary.enemies[0].position, relocating.enemies[0].position) < 0.0001)
        #expect(abs(stationary.enemies[0].yaw - relocating.enemies[0].yaw) < 0.0001)
        #expect(!relocating.drainEvents().contains { $0.kind == .enemyShot || $0.kind == .enemyAlert })
        advance(stationary, 3)
        #expect(stationary.enemies[0].isMoving)
        #expect(stationary.enemies[0].awareness == .investigating)
    }

    @Test func explosionInvestigationUsesBlastSourceRatherThanCurrentPlayerPosition() {
        let first = game(player: SIMD3(0, 0, 12), enemy: SIMD3(0, 0, -20), world: [wall])
        let second = game(player: SIMD3(15, 0, 12), enemy: SIMD3(0, 0, -20), world: [wall])
        for simulation in [first, second] {
            simulation.explode(at: SIMD3(0, 0.1, -26))
            #expect(simulation.enemies[0].health > 0 && simulation.enemies[0].health < 100)
            #expect(simulation.enemies[0].awareness == .investigating)
            advance(simulation, 3)
        }
        #expect(simd_distance(first.enemies[0].position, second.enemies[0].position) < 0.0001)
        #expect(first.enemies[0].position.z < -24)
        #expect(first.enemies[0].awareness == .searching)
        advance(first, 6)
        #expect(first.enemies[0].awareness == .watching)
        #expect(!first.enemies[0].seesPlayer)
        #expect(first.enemies[0].walkCycle > 5)
    }

    @Test func lostSightCancelsShotAndReacquisitionRequiresFullWindup() {
        let cover = Obstacle(id: 1, kind: .barrier, position: SIMD3(0, 0, 14.1), size: SIMD3(12, 0.9, 0.6))
        let simulation = game(world: [cover])
        advance(simulation, 2.15)
        #expect(simulation.enemies[0].windup > 0)
        _ = simulation.drainEvents()
        simulation.toggleProne()
        advance(simulation, 0.6)
        #expect(!simulation.enemies[0].seesPlayer)
        #expect(simulation.enemies[0].awareness == .searching)
        #expect(simulation.enemies[0].windup == 0)
        #expect(!simulation.drainEvents().contains { $0.kind == .enemyShot })
        simulation.toggleProne()
        var reacquired = false
        for _ in 0..<180 {
            simulation.step(deltaTime: 1.0 / 120, input: GameInput())
            #expect(!simulation.drainEvents().contains { $0.kind == .enemyShot })
            if simulation.enemies[0].windup > 0 { reacquired = true; break }
        }
        #expect(reacquired)
        #expect(simulation.enemies[0].windup > 0.63)
        advance(simulation, 0.5)
        #expect(!simulation.drainEvents().contains { $0.kind == .enemyShot })
        advance(simulation, 0.2)
        #expect(simulation.drainEvents().contains { $0.kind == .enemyShot })
    }

    @Test func initialWaveApproachesTheBattlefieldWithoutSecretPlayerKnowledge() {
        let simulation = CombatSimulation(seed: 41)
        simulation.spawnWave()
        let starts = simulation.enemies.map(\.position)
        advance(simulation, 1.5)
        #expect(zip(starts, simulation.enemies).filter { horizontalDistance($0.0, $0.1.position) > 1 }.count >= 3)
    }

    @Test func awarenessAndPatrolRemainDeterministicAcrossFrameRatesAndPause() {
        let slow = game(player: SIMD3(-35, 0, -35), enemy: SIMD3(30, 0, 30))
        let fast = game(player: SIMD3(-35, 0, -35), enemy: SIMD3(30, 0, 30))
        for _ in 0..<240 { slow.step(deltaTime: 1.0 / 30, input: GameInput()) }
        advance(fast, 8)
        #expect(simd_distance(slow.enemies[0].position, fast.enemies[0].position) < 0.0001)
        #expect(slow.enemies[0].yaw == fast.enemies[0].yaw)
        #expect(slow.enemies[0].awareness == fast.enemies[0].awareness)
        let position = fast.enemies[0].position, yaw = fast.enemies[0].yaw
        for _ in 0..<120 { fast.step(deltaTime: 0, input: GameInput()) }
        #expect(fast.enemies[0].position == position && fast.enemies[0].yaw == yaw)
    }
}
