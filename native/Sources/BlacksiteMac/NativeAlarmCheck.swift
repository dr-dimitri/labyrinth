import Foundation
import simd
import BlacksiteCore

/// A small diagnostic arena exercises the actual recognition/reporting rules.
/// It isolates those rules from a full combat mission, not from collision or AI.
@MainActor
enum NativeAlarmCheck {
    struct Result {
        let simulation: CombatSimulation
        let metadata: [String: Any]
        let events: [GameEvent]
    }
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static let scenes = ["alarm-started", "alarm-transmitted", "alarm-interrupted"]
    private static let reporterID = 9860, receiverID = 9861

    static func prepare(arguments: [String], renderer: NativeRenderer,
                        loadout: LoadoutDefinition = .init()) throws -> Result? {
        guard let index = arguments.firstIndex(of: "--scene"), index + 1 < arguments.count,
              arguments[index + 1].hasPrefix("alarm-") else { return nil }
        let result = try makeScenario(scene: arguments[index + 1], loadout: loadout)
        try renderer.setMap(result.simulation.map)
        renderer.handle(events: result.events, simulation: result.simulation)
        if arguments[index + 1] == "alarm-interrupted" {
            // makeScenario already advances the corpse 42 fixed ticks after
            // the shot. Match only the visual effect clock to that 0.35 s age;
            // do not advance gameplay or leave a freshly replayed muzzle flash.
            for _ in 0..<42 { renderer.advanceEffects(deltaTime: 1.0 / 120, simulation: result.simulation) }
        }
        return result
    }

    /// CPU-only entry point: no renderer, audio device or synthetic report state.
    static func makeScenario(scene: String, loadout: LoadoutDefinition = .init()) throws -> Result {
        guard scenes.contains(scene) else {
            throw Failure(message: "Alarm scenes: \(scenes.joined(separator: ", ")).")
        }
        let map = try diagnosticMap()
        var reporter = EnemyState(id: reporterID, position: SIMD3(0, 0, -6))
        reporter.yaw = 0
        var receiver = EnemyState(id: receiverID, position: SIMD3(9, 0, -8))
        receiver.yaw = .pi
        let game = CombatSimulation(difficulty: .easy, seed: 1745, world: map.obstacles,
            startingPlayer: map.playerStart, startingEnemies: [reporter, receiver], startingWave: 3,
            map: map, loadout: loadout)
        var records: [GameEvent] = []
        func tick(fire: Bool = false, head: Bool = false) {
            let target = game.enemies.first { $0.id == reporterID } ?? reporter
            let pose = EnemyPose(target)
            let delta = (head ? pose.headCenter : pose.bodyCenter) - game.eyePosition
            var input = GameInput()
            input.yaw = atan2(-delta.x, -delta.z)
            input.pitch = atan2(delta.y, simd_length(SIMD2(delta.x, delta.z)))
            input.aim = fire; input.fire = fire
            game.step(deltaTime: 1.0 / 120, input: input)
            records.append(contentsOf: game.drainEvents())
        }

        // Stop on the actual state transition, not on assumed recognition time.
        for _ in 0..<720 {
            tick()
            if game.pendingContactReports.contains(where: { $0.enemyID == reporterID && $0.progress >= 0.2 }) { break }
        }
        guard let pending = game.pendingContactReports.first(where: { $0.enemyID == reporterID }),
              pending.progress >= 0.2, pending.progress < 1,
              let started = records.first(where: { $0.kind == .contactReportStarted && $0.contactReport?.id == pending.id }),
              game.enemies.contains(where: { $0.id == reporterID && $0.seesPlayer }) else {
            throw Failure(message: "The alarm fixture did not reach a real confirmed-contact report attempt.")
        }

        if scene == "alarm-transmitted" {
            for _ in 0..<240 {
                tick()
                if records.contains(where: { $0.kind == .contactReportTransmitted && $0.contactReport?.id == pending.id && $0.contactReport?.channel == .radio }) { break }
            }
        } else if scene == "alarm-interrupted" {
            game.selectWeapon(.sniper)
            tick(fire: true, head: true)
            // Leave a visible falling body while keeping the original attempt's
            // interruption separate from any future contact by another actor.
            for _ in 0..<42 { tick() }
        }

        let sent = records.filter { $0.kind == .contactReportTransmitted && $0.contactReport?.id == pending.id && $0.contactReport?.channel == .radio }
        let localReports = records.filter { $0.kind == .contactReportTransmitted && $0.contactReport?.id == pending.id && $0.contactReport?.channel == .localShout }
        let interrupted = records.filter { $0.kind == .contactReportInterrupted && $0.contactReport?.id == pending.id }
        let escalation = records.filter { $0.kind == .alarmEscalated }
        guard let finalReporter = game.enemies.first(where: { $0.id == reporterID }),
              let finalReceiver = game.enemies.first(where: { $0.id == receiverID }),
              game.loadout == loadout, game.state == .active,
              !finalReceiver.seesPlayer, finalReceiver.detectionProgress < 1,
              !records.contains(where: { $0.kind == .enemyShot && $0.id == receiverID }) else {
            throw Failure(message: "The hidden report receiver gained visual confirmation/fire permission or the fixture lost its active loadout.")
        }
        switch scene {
        case "alarm-started":
            guard game.pendingContactReports.contains(where: { $0.id == pending.id }), sent.isEmpty,
                  interrupted.isEmpty, !game.alarmStatus.escalated else {
                throw Failure(message: "The pending report scene already transmitted or interrupted its attempt.")
            }
        case "alarm-transmitted":
            guard sent.count == 1, localReports.count == 1, interrupted.isEmpty, escalation.count == 1,
                  let report = sent.first?.contactReport, report.channel == .radio,
                  let local = localReports.first?.contactReport,
                  report.contactPosition == pending.contactPosition, report.contactTime == pending.contactTime,
                  local.contactPosition == pending.contactPosition, local.contactTime == pending.contactTime,
                  finalReceiver.lastContactReport?.id == pending.id,
                  game.alarmStatus.escalated, game.alarmStatus.playerHeardEscalation,
                  game.alarmStatus.reinforcementsCommitted == 2,
                  game.alarmStatus.assignedGuardIDs.count <= 2 else {
                throw Failure(message: "The transmitted report lost its frozen contact, hidden recipient or bounded escalation.")
            }
        default:
            guard finalReporter.health == 0, sent.isEmpty, localReports.isEmpty, interrupted.count == 1,
                  records.filter({ $0.kind == .shot }).count == 1,
                  records.contains(where: { $0.kind == .kill && $0.id == reporterID }),
                  !game.pendingContactReports.contains(where: { $0.id == pending.id }),
                  !game.alarmStatus.escalated else {
                throw Failure(message: "The real sniper shot did not interrupt the reporting enemy before transmission.")
            }
        }

        let sound = started.hearing
        var metadata: [String: Any] = [
            "scene": scene, "fixtureMap": map.id, "fixtureElapsed": game.elapsed,
            "effectAgeAfterShot": scene == "alarm-interrupted" ? 0.35 : 0,
            "fixtureScope": "isolated real recognition/reporting, not a full combat playthrough",
            "reportID": pending.id, "reporterID": reporterID, "reporterHealth": finalReporter.health,
            "reporterPosition": vector(finalReporter.position),
            "contactPosition": vector(pending.contactPosition), "contactTime": pending.contactTime,
            "reportStarted": records.filter { $0.kind == .contactReportStarted && $0.contactReport?.id == pending.id }.count,
            "reportTransmitted": sent.count, "localReportTransmitted": localReports.count, "reportInterrupted": interrupted.count,
            "pendingProgress": game.pendingContactReports.first { $0.id == pending.id }?.progress ?? 0,
            "pendingReports": game.pendingContactReports.count, "activeReports": game.contactReports.count,
            "radioPowered": game.alarmStatus.radioPowered, "alarmEscalated": game.alarmStatus.escalated,
            "alarmReinforcementsCommitted": game.alarmStatus.reinforcementsCommitted,
            "assignedGuardIDs": game.alarmStatus.assignedGuardIDs,
            "alarmHeardByPlayer": game.alarmStatus.playerHeardEscalation,
            "receiverID": receiverID, "receiverSeesPlayer": finalReceiver.seesPlayer,
            "receiverRecognition": finalReceiver.detectionProgress,
            "receiverReportID": finalReceiver.lastContactReport?.id ?? -1,
            "playerFeet": vector(game.player.position), "playerHealth": game.player.health,
            "remainingGrenades": game.grenadeCount
        ]
        if let report = sent.first?.contactReport {
            metadata["transmittedAt"] = report.transmittedAt
            metadata["reportExpiresAt"] = report.expiresAt
            metadata["reportChannel"] = report.channel.rawValue
        }
        if let sound {
            metadata["actualCallSource"] = vector(sound.position)
            metadata["callAudibleAtPlayer"] = game.acousticSample(for: sound, listener: game.eyePosition).audible
        }
        return Result(simulation: game, metadata: metadata, events: records)
    }

    private static func vector(_ value: SIMD3<Float>) -> [Float] { [value.x, value.y, value.z] }

    private static func diagnosticMap() throws -> MapDefinition {
        let wall = Obstacle(id: 9870, kind: .bunker, position: SIMD3(4, 0, -4), size: SIMD3(1, 3.6, 20))
        let generator = Obstacle(id: 9871, kind: .container, position: SIMD3(-5, 0, -5), size: SIMD3(1.6, 1.4, 1.2))
        var environment = MapEnvironmentDefinition()
        environment.shadowExtent = 45
        environment.devices = [WorldInteractableDefinition(id: 1001, kind: .generator,
            ownerObstacleID: generator.id, interactionPoints: [SIMD3(-5, 0, -3)])]
        environment.alarm = MapAlarmDefinition(radioDeviceID: 1001, radioPosition: SIMD3(-5, 1, -5),
            returnGuardPosts: [SIMD3(9, 0, -2), SIMD3(9, 0, -11)], reinforcementCount: 2)
        return try MapDefinition(id: "diagnostic-alarm", displayName: "Alarmprüfung",
            minimum: SIMD3(-32, 0, -32), maximum: SIMD3(32, 0, 32), terrain: .flat,
            obstacles: [wall, generator], playerStart: PlayerState(position: SIMD3(0, 0, 6)),
            reinforcementEntries: [SIMD3(-12, 0, 25), SIMD3(12, 0, 25)], waveStaging: [SIMD3(0, 0, 14)],
            extraction: SIMD3(0, 0, -26), dataSite: SIMD3(-14, 0, 4), radioSite: SIMD3(-14, 0, -4),
            environment: environment, resources: MapDefinition.testRange.resources)
    }
}
