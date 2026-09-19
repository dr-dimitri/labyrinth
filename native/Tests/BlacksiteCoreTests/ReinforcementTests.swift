import Testing
import simd
@testable import BlacksiteCore

@Suite(.serialized)
struct ReinforcementTests {
    private func advance(_ simulation: CombatSimulation, _ seconds: Double, input: GameInput = GameInput()) {
        for _ in 0..<Int((seconds * 120).rounded()) { simulation.step(deltaTime: 1.0 / 120, input: input) }
    }
    private var sealedArena: Obstacle {
        Obstacle(id: 1, kind: .crate, position: .zero, size: SIMD3(76, 3, 84))
    }

    @Test func completeBodyMustBeBehindCameraOrOneIntactOccluder() {
        let player = PlayerState(position: SIMD3(0, 0, 20))
        let open = CombatSimulation(world: [], startingPlayer: player, startingWave: 3)
        #expect(!open.reinforcementIsHidden(at: .zero))
        #expect(open.reinforcementIsHidden(at: SIMD3(20, 0, 30)))
        let low = Obstacle(id: 1, kind: .crate, position: SIMD3(0, 0, 10), size: SIMD3(5, 1, 2))
        let partial = CombatSimulation(world: [low], startingPlayer: player, startingWave: 3)
        #expect(!partial.reinforcementIsHidden(at: .zero))
        let tall = Obstacle(id: 1, kind: .container, position: SIMD3(0, 0, 10), size: SIMD3(5, 4, 2))
        let covered = CombatSimulation(world: [tall], startingPlayer: player, startingWave: 3)
        #expect(covered.reinforcementIsHidden(at: .zero))
        covered.damageCover(index: 0, amount: 1000)
        #expect(!covered.reinforcementIsHidden(at: .zero))
    }

    @Test func partialPathDoesNotProveReachabilityAndThinWallsBlockConnections() {
        // z=1 falls between the two-metre navigation rows. Neither endpoint
        // lies inside this thin wall, so checking only cells would miss it.
        let wall = Obstacle(id: 1, kind: .crate, position: SIMD3(0, 0, 1), size: SIMD3(76, 4, 0.25))
        let simulation = CombatSimulation(world: [wall], startingWave: 3)
        let from = SIMD3<Float>(0, 0, -20), to = SIMD3<Float>(0, 0, 20)
        #expect(!simulation.findPath(from: from, to: to).isEmpty)
        #expect(!simulation.hasReachableRoute(from: from, to: to))
        simulation.damageCover(index: 0, amount: 1000)
        #expect(simulation.hasReachableRoute(from: from, to: to))
    }

    @Test func pendingEnemiesRetryOnScheduleAndPreventPrematureExtraction() {
        let simulation = CombatSimulation(world: [sealedArena], startingWave: 2)
        simulation.spawnWave()
        #expect(simulation.wave == 3 && simulation.aliveCount == 0 && simulation.pendingReinforcements == 9)
        #expect(simulation.remainingEnemies == 9 && !simulation.extractionReady)
        simulation.spawnWave()
        #expect(simulation.wave == 3 && simulation.pendingReinforcements == 9)
        advance(simulation, 0.1)
        #expect(!simulation.drainEvents().contains { $0.kind == .extractionUnlocked || $0.kind == .waveCleared })
        simulation.damageCover(index: 0, amount: 1000)
        advance(simulation, 0.2)
        #expect(simulation.aliveCount == 0)
        advance(simulation, 0.25)
        #expect(simulation.aliveCount > 0)
        #expect(simulation.aliveCount + simulation.pendingReinforcements == 9)
        #expect(!simulation.extractionReady)
        var arrivals = simulation.drainEvents().filter { $0.kind == .reinforcementsArrived }
        for _ in 0..<8 {
            for index in simulation.enemies.indices { simulation.damageEnemy(index: index, amount: 1000) }
            advance(simulation, 0.55)
            arrivals += simulation.drainEvents().filter { $0.kind == .reinforcementsArrived }
            if simulation.remainingEnemies == 0 { break }
        }
        #expect(arrivals.count == 9 && Set(arrivals.map(\.id)).count == 9)
        #expect(simulation.kills == 9 && simulation.pendingReinforcements == 0)
        #expect(simulation.extractionReady)
    }

    @Test func impossibleArenaKeepsWavePendingWithoutRepeatedWaveEventsOrFalseVictory() {
        let simulation = CombatSimulation(world: [sealedArena], startingWave: 0)
        simulation.spawnWave()
        advance(simulation, 12)
        #expect(simulation.wave == 1 && simulation.pendingReinforcements == 5)
        #expect(simulation.aliveCount == 0 && simulation.state == .active)
        #expect(simulation.intermission == 0 && !simulation.extractionReady)
        let events = simulation.drainEvents()
        #expect(events.filter { $0.kind == .waveStarted }.count == 1)
        #expect(!events.contains { $0.kind == .waveCleared || $0.kind == .reinforcementsArrived || $0.kind == .win })
    }

    @Test func realMapDeploysFullFinalWaveAcrossViewsElevationsAndDestroyedCover() {
        let terrain = TerrainProfile.battlefield
        let positions: [SIMD3<Float>] = [SIMD3(0, 0, 32), SIMD3(0, 0, -35), SIMD3(16, 0, 24),
            SIMD3(-15, terrain.height(x: -15, z: 14) + 3.1, 14),
            SIMD3(-22, terrain.height(x: -22, z: -12) + 5.6, -12),
            SIMD3(24, terrain.height(x: 24, z: -27) + 7.2, -27)]
        for destroyed in [false, true] {
            let world = GameMap.obstacles.map { original in
                var obstacle = original
                if destroyed && obstacle.kind != .bunker { obstacle.destroyed = true; obstacle.health = 0 }
                return obstacle
            }
            for position in positions { for yaw: Float in [0, .pi / 2, .pi, -.pi / 2] { for pitch: Float in [-1.4, 0, 1.4] {
                var player = PlayerState(position: position); player.yaw = yaw; player.pitch = pitch
                let simulation = CombatSimulation(seed: 41, world: world, startingPlayer: player, startingWave: 2, terrain: terrain)
                simulation.spawnWave()
                var arrivals = simulation.drainEvents().filter { $0.kind == .reinforcementsArrived }
                #expect(arrivals.allSatisfy { simulation.reinforcementIsHidden(at: $0.position) })
                var input = GameInput(); input.yaw = yaw; input.pitch = pitch
                for _ in 0..<240 where simulation.pendingReinforcements > 0 {
                    simulation.step(deltaTime: 1.0 / 120, input: input)
                    let next = simulation.drainEvents().filter { $0.kind == .reinforcementsArrived }
                    #expect(next.allSatisfy { simulation.reinforcementIsHidden(at: $0.position) })
                    arrivals += next
                }
                #expect(simulation.pendingReinforcements == 0, "position=\(position), yaw=\(yaw), pitch=\(pitch), destroyed=\(destroyed)")
                #expect(arrivals.count == 9)
                #expect(Set(arrivals.map(\.id)).count == 9)
                for event in arrivals {
                    #expect(abs(event.position.y - terrain.height(x: event.position.x, z: event.position.z)) < 0.001)
                    #expect(!simulation.blocked(event.position, height: 2, radius: 0.6))
                    #expect(horizontalDistance(event.position, event.endPosition) >= 14)
                }
            } } }
        }
    }

    @Test func delayedFirstWaveStillCompletesExactlyThreeWavesAndOneExtraction() {
        let simulation = CombatSimulation(world: [sealedArena], startingPlayer: PlayerState(position: GameMap.extraction))
        advance(simulation, 1.5)
        #expect(simulation.pendingReinforcements == 5)
        simulation.damageCover(index: 0, amount: 1000)
        advance(simulation, 0.6)
        #expect(simulation.aliveCount == 5 && simulation.pendingReinforcements == 0)
        for completed in 1...3 {
            #expect(simulation.wave == completed)
            for index in simulation.enemies.indices { simulation.damageEnemy(index: index, amount: 1000) }
            advance(simulation, completed < 3 ? 7.1 : 3.1)
        }
        #expect(simulation.state == .won && simulation.kills == 21)
        let events = simulation.drainEvents()
        #expect(events.filter { $0.kind == .waveStarted }.map(\.count) == [1, 2, 3])
        #expect(events.filter { $0.kind == .reinforcementsArrived }.count == 21)
        #expect(events.filter { $0.kind == .extractionUnlocked }.count == 1)
        #expect(events.filter { $0.kind == .win }.count == 1)
    }
}
