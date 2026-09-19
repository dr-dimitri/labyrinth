import Testing
import simd
@testable import BlacksiteCore

@Suite(.serialized)
struct SiroccoTests {
    private let map = MapDefinition.sirocco
    private var held: GameInput { var input = GameInput(); input.interact = true; return input }
    private func scene(at point: SIMD3<Float>? = nil,mission: MissionKind = .waves,
                       role: OperatorClass = .assault,enemies: [EnemyState] = []) -> CombatSimulation {
        CombatSimulation(difficulty: .easy,seed: 1745,world: map.obstacles,
            startingPlayer: point.map { PlayerState(position: $0) },startingEnemies: enemies,
            startingWave: 3,mission: mission,map: map,loadout: .init(operatorClass: role))
    }
    @discardableResult private func advance(_ game: CombatSimulation,_ ticks: Int,input: GameInput = GameInput(),
                                            isolateCombat: Bool = false) -> [GameEvent] {
        var events: [GameEvent] = []
        for _ in 0..<ticks {
            if isolateCombat { for index in game.enemies.indices where game.enemies[index].health > 0 { game.damageEnemy(index: index,amount: 10_000) } }
            game.step(deltaTime: 1.0/120,input: input); events += game.drainEvents()
        }
        return events
    }
    private func walk(_ game: CombatSimulation,_ points: [SIMD3<Float>],isolateCombat: Bool = false) throws {
        for point in points {
            var reached = false
            for _ in 0..<2400 {
                let delta = SIMD2(point.x-game.player.position.x,point.z-game.player.position.z)
                if simd_length(delta) < 0.08 { reached = true; break }
                var input = GameInput(); input.moveForward = 1; input.yaw = atan2(-delta.x,-delta.y)
                advance(game,1,input: input,isolateCombat: isolateCombat)
            }
            try #require(reached,"target=\(point), actual=\(game.player.position), state=\(game.state)")
        }
    }
    private func breakAllCover(_ game: CombatSimulation) {
        for id in game.obstacles.filter({ $0.health.isFinite }).map(\.id) {
            if let index = game.obstacles.firstIndex(where: { $0.id == id }) { game.damageCover(index: index,amount: 10_000) }
        }
    }
    private func pathLength(_ game: CombatSimulation,from: SIMD3<Float>,to: SIMD3<Float>) -> Float {
        let route = [from]+game.findPath(from: from,to: to)+[to]
        return zip(route,route.dropFirst()).reduce(0) { $0+simd_distance($1.0,$1.1) }
    }

    @Test func saltBankAndEverySolidFoundationAreRealAndNineGuardsCanPatrol() throws {
        try map.validateGameplay()
        #expect(map.spawns.count == 9 && map.breaches.count == 12)
        #expect(map.breaches.filter { $0.visibility == .opaque }.count == 8)
        #expect(map.breaches.filter { $0.visibility == .clear }.count == 4)
        #expect(map.environment.vegetationZones.isEmpty && map.environment.shallowWaterZones.isEmpty)
        #expect(abs(map.terrain.height(x: 0,z: 0)-1) < 0.001)
        #expect(abs(map.terrain.height(x: 30,z: 0)-2.8) < 0.001)
        #expect(map.terrain.height(x: 30,z: 24) > 1 && map.terrain.height(x: 30,z: 24) < 2.8)
        #expect(!map.resources.texturePaths.values.contains { $0.contains("pine") || $0.contains("bark") })
        let game = scene()
        for box in game.obstacles {
            let offset: Float = [3034,3035].contains(box.id) ? 3 : 0
            for x in [box.minimum.x,box.position.x,box.maximum.x] { for z in [box.minimum.z,box.position.z,box.maximum.z] {
                #expect(abs(box.minimum.y-map.terrain.height(x: x,z: z)-offset) < 0.001,"owner=\(box.id)")
            } }
        }
        let guards = map.spawns.enumerated().map { EnemyState(id: 4000+$0.offset,position: map.grounded($0.element)) }
        let patrol = scene(enemies: guards)
        advance(patrol,600)
        #expect(patrol.enemies.count == 9 && patrol.state == .active)
        #expect(patrol.enemies.enumerated().contains { simd_distance($0.element.position,guards[$0.offset].position) > 1 })
        #expect(patrol.enemies.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite })
    }

    @Test func threeGroundRoutesRadioAndBothExitsWorkWithIntactOrDestroyedPanes() throws {
        for destroyed in [false,true] {
            for route in [SiroccoDefinition.westRoute,SiroccoDefinition.centralRoute,SiroccoDefinition.eastRoute,
                          SiroccoDefinition.dataToRadioRoute,SiroccoDefinition.northReturnRoute,SiroccoDefinition.saltReturnRoute] {
                let game = scene(at: route[0])
                if destroyed { breakAllCover(game) }
                #expect(game.hasReachableRoute(from: game.player.position,to: map.grounded(route.last!)))
                try walk(game,Array(route.dropFirst()))
                #expect(game.player.grounded && abs(game.player.position.y-map.terrain.height(x: game.player.position.x,z: game.player.position.z)) < 0.05)
            }
        }
    }

    @Test func everyPaneHasHonestVisibilityAndOpeningAllowsThePlayerThroughItsRetainedFrame() throws {
        for definition in map.breaches {
            let owner = try #require(map.obstacles.first { $0.id == definition.ownerObstacleID })
            let from = map.grounded(owner.position+SIMD3(-2,0,0)), to = map.grounded(owner.position+SIMD3(4,0,0))
            let game = scene(at: owner.position+SIMD3(-2,0,0))
            let index = try #require(game.obstacles.firstIndex { $0.id == owner.id })
            let eyeFrom = from+SIMD3(0,1.6,0), eyeTo = to+SIMD3(0,1.6,0)
            #expect(game.sightLine(eyeFrom,eyeTo) == (definition.visibility == .clear))
            #expect(!game.clearLine(eyeFrom,eyeTo) && game.blocked(map.grounded(owner.position)))
            let closed = pathLength(game,from: from,to: to)
            var input = GameInput(); input.moveRight = 1
            advance(game,75,input: input)
            #expect(game.player.position.x < owner.position.x-0.3)
            game.damageCover(index: index,amount: 28)
            #expect(game.breaches.first { $0.id == owner.id }?.damageStage == .damaged)
            #expect(game.sightLine(eyeFrom,eyeTo) == (definition.visibility == .clear))
            game.damageCover(index: index,amount: 28)
            #expect(game.sightLine(eyeFrom,eyeTo) && game.clearLine(eyeFrom,eyeTo))
            #expect(pathLength(game,from: from,to: to) < closed-6)
            try walk(game,[owner.position+SIMD3(4,0,0)])
            #expect(game.player.grounded)
            for id in definition.frameObstacleIDs {
                let frame = try #require(game.obstacles.first { $0.id == id })
                #expect(!frame.destroyed && !frame.health.isFinite)
            }
            #expect(game.coverDebris.allSatisfy { $0.solidObstacleID == nil })
        }
    }

    @Test func alertedGuardActuallyCrossesAnOpenedOpaqueSideInsteadOfDetouringAroundTheGreenhouse() throws {
        var guardState = EnemyState(id: 4001,position: map.grounded(SIMD3(-17,0,-2.3)))
        guardState.yaw = -.pi/2
        let game = scene(at: SIMD3(10,0,-2.3),enemies: [guardState])
        let index = try #require(game.obstacles.firstIndex { $0.id == 3003 })
        #expect(!game.sightLine(guardState.position+SIMD3(0,1.6,0),game.eyePosition))
        game.damageCover(index: index,amount: 1000)
        game.damageEnemy(index: 0,amount: 0.01,from: game.player.position)
        var crossing: SIMD3<Float>?
        for _ in 0..<2400 {
            advance(game,1)
            if game.enemies[0].position.x > -11.5 { crossing = game.enemies[0].position; break }
        }
        let point = try #require(crossing,"guard=\(game.enemies[0].position), state=\(game.state), awareness=\(game.enemies[0].awareness)")
        #expect(abs(point.z+2.3) < 2 && game.enemies[0].grounded && game.state == .active)
    }

    @Test func openingOneOpaqueRadioPaneShortensTheActualSaltReturnAndRemovesItsCover() throws {
        let game = scene(at: map.radioSite), intact = scene(at: map.radioSite)
        let index = try #require(game.obstacles.firstIndex { $0.id == 3010 })
        let from = map.grounded(SIMD3(9,0,3.5))+SIMD3(0,1.6,0), to = map.grounded(SIMD3(14,0,3.5))+SIMD3(0,1.6,0)
        #expect(!game.sightLine(from,to))
        game.damageCover(index: index,amount: 1000)
        func length(_ route: [SIMD3<Float>]) -> Float {
            zip(route,route.dropFirst()).reduce(0) { $0+simd_distance(map.grounded($1.0),map.grounded($1.1)) }
        }
        #expect(length(SiroccoDefinition.breachedSaltReturnRoute) < length(SiroccoDefinition.saltReturnRoute)-2)
        #expect(game.sightLine(from,to) && game.breaches.filter(\.isOpen).count == 1)
        try walk(intact,Array(SiroccoDefinition.saltReturnRoute.dropFirst()))
        try walk(game,Array(SiroccoDefinition.breachedSaltReturnRoute.dropFirst()))
        #expect(game.player.grounded && intact.player.grounded)
        #expect(game.elapsed < intact.elapsed-0.3,"intact=\(intact.elapsed), breached=\(game.elapsed)")
    }

    @Test func optionalPumpRoofClimbUsesRealStepsWhileGroundRouteStaysOpen() throws {
        var player = PlayerState(position: SIMD3(19.8,0,8)); player.yaw = -.pi/2
        let game = CombatSimulation(world: map.obstacles,startingPlayer: player,startingWave: 3,map: map)
        var input = GameInput(); input.yaw = player.yaw
        for (stage,id) in [3046,3047,3045].enumerated() {
            if stage > 0 { input.moveForward = 1; advance(game,8,input: input); input.moveForward = 0 }
            try #require(game.mantle(),"owner=\(id), actual=\(game.player.position)")
            advance(game,100,input: input)
            let owner = try #require(game.obstacles.first { $0.id == id })
            #expect(game.player.grounded && abs(game.player.position.y-owner.maximum.y) < 0.001)
        }
        try walk(game,[SIMD3(33,0,8)]); advance(game,120)
        #expect(game.player.grounded && abs(game.player.position.y-map.terrain.height(x: 33,z: 8)) < 0.001)
    }

    @Test func everyClassCompletesDataThenRadioHoldAndBothExitsWithRealMovement() throws {
        // Combat is isolated here so route/objective assertions remain stable;
        // the dedicated patrol and breach checks exercise real enemy movement.
        for role in OperatorClass.allCases { for destroyed in [false,true] {
            let game = scene(mission: .operation,role: role)
            if destroyed { breakAllCover(game) }
            let route = destroyed ? SiroccoDefinition.eastRoute : SiroccoDefinition.centralRoute
            try walk(game,Array(route.dropFirst()),isolateCombat: true)
            var events = advance(game,96,input: held,isolateCombat: true)
            #expect(game.missionStatus.phase == .activateRadio && !game.extractionReady)
            try walk(game,Array(SiroccoDefinition.dataToRadioRoute.dropFirst()),isolateCombat: true)
            events += advance(game,96,input: held,isolateCombat: true)
            #expect(game.missionStatus.phase == .holdRadio && game.missionStatus.progress == 0)
            events += advance(game,1439,isolateCombat: true)
            #expect(!game.extractionReady && game.missionStatus.phase == .holdRadio)
            events += advance(game,1,isolateCombat: true)
            #expect(game.extractionReady && game.operationStatus?.stages.allSatisfy(\.completed) == true)
            let exitRoute = destroyed ? SiroccoDefinition.breachedSaltReturnRoute : SiroccoDefinition.northReturnRoute
            try walk(game,Array(exitRoute.dropFirst()),isolateCombat: true)
            events += advance(game,361,isolateCombat: true)
            #expect(game.state == .won && game.selectedExtractionID == (destroyed ? "salt" : "north"))
            #expect(game.loadout.operatorClass == role && game.pendingReinforcements == 0)
            #expect(events.filter { $0.kind == .operationObjectiveCompleted }.compactMap(\.operationObjective).map(\.id) == ["greenhouse-data","salt-radio"])
            #expect(events.filter { $0.kind == .win }.count == 1)
        } }
    }

    @Test func prematureRadioExitAndInterruptedHoldCannotCompleteTheOperationOrLeakIntoRetry() throws {
        let locked = scene(at: map.radioSite,mission: .operation)
        #expect(locked.missionContextAvailable && !locked.missionInteractionAvailable)
        #expect(locked.missionStatus.interruption == .prerequisites)
        advance(locked,240,input: held,isolateCombat: true)
        #expect(!locked.extractionReady && locked.operationStatus?.stages.flatMap(\.targets).contains(where: \.completed) == false)
        let exit = scene(at: SiroccoDefinition.northExit,mission: .operation)
        advance(exit,600,isolateCombat: true)
        #expect(exit.state == .active && exit.extractionProgress == 0)
        let game = scene(at: map.dataSite,mission: .operation)
        advance(game,96,input: held,isolateCombat: true)
        try walk(game,Array(SiroccoDefinition.dataToRadioRoute.dropFirst()),isolateCombat: true)
        advance(game,96,input: held,isolateCombat: true)
        advance(game,240,isolateCombat: true)
        try walk(game,[SIMD3(0,0,7)],isolateCombat: true)
        let progress = game.missionStatus.progress, elapsed = game.elapsed
        #expect(game.missionStatus.interruption == .outOfRange)
        game.step(deltaTime: 0,input: held)
        #expect(game.elapsed == elapsed && game.missionStatus.progress == progress)
        advance(game,240,isolateCombat: true)
        #expect(game.missionStatus.progress == progress && !game.extractionReady)
        try walk(game,[map.radioSite],isolateCombat: true)
        advance(game,1440,isolateCombat: true)
        #expect(game.extractionReady)
        let retry = scene(mission: .operation)
        #expect(retry.breaches.allSatisfy { !$0.isOpen && $0.openedAt == nil })
        #expect(retry.missionStatus.progress == 0 && !retry.extractionReady && retry.coverDebris.isEmpty)
    }
}
