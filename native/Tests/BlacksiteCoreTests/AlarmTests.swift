import Testing
import simd
@testable import BlacksiteCore

@Suite(.serialized)
struct AlarmTests {
    private func map(wallX: Float = 8, group: Int = 2,
                     posts: [SIMD3<Float>] = [SIMD3(20,0,-20),SIMD3(25,0,-24)], entriesBlocked: Bool = false,
                     start: SIMD3<Float> = .zero) throws -> MapDefinition {
        let generator = Obstacle(id: 23, kind: .container, position: SIMD3(-20,0,15), size: SIMD3(1.6,1.4,1.2))
        let wall = Obstacle(id: 40, kind: .bunker, position: SIMD3(wallX,0,-12), size: SIMD3(1.5,5,30))
        var world = [generator,wall]
        if entriesBlocked {
            for (index,x) in [Float(-4),4].enumerated() {
                world.append(Obstacle(id: 50+index, kind: .container, position: SIMD3(x,0,26), size: SIMD3(3,3,3)))
            }
        }
        var environment = MapEnvironmentDefinition()
        environment.devices = [WorldInteractableDefinition(id: 1001, kind: .generator, ownerObstacleID: 23,
            interactionPoints: [SIMD3(-20,0,16.5)])]
        environment.alarm = MapAlarmDefinition(radioDeviceID: 1001, radioPosition: SIMD3(-20,1.2,15.7),
            returnGuardPosts: posts, reinforcementCount: group)
        return try MapDefinition(id: "alarm-test", displayName: "Alarmprüfung", minimum: SIMD3(-32,0,-32), maximum: SIMD3(32,0,32),
            terrain: .flat, obstacles: world, playerStart: PlayerState(position: start),
            reinforcementEntries: [SIMD3(-4,0,26),SIMD3(4,0,26)], waveStaging: [SIMD3(24,0,-24)],
            extraction: SIMD3(0,0,-28), dataSite: .zero, radioSite: SIMD3(-24,0,-24), environment: environment)
    }
    private func scene(_ map: MapDefinition, enemies: [EnemyState]? = nil, mission: MissionKind = .waves,
                       generatorDestroyed: Bool = false) -> CombatSimulation {
        var world = map.obstacles
        if generatorDestroyed { world[0].destroyed = true; world[0].health = 0 }
        return CombatSimulation(difficulty: .easy, seed: 41, world: world,
            startingEnemies: enemies ?? [EnemyState(id: 1, position: SIMD3(0,0,-12)),
                EnemyState(id: 2, position: SIMD3(22,0,-12)),EnemyState(id: 3, position: SIMD3(24,0,-16))],
            startingWave: 3, mission: mission, map: map)
    }
    @discardableResult private func advance(_ game: CombatSimulation, ticks: Int, input: GameInput = GameInput(),
                                            isolateCombat: Bool = false, preserveID: Int? = nil) -> [GameEvent] {
        var events: [GameEvent] = []
        for _ in 0..<ticks {
            game.step(deltaTime: 1.0/120, input: input)
            if isolateCombat {
                for index in game.enemies.indices where game.enemies[index].health > 0 && game.enemies[index].id != preserveID {
                    game.damageEnemy(index: index, amount: 10_000)
                }
            }
            events += game.drainEvents()
        }
        return events
    }
    private func waitForPending(_ game: CombatSimulation) -> [GameEvent] {
        var events: [GameEvent] = []
        for _ in 0..<480 {
            events += advance(game, ticks: 1)
            if !game.pendingContactReports.isEmpty { break }
        }
        return events
    }
    private func waitForEscalation(_ game: CombatSimulation) -> [GameEvent] {
        var events: [GameEvent] = []
        for _ in 0..<480 {
            events += advance(game, ticks: 1)
            if game.alarmStatus.escalated { break }
        }
        return events
    }

    @Test func contactSnapshotDoesNotTrackBehindCoverOrGrantRemoteFiringPermission() throws {
        let game = scene(try map())
        let started = waitForPending(game)
        let pending = try #require(game.pendingContactReports.first)
        #expect(started.contains { $0.kind == .contactReportStarted && $0.hearing?.kind == .radio })
        #expect(!game.alarmStatus.escalated && game.contactReports.isEmpty)
        var sideways = GameInput(); sideways.moveRight = -1
        let events = advance(game, ticks: 144, input: sideways)
        let report = try #require(events.first { $0.kind == .alarmEscalated }?.contactReport)
        #expect(report.contactPosition == pending.contactPosition && report.contactTime == pending.contactTime)
        #expect(simd_distance(report.contactPosition, game.player.position) > 4)
        #expect(game.alarmStatus.assignedGuardIDs.count == 2 && !game.alarmStatus.assignedGuardIDs.contains(1))
        for id in [2,3] {
            let receiver = try #require(game.enemies.first { $0.id == id })
            #expect(receiver.lastContactReport?.contactPosition == pending.contactPosition)
            #expect(!receiver.seesPlayer && receiver.detectionProgress < 1)
            #expect(!events.contains { $0.kind == .enemyShot && $0.id == id })
        }
        game.damageEnemy(index: 0, amount: 10_000)
        let after = advance(game, ticks: 420)
        for (id,post) in zip(game.alarmStatus.assignedGuardIDs, [SIMD3<Float>(20,0,-20),SIMD3(25,0,-24)]) {
            let receiver = try #require(game.enemies.first { $0.id == id })
            #expect(horizontalDistance(receiver.position, post) < 2.5)
        }
        #expect(!after.contains { $0.kind == .enemyShot && [2,3].contains($0.id) })
    }

    @Test func interruptedReporterNeverTransmitsAndLosingContactDoesNotEraseItsMemory() throws {
        let game = scene(try map(group: 0, posts: []))
        _ = waitForPending(game)
        #expect(game.pendingContactReports.count == 1)
        game.damageEnemy(index: 0, amount: 1)
        let interrupted = advance(game, ticks: 1)
        #expect(game.pendingContactReports.isEmpty && game.contactReports.isEmpty && !game.alarmStatus.escalated)
        #expect(interrupted.contains { $0.kind == .contactReportInterrupted })
        #expect(game.enemies[0].awareness != .watching)
        // Killing the reporter during its next attempt must stop both channels.
        _ = waitForPending(game)
        #expect(!game.pendingContactReports.isEmpty)
        game.damageEnemy(index: 0, amount: 10_000)
        let killed = advance(game, ticks: 150)
        #expect(killed.filter { $0.kind == .contactReportInterrupted }.count == 1)
        #expect(!killed.contains { $0.kind == .contactReportTransmitted || $0.kind == .alarmEscalated })
    }

    @Test func actualLossOfSightCancelsThePendingFrozenContact() throws {
        let definition = try map(group: 0, posts: [])
        let game = CombatSimulation(difficulty: .easy, world: definition.obstacles,
            startingPlayer: PlayerState(position: SIMD3(6,0,4)),
            startingEnemies: [EnemyState(id: 1, position: SIMD3(0,0,-12))], startingWave: 3, map: definition)
        _ = waitForPending(game)
        let initial = try #require(game.pendingContactReports.first)
        var right = GameInput(); right.moveRight = 1
        let events = advance(game, ticks: 120, input: right)
        #expect(game.player.position.x > 10 && !game.clearLine(EnemyPose(game.enemies[0]).eyePosition, game.eyePosition))
        #expect(events.contains { $0.kind == .contactReportInterrupted && $0.contactReport?.id == initial.id })
        #expect(game.contactReports.isEmpty && !game.alarmStatus.escalated)
        #expect(game.enemies[0].awareness != .watching && !game.enemies[0].seesPlayer)
    }

    @Test func powerLossCancelsOnlyRadioAndNearbyShoutsSurviveWithoutGlobalAlarm() throws {
        let receivers = [EnemyState(id: 1, position: SIMD3(0,0,-12)),EnemyState(id: 2, position: SIMD3(4,0,-12)),
                         EnemyState(id: 3, position: SIMD3(24,0,-12))]
        let game = scene(try map(wallX: 2), enemies: receivers)
        _ = waitForPending(game)
        game.damageCover(index: 0, amount: 10_000)
        let events = advance(game, ticks: 144)
        #expect(!game.alarmStatus.radioPowered && !game.alarmStatus.escalated && game.alarmStatus.reinforcementsCommitted == 0)
        #expect(events.filter { $0.kind == .contactReportInterrupted && $0.contactReport?.channel == .radio }.count == 1)
        #expect(events.filter { $0.kind == .contactReportTransmitted }.allSatisfy { $0.contactReport?.channel == .localShout })
        #expect(game.enemies[1].lastContactReport?.channel == .localShout)
        #expect(game.enemies[2].lastContactReport == nil && !game.enemies[2].seesPlayer)
        let alreadyOff = scene(try map(wallX: 2), enemies: receivers, generatorDestroyed: true)
        let began = waitForPending(alreadyOff)
        #expect(began.contains { $0.kind == .contactReportStarted && $0.hearing?.kind == .shout })
        advance(alreadyOff, ticks: 144)
        #expect(alreadyOff.enemies[1].lastContactReport != nil && !alreadyOff.alarmStatus.escalated)
    }

    @Test func channelsDeduplicateAndLaterRadioDoesNotContinuouslyPullGuardsOffPosts() throws {
        // Keep the sender outside the wall's 13m cover-search radius so a
        // valid second observation, rather than an intentional cover retreat,
        // tests whether a new report preserves the recipient's route order.
        let receivers = [EnemyState(id: 1, position: SIMD3(-13,0,-12)),EnemyState(id: 2, position: SIMD3(1.8,0,-12))]
        let game = scene(try map(wallX: 0.5, group: 0, posts: [SIMD3(20,0,-20)], start: SIMD3(-13,0,0)), enemies: receivers)
        let events = waitForEscalation(game)
        let reports = events.filter { $0.kind == .contactReportTransmitted }.compactMap(\.contactReport)
        #expect(reports.count == 2 && Set(reports.map(\.id)).count == 1)
        #expect(game.enemies[1].lastContactReport?.channel == .localShout) // Radio with same ID is not applied twice.
        #expect(game.alarmStatus.assignedGuardIDs == [2])
        // The same source can send one later direct observation. The existing
        // tactical post is retained instead of becoming a new pursuit order.
        let later = advance(game, ticks: 1800)
        #expect(later.contains { $0.kind == .contactReportTransmitted && $0.contactReport?.id != reports.first?.id })
        #expect(horizontalDistance(game.enemies[1].position, SIMD3(20,0,-20)) < 1.2)
        #expect(!later.contains { $0.kind == .alarmEscalated })
    }

    @Test func alarmReserveSurvivesSabotageAndRetriesWithoutVisibleOrBlockedSpawns() throws {
        let game = scene(try map(entriesBlocked: true))
        let events = waitForEscalation(game)
        #expect(game.alarmStatus.reinforcementsCommitted == 2 && game.pendingReinforcements == 2)
        #expect(!events.contains { $0.kind == .reinforcementsArrived })
        game.damageCover(index: 0, amount: 10_000)
        #expect(game.alarmStatus.escalated && !game.alarmStatus.radioPowered)
        advance(game, ticks: 180)
        #expect(game.pendingReinforcements == 2)
        for id in [50,51] { if let index = game.obstacles.firstIndex(where: { $0.id == id }) { game.damageCover(index: index, amount: 10_000) } }
        let arrivals = advance(game, ticks: 70).filter { $0.kind == .reinforcementsArrived }
        #expect(arrivals.count == 2 && game.pendingReinforcements == 0)
        for arrival in arrivals {
            #expect(arrival.alarmReportID != nil && arrival.contactReport?.channel == .radio)
            #expect(arrival.position.z > 20 && horizontalDistance(arrival.position, game.player.position) >= 14)
            #expect(!game.blocked(arrival.position, height: 2, radius: 0.6))
        }
        #expect(game.alarmStatus.reinforcementsCommitted == 2)
    }

    @Test func pauseRateCapsExpiryAndRestartHaveFiniteDeterministicState() throws {
        var times: [Double] = []
        for rate in [30,60,120] {
            let game = scene(try map(group: 0, posts: []), enemies: [EnemyState(id: 1, position: SIMD3(0,0,-25))])
            for _ in 0..<(rate * 3) { game.step(deltaTime: 1 / Double(rate), input: GameInput()) }
            let first = try #require(game.contactReports.first)
            times.append(first.contactTime)
            let clock = game.elapsed, history = game.contactReports.count
            for dt in [Double(0),-1,.nan,.infinity] { game.step(deltaTime: dt, input: GameInput()) }
            #expect(game.elapsed == clock && game.contactReports.count == history)
            var transmitted = game.drainEvents().filter { $0.kind == .contactReportTransmitted }
            for _ in 0..<4080 {
                let events = advance(game, ticks: 1)
                transmitted += events.filter { $0.kind == .contactReportTransmitted }
                #expect(game.pendingContactReports.count <= 4 && game.contactReports.count <= 16)
            }
            #expect(transmitted.count == 4) // Two successes, each delivered locally and over radio.
            #expect(game.contactReports.isEmpty && game.pendingContactReports.isEmpty)
            #expect(game.state == .active)
        }
        #expect(abs(times[0] - times[1]) < 0.00001 && abs(times[1] - times[2]) < 0.00001)
        let reset = scene(try map())
        #expect(reset.pendingContactReports.isEmpty && reset.contactReports.isEmpty && !reset.alarmStatus.escalated)
        #expect(reset.alarmStatus.assignedGuardIDs.isEmpty && reset.alarmStatus.reinforcementsCommitted == 0)
    }

    @Test func historicalContactSurvivesMessageExpiryWithoutBeingRefreshedOrFiringThroughCover() throws {
        let game = scene(try map(group: 0))
        _ = waitForEscalation(game)
        let historical = try #require(game.enemies[1].lastContactReport)
        game.damageEnemy(index: 0, amount: 10_000)
        let events = advance(game, ticks: 2700)
        #expect(game.contactReports.isEmpty && game.enemies[1].lastContactReport?.contactTime == historical.contactTime)
        #expect(game.enemies[1].lastContactReport?.contactPosition == historical.contactPosition)
        #expect(!events.contains { $0.kind == .enemyShot || $0.kind == .contactReportStarted })
        #expect(!game.enemies[1].seesPlayer && !game.enemies[2].seesPlayer)
    }

    @Test func sameDataRouteCompletesQuietAndAlarmedWithAnExplicitFiniteEnemyBudget() throws {
        for alarmed in [false,true] {
            // Both runs add the same isolated witness to the normal 4+3 mission
            // guards. Quiet:8 total; alarmed:10 including the one two-man batch.
            let game = scene(try map(), enemies: [EnemyState(id: 1, position: SIMD3(0,0,-12))], mission: .recoverData)
            if alarmed {
                for _ in 0..<400 {
                    advance(game, ticks: 1, isolateCombat: true, preserveID: 1)
                    if game.alarmStatus.escalated { break }
                }
                #expect(game.alarmStatus.escalated && game.alarmStatus.reinforcementsCommitted == 2)
            }
            if let index = game.enemies.firstIndex(where: { $0.id == 1 }) { game.damageEnemy(index: index, amount: 10_000) }
            var interact = GameInput(); interact.interact = true
            advance(game, ticks: 96, input: interact, isolateCombat: true)
            #expect(game.extractionReady)
            var forward = GameInput(); forward.moveForward = 1
            for _ in 0..<1200 {
                if horizontalDistance(game.player.position, game.extractionPosition) < 0.1 { break }
                advance(game, ticks: 1, input: forward, isolateCombat: true)
            }
            advance(game, ticks: 400, isolateCombat: true)
            #expect(game.state == .won && game.pendingReinforcements == 0)
            #expect(game.kills == (alarmed ? 10 : 8))
            #expect(game.alarmStatus.escalated == alarmed)
        }
    }
}
