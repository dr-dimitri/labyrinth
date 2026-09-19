import Testing
import simd
@testable import BlacksiteCore

/// These checks prove physical routes and mission transitions. Combat is
/// isolated during the walks; a separate check exercises actual alarm reports.
@Suite(.serialized)
struct RunVariantRouteTests {
    private static let mapIDs = ["blacksite","nebelwacht","sundkai","kessel9","sirocco"]
    private func authoredMap(_ id: String) -> MapDefinition {
        switch id {
        case "nebelwacht": return .nebelwacht
        case "sundkai": return .sundkai
        case "kessel9": return .kessel9
        case "sirocco": return .sirocco
        default: return .blacksite
        }
    }
    private func representativeSeed(for variantIndex: Int,map: MapDefinition) -> UInt64 {
        UInt64((variantIndex+3-max(0,map.version-1)%3)%3)
    }
    private struct Record {
        var events: [GameEvent] = []
        var peakPending = 0
    }
    private func advance(_ game: CombatSimulation,_ ticks: Int,input: GameInput = GameInput(),
                         isolateCombat: Bool = true,preserveID: Int? = nil,record: inout Record) {
        for _ in 0..<ticks {
            if isolateCombat {
                for index in game.enemies.indices where game.enemies[index].health > 0 && game.enemies[index].id != preserveID {
                    game.damageEnemy(index: index,amount: 10_000)
                }
            }
            game.step(deltaTime: 1.0/120,input: input)
            record.events += game.drainEvents()
            record.peakPending = max(record.peakPending,game.pendingReinforcements)
        }
    }
    private func walk(_ game: CombatSimulation,to raw: SIMD3<Float>,record: inout Record) throws {
        let target = game.map.grounded(raw)
        try #require(game.hasReachableRoute(from: game.player.position,to: target),
                     "map=\(game.map.id), from=\(game.player.position), target=\(target)")
        let path = game.findPath(from: game.player.position,to: target)+[target]
        for point in path {
            var reached = false
            for _ in 0..<1800 {
                let offset = SIMD2(point.x-game.player.position.x,point.z-game.player.position.z)
                if simd_length(offset) < 0.075 { reached = true; break }
                var input = GameInput(); input.moveForward = 1; input.yaw = atan2(-offset.x,-offset.y)
                // The shared navigation graph deliberately crosses low cover.
                // Exercise the player's real jump, as the guard controller does,
                // instead of pretending that these links are walk-only paths.
                let direction = simd_normalize(SIMD3(offset.x,0,offset.y))
                let ahead = game.player.position+direction*0.75
                if game.player.grounded && game.blocked(ahead) && !game.blocked(ahead+SIMD3(0,1.12,0)) {
                    try #require(game.jump(),"map=\(game.map.id), low-cover jump at \(game.player.position)")
                }
                advance(game,1,input: input,record: &record)
                if game.state != .active { break }
            }
            try #require(reached,"map=\(game.map.id), waypoint=\(point), actual=\(game.player.position), state=\(game.state)")
        }
        #expect(game.player.grounded)
        #expect(abs(game.player.position.y-target.y) < 0.06)
    }
    private func finishRequiredObjectives(_ game: CombatSimulation,record: inout Record) throws {
        let stages = game.map.operation?.requiredStages ?? []
        var held = GameInput(); held.interact = true
        if stages.isEmpty {
            try walk(game,to: game.map.dataSite,record: &record)
            advance(game,96,input: held,record: &record)
        } else {
            for stage in stages {
                for target in stage.targets {
                    try walk(game,to: target.position,record: &record)
                    advance(game,1,record: &record) // Explicitly release a previous interaction latch.
                    try #require(game.missionInteractionAvailable,
                                 "map=\(game.map.id), target=\(target.id), status=\(game.missionStatus.interruption)")
                    advance(game,Int((stage.interactionDuration*120).rounded(.up)),input: held,record: &record)
                    if stage.holdDuration > 0 {
                        try #require(game.missionStatus.phase == .holdRadio)
                        advance(game,Int((stage.holdDuration*120).rounded(.up)),record: &record)
                    }
                    #expect(game.operationStatus?.stages.flatMap(\.targets).first { $0.id == target.id }?.completed == true)
                }
            }
        }
        try #require(game.extractionReady && game.missionStatus.phase == .extract)
    }

    @Test(arguments: mapIDs, [0,1,2])
    func everyAuthoredVariantCompletesBothExitsWithRealMovement(mapID: String,variantIndex: Int) throws {
        let authored = authoredMap(mapID)
        let variants = try RunVariantCatalog.variants(for: authored)
        try #require(variants.count == 3)
        let seed = representativeSeed(for: variantIndex,map: authored)
        let variant = try RunVariantCatalog.resolve(map: authored,seed: seed)
        #expect(variant.id == variants[variantIndex].id)
        let map = variant.map
        try map.validateGameplay()
        let operation = try #require(map.operation)
        let role = OperatorClass.allCases[variantIndex % OperatorClass.allCases.count]
        for exit in operation.extractions {
            let game = CombatSimulation(difficulty: .easy,seed: seed,world: map.obstacles,
                mission: .operation,map: map,loadout: .init(operatorClass: role))
            var record = Record()
            try finishRequiredObjectives(game,record: &record)
            try walk(game,to: exit.position,record: &record)
            advance(game,Int((exit.holdDuration*120).rounded(.up))+1,record: &record)
            #expect(game.state == .won && game.selectedExtractionID == exit.id)
            #expect(game.loadout.operatorClass == role)
            #expect(record.events.filter { $0.kind == .win }.count == 1)
            #expect(!record.events.contains { $0.kind == .waveStarted || $0.kind == .lose })
            let arrivals = record.events.filter { $0.kind == .reinforcementsArrived }
            let alarmBudget = map.environment.alarm?.reinforcementCount ?? 0
            #expect(arrivals.count+game.pendingReinforcements <= 7+alarmBudget)
            #expect(record.peakPending <= 7+alarmBudget && Set(arrivals.map(\.id)).count == arrivals.count)
            #expect(game.alarmStatus.reinforcementsCommitted <= alarmBudget)
            if !operation.requiredStages.isEmpty {
                let expected = operation.requiredStages.flatMap(\.targets).map(\.id)
                let completed = record.events.filter { $0.kind == .operationObjectiveCompleted }.compactMap(\.operationObjective).map(\.id)
                #expect(completed == expected)
            }
        }
    }

    @Test(arguments: mapIDs)
    func collapsingOptionalCoverPreservesEveryVariantTargetAndReturn(mapID: String) throws {
        for variant in try RunVariantCatalog.variants(for: authoredMap(mapID)) {
            let map = variant.map
            let game = CombatSimulation(world: map.obstacles,startingWave: 3,map: map)
            for id in game.obstacles.filter({ $0.health.isFinite && !$0.destroyed }).map(\.id) {
                if let index = game.obstacles.firstIndex(where: { $0.id == id }) { game.damageCover(index: index,amount: 10_000) }
            }
            let targets = (map.operation?.requiredStages.flatMap(\.targets).map(\.position) ?? [])+[map.dataSite,map.radioSite]
            let exits = map.operation?.extractions.map(\.position) ?? [map.extraction]
            for target in targets {
                #expect(game.hasReachableRoute(from: game.player.position,to: map.grounded(target)),"variant=\(variant.id), target=\(target)")
                for exit in exits {
                    #expect(game.hasReachableRoute(from: map.grounded(target),to: map.grounded(exit)),"variant=\(variant.id), exit=\(exit)")
                }
            }
            #expect(game.coverDebris.count <= CoverDebrisState.maximumCount)
        }
    }

    @Test(arguments: ["blacksite","nebelwacht","sundkai","kessel9"], [0,1,2])
    func actualRadioReportsRespectEachVariantsPowerAndOneFiniteAlarmBudget(mapID: String,variantIndex: Int) throws {
        let authored = authoredMap(mapID), seed = representativeSeed(for: variantIndex,map: authored)
        let map = try RunVariantCatalog.resolve(map: authored,seed: seed).map
        let alarm = try #require(map.environment.alarm)
        let probe = CombatSimulation(world: map.obstacles,startingWave: 3,map: map)
        let playerPoint = map.grounded(map.radioSite)
        let offsets: [SIMD3<Float>] = [SIMD3(5,0,0),SIMD3(-5,0,0),SIMD3(0,0,5),SIMD3(0,0,-5)]
        let witnessPoint = try #require(offsets.map { map.grounded(map.radioSite+$0) }.first {
            !probe.blocked($0,height: 1.96,radius: 0.38) &&
            probe.terrain.normal(x: $0.x,z: $0.z).y >= 0.72 &&
            probe.sightLine($0+SIMD3(0,1.6,0),playerPoint+SIMD3(0,1.6,0)) &&
            simd_distance($0,map.grounded(alarm.radioPosition)) < alarm.radioRange-1
        })
        var witness = EnemyState(id: 9001,position: witnessPoint)
        witness.yaw = atan2(playerPoint.x-witnessPoint.x,playerPoint.z-witnessPoint.z)
        let game = CombatSimulation(difficulty: .easy,seed: seed,world: map.obstacles,
            startingPlayer: PlayerState(position: playerPoint),startingEnemies: [witness],startingWave: 3,map: map)
        let powered = game.alarmStatus.radioPowered
        var record = Record()
        for _ in 0..<960 {
            advance(game,1,preserveID: witness.id,record: &record)
            if record.events.contains(where: { $0.kind == .contactReportTransmitted }) { break }
        }
        try #require(record.events.contains { $0.kind == .contactReportTransmitted },"map=\(mapID), variant=\(variantIndex)")
        #expect(game.alarmStatus.escalated == powered)
        #expect(game.alarmStatus.reinforcementsCommitted == (powered ? alarm.reinforcementCount : 0))
        advance(game,1200,preserveID: witness.id,record: &record)
        advance(game,240,record: &record)
        let arrivals = record.events.filter { $0.kind == .reinforcementsArrived && $0.contactReport != nil }
        #expect(game.state == .active && game.pendingReinforcements == 0)
        #expect(record.events.filter { $0.kind == .alarmEscalated }.count == (powered ? 1 : 0))
        #expect(arrivals.count == (powered ? alarm.reinforcementCount : 0))
        #expect(record.peakPending <= alarm.reinforcementCount)
        #expect(game.alarmStatus.reinforcementsCommitted == (powered ? alarm.reinforcementCount : 0))
        if !powered { #expect(record.events.compactMap(\.contactReport).allSatisfy { $0.channel == .localShout }) }
    }
}
