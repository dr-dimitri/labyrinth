import Foundation
import Darwin
import simd

/// Whole-core benchmark on the selected authored map. Rendering is deliberately
/// absent. Population, deaths and weather exposure remain visible in the report.
@main
enum MapCoreBenchmark {
    private struct Options {
        var mapID = "nebelwacht", spray = true, water = true, seconds = 60, samples = 5, enemyCount = 9, seed: UInt64 = 1745
        var grenades = false
        init() throws {
            let args = Array(CommandLine.arguments.dropFirst()); var index = 0
            while index < args.count {
                let flag = args[index]; index += 1
                if flag == "--grenades" { grenades = true; continue }
                guard index < args.count else { throw Failure("Missing value after \(flag)") }
                let value = args[index]; index += 1
                switch flag {
                case "--map": mapID = value
                case "--spray":
                    guard ["on","off"].contains(value) else { throw Failure("--spray must be on or off") }
                    spray = value == "on"
                case "--water":
                    guard ["on","off"].contains(value) else { throw Failure("--water must be on or off") }
                    water = value == "on"
                case "--seconds":
                    guard let parsed = Int(value), (10...300).contains(parsed) else { throw Failure("--seconds must be 10…300") }; seconds = parsed
                case "--samples":
                    guard let parsed = Int(value), (1...9).contains(parsed) else { throw Failure("--samples must be 1…9") }; samples = parsed
                case "--enemies":
                    guard let parsed = Int(value), (1...12).contains(parsed) else { throw Failure("--enemies must be 1…12") }; enemyCount = parsed
                case "--seed":
                    guard let parsed = UInt64(value) else { throw Failure("--seed must be an unsigned integer") }; seed = parsed
                default: throw Failure("Unknown map benchmark option: \(flag)")
                }
            }
        }
    }
    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = message }
    }
    private struct Sample: Codable {
        let cpuSeconds, wallSeconds, simulatedSeconds: Double
        let steps, restartsAfterPlayerDeath, minimumLivingEnemies, maximumLivingEnemies: Int
        let warningEvents, cloudEvents, peakVolumes, acceptedGrenades, explosionEvents: Int
        let playerWaterContactSteps, waterHearingEvents, waterImpactEvents: Int
        let checksum: Double
        var cpuMicrosecondsPerStep: Double { cpuSeconds * 1_000_000 / Double(steps) }
    }
    private static func definition(_ options: Options) throws -> MapDefinition {
        let original: MapDefinition
        switch options.mapID {
        case "nebelwacht": original = .nebelwacht
        case "blacksite": original = .blacksite
        case "sundkai": original = .sundkai
        case "kessel9": original = .kessel9
        default: throw Failure("Unknown map ID; use blacksite, nebelwacht, sundkai or kessel9")
        }
        guard options.enemyCount <= original.spawns.count else {
            throw Failure("Map \(original.id) has only \(original.spawns.count) authored starts")
        }
        guard !options.spray || !options.water else { return original }
        var environment = original.environment
        // Keep other smoke kinds, devices, alarms, geometry and resource data.
        if !options.spray { environment.smokeEmitters.removeAll { $0.kind == .spray } }
        if !options.water { environment.shallowWaterZones = [] }
        return try MapDefinition(id: original.id,version: original.version,displayName: original.displayName,
            minimum: original.minimum,maximum: original.maximum,terrain: original.terrain,obstacles: original.obstacles,
            playerStart: original.playerStart,spawns: original.spawns,reinforcementEntries: original.reinforcementEntries,
            waveStaging: original.waveStaging,extraction: original.extraction,extractionRadius: original.extractionRadius,
            dataSite: original.dataSite,radioSite: original.radioSite,serviceApproach: original.serviceApproach,
            roads: original.roads,supportSurfaces: original.supportSurfaces,levelProps: original.levelProps,
            scenery: original.scenery,environment: environment,resources: original.resources,
            operation: original.operation,breaches: original.breaches)
    }
    private static func scenario(_ map: MapDefinition, _ options: Options) -> CombatSimulation {
        let enemies = map.spawns.prefix(options.enemyCount).enumerated().map {
            EnemyState(id: 9000+$0.offset,position: map.grounded($0.element))
        }
        let game = CombatSimulation(difficulty: .normal,seed: options.seed,world: map.obstacles,
            startingEnemies: enemies,startingWave: 3,map: map)
        precondition(game.aliveCount == options.enemyCount)
        precondition(game.enemies.allSatisfy { !game.blocked($0.position,height: 1.9,radius: 0.4) })
        // Actual hearing/combat state initiates pursuit; no frozen or invincible AI.
        for index in game.enemies.indices { game.damageEnemy(index: index,amount: 0.01) }
        _ = game.drainEvents()
        return game
    }
    private static func cpuTime() -> Double {
        var usage = rusage(); precondition(getrusage(RUSAGE_SELF,&usage) == 0)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
            Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    private static func measure(_ map: MapDefinition, _ options: Options, seconds: Int) -> Sample {
        var game = scenario(map,options), restarts = 0, minimum = options.enemyCount, maximum = options.enemyCount
        var warnings = 0, clouds = 0, peak = 0, throwsAccepted = 0, explosions = 0, runThrows = 0
        var wetSteps = 0, wetSounds = 0, splashes = 0
        var simulated: Double = 0, checksum: Double = 0
        let steps = seconds * 120, cpuStart = cpuTime(), wallStart = ProcessInfo.processInfo.systemUptime
        for step in 0..<steps {
            if game.state == .lost { game = scenario(map,options); restarts += 1; runThrows = 0 }
            precondition(game.state == .active)
            let t = Float(step)/120
            var input = GameInput(); input.moveForward = 1; input.moveRight = sin(t*0.45)*0.6
            input.yaw = sin(t*0.2)*0.8; input.sprint = step % 960 < 240
            if options.grenades, runThrows < 3, game.elapsed + 0.000001 >= Double(runThrows)*0.75 {
                // Ordinary stock, cooldown, physics and explosions; no forced detonation.
                if game.throwGrenade() { runThrows += 1; throwsAccepted += 1 }
            }
            if step % 600 == 0 { game.jump() }
            let before = game.elapsed
            game.step(deltaTime: 1.0/120,input: input); simulated += game.elapsed-before
            if game.waterContact(at: game.player.position,grounded: game.player.grounded) != nil { wetSteps += 1 }
            minimum = min(minimum,game.aliveCount); maximum = max(maximum,game.aliveCount)
            peak = max(peak,game.smokeVolumes.count)
            if step % 2 == 1 {
                for event in game.drainEvents() {
                    if event.kind == .smokeWarning { warnings += 1 }
                    if event.kind == .smokeActivated { clouds += 1 }
                    if event.kind == .explosion { explosions += 1 }
                    if event.hearing?.surface == .water { wetSounds += 1 }
                    if event.waterImpact != nil { splashes += 1 }
                }
            }
            if step % 60 == 0 {
                checksum += Double(game.player.position.x + game.player.position.y + game.player.position.z + game.player.health)
                for enemy in game.enemies {
                    checksum += Double(enemy.position.x*0.13 + enemy.position.y*0.21 + enemy.position.z*0.37 + enemy.windup + enemy.health*0.01)
                }
                for volume in game.smokeVolumes { checksum += Double(volume.density + volume.age*0.1) }
            }
        }
        let cpu = cpuTime()-cpuStart, wall = ProcessInfo.processInfo.systemUptime-wallStart
        precondition(abs(simulated-Double(seconds)) < 0.000001)
        return Sample(cpuSeconds: cpu,wallSeconds: wall,simulatedSeconds: simulated,steps: steps,
            restartsAfterPlayerDeath: restarts,minimumLivingEnemies: minimum,maximumLivingEnemies: maximum,
            warningEvents: warnings,cloudEvents: clouds,peakVolumes: peak,acceptedGrenades: throwsAccepted,
            explosionEvents: explosions,playerWaterContactSteps: wetSteps,waterHearingEvents: wetSounds,waterImpactEvents: splashes,checksum: checksum)
    }
    static func main() throws {
        let options = try Options(), map = try definition(options)
        try map.validateGameplay()
        _ = measure(map,options,seconds: 5)
        let samples = (0..<options.samples).map { _ in measure(map,options,seconds: options.seconds) }
        let baseline = samples[0]
        let deterministic = samples.allSatisfy {
            $0.checksum == baseline.checksum && $0.restartsAfterPlayerDeath == baseline.restartsAfterPlayerDeath &&
            $0.minimumLivingEnemies == baseline.minimumLivingEnemies && $0.maximumLivingEnemies == baseline.maximumLivingEnemies &&
            $0.warningEvents == baseline.warningEvents && $0.cloudEvents == baseline.cloudEvents && $0.explosionEvents == baseline.explosionEvents &&
            $0.playerWaterContactSteps == baseline.playerWaterContactSteps && $0.waterHearingEvents == baseline.waterHearingEvents && $0.waterImpactEvents == baseline.waterImpactEvents
        }
        precondition(deterministic,"Repeated fixed-seed runs diverged")
        let medianCPU = samples.map(\.cpuSeconds).sorted()[samples.count/2]
        let sampleJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(samples))
        let report: [String: Any] = [
            "benchmark": "Native authored-map combat", "build": "Swift -O -whole-module-optimization",
            "mapID": map.id, "mapVersion": map.version, "seed": options.seed,
            "sprayEnabled": options.spray, "authoredSpraySources": map.environment.smokeEmitters.filter { $0.kind == .spray }.count,
            "waterEnabled": options.water, "authoredWaterZones": map.environment.shallowWaterZones.count,
            "initialEnemyCount": options.enemyCount, "obstacleCount": map.obstacles.count,
            "fixedFrequencyHz": 120, "sampleDurationSeconds": options.seconds, "measuredSamples": samples.count,
            "scriptedGrenades": options.grenades, "deterministic": deterministic,
            "medianCPUMicrosecondsPerStep": medianCPU*1_000_000/Double(options.seconds*120),
            "medianCPUSeconds": medianCPU, "medianWallSeconds": samples.map(\.wallSeconds).sorted()[samples.count/2],
            "scenario": "Authored starts, initially alerted live AI, scripted movement/jumps, real alarm response and optional ordinary frag throws. Death restarts are measured. Population bounds, water contacts and optical events expose differing environment workloads; this is CPU simulation cost, not GPU frame time.",
            "samples": sampleJSON
        ]
        let data = try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys])
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
