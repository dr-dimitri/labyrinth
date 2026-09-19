import Testing
import simd
@testable import BlacksiteCore

@Suite(.serialized)
struct ShallowWaterTests {
    private let pool = MapShallowWaterZone(id: 90,minimum: SIMD2(-8,-8),maximum: SIMD2(8,8),surfaceHeight: 0.25)
    private func map(wet: Bool = true, world: [Obstacle] = [], zones: [MapShallowWaterZone]? = nil) throws -> MapDefinition {
        var environment = MapEnvironmentDefinition(); environment.shallowWaterZones = zones ?? (wet ? [pool] : [])
        return try MapDefinition(id: "water-test",displayName: "Wasserprüfung",minimum: SIMD3(-32,0,-32),maximum: SIMD3(32,8,32),
            terrain: .flat,obstacles: world,playerStart: PlayerState(position: SIMD3(0,0,6)),
            reinforcementEntries: [SIMD3(24,0,-24)],waveStaging: [SIMD3(20,0,-20)],
            extraction: SIMD3(24,0,-24),dataSite: SIMD3(-20,0,20),radioSite: SIMD3(20,0,20),environment: environment)
    }
    private func scene(wet: Bool = true, world: [Obstacle] = [], player: PlayerState? = nil,
                       enemies: [EnemyState] = []) throws -> CombatSimulation {
        CombatSimulation(seed: 41,world: world,startingPlayer: player,startingEnemies: enemies,startingWave: 3,
            map: try map(wet: wet,world: world))
    }
    @discardableResult private func advance(_ game: CombatSimulation, _ ticks: Int, input: GameInput = GameInput()) -> [GameEvent] {
        var events: [GameEvent] = []
        for _ in 0..<ticks { game.step(deltaTime: 1.0/120,input: input); events += game.drainEvents() }
        return events
    }

    @Test func supportedWalkingHasDeterministicDistanceCadenceAndOneSharedWaterSurface() throws {
        var sequences: [[SurfaceSound]] = []
        for fps in [30,60,120] {
            let wet = try scene(), dry = try scene(wet: false)
            var input = GameInput(); input.moveForward = 1
            var events: [GameEvent] = []
            for _ in 0..<fps {
                wet.step(deltaTime: 1.0/Double(fps),input: input); dry.step(deltaTime: 1.0/Double(fps),input: input)
                events += wet.drainEvents()
            }
            #expect(abs((6-wet.player.position.z)/(6-dry.player.position.z)-0.65) < 0.0001)
            let sounds = events.filter { $0.kind == .footstep }.compactMap(\.hearing)
            #expect(sounds.count == 1 && sounds.allSatisfy { $0.surface == .water && abs($0.position.y-0.31) < 0.0001 && $0.strength >= 0.4 })
            #expect(wet.player.position.y == 0 && wet.environmentSample(at: wet.player.position).waterDepth == 0.25)
            #expect(wet.environmentSample(at: wet.player.position).camouflageGround == .none)
            sequences.append(sounds.compactMap(\.surface))
            let time = wet.elapsed; wet.step(deltaTime: 0,input: input)
            #expect(wet.elapsed == time && wet.drainEvents().isEmpty)
        }
        #expect(sequences[0] == sequences[1] && sequences[1] == sequences[2])
        let crawling = try scene(); crawling.toggleProne()
        var crawl = GameInput(); crawl.moveForward = 1
        let crawlStep = try #require(advance(crawling,150,input: crawl).first { $0.kind == .footstep }?.hearing)
        #expect(crawlStep.surface == .water && crawlStep.strength >= 0.4)
    }

    @Test func physicalRoofsAndRealDebrisStayDryUntilTheirSupportDisappears() throws {
        let roof = Obstacle(id: 4,kind: .container,position: SIMD3(0,0,4),size: SIMD3(6,3,8))
        let game = try scene(world: [roof],player: PlayerState(position: SIMD3(0,3,6)))
        #expect(game.waterContact(at: game.player.position) == nil)
        #expect(game.environmentSample(at: game.player.position).soundSurface == .metal)
        #expect(game.waterContact(at: SIMD3(0,0.4,0),grounded: false) == nil)
        var input = GameInput(); input.moveForward = 1
        let sounds = advance(game,50,input: input).compactMap(\.hearing).filter { $0.kind == .footstep }
        #expect(sounds.count == 1 && sounds[0].surface == .metal)
        let barrier = Obstacle(id: 5,kind: .barrier,position: SIMD3(0,0,4),size: SIMD3(5,1.4,5))
        let remnants = try scene(world: [barrier],player: PlayerState(position: SIMD3(0,1.4,4)))
        remnants.damageCover(index: 0,amount: 1000)
        advance(remnants,80)
        #expect(abs(remnants.player.position.y-0.5) < 0.001 && remnants.player.grounded)
        #expect(remnants.waterContact(at: remnants.player.position) == nil)
        advance(remnants,2400)
        #expect(remnants.coverDebris.isEmpty && remnants.player.grounded && remnants.player.position.y == 0)
        #expect(remnants.waterContact(at: remnants.player.position)?.depth == 0.25)
    }

    @Test func repeatedJumpsAreQuietInFlightButBothActorsLandAudiblyOnTheRealPlane() throws {
        let game = try scene()
        for _ in 0..<3 {
            #expect(game.jump()); var events: [GameEvent] = [], airborne = 0
            for _ in 0..<180 {
                let batch = advance(game,1); events += batch
                if !game.player.grounded {
                    airborne += 1; #expect(!batch.contains { $0.kind == .footstep })
                } else { break }
            }
            let landings = events.filter { $0.kind == .land }
            #expect(airborne > 50 && landings.count == 1)
            let sound = try #require(landings.first?.hearing)
            #expect(sound.surface == .water && sound.strength >= 0.55 && abs(sound.position.y-0.31) < 0.0001)
            #expect(landings[0].position.y == 0 && game.player.grounded)
        }
        var falling = EnemyState(id: 71,position: SIMD3(2,2,2)); falling.grounded = false; falling.verticalVelocity = -1
        let enemy = try scene(player: PlayerState(position: SIMD3(-25,0,-25)),enemies: [falling])
        let events = advance(enemy,90)
        let enemyLand = events.filter { $0.kind == .land && $0.hearing?.source == .enemy }
        #expect(enemyLand.count == 1 && enemyLand[0].hearing?.sourceID == 71 && enemyLand[0].hearing?.surface == .water)
        #expect(enemy.enemies[0].grounded && enemy.enemies[0].position.y == 0)
    }

    @Test func wetEnemyPursuitSlowsAndWaterNoiseRecordsAFrozenContact() throws {
        var enemy = EnemyState(id: 8,position: SIMD3(0,0,5)); enemy.yaw = .pi
        let wet = try scene(player: PlayerState(position: SIMD3(0,0,-25)),enemies: [enemy])
        let dry = try scene(wet: false,player: PlayerState(position: SIMD3(0,0,-25)),enemies: [enemy])
        for game in [wet,dry] { game.damageEnemy(index: 0,amount: 0.01); _ = game.drainEvents() }
        // A real hit causes 0.25 s recoil and a crouched response. Two seconds
        // allow a complete wet stride; the first second travels only 0.616 m.
        advance(wet,240); advance(dry,240)
        let wetDistance = simd_distance(wet.enemies[0].position,enemy.position)
        let dryDistance = simd_distance(dry.enemies[0].position,enemy.position)
        #expect(dryDistance > 1 && wetDistance < dryDistance*0.8 && wetDistance > dryDistance*0.5)
        #expect(wet.hearingStimuli.contains { $0.kind == .footstep && $0.source == .enemy && $0.surface == .water })
        // A nearby guard looks away. Actual wading, not a synthetic noise call,
        // causes an observation which must not follow a later airborne player.
        var listener = EnemyState(id: 9,position: SIMD3(3,0,4)); listener.yaw = .pi/2
        let heard = try scene(enemies: [listener]); var movement = GameInput(); movement.moveForward = 1
        let steps = advance(heard,70,input: movement).filter { $0.kind == .footstep && $0.hearing?.source == .player }
        let step = try #require(steps.first?.hearing), snapshot = try #require(heard.enemies[0].lastHeard)
        #expect(snapshot.position == step.position && snapshot.time == step.time && snapshot.kind == .footstep)
        #expect(heard.jump()); advance(heard,30,input: movement)
        #expect(heard.enemies[0].lastHeard?.position == snapshot.position && heard.enemies[0].lastHeard?.time == snapshot.time)
        #expect(simd_distance(heard.player.position,snapshot.position) > 0.5)
    }

    @Test func actualBulletsAndSubmergedBlastsKeepPhysicalHitsAndEmitOnlyTheFirstSurfaceCrossing() throws {
        var player = PlayerState(position: SIMD3(0,0,6)); player.pitch = -0.65
        let wet = try scene(player: player), dry = try scene(wet: false,player: player)
        #expect(wet.fire() && dry.fire())
        let events = wet.drainEvents(), shot = try #require(events.first { $0.kind == .shot })
        let dryShot = try #require(dry.drainEvents().first { $0.kind == .shot })
        let splash = try #require(shot.waterImpact)
        #expect(events.filter { $0.kind == .shot }.count == 1 && shot.endPosition == dryShot.endPosition)
        #expect(shot.surfaceImpact?.material == .soil && abs(shot.endPosition.y) < 0.00001)
        #expect(splash.zoneID == 90 && splash.position.y == 0.25 && splash.normal == SIMD3<Float>(0,1,0))
        #expect(simd_distance(shot.position,splash.position) < simd_distance(shot.position,shot.endPosition))
        #expect(dryShot.waterImpact == nil && wet.weapons[.rifle]?.ammo == dry.weapons[.rifle]?.ammo)
        let wall = Obstacle(id: 5,kind: .bunker,position: SIMD3(0,0,5),size: SIMD3(4,3,0.2))
        let stopped = try scene(world: [wall],player: player); #expect(stopped.fire())
        let wallShot = try #require(stopped.drainEvents().first { $0.kind == .shot })
        #expect(wallShot.surfaceImpact?.obstacleID == 5 && wallShot.waterImpact == nil)
        #expect(wet.waterImpact(from: SIMD3(0,1,0),to: SIMD3(4,1,0)) == nil)
        let blast = try scene(player: PlayerState(position: SIMD3(20,0,20)))
        blast.explode(at: SIMD3(0,0.1,0))
        let explosion = try #require(blast.drainEvents().first { $0.kind == .explosion })
        #expect(simd_distance(explosion.position,SIMD3<Float>(0,0.28,0)) < 0.00001 && explosion.waterImpact?.position == SIMD3<Float>(0,0.25,0))
    }

    @Test func authoringRejectsDeepOverlappingAndUnboundedPools() throws {
        for zone in [MapShallowWaterZone(id: 1,minimum: SIMD2(-8,-8),maximum: SIMD2(8,8),surfaceHeight: 0.5),
                     MapShallowWaterZone(id: 1,minimum: SIMD2(-8,-8),maximum: SIMD2(8,8),surfaceHeight: 0.25,movementMultiplier: 0.1)] {
            #expect(throws: MapValidationError.self) { try map(zones: [zone]) }
        }
        #expect(throws: MapValidationError.self) { try map(zones: [pool,pool]) }
        #expect(throws: MapValidationError.self) { try map(zones: (0..<5).map { MapShallowWaterZone(id: $0,minimum: SIMD2(-2,-2),maximum: SIMD2(2,2),surfaceHeight: 0.25) }) }
        #expect(try map(wet: false).environment.shallowWaterZones.isEmpty)
    }
}
