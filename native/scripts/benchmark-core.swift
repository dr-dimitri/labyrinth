import Foundation
import Darwin
import simd

/// A standalone optimized benchmark compiled with the actual core source files.
@main
enum CoreBenchmark {
    private static let enemyPositions: [SIMD3<Float>] = [
        SIMD3(9, 0, 1), SIMD3(-8, 0, 5), SIMD3(25, 0, -10), SIMD3(-11, 0, -17),
        SIMD3(2, 0, -30), SIMD3(-30, 0, 14), SIMD3(30, 0, 21), SIMD3(11, 0, -30),
        SIMD3(-28, 0, -30), SIMD3(-32, 0, 32), SIMD3(30, 0, -2), SIMD3(0, 0, 20)
    ]

    private struct Sample: Codable {
        let cpuSeconds: Double
        let wallSeconds: Double
        let steps: Int
        let simulatedSeconds: Double
        let restartsAfterPlayerDeath: Int
        let minimumLivingEnemies: Int
        let maximumLivingEnemies: Int
        let checksum: Double
        var cpuMicrosecondsPerStep: Double { cpuSeconds * 1_000_000 / Double(steps) }
    }

    private struct Report: Codable {
        let benchmark: String
        let build: String
        let scenario: String
        let seed: UInt64
        let fixedFrequencyHz: Int
        let initialEnemyCount: Int
        let obstacleCount: Int
        let vegetationZoneCount: Int
        let sampleDurationSeconds: Int
        let measuredSamples: Int
        let deterministic: Bool
        let medianCPUMicrosecondsPerStep: Double
        let medianCPUSeconds: Double
        let medianWallSeconds: Double
        let simulationSecondsPerCPUSecond: Double
        let samples: [Sample]
    }

    private static func makeScenario() -> CombatSimulation {
        let enemies = enemyPositions.enumerated().map {
            EnemyState(id: 100 + $0.offset, position: $0.element)
        }
        let game = CombatSimulation(difficulty: .normal, seed: 1745, world: GameMap.obstacles,
                                    startingPlayer: PlayerState(), startingEnemies: enemies, startingWave: 3,
                                    terrain: .battlefield, map: .blacksite)
        precondition(game.aliveCount == 12)
        precondition(game.enemies.allSatisfy { !game.blocked($0.position, height: 1.9, radius: 0.4) })
        // Alert every soldier once, exercising pursuit and route finding from the start.
        for index in game.enemies.indices { game.damageEnemy(index: index, amount: 0.01) }
        _ = game.drainEvents()
        return game
    }

    private static func processCPUTime() -> Double {
        var usage = rusage()
        precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000 +
            Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    }

    private static func measure(seconds: Int) -> Sample {
        var game = makeScenario(), restarts = 0, minimumEnemies = 12, maximumEnemies = 12
        var checksum: Double = 0, simulatedSeconds: Double = 0
        let steps = seconds * 120
        let cpuStart = processCPUTime(), wallStart = ProcessInfo.processInfo.systemUptime
        for step in 0..<steps {
            if game.state == .lost { game = makeScenario(); restarts += 1 }
            precondition(game.state == .active)
            let t = Float(step) / 120
            var input = GameInput()
            input.moveForward = 1
            input.moveRight = sin(t * 0.45) * 0.6
            input.yaw = sin(t * 0.2) * 0.8
            input.sprint = step % 960 < 240
            if step % 600 == 0 { game.jump() }
            let before = game.elapsed
            game.step(deltaTime: 1.0 / 120, input: input)
            simulatedSeconds += game.elapsed - before
            minimumEnemies = min(minimumEnemies, game.aliveCount)
            maximumEnemies = max(maximumEnemies, game.aliveCount)
            if step % 2 == 0 { _ = game.drainEvents() } // Same cadence as a 60 Hz presentation.
            if step % 60 == 0 {
                checksum += Double(game.player.position.x + game.player.position.y + game.player.position.z + game.player.health)
                for enemy in game.enemies {
                    checksum += Double(enemy.position.x * 0.13 + enemy.position.y * 0.21 + enemy.position.z * 0.37 + enemy.windup)
                }
            }
        }
        let cpu = processCPUTime() - cpuStart
        let wall = ProcessInfo.processInfo.systemUptime - wallStart
        precondition(abs(simulatedSeconds - Double(seconds)) < 0.000_001)
        precondition(minimumEnemies == 12)
        return Sample(cpuSeconds: cpu, wallSeconds: wall, steps: steps, simulatedSeconds: simulatedSeconds,
                      restartsAfterPlayerDeath: restarts, minimumLivingEnemies: minimumEnemies,
                      maximumLivingEnemies: maximumEnemies, checksum: checksum)
    }

    static func main() throws {
        _ = measure(seconds: 5) // Warm up code, caches, and allocator before measurement.
        let samples = (0..<5).map { _ in measure(seconds: 60) }
        let medianCPU = samples.map(\.cpuSeconds).sorted()[samples.count / 2]
        let medianWall = samples.map(\.wallSeconds).sorted()[samples.count / 2]
        let deterministic = samples.allSatisfy {
            $0.checksum == samples[0].checksum && $0.restartsAfterPlayerDeath == samples[0].restartsAfterPlayerDeath
        }
        precondition(deterministic, "The fixed-seed simulation produced inconsistent state checksums")
        let report = Report(benchmark: "Blacksite native combat simulation", build: "Swift -O -whole-module-optimization",
                            scenario: "Battlefield hills and hollows, initially 12 alerted AI soldiers plus any real alarm response, scripted movement/jumps. Restart on player death keeps every measured step active; enemies are never removed. Per-sample population bounds expose changes in combat workload.",
                            seed: 1745, fixedFrequencyHz: 120, initialEnemyCount: 12, obstacleCount: GameMap.obstacles.count,
                            vegetationZoneCount: MapDefinition.blacksite.environment.vegetationZones.count,
                            sampleDurationSeconds: 60, measuredSamples: samples.count, deterministic: deterministic,
                            medianCPUMicrosecondsPerStep: medianCPU * 1_000_000 / 7200,
                            medianCPUSeconds: medianCPU, medianWallSeconds: medianWall,
                            simulationSecondsPerCPUSecond: 60 / medianCPU, samples: samples)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
