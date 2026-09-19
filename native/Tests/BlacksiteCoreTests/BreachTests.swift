import Foundation
import Testing
import simd
@testable import BlacksiteCore

struct BreachTests {
    private func definition(kind: BreachKind = .glass, visibility: BreachVisibility = .clear,
                            health: Float? = nil, start: SIMD3<Float> = SIMD3(0,0,6),
                            target: Bool = false) throws -> MapDefinition {
        var pane = Obstacle(id: 1,kind: kind == .glass ? .glass : .accessPanel,position: .zero,size: SIMD3(3.2,2.8,0.18))
        if let health { pane.health = health }
        let left = Obstacle(id: 2,kind: .bunker,position: SIMD3(-6.8,0,0),size: SIMD3(10.4,3.1,0.35))
        let right = Obstacle(id: 3,kind: .bunker,position: SIMD3(6.8,0,0),size: SIMD3(10.4,3.1,0.35))
        let header = Obstacle(id: 4,kind: .bunker,position: SIMD3(0,2.8,0),size: SIMD3(3.2,0.3,0.35))
        var world = [pane,left,right,header]
        if target { world.append(Obstacle(id: 5,kind: .crate,position: SIMD3(0,0,-5),size: SIMD3(2,2,2))) }
        return try MapDefinition(id: "breach-test",displayName: "Durchbruchprüfung",minimum: SIMD3(-30,0,-30),maximum: SIMD3(30,0,30),
            terrain: .flat,obstacles: world,playerStart: PlayerState(position: start),reinforcementEntries: [SIMD3(24,0,24)],
            waveStaging: [SIMD3(20,0,20)],extraction: SIMD3(0,0,-26),dataSite: SIMD3(-20,0,20),radioSite: SIMD3(20,0,20),
            breaches: [MapBreachDefinition(ownerObstacleID: 1,kind: kind,visibility: visibility,frameObstacleIDs: [2,3,4])])
    }
    private func scene(_ map: MapDefinition, enemies: [EnemyState] = [], difficulty: Difficulty = .easy) -> CombatSimulation {
        CombatSimulation(difficulty: difficulty,seed: 41,world: map.obstacles,startingEnemies: enemies,startingWave: 3,map: map)
    }
    @discardableResult private func advance(_ game: CombatSimulation, _ ticks: Int, input: GameInput = GameInput()) -> [GameEvent] {
        var result: [GameEvent] = []
        for _ in 0..<ticks { game.step(deltaTime: 1.0/120,input: input); result += game.drainEvents() }
        return result
    }
    private func pathLength(_ game: CombatSimulation, from: SIMD3<Float>, to: SIMD3<Float>) -> Float {
        var length: Float = 0, previous = from
        for point in game.findPath(from: from,to: to) { length += simd_distance(previous,point); previous = point }
        return length+simd_distance(previous,to)
    }

    @Test func clearGlassStopsItsBreakingBulletAndOnlyTheFollowingShotReachesTheTarget() throws {
        let game = scene(try definition(target: true))
        #expect(game.breaches[0].damageStage == .intact && game.breaches[0].openedAt == nil)
        #expect(game.sightLine(SIMD3(0,1.6,3),SIMD3(0,1.6,-3)))
        #expect(!game.clearLine(SIMD3(0,1.6,3),SIMD3(0,1.6,-3)))
        #expect(game.fire())
        var events = game.drainEvents()
        #expect(game.obstacles[0].health == 17 && game.breaches[0].damageStage == .damaged)
        #expect(game.obstacles[4].health == 110 && game.blocked(.zero))
        advance(game,13)
        #expect(game.fire()); events += game.drainEvents()
        #expect(game.breaches[0].isOpen && game.obstacles[4].health == 110 && !game.blocked(.zero))
        let broken = try #require(events.first { $0.kind == .breachOpened })
        #expect(broken.id == 1 && broken.breach?.openedAt == game.elapsed && broken.breach?.isOpen == true)
        #expect(broken.hearing?.kind == .breakage && broken.hearing?.surface == .glass && broken.hearing?.position == broken.position)
        advance(game,13)
        #expect(game.fire()); events += game.drainEvents()
        let shots = events.filter { $0.kind == .shot }
        #expect(shots.count == 3 && game.weapons[.rifle]?.ammo == 27)
        #expect(shots[0].surfaceImpact?.material == .glass && shots[1].surfaceImpact?.obstacleID == 1)
        #expect(shots[1].surfaceImpact?.normal == SIMD3<Float>(0,0,1))
        #expect(shots[2].surfaceImpact?.obstacleID == 5 && game.obstacles[4].health == 82)
        #expect(events.filter { $0.kind == .breachOpened }.count == 1 && game.score == 25)
        #expect(game.coverDebris.count == 1 && game.coverDebris[0].solidObstacleID == nil)
        game.damageCover(index: 0,amount: 1000)
        #expect(game.drainEvents().isEmpty && game.score == 25)
    }

    @Test func clearVersusObscuredGlassChangesPerceptionAndSpawnCoverButNeverPhysicalCollision() throws {
        let enemy = EnemyState(id: 8,position: SIMD3(0,0,-12))
        let clear = scene(try definition(),enemies: [enemy])
        let obscured = scene(try definition(visibility: .opaque),enemies: [enemy])
        advance(clear,130); advance(obscured,130)
        #expect(clear.enemies[0].seesPlayer && clear.enemies[0].detectionProgress == 1)
        #expect(!obscured.enemies[0].seesPlayer && obscured.enemies[0].detectionProgress == 0)
        #expect(!clear.reinforcementIsHidden(at: SIMD3(0,0,-10)))
        #expect(obscured.reinforcementIsHidden(at: SIMD3(0,0,-10)))
        for game in [clear,obscured] {
            #expect(game.blocked(.zero) && !game.clearLine(SIMD3(0,1.4,3),SIMD3(0,1.4,-3)))
            #expect(!game.sightLine(SIMD3(3,1.4,3),SIMD3(3,1.4,-3))) // Real frame, not glass.
        }
        obscured.damageCover(index: 0,amount: 1000)
        advance(obscured,130)
        #expect(obscured.enemies[0].seesPlayer && !obscured.reinforcementIsHidden(at: SIMD3(0,0,-10)))
    }

    @Test func enemyFireHitsThePhysicalPaneBeforeItMayDamageThePlayer() throws {
        let game = scene(try definition(health: 13,start: SIMD3(0,0,10)),
                         enemies: [EnemyState(id: 8,position: SIMD3(0,0,-10))],difficulty: .hard)
        var firstShot: GameEvent?
        for _ in 0..<1200 {
            let events = advance(game,1)
            if let shot = events.first(where: { $0.kind == .enemyShot }) { firstShot = shot; break }
        }
        let shot = try #require(firstShot)
        #expect(shot.surfaceImpact?.obstacleID == 1 && shot.surfaceImpact?.material == .glass && shot.amount == 0)
        #expect(game.player.health == 100 && game.breaches[0].isOpen)
        let subsequent = advance(game,1500).filter { $0.kind == .enemyShot }
        #expect(subsequent.contains { $0.amount > 0 && $0.surfaceImpact == nil })
        #expect(game.player.health < 100)
    }

    @Test func openingUpdatesNavigationAndBothPlayerAndGuardCanUseTheActualAperture() throws {
        let map = try definition(kind: .lightPanel,visibility: .opaque,start: SIMD3(0,0,22))
        let game = scene(map,enemies: [EnemyState(id: 8,position: SIMD3(0,0,-8))])
        let from = SIMD3<Float>(0,0,-6), to = SIMD3<Float>(0,0,6)
        #expect(game.hasReachableRoute(from: from,to: to))
        let closedLength = pathLength(game,from: from,to: to)
        game.damageCover(index: 0,amount: 80)
        #expect(game.breaches[0].damageStage == .damaged && !game.sightLine(from+SIMD3(0,1.4,0),to+SIMD3(0,1.4,0)))
        #expect(pathLength(game,from: from,to: to) == closedLength)
        game.damageCover(index: 0,amount: 80)
        #expect(pathLength(game,from: from,to: to) < closedLength-10)
        game.damageEnemy(index: 0,amount: 0.01,from: game.player.position)
        advance(game,1200)
        #expect(game.enemies[0].position.z > 0.6 && game.enemies[0].grounded)
        let walking = scene(try definition(kind: .lightPanel,visibility: .opaque,start: SIMD3(0,0,4)))
        var input = GameInput(); input.moveForward = 1
        advance(walking,120,input: input)
        #expect(walking.player.position.z > 0.4)
        walking.damageCover(index: 0,amount: 160)
        advance(walking,120,input: input)
        #expect(walking.player.position.z < -3 && walking.player.grounded)
    }

    @Test func breakageAndTemporaryShardsAreFiniteAudibleAndHarmlessAcrossPauseAndRetry() throws {
        let map = try definition(start: SIMD3(0,0,1.7))
        let game = scene(map)
        game.damageCover(index: 0,amount: 1000)
        let events = game.drainEvents(), opened = try #require(events.first { $0.kind == .breachOpened })
        #expect(game.acousticSample(for: try #require(opened.hearing),listener: game.eyePosition).audible)
        let age = game.elapsed, debris = game.coverDebris.count
        for dt in [Double(0),-1,.nan,.infinity] { game.step(deltaTime: dt,input: GameInput()) }
        #expect(game.elapsed == age && game.coverDebris.count == debris)
        var input = GameInput(); input.moveForward = 1
        let footsteps = advance(game,65,input: input).filter { $0.kind == .footstep }
        #expect(footsteps.contains { $0.hearing?.surface == .glass })
        #expect(game.player.health == 100 && !game.blocked(.zero))
        advance(game,1440)
        #expect(game.coverDebris.isEmpty && game.breaches[0].isOpen && game.breaches[0].openedAt == age)
        #expect(!game.drainEvents().contains { $0.kind == .breachOpened })
        let reset = scene(map)
        #expect(reset.breaches[0].damageStage == .intact && reset.breaches[0].openedAt == nil && reset.coverDebris.isEmpty)
    }

    @Test func realBlacksiteThresholdsAreGroundedAndShortenOptionalRoutesWithoutReplacingTheOpenBypasses() throws {
        try MapDefinition.blacksite.validateGameplay()
        for definition in MapDefinition.blacksite.breaches {
            let owner = try #require(MapDefinition.blacksite.obstacles.first { $0.id == definition.ownerObstacleID })
            let start = SIMD3<Float>(owner.position.x-3,0,owner.position.z)
            let game = CombatSimulation(world: MapDefinition.blacksite.obstacles,startingPlayer: PlayerState(position: start),startingWave: 3,map: .blacksite)
            let target = game.map.grounded(SIMD3(owner.position.x+3,0,owner.position.z)), from = game.player.position
            let closed = pathLength(game,from: from,to: target)
            #expect(game.hasReachableRoute(from: from,to: target) && closed > 15)
            let index = try #require(game.obstacles.firstIndex { $0.id == owner.id }), grounded = game.obstacles[index]
            for dx: Float in [-0.09,0,0.09] { for dz: Float in [-1.1,0,1.1] {
                #expect(abs(game.terrain.height(x: grounded.position.x+dx,z: grounded.position.z+dz)-grounded.position.y) < 0.001)
            } }
            var input = GameInput(); input.moveRight = 1
            advance(game,120,input: input)
            #expect(game.player.position.x < owner.position.x-0.4)
            game.damageCover(index: index,amount: 1000)
            #expect(pathLength(game,from: from,to: target) < closed-8)
            advance(game,150,input: input)
            #expect(game.player.position.x > owner.position.x+2 && game.player.grounded)
            #expect(game.coverDebris.allSatisfy { $0.solidObstacleID == nil })
            for id in definition.frameObstacleIDs {
                let frame = try #require(game.obstacles.first { $0.id == id })
                #expect(!frame.destroyed && !frame.health.isFinite)
            }
            for anchor in [game.map.dataSite,game.map.radioSite,game.map.extraction] {
                #expect(game.hasReachableRoute(from: game.player.position,to: game.map.grounded(anchor)))
            }
        }
    }

    @Test func elevatedShardsSoundOnlyOnTheirRealRoofSupport() throws {
        let pane = Obstacle(id: 1,kind: .glass,position: SIMD3(0,3,0),size: SIMD3(3.2,2.8,0.18))
        let roof = Obstacle(id: 2,kind: .bunker,position: .zero,size: SIMD3(10,3,10))
        let map = try MapDefinition(id: "roof-glass",displayName: "Dachglas",minimum: SIMD3(-20,0,-20),maximum: SIMD3(20,0,20),
            terrain: .flat,obstacles: [pane,roof],playerStart: PlayerState(position: SIMD3(0,3,1.7)),
            reinforcementEntries: [SIMD3(18,0,18)],waveStaging: [SIMD3(16,0,16)],extraction: SIMD3(0,0,-16),
            dataSite: SIMD3(-16,0,16),radioSite: SIMD3(16,0,16),
            breaches: [MapBreachDefinition(ownerObstacleID: 1,kind: .glass,visibility: .clear)])
        let game = scene(map)
        game.damageCover(index: 0,amount: 1000)
        #expect(game.standingOnGlassShards(at: SIMD3(0,3,0)))
        #expect(!game.standingOnGlassShards(at: .zero))
        var input = GameInput(); input.moveForward = 1
        let events = advance(game,65,input: input)
        #expect(events.contains { $0.kind == .footstep && $0.hearing?.surface == .glass })
        #expect(game.player.grounded && game.player.position.y == 3 && game.player.health == 100)
    }

    @Test func chainExplosionsOpenEachAccessOnceAndRemainInsideTheExistingDebrisBudget() throws {
        var world: [Obstacle] = [], definitions: [MapBreachDefinition] = []
        for index in 0..<16 {
            let position = SIMD3<Float>(Float(index%4)*8-12,0,Float(index/4)*8-12)
            world.append(Obstacle(id: index+1,kind: .glass,position: position,size: SIMD3(2.2,2.8,0.18)))
            definitions.append(MapBreachDefinition(ownerObstacleID: index+1,kind: .glass,visibility: .clear))
        }
        for index in 0..<10 {
            world.append(Obstacle(id: index+30,kind: .crate,position: SIMD3(-24,0,Float(index)*4-20),size: SIMD3(1,1,1)))
        }
        world.append(Obstacle(id: 50,kind: .barrel,position: SIMD3(-12,0,-10),size: SIMD3(0.8,1.15,0.8)))
        world.append(Obstacle(id: 51,kind: .barrel,position: SIMD3(-10,0,-10),size: SIMD3(0.8,1.15,0.8)))
        let map = try MapDefinition(id: "breach-chain",displayName: "Bruchbudget",minimum: SIMD3(-30,0,-30),maximum: SIMD3(30,0,30),
            terrain: .flat,obstacles: world,playerStart: PlayerState(position: SIMD3(26,0,26)),reinforcementEntries: [SIMD3(24,0,24)],
            waveStaging: [SIMD3(20,0,20)],extraction: SIMD3(0,0,-26),dataSite: SIMD3(-20,0,20),radioSite: SIMD3(20,0,20),breaches: definitions)
        let game = scene(map)
        game.explode(at: SIMD3(-12,0.6,-10))
        var events = game.drainEvents()
        #expect(events.filter { $0.kind == .explosion }.count == 3) // Initial blast plus two barrels.
        #expect(game.breaches[0].isOpen && game.obstacles.suffix(2).allSatisfy(\.destroyed))
        for index in game.obstacles.indices { game.damageCover(index: index,amount: 10_000) }
        events += game.drainEvents()
        let score = game.score
        for index in game.obstacles.indices { game.damageCover(index: index,amount: 10_000) }
        #expect(game.drainEvents().isEmpty && game.score == score && score == 28*25)
        #expect(events.filter { $0.kind == .breachOpened }.count == 16)
        #expect(Set(events.filter { $0.kind == .breachOpened }.map(\.id)).count == 16)
        #expect(game.coverDebris.count == CoverDebrisState.maximumCount && game.coverDebris.allSatisfy { $0.solidObstacleID == nil })
        #expect(game.breaches.allSatisfy(\.isOpen) && game.breachOpeningTimes.count == 16)
    }

    @Test func mapBudgetAndOwnerContractsRejectInvalidOrMisleadingAccessElements() throws {
        let valid = try definition()
        func copy(_ breaches: [MapBreachDefinition]) throws -> MapDefinition {
            try MapDefinition(id: valid.id,displayName: valid.displayName,minimum: valid.minimum,maximum: valid.maximum,
                terrain: valid.terrain,obstacles: valid.obstacles,playerStart: valid.playerStart,
                reinforcementEntries: valid.reinforcementEntries,waveStaging: valid.waveStaging,
                extraction: valid.extraction,dataSite: valid.dataSite,radioSite: valid.radioSite,breaches: breaches)
        }
        #expect(throws: MapValidationError.self) { try copy(Array(repeating: valid.breaches[0],count: 17)) }
        #expect(throws: MapValidationError.self) { try copy([MapBreachDefinition(ownerObstacleID: 999,kind: .glass,visibility: .clear)]) }
        #expect(throws: MapValidationError.self) { try copy([MapBreachDefinition(ownerObstacleID: 1,kind: .lightPanel,visibility: .clear)]) }
        #expect(throws: MapValidationError.self) { try copy([MapBreachDefinition(ownerObstacleID: 1,kind: .glass,visibility: .clear,frameObstacleIDs: [1])]) }
        #expect(CombatSimulation(world: []).map.breaches.isEmpty)
    }
}
