import Testing
import simd
@testable import BlacksiteCore

@Suite(.serialized)
struct OperationTests {
    private var held: GameInput { var input = GameInput(); input.interact = true; return input }
    private func fixture(extra: [Obstacle] = [], radioDeviceID: Int? = 1001,
                         preparations: [OperationPreparationDefinition]? = nil,
                         exits: [ExtractionDefinition]? = nil) throws -> MapDefinition {
        let generator = Obstacle(id: 23, kind: .container, position: SIMD3(-6,0,8), size: SIMD3(1.6,1.4,1.2))
        let gate = Obstacle(id: 24, kind: .container, position: .zero, size: SIMD3(6,2.8,0.45))
        let spare = Obstacle(id: 25, kind: .container, position: SIMD3(-12,0,8), size: SIMD3(1.6,1.4,1.2))
        var environment = MapEnvironmentDefinition()
        environment.devices = [
            WorldInteractableDefinition(id: 1001, kind: .generator, ownerObstacleID: 23, interactionPoints: [SIMD3(-6,0,9.5)]),
            WorldInteractableDefinition(id: 1002, kind: .serviceGate, ownerObstacleID: 24, interactionPoints: [SIMD3(4,0,0)],
                generatorID: 1001, openOffset: SIMD3(0,3.4,0)),
            WorldInteractableDefinition(id: 1003, kind: .generator, ownerObstacleID: 25, interactionPoints: [SIMD3(-12,0,9.5)])
        ]
        if let radioDeviceID {
            environment.alarm = MapAlarmDefinition(radioDeviceID: radioDeviceID, radioPosition: SIMD3(-6,1.2,8.7),
                returnGuardPosts: [], reinforcementCount: 0)
        }
        let operation = MapOperationDefinition(preparations: preparations ?? [
            OperationPreparationDefinition(kind: .disableRadio, deviceID: 1001),
            OperationPreparationDefinition(kind: .openGate, deviceID: 1002)
        ], extractions: exits ?? [
            ExtractionDefinition(id: "north", title: "Nord", detail: "Direkter Ausgang", position: SIMD3(0,0,-12), radius: 2, routeKind: .exposed),
            ExtractionDefinition(id: "service", title: "Ost", detail: "Zweiter Ausgang", position: SIMD3(12,0,-12), radius: 2, routeKind: .sheltered)
        ])
        return try MapDefinition(id: "operation-test", displayName: "Operationsprüfung", minimum: SIMD3(-24,0,-24), maximum: SIMD3(24,0,24),
            terrain: .flat, obstacles: [generator,gate,spare] + extra, playerStart: PlayerState(position: SIMD3(0,0,8)),
            reinforcementEntries: [SIMD3(-18,0,20),SIMD3(18,0,20)], waveStaging: [SIMD3(0,0,16)],
            extraction: SIMD3(0,0,-12), dataSite: SIMD3(0,0,8), radioSite: SIMD3(15,0,8),
            environment: environment, operation: operation)
    }
    private func scene(_ map: MapDefinition, world: [Obstacle]? = nil, enemies: [EnemyState] = []) -> CombatSimulation {
        CombatSimulation(difficulty: .easy, seed: 41, world: world ?? map.obstacles,
            startingEnemies: enemies, mission: .operation, map: map)
    }
    /// The route tests isolate combat explicitly; movement, collisions, devices,
    /// actual reporting by a preserved witness, objectives and spawns still run.
    @discardableResult private func advance(_ game: CombatSimulation, _ ticks: Int, input: GameInput = GameInput(),
                                           isolateCombat: Bool = true, preserveID: Int? = nil) -> [GameEvent] {
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
    private func walk(_ game: CombatSimulation, through points: [SIMD2<Float>], events: inout [GameEvent]) throws {
        for point in points {
            var reached = false
            for _ in 0..<3000 {
                let delta = point - SIMD2(game.player.position.x,game.player.position.z)
                if simd_length(delta) < 0.08 { reached = true; break }
                var input = GameInput(); input.moveForward = 1; input.yaw = atan2(-delta.x,-delta.y)
                events += advance(game, 1, input: input)
            }
            try #require(reached, "route point \(point), player \(game.player.position), state \(game.state)")
        }
    }
    private func gate(_ game: CombatSimulation) -> WorldInteractableState { game.devices.first { $0.kind == .serviceGate }! }

    @Test func optionalPreparationUsesTheFirstHeldTickAndUnsupportedMapsFallBackSafely() throws {
        let map = try fixture(), game = scene(map)
        #expect(map.supportsMission(.operation) && game.missionStatus.phase == .prepareOperation)
        #expect(game.operationStatus?.extractions.allSatisfy { !$0.unlocked } == true)
        var events = advance(game, 1, input: held)
        #expect(game.missionStatus.phase == .collectData && game.missionStatus.progress == Float(1)/120)
        events += advance(game, 1)
        #expect(game.missionStatus.progress == 0 && game.missionStatus.interruption == .interactionReleased)
        events += advance(game, 95, input: held)
        #expect(!game.extractionReady)
        events += advance(game, 1, input: held)
        #expect(game.missionStatus.phase == .extract && game.extractionReady)
        #expect(game.devices[0].enabled && gate(game).gateProgress == 0)
        #expect(game.operationStatus?.preparations.allSatisfy { !$0.completed } == true)
        #expect(game.operationStatus?.extractions.allSatisfy(\.unlocked) == true)
        #expect(events.filter { $0.kind == .missionPhaseChanged }.compactMap(\.missionPhase) == [.prepareOperation,.collectData,.extract])
        let arrivalsBefore = events.filter { $0.kind == .reinforcementsArrived }.count
        events += advance(game, 120, input: held)
        #expect(arrivalsBefore <= 7 && events.filter { $0.kind == .reinforcementsArrived }.count <= 7)
        #expect(!events.contains { $0.kind == .waveStarted })
        let unsupported = CombatSimulation(map: .testRange, mission: .operation)
        #expect(!MapDefinition.testRange.supportsMission(.operation))
        #expect(unsupported.missionKind == .recoverData && unsupported.operationStatus == nil)
        #expect(unsupported.missionStatus.objectivePosition == unsupported.map.grounded(unsupported.map.dataSite))
        let isolated = CombatSimulation(world: [], mission: .operation)
        #expect(isolated.missionKind == .recoverData && isolated.operationStatus == nil)
        for kind in [MissionKind.waves,.recoverData,.secureRadio] {
            let old = CombatSimulation(map: map, mission: kind)
            #expect(old.operationStatus == nil && old.missionKind == kind && map.supportsMission(kind))
        }
    }

    @Test func leavingSwitchingAndJumpingResetOnlyTheChosenExitTimerWhilePauseFreezesIt() throws {
        let game = scene(try fixture())
        var events = advance(game, 96, input: held)
        try walk(game, through: [SIMD2(5,8),SIMD2(5,-4),SIMD2(0,-12)], events: &events)
        events += advance(game, 40)
        let progress = game.extractionProgress, time = game.elapsed
        #expect(progress > 0.3 && progress < 2 && game.selectedExtractionID == "north")
        for dt in [Double(0),-1,.nan,.infinity] { game.step(deltaTime: dt, input: held) }
        #expect(game.elapsed == time && game.extractionProgress == progress)
        try walk(game, through: [SIMD2(12,-12)], events: &events)
        let status = try #require(game.operationStatus)
        #expect(status.selectedExtractionID == "service" && status.activeExtractionID == "service")
        #expect(status.extractions.first { $0.id == "north" }?.progress == 0)
        #expect(game.extractionProgress > 0 && game.extractionProgress < 1)
        game.jump(); events += advance(game, 1)
        #expect(game.extractionProgress == 0 && game.missionStatus.interruption == .notGrounded)
        #expect(game.selectedExtractionID == "service" && game.operationStatus?.activeExtractionID == nil)
        events += advance(game, 160)
        #expect(game.player.grounded && game.state == .active && game.extractionProgress < 2)
        events += advance(game, 360)
        #expect(game.state == .won && game.missionStatus.extractionID == "service")
        #expect(events.filter { $0.kind == .extractionSelected }.compactMap(\.extractionID) == ["north","service"])
        #expect(events.filter { $0.kind == .win }.count == 1)
        #expect(events.filter { $0.kind == .missionPhaseChanged && $0.missionPhase == .completed }.count == 1)
        #expect(advance(game, 480).isEmpty)
    }

    @Test func actualLethalShotOnTheFinalExitTickPreventsCompletion() throws {
        let barrel = Obstacle(id: 50, kind: .barrel, position: SIMD3(12,0,-14.5), size: SIMD3(0.8,1.15,0.8))
        let game = scene(try fixture(extra: [barrel]))
        var events = advance(game, 96, input: held)
        try walk(game, through: [SIMD2(5,8),SIMD2(5,-4),SIMD2(12,-12)], events: &events)
        let elapsedTicks = Int((game.extractionProgress * 120).rounded())
        try #require(elapsedTicks < 359)
        advance(game, 359-elapsedTicks)
        #expect(game.state == .active && game.extractionProgress == Float(359)/120)
        let barrelIndex = try #require(game.obstacles.firstIndex { $0.id == 50 })
        game.damageCover(index: barrelIndex, amount: 54)
        game.damagePlayer(amount: 99, from: game.player.position)
        _ = game.drainEvents()
        let aim = game.obstacles[barrelIndex].position + SIMD3<Float>(0,0.55,0) - game.eyePosition
        var input = GameInput(); input.fire = true; input.aim = true
        input.yaw = atan2(-aim.x,-aim.z); input.pitch = atan2(aim.y,simd_length(SIMD2(aim.x,aim.z)))
        let last = advance(game, 1, input: input)
        #expect(game.state == .lost && game.player.health == 0)
        #expect(game.missionStatus.phase == .extract && game.extractionProgress < 3)
        #expect(last.contains { $0.kind == .shot } && last.contains { $0.kind == .explosion } && last.contains { $0.kind == .lose })
        #expect(!last.contains { $0.kind == .win || ($0.kind == .missionPhaseChanged && $0.missionPhase == .completed) })
    }

    @Test func pendingObjectiveGuardsRetrySafelyWithoutAddingAnotherWaveOrLockingTheExits() throws {
        let map = try fixture()
        let sealed = Obstacle(id: 500, kind: .crate, position: .zero, size: SIMD3(48,3,48))
        let game = scene(map, world: map.obstacles + [sealed])
        advance(game, 96, input: held, isolateCombat: false)
        #expect(game.pendingReinforcements == 7 && game.aliveCount == 0 && game.extractionReady)
        game.damageCover(index: 3, amount: 1000)
        advance(game, 30, isolateCombat: false)
        #expect(game.pendingReinforcements == 7 && game.aliveCount == 0)
        var arrivals = advance(game, 31, isolateCombat: false).filter { $0.kind == .reinforcementsArrived }
        #expect(arrivals.count == 2 && game.pendingReinforcements == 5)
        #expect(arrivals.allSatisfy { game.reinforcementIsHidden(at: $0.position) &&
            !game.blocked($0.position, height: 2, radius: 0.6) && horizontalDistance($0.position,$0.endPosition) >= 14 })
        // Two authored entries admit at most two guards per retry. Clear each
        // accepted batch and prove that the five pending guards arrive later,
        // on the fixed retry clock, rather than forcing an unsafe extra spawn.
        var previousArrival = game.elapsed
        for _ in 0..<240 {
            let batch = advance(game, 1).filter { $0.kind == .reinforcementsArrived }
            if !batch.isEmpty {
                #expect(batch.count <= 2 && game.elapsed - previousArrival >= 0.49)
                #expect(batch.allSatisfy { game.reinforcementIsHidden(at: $0.position) &&
                    !game.blocked($0.position, height: 2, radius: 0.6) && horizontalDistance($0.position,$0.endPosition) >= 14 })
                previousArrival = game.elapsed; arrivals += batch
            }
        }
        #expect(arrivals.count == 7 && Set(arrivals.map(\.id)).count == 7)
        #expect(game.pendingReinforcements == 0 && game.wave == 0 && game.state == .active)
        #expect(game.operationStatus?.extractions.allSatisfy { $0.unlocked && !$0.blocked } == true)
    }

    @Test func threeCompleteBlacksiteOperationsPreserveQuietLoudAndFailedPreparationConsequences() throws {
        let toGenerator: [SIMD2<Float>] = [SIMD2(8,32),SIMD2(21,29),SIMD2(29,21),SIMD2(32,13),SIMD2(32,5),SIMD2(30,3.5),SIMD2(27,3.5)]
        let eastExit: [SIMD2<Float>] = [SIMD2(-18,32),SIMD2(-8,32),SIMD2(0,32),SIMD2(8,32),SIMD2(21,29),SIMD2(29,21),SIMD2(32,13),SIMD2(32,5),SIMD2(32,-3),SIMD2(29,-10),SIMD2(33,-18),SIMD2(33,-28),SIMD2(33,-37)]
        let westBypass: [SIMD2<Float>] = [SIMD2(-32,22),SIMD2(-30,14),SIMD2(-32,4),SIMD2(-33,-6),SIMD2(-33,-20),SIMD2(-28,-25),SIMD2(-20,-26),SIMD2(-12,-28),SIMD2(-7,-32),SIMD2(0,-35)]
        for run in 0..<3 {
            let map = MapDefinition.blacksite
            var world = map.obstacles
            // This isolated scenario adds one actual obstacle over the optional
            // exit to verify the fallback, without altering the authored map.
            if run == 2 { world.append(Obstacle(id: 99_000, kind: .bunker, position: SIMD3(33,0,-37), size: SIMD3(2,3,2))) }
            // Only the loud run preserves a controlled witness long enough to
            // confirm and transmit by the real perception/reporting pipeline.
            var witness = EnemyState(id: 91_000, position: SIMD3(0,0,40)); witness.yaw = .pi
            let game = scene(map, world: world, enemies: run == 1 ? [witness] : [])
            var events: [GameEvent] = []
            if run == 1 {
                var shot = GameInput(); shot.fire = true
                events += advance(game, 1, input: shot, preserveID: witness.id)
                for _ in 0..<600 {
                    events += advance(game, 1, preserveID: witness.id)
                    if game.alarmStatus.escalated { break }
                }
                try #require(game.alarmStatus.escalated, "The actual witness must finish a powered radio report")
                #expect(game.alarmStatus.reinforcementsCommitted == 2)
                events += advance(game, 1)
                try walk(game, through: [SIMD2(-8,32),SIMD2(-18,32),SIMD2(-31,31)], events: &events)
            } else {
                try walk(game, through: toGenerator, events: &events)
                try #require(game.deviceInteractionStatus?.action == .disableGenerator)
                if run == 0 {
                    events += advance(game, 120, input: held); events += advance(game, 1)
                    #expect(!game.alarmStatus.radioPowered && !game.devices[0].enabled)
                    try walk(game, through: [SIMD2(32,3.5),SIMD2(32,-3),SIMD2(29,-10),SIMD2(24,-13),SIMD2(8,-12),SIMD2(6.9,-13.8)], events: &events)
                    try #require(game.deviceInteractionStatus?.manual == true && game.deviceInteractionStatus?.action == .openGate)
                    events += advance(game, 240, input: held); events += advance(game, 485)
                    try #require(gate(game).gateProgress == 1)
                    try walk(game, through: [SIMD2(6.9,-12),SIMD2(0,-12),SIMD2(0,8),SIMD2(-8,8),SIMD2(-25,8),SIMD2(-30,14),SIMD2(-32,22),SIMD2(-31,31)], events: &events)
                } else {
                    events += advance(game, 60, input: held)
                    game.jump(); events += advance(game, 150)
                    #expect(game.devices[0].enabled && game.deviceInteractionStatus?.progress == 0)
                    try walk(game, through: [SIMD2(30,3.5),SIMD2(32,5),SIMD2(32,13),SIMD2(29,21),SIMD2(21,29),SIMD2(8,32),SIMD2(0,32),SIMD2(-8,32),SIMD2(-18,32),SIMD2(-31,31)], events: &events)
                }
            }
            events += advance(game, 96, input: held)
            try #require(game.missionStatus.phase == .extract)
            if run == 0 {
                #expect(game.operationStatus?.preparations.allSatisfy(\.completed) == true)
                #expect(!game.devices[0].enabled && gate(game).gateProgress == 1 && !game.alarmStatus.escalated)
                try walk(game, through: [SIMD2(-32,22),SIMD2(-30,14),SIMD2(-25,8),SIMD2(-8,8),SIMD2(0,8),SIMD2(0,-12),SIMD2(0,-18),SIMD2(0,-35)], events: &events)
            } else if run == 1 {
                #expect(game.devices[0].enabled && gate(game).gateProgress == 0 && game.alarmStatus.escalated)
                try walk(game, through: eastExit, events: &events)
            } else {
                let secondary = try #require(game.operationStatus?.extractions.first { $0.id == "service" })
                #expect(secondary.blocked && secondary.interruption == .blocked && game.missionStatus.extractionID == "north")
                #expect(game.devices[0].enabled && gate(game).gateProgress == 0)
                try walk(game, through: westBypass, events: &events)
            }
            events += advance(game, 360)
            #expect(game.state == .won && game.missionStatus.extractionID == (run == 1 ? "service" : "north"), "run \(run)")
            #expect(events.filter { $0.kind == .win }.count == 1)
            #expect(events.filter { $0.kind == .missionPhaseChanged && $0.missionPhase == .extract }.count == 1)
            #expect(events.filter { $0.kind == .reinforcementsArrived }.count <= (run == 1 ? 9 : 7))
            #expect(events.filter { $0.kind == .alarmEscalated }.count == (run == 1 ? 1 : 0))
            let reset = scene(map)
            #expect(reset.missionStatus.phase == .prepareOperation && reset.selectedExtractionID == nil && reset.extractionProgress == 0)
            #expect(reset.devices[0].enabled && gate(reset).gateProgress == 0 && !reset.alarmStatus.escalated)
            #expect(reset.pendingReinforcements == 0 && reset.noiseDecoyCount == 0 && reset.grenadeCount == 4)
        }
    }

    @Test func authoredExitPathsAndPermanentBunkerOfferDifferentActualSightLines() throws {
        let map = MapDefinition.blacksite, game = scene(.blacksite)
        let exits = try #require(map.operation?.extractions)
        let start = map.grounded(map.dataSite)
        var lengths: [Float] = []
        for exit in exits {
            let target = map.grounded(exit.position)
            #expect(game.hasReachableRoute(from: start, to: target))
            let path = [start] + game.findPath(from: start, to: target) + [target]
            lengths.append(zip(path,path.dropFirst()).reduce(0) { $0 + horizontalDistance($1.0,$1.1) })
        }
        #expect(lengths[1] > lengths[0], "navigation lengths north=\(lengths[0]), service=\(lengths[1])")
        for post in try #require(map.environment.alarm?.returnGuardPosts) {
            let eye = map.grounded(post) + SIMD3<Float>(0,1.7,0)
            #expect(game.clearLine(eye,map.grounded(exits[0].position) + SIMD3(0,1.62,0)))
            #expect(!game.clearLine(eye,map.grounded(exits[1].position) + SIMD3(0,1.62,0)))
        }
        for id in game.obstacles.filter({ $0.health.isFinite }).map(\.id) {
            if let index = game.obstacles.firstIndex(where: { $0.id == id }) { game.damageCover(index: index, amount: 10_000) }
        }
        for exit in exits { #expect(game.hasReachableRoute(from: start, to: map.grounded(exit.position))) }
        let roadEye = map.grounded(SIMD3(7.8,0,-19)) + SIMD3<Float>(0,1.7,0)
        #expect(!game.clearLine(roadEye,map.grounded(exits[1].position) + SIMD3(0,1.62,0)))
    }

    @Test func operationAuthoringRejectsUnrelatedRadioPreparationAndInvalidExitPairs() throws {
        _ = try fixture()
        #expect(throws: MapValidationError.self) { try fixture(radioDeviceID: nil) }
        #expect(throws: MapValidationError.self) { try fixture(radioDeviceID: 1003) }
        let existing = try #require(try fixture().operation)
        #expect(throws: MapValidationError.self) { try fixture(exits: [existing.extractions[0]]) }
        #expect(throws: MapValidationError.self) { try fixture(exits: [existing.extractions[0],existing.extractions[0]]) }
        let overlap = ExtractionDefinition(id: "near", title: "Nähe", detail: "Unzulässige Überlappung", position: SIMD3(2,0,-12), radius: 2, routeKind: .sheltered)
        #expect(throws: MapValidationError.self) { try fixture(exits: [existing.extractions[0],overlap]) }
        // A map without optional preparations needs no radio or generator link.
        #expect(try fixture(radioDeviceID: nil, preparations: []).supportsMission(.operation))
    }
}
