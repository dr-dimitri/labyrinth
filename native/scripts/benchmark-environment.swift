import Foundation
import Darwin
import simd

/// A deliberately dense synthetic perception query complements the full combat
/// benchmark. It measures query cost, not frame time or the entire AI update.
@main
enum EnvironmentBenchmark {
    private static func scenario(zones: Int) throws -> CombatSimulation {
        var environment = MapEnvironmentDefinition()
        environment.vegetationZones = (0..<zones).map {
            EnvironmentZone(id: "overlap-\($0)", center: SIMD2(0,15), radii: SIMD2(1.7,2.7),
                            height: 1.2, density: 0.7, kind: .brush)
        }
        var player = PlayerState(position: SIMD3(0,0,15)); player.prone = true; player.height = 0.57
        let map = try MapDefinition(id: "perception-benchmark", displayName: "Perception benchmark",
            minimum: SIMD3(-24,0,-24), maximum: SIMD3(24,0,24), terrain: .flat,
            playerStart: player, reinforcementEntries: [SIMD3(0,0,-20)], waveStaging: [SIMD3(0,0,-12)],
            extraction: SIMD3(0,0,-20), dataSite: SIMD3(-12,0,10), radioSite: SIMD3(12,0,10), environment: environment)
        return CombatSimulation(seed: 1745, world: [], startingPlayer: player, map: map)
    }
    private static func cpuTime() -> Double {
        var usage = rusage(); precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
            Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    private static func measure(_ game: CombatSimulation, queries: Int) -> (Double, Double) {
        var checksum: Double = 0
        let start = cpuTime()
        for index in 0..<queries {
            let observer = SIMD3<Float>(Float(index % 41 - 20) * 0.02, 1.68, -5)
            let factor = game.vegetationRecognitionFactor(from: observer)
            precondition(factor >= 0.25 && factor <= 1)
            checksum += Double(factor)
        }
        return ((cpuTime() - start) * 1_000_000 / Double(queries), checksum)
    }
    static func main() throws {
        var rows: [[String: Any]] = []
        for count in [0, 1, 16] {
            let game = try scenario(zones: count)
            _ = measure(game, queries: 1000)
            let samples = (0..<5).map { _ in measure(game, queries: 10_000) }
            precondition(samples.allSatisfy { $0.1 == samples[0].1 })
            rows.append(["overlappingZones": count, "queriesPerSample": 10_000,
                         "samples": samples.map { $0.0 }, "checksum": samples[0].1,
                         "medianCPUMicrosecondsPerQuery": samples.map { $0.0 }.sorted()[2]])
        }
        let report: [String: Any] = ["benchmark": "Unconfirmed prone-player vegetation perception query",
            "build": "Swift -O -whole-module-optimization", "samplesPerScenario": 5,
            "note": "Synthetic overlapping foliage stresses the bounded query, including hard sight and body samples. This is not a frame-rate measurement.",
            "scenarios": rows]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
