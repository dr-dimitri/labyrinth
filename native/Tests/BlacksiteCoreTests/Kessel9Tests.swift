import Testing
import simd
@testable import BlacksiteCore

@Suite(.serialized)
struct Kessel9Tests {
    private let map = MapDefinition.kessel9
    private var held: GameInput { var input = GameInput(); input.interact = true; return input }
    private func scene(at point: SIMD3<Float>? = nil, mission: MissionKind = .waves,
                       role: OperatorClass = .assault, enemies: [EnemyState] = [], selected: MapDefinition? = nil) -> CombatSimulation {
        let chosen = selected ?? map
        var player = PlayerState(position: chosen.grounded(point ?? chosen.playerStart.position)); player.health = 10_000
        return CombatSimulation(difficulty: .easy,seed: 1745,world: chosen.obstacles,startingPlayer: player,
            startingEnemies: enemies,startingWave: 3,mission: mission,map: chosen,loadout: .init(operatorClass: role))
    }
    @discardableResult private func advance(_ game: CombatSimulation, _ ticks: Int, input: GameInput = GameInput(), isolate: Bool = false) -> [GameEvent] {
        var events: [GameEvent] = []
        for _ in 0..<ticks {
            if isolate { for i in game.enemies.indices where game.enemies[i].health > 0 { game.damageEnemy(index: i,amount: 10_000) } }
            game.step(deltaTime: 1.0/120,input: input); events += game.drainEvents()
        }
        return events
    }
    private func walk(_ game: CombatSimulation, _ route: [SIMD3<Float>], isolate: Bool = false) throws {
        for target in route {
            var reached = false
            for _ in 0..<2400 {
                let delta = SIMD2(target.x-game.player.position.x,target.z-game.player.position.z)
                if simd_length(delta) < 0.08 { reached = true; break }
                var input = GameInput(); input.moveForward = 1; input.yaw = atan2(-delta.x,-delta.y)
                advance(game,1,input: input,isolate: isolate)
            }
            try #require(reached,"target=\(target), player=\(game.player.position), state=\(game.state)")
        }
    }
    private func device(_ game: CombatSimulation, _ id: Int) -> WorldInteractableState { game.devices.first { $0.id == id }! }
    private func toggle(_ game: CombatSimulation, isolate: Bool = false) {
        advance(game,1,isolate: isolate)
        advance(game,game.loadout.deviceInteractionTicks(manual: false),input: held,isolate: isolate)
        advance(game,245,isolate: isolate)
    }
    private func altered(_ environment: MapEnvironmentDefinition) throws -> MapDefinition {
        try MapDefinition(id: map.id,displayName: map.displayName,minimum: map.minimum,maximum: map.maximum,
            terrain: map.terrain,obstacles: map.obstacles,playerStart: map.playerStart,spawns: map.spawns,
            reinforcementEntries: map.reinforcementEntries,waveStaging: map.waveStaging,
            extraction: map.extraction,dataSite: map.dataSite,radioSite: map.radioSite,
            serviceApproach: map.serviceApproach,environment: environment,operation: map.operation)
    }

    @Test func authoredObjectivesSpawnsAndRealFoundationsAreReachableInBothStates() throws {
        try map.validateGameplay()
        #expect(map.spawns.count == 9 && map.environment.devices.count == 4)
        let game = scene(at: Kessel9Definition.switchPoint)
        for openA in [false,true] {
            if openA { toggle(game) }
            #expect(device(game,2951).gateProgress == (openA ? 1 : 0))
            #expect(device(game,2952).gateProgress == (openA ? 0 : 1))
            for target in map.spawns + map.reinforcementEntries + map.waveStaging + [map.dataSite,map.radioSite] + map.operation!.extractions.map(\.position) {
                #expect(game.hasReachableRoute(from: game.player.position,to: map.grounded(target)),"target=\(target), A=\(openA)")
            }
        }
        for box in map.obstacles {
            for x in [box.minimum.x,box.position.x,box.maximum.x] { for z in [box.minimum.z,box.position.z,box.maximum.z] {
                #expect(abs(map.grounded(box.position).y-map.terrain.height(x: x,z: z)) < 0.0001,"id=\(box.id)")
            } }
        }
        #expect(map.terrain.height(x: 28,z: 10) > map.terrain.height(x: 20,z: 10)+1)
    }

    @Test func pairedCollidersShotsAndCachedNavigationChangeTogetherAndRequireRelease() throws {
        let game = scene(at: Kessel9Definition.switchPoint)
        let near = map.grounded(SIMD3<Float>(-6,0,8)), far = map.grounded(SIMD3<Float>(-6,0,0))
        func pathLength() -> Float {
            let points = [near]+game.findPath(from: near,to: far)
            return zip(points,points.dropFirst()).reduce(0) { $0+simd_distance($1.0,$1.1) }
        }
        let closedLength = pathLength()
        #expect(!game.clearLine(near+SIMD3(0,1.5,0),far+SIMD3(0,1.5,0)))
        #expect(game.clearLine(map.grounded(SIMD3(8,1.5,8)),map.grounded(SIMD3(8,1.5,0))))
        let activated = advance(game,120,input: held)
        #expect(game.deviceInteractionStatus?.action == .switchBulkheads && device(game,2950).isMoving)
        advance(game,100)
        #expect(abs(device(game,2951).gateProgress+device(game,2952).gateProgress-1) < 0.0001)
        let mid = game.obstacles.first { $0.id == 2910 }!
        #expect(mid.minimum.y > 5 && mid.minimum.y < 6)
        #expect(game.clearLine(near+SIMD3(0,0.8,0),far+SIMD3(0,0.8,0)))
        #expect(!game.clearLine(near+SIMD3(0,2.3,0),far+SIMD3(0,2.3,0)))
        advance(game,145,input: held)
        // Release occurred during motor motion, so this new hold has not yet
        // completed a second interaction after the motor actually stops.
        #expect(device(game,2951).gateProgress == 1 && device(game,2952).gateProgress == 0)
        #expect(pathLength() < closedLength-8)
        #expect(game.clearLine(near+SIMD3(0,1.5,0),far+SIMD3(0,1.5,0)))
        #expect(!game.clearLine(map.grounded(SIMD3(8,1.5,8)),map.grounded(SIMD3(8,1.5,0))))
        #expect(activated.filter { $0.kind == .deviceActivated }.count == 1)
        toggle(game)
        #expect(device(game,2951).gateProgress == 0 && pathLength() > 20)
        // A fully held command performs exactly one transition, however long.
        advance(game,1); let heldEvents = advance(game,700,input: held)
        #expect(heldEvents.filter { $0.kind == .deviceActivated }.count == 1)
        #expect(device(game,2950).enabled && game.deviceInteractionStatus?.interruption == .releaseRequired)
    }

    @Test func occupiedClosingWaitsForStandingAndPronePlayersWithoutMovingEitherGate() throws {
        var environment = map.environment
        environment.devices[0] = .init(id: 2950,kind: .maintenanceSwitch,ownerObstacleID: 2930,
            interactionPoints: [SIMD3(8,0,5.6)],linkedGateIDs: [2951,2952])
        let nearby = try altered(environment)
        for prone in [false,true] {
            let game = scene(at: SIMD3(8,0,5.6),selected: nearby)
            if prone { game.toggleProne(); advance(game,90) }
            advance(game,120,input: held)
            try walk(game,[Kessel9Definition.gateB])
            let events = advance(game,480)
            #expect(device(game,2950).blockedByActor && device(game,2951).blockedByActor && device(game,2952).blockedByActor)
            #expect(game.deviceInteractionStatus?.interruption == .blockedByActor)
            let paused = device(game,2950).gateProgress
            advance(game,120)
            #expect(device(game,2950).gateProgress == paused)
            #expect(!game.blocked(game.player.position,height: game.player.height))
            #expect(events.filter { $0.kind == .gateBlocked }.count <= 1)
            try walk(game,[SIMD3(8,0,7)])
            advance(game,480)
            #expect(!device(game,2950).blockedByActor && device(game,2951).gateProgress == 1 && device(game,2952).gateProgress == 0)
        }
    }

    @Test func enemyOnOpeningGatePausesPairAndDestroyedSwitchLeavesActualSafeGeometry() throws {
        let enemy = EnemyState(id: 4000,position: map.grounded(Kessel9Definition.gateA)+SIMD3(0,3.2,0))
        let game = scene(at: Kessel9Definition.switchPoint,enemies: [enemy])
        let events = advance(game,120,input: held)
        #expect(device(game,2950).blockedByActor && device(game,2951).gateProgress == 0 && device(game,2952).gateProgress == 1)
        #expect(events.contains { $0.kind == .gateBlocked && $0.device?.kind == .maintenanceSwitch && $0.device?.blockedByActor == true })
        game.damageEnemy(index: 0,amount: 10_000); advance(game,100)
        let before = game.obstacles.filter { $0.id == 2910 || $0.id == 2911 }.map(\.position)
        game.damageCover(index: try #require(game.obstacles.firstIndex { $0.id == 2930 }),amount: 10_000)
        advance(game,300)
        #expect(device(game,2950).destroyed && !device(game,2951).isMoving && !device(game,2952).powered)
        #expect(before == game.obstacles.filter { $0.id == 2910 || $0.id == 2911 }.map(\.position))
        #expect(game.deviceInteractionStatus?.interruption == .destroyed)
        try walk(game,[SIMD3(8,0,24),SIMD3(28,0,31)]+Array(Kessel9Definition.eastRoute.dropFirst(2)))
        #expect(game.hasReachableRoute(from: game.player.position,to: map.grounded(map.radioSite)))
    }

    @Test func everyClassCompletesDataRadioHoldAndBothExitsWithDefaultPreparedOrDestroyedSwitch() throws {
        // Combat damage is isolated; real input, movement, objectives, terrain,
        // reinforcements, motor timing and both extraction timers remain live.
        for role in OperatorClass.allCases { for condition in 0..<3 {
            let game = scene(mission: .operation,role: role)
            if condition > 0 {
                try walk(game,[Kessel9Definition.switchPoint],isolate: true)
                if condition == 1 { toggle(game,isolate: true) }
                else { game.damageCover(index: try #require(game.obstacles.firstIndex { $0.id == 2930 }),amount: 10_000) }
            }
            let route = condition == 1 ? Kessel9Definition.channelA : condition == 2 ? Kessel9Definition.eastRoute : Kessel9Definition.channelB
            if condition == 2 { try walk(game,[SIMD3(8,0,24),SIMD3(28,0,31)],isolate: true) }
            try walk(game,Array(route.dropFirst(condition == 2 ? 2 : 1)),isolate: true)
            advance(game,96,input: held,isolate: true)
            #expect(game.operationStatus?.stages[0].completed == true && !game.extractionReady)
            #expect(game.missionStatus.phase == .activateRadio)
            let back = condition == 1 ? Kessel9Definition.radioReturnA : condition == 2 ? Kessel9Definition.radioReturnEast : Kessel9Definition.radioReturnB
            try walk(game,Array(back.dropFirst()),isolate: true)
            advance(game,120,input: held,isolate: true)
            #expect(game.missionStatus.phase == .holdRadio && !game.extractionReady)
            advance(game,960,isolate: true)
            #expect(game.extractionReady && game.operationStatus?.stages.allSatisfy(\.completed) == true)
            let north = condition == 1
            try walk(game,Array((north ? Kessel9Definition.northReturn : Kessel9Definition.cableReturn).dropFirst()),isolate: true)
            let events = advance(game,361,isolate: true)
            #expect(game.state == .won && game.selectedExtractionID == (north ? "north" : "cable"))
            #expect(events.filter { $0.kind == .win }.count == 1 && game.loadout.operatorClass == role)
        } }
    }

    @Test func westAndEastRoutesRemainWalkableAfterOptionalCoverDestruction() throws {
        for route in [Kessel9Definition.westRoute,Kessel9Definition.eastRoute] {
            let game = scene()
            for id in game.obstacles.filter({ $0.health.isFinite }).map(\.id) {
                game.damageCover(index: try #require(game.obstacles.firstIndex { $0.id == id }),amount: 10_000)
            }
            try walk(game,Array(route.dropFirst()))
            #expect(game.player.grounded && game.hasReachableRoute(from: game.player.position,to: map.grounded(map.radioSite)))
        }
    }

    @Test func guardsMoveOnBothBypassesAndInvestigateAcrossTheOpenChannelInsteadOfTheClosedBulkhead() throws {
        let soldiers = map.spawns.enumerated().map { EnemyState(id: 4000+$0.offset,position: map.grounded($0.element)) }
        let patrols = scene(enemies: soldiers)
        advance(patrols,720)
        for indices in [[3,5],[4,6]] {
            #expect(indices.contains { horizontalDistance(patrols.enemies[$0].position,soldiers[$0].position) > 1 })
        }
        #expect(patrols.enemies.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite })
        var enemy = EnemyState(id: 4100,position: map.grounded(SIMD3(-6,0,8))); enemy.yaw = .pi
        let pursuit = scene(at: SIMD3(-6,0,0),enemies: [enemy])
        var shot = GameInput(); shot.fire = true; shot.yaw = 0
        advance(pursuit,1,input: shot)
        #expect(pursuit.enemies[0].lastHeard?.kind == .gunshot)
        var crossing: SIMD3<Float>?
        for _ in 0..<1800 {
            advance(pursuit,1)
            let soldier = pursuit.enemies[0]
            // Record the physical crossing. The guard may then stop to aim as
            // soon as it sees the player along the far side of the wall.
            if soldier.position.z < 3 { crossing = soldier.position; break }
        }
        let reached = try #require(crossing,"Guard must use the open B lane or a bypass: \(pursuit.enemies[0].position)")
        #expect(reached.x > 5 && reached.x < 11)
        #expect(device(pursuit,2951).gateProgress == 0 && device(pursuit,2952).gateProgress == 1)
    }

    @Test func invalidCouplingsAreRejectedBeforeSimulationStarts() throws {
        for gates in [[2951],[2951,2951],[2951,9999]] {
            var environment = map.environment
            environment.devices[0] = .init(id: 2950,kind: .maintenanceSwitch,ownerObstacleID: 2930,
                interactionPoints: [Kessel9Definition.switchPoint],linkedGateIDs: gates)
            #expect(throws: MapValidationError.self) { try altered(environment) }
        }
        var sameState = map.environment
        let gate = sameState.devices[2]
        sameState.devices[2] = .init(id: gate.id,kind: gate.kind,ownerObstacleID: gate.ownerObstacleID,
            interactionPoints: gate.interactionPoints,openOffset: gate.openOffset,controllerID: gate.controllerID)
        #expect(throws: MapValidationError.self) { try altered(sameState) }
    }
}
