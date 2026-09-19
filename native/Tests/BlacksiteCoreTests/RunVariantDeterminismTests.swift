import Testing
import simd
@testable import BlacksiteCore

struct RunVariantDeterminismTests {
    @Test func equalInputSequencesReplayCompleteCombatAndEnvironmentalEvents() throws {
        let maps: [MapDefinition] = [.blacksite, .nebelwacht, .sundkai, .kessel9, .sirocco]
        for map in maps {
            #expect(map.version == 2)
            let catalog = try RunVariantCatalog.variants(for: map)
            var replayedIDs = Set<String>()
            for index in 0..<3 {
                let seed = UInt64((index + 3 - (map.version - 1) % 3) % 3)
                let variant = try RunVariantCatalog.resolve(map: map, seed: seed)
                #expect(variant.id == catalog[index].id)
                replayedIDs.insert(variant.id)
                var player = variant.map.playerStart
                player.position = variant.map.grounded(player.position)
                player.health = 1_000_000
                // Suppress the initial health-regeneration clamp while awaiting
                // first contact; damage still emits normally in both replays.
                player.lastHit = 120
                let a = CombatSimulation(seed: seed, world: variant.map.obstacles,
                    startingPlayer: player, mission: .operation, map: variant.map)
                let b = CombatSimulation(seed: seed, world: variant.map.obstacles,
                    startingPlayer: player, mission: .operation, map: variant.map)
                var input = GameInput(), emittedSpraySources = Set<Int>()
                for tick in 0..<2520 {
                    input.yaw = tick < 300 ? 0 : -.pi / 2
                    input.moveForward = tick < 300 ? 0.4 : 0
                    input.fire = tick == 1 || (tick > 360 && tick < 400)
                    if tick == 120 { #expect(a.throwGrenade() == b.throwGrenade()) }
                    a.step(deltaTime: 1.0 / 120, input: input)
                    b.step(deltaTime: 1.0 / 120, input: input)
                    let eventsA = a.drainEvents(), eventsB = b.drainEvents()
                    #expect(eventsA.map(EventFingerprint.init) == eventsB.map(EventFingerprint.init),
                            "map=\(map.id), variant=\(variant.id), tick=\(tick)")
                    for event in eventsA where event.kind == .smokeActivated && event.smoke?.kind == .spray {
                        if let id = event.smoke?.sourceEmitterID { emittedSpraySources.insert(id) }
                    }
                    #expect(playerFingerprint(a.player) == playerFingerprint(b.player))
                    #expect(a.enemies.map(EnemyFingerprint.init) == b.enemies.map(EnemyFingerprint.init))
                    #expect(a.runStatistics == b.runStatistics)
                    #expect(a.state == b.state && a.elapsed == b.elapsed)
                }
                #expect(a.state == .active && abs(a.elapsed - 21) < 0.000_001)
                if map.id == "nebelwacht" {
                    let sources = variant.map.environment.smokeEmitters.filter { $0.kind == .spray }
                    #expect(sources.allSatisfy { $0.firstEmissionTime(seed: seed) <= 20 })
                    #expect(emittedSpraySources == Set(sources.map(\.id)))
                }
            }
            #expect(replayedIDs == Set(catalog.map(\.id)))
        }
    }
}

/// Preserve optionality and numeric types; absent payloads must differ from
/// present payloads with empty strings, zero values or negative IDs.
private struct SnapshotFingerprint: Equatable {
    var names: [String?] = []
    var integers: [Int?] = []
    var vectors: [SIMD3<Float>] = []
    var floats: [Float] = []
    var times: [Double?] = []
    var flags: [Bool] = []
}

private struct EventFingerprint: Equatable {
    let event: SnapshotFingerprint
    let surfaceImpact: SurfaceImpact?
    let waterImpact: WaterImpact?
    let warning: SmokeWarning?
    let mark: ReconMark?
    let hearing: SnapshotFingerprint?
    let noiseEmitter: SnapshotFingerprint?
    let device: SnapshotFingerprint?
    let contactReport: SnapshotFingerprint?
    let smoke: SnapshotFingerprint?
    let breach: SnapshotFingerprint?
    let charge: SnapshotFingerprint?
    let operationObjective: SnapshotFingerprint?

    init(_ value: GameEvent) {
        event = SnapshotFingerprint(
            names: [value.kind.rawValue, value.weapon?.rawValue, value.missionPhase?.rawValue, value.extractionID],
            integers: [value.id, value.count, value.alarmReportID], vectors: [value.position, value.endPosition],
            floats: [value.amount], flags: [value.headshot])
        surfaceImpact = value.surfaceImpact; waterImpact = value.waterImpact
        warning = value.warning; mark = value.mark
        hearing = value.hearing.map {
            SnapshotFingerprint(names: [$0.kind.rawValue, $0.surface?.rawValue, $0.source.rawValue],
                integers: [$0.id, $0.sourceID], vectors: [$0.position], floats: [$0.strength, $0.range], times: [$0.time])
        }
        noiseEmitter = value.noiseEmitter.map {
            SnapshotFingerprint(integers: [$0.id, $0.ownerObstacleID], vectors: [$0.position],
                floats: [$0.strength, $0.range], flags: [$0.enabled])
        }
        device = value.device.map {
            SnapshotFingerprint(names: [$0.kind.rawValue], integers: [$0.id, $0.ownerObstacleID],
                vectors: $0.interactionPoints + [$0.closedPosition], floats: [$0.gateProgress, $0.interactionProgress],
                flags: [$0.enabled, $0.powered, $0.destroyed, $0.targetOpen, $0.isMoving,
                        $0.blockedByActor, $0.navigationClear, $0.manualMotion])
        }
        contactReport = value.contactReport.map(contactFingerprint)
        smoke = value.smoke.map {
            SnapshotFingerprint(names: [$0.kind.rawValue], integers: [$0.id, $0.sourceEmitterID],
                vectors: [$0.position, $0.origin, $0.maximumRadii, $0.clipMinimum, $0.clipMaximum, $0.radii],
                floats: [$0.peakDensity, $0.lifetime, $0.age, $0.density], times: [$0.createdAt])
        }
        breach = value.breach.map {
            SnapshotFingerprint(names: [$0.kind.rawValue, $0.visibility.rawValue, $0.damageStage.rawValue],
                integers: [$0.ownerObstacleID, $0.id], vectors: [$0.position, $0.size],
                times: [$0.openedAt], flags: [$0.isOpen])
        }
        charge = value.charge.map {
            SnapshotFingerprint(integers: [$0.id, $0.ownerObstacleID, $0.remainingTicks],
                vectors: [$0.position, $0.normal, $0.velocity], floats: [$0.fuse],
                times: [$0.createdAt], flags: [$0.attached, $0.resting])
        }
        operationObjective = value.operationObjective.map {
            SnapshotFingerprint(names: [$0.id, $0.title, $0.stageID, $0.kind.rawValue, $0.interruption?.rawValue],
                integers: [$0.ownerObstacleID], vectors: [$0.position], floats: [$0.progress, $0.requiredProgress],
                flags: [$0.completed, $0.available])
        }
    }
}

private func contactFingerprint(_ report: ContactReport) -> SnapshotFingerprint {
    SnapshotFingerprint(names: [report.channel.rawValue], integers: [report.id, report.enemyID],
        vectors: [report.contactPosition], times: [report.contactTime, report.transmittedAt, report.expiresAt])
}

private func playerFingerprint(_ player: PlayerState) -> SnapshotFingerprint {
    SnapshotFingerprint(vectors: [player.position],
        floats: [player.yaw, player.pitch, player.height, player.health, player.stamina, player.verticalVelocity],
        times: [player.lastHit], flags: [player.prone, player.grounded, player.exhausted])
}

private struct EnemyFingerprint: Equatable {
    let state: SnapshotFingerprint
    let lastHeard: SnapshotFingerprint?
    let lastContactReport: SnapshotFingerprint?

    init(_ enemy: EnemyState) {
        state = SnapshotFingerprint(names: [enemy.awareness.rawValue], integers: [enemy.id], vectors: [enemy.position],
            floats: [enemy.health, enemy.yaw, enemy.walkCycle, enemy.windup, enemy.detectionProgress,
                     enemy.crouchAmount, enemy.aimPitch, enemy.aimBlend, enemy.recoil, enemy.verticalVelocity],
            times: [enemy.deathTime], flags: [enemy.seesPlayer, enemy.isMoving, enemy.isRunning, enemy.grounded])
        lastHeard = enemy.lastHeard.map {
            SnapshotFingerprint(names: [$0.kind.rawValue], vectors: [$0.position], times: [$0.time])
        }
        lastContactReport = enemy.lastContactReport.map(contactFingerprint)
    }
}
