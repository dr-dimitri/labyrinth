import Foundation
import Testing
import simd
@testable import BlacksiteCore

@Suite(.serialized)
struct SmokeTests {
    private func emitter(id: Int = 9001, position: SIMD3<Float> = SIMD3(0,0,-7.5), delay: Float = 0,
                         radii: SIMD3<Float> = SIMD3(4,2,4), lifetime: Float = 10, interval: Float = 24,
                         power: Int? = nil) -> SmokeEmitterDefinition {
        SmokeEmitterDefinition(id: id,position: position,radii: radii,density: 4,lifetime: lifetime,
            interval: interval,startDelay: delay,powerDeviceID: power)
    }
    private func map(_ emitters: [SmokeEmitterDefinition], obstacles: [Obstacle] = [], devices: [WorldInteractableDefinition] = [],
                     start: SIMD3<Float> = .zero) throws -> MapDefinition {
        var environment = MapEnvironmentDefinition(); environment.smokeEmitters = emitters; environment.devices = devices
        return try MapDefinition(id: "smoke-test",displayName: "Rauchprüfung",minimum: SIMD3(-30,0,-30),maximum: SIMD3(30,0,30),
            terrain: .flat,obstacles: obstacles,playerStart: PlayerState(position: start),
            reinforcementEntries: [SIMD3(24,0,24)],waveStaging: [SIMD3(20,0,20)],extraction: SIMD3(0,0,-26),
            dataSite: SIMD3(-20,0,20),radioSite: SIMD3(20,0,20),environment: environment)
    }
    private func scene(_ map: MapDefinition, enemy: Bool = false) -> CombatSimulation {
        CombatSimulation(difficulty: .easy,seed: 41,world: map.obstacles,
            startingEnemies: enemy ? [EnemyState(id: 1,position: SIMD3(0,0,-15))] : [],startingWave: 3,map: map)
    }
    @discardableResult private func advance(_ game: CombatSimulation, _ ticks: Int, input: GameInput = GameInput()) -> [GameEvent] {
        var result: [GameEvent] = []
        for _ in 0..<ticks { game.step(deltaTime: 1.0/120,input: input); result += game.drainEvents() }
        return result
    }

    @Test func exactOpticalIntegralHandlesClippedChordsEdgesInsideAndFiniteInputs() {
        let cloud = SmokeVolumeState(id: 1,position: SIMD3(0,1.3,0),age: 2)
        let from = SIMD3<Float>(-6,1.3,0), to = SIMD3<Float>(6,1.3,0)
        let full = cloud.opticalDepth(from: from,to: to)
        #expect(abs(full-7.04) < 0.0001)
        #expect(abs(cloud.opticalDepth(from: cloud.position,to: to)-full*0.5) < 0.0001)
        #expect(abs(cloud.opticalDepth(from: to,to: from)-full) < 0.0001)
        #expect(SmokeVisibilitySample(opticalDepth: full).opaque)
        #expect(cloud.opticalDepth(from: SIMD3(-6,1.3,3),to: SIMD3(6,1.3,3)) == 0)
        #expect(cloud.opticalDepth(from: SIMD3(-6,3.4,0),to: SIMD3(6,3.4,0)) == 0)
        #expect(cloud.opticalDepth(from: from,to: SIMD3(-4,1.3,0)) == 0)
        #expect(cloud.opticalDepth(from: .zero,to: .zero) == 0)
        #expect(cloud.opticalDepth(from: SIMD3(.nan,0,0),to: to) == 0)
        let half = SmokeVolumeState(id: 2,position: cloud.position,age: 2,clipMinimum: SIMD3(0,-1,-3),clipMaximum: SIMD3(3,4,3))
        #expect(abs(half.opticalDepth(from: from,to: to)-full*0.5) < 0.0001)
        #expect(half.density(at: SIMD3(-0.1,1.3,0)) == 0)
        let shifted = SmokeVolumeState(id: 3,position: cloud.position+SIMD3(110,45,215),age: 2)
        #expect(abs(shifted.opticalDepth(from: from+SIMD3(110,45,215),to: to+SIMD3(110,45,215))-full) < 0.0001)
        // An independent numerical integral catches a wrong clipping interval
        // or Gauss coefficient without merely copying the production formula.
        let a = SIMD3<Float>(-4,0.6,-2), b = SIMD3<Float>(4,2.4,2)
        var numerical: Float = 0
        for i in 0..<10_000 { numerical += half.density(at: a+(b-a)*((Float(i)+0.5)/10_000))*simd_distance(a,b)/10_000 }
        #expect(abs(half.opticalDepth(from: a,to: b)-numerical) < 0.001)
    }

    @Test func unknownPlayerRemainsUnseenThroughOpaqueSmokeThenCanBeRecognizedAfterDissipation() throws {
        let obscured = scene(try map([emitter()]),enemy: true), clear = scene(try map([]),enemy: true)
        let events = advance(obscured,600)
        _ = advance(clear,120)
        #expect(clear.enemies[0].seesPlayer && clear.enemies[0].detectionProgress == 1)
        #expect(!obscured.enemies[0].seesPlayer && obscured.enemies[0].detectionProgress == 0)
        #expect(!events.contains { $0.kind == .enemyAlert || $0.kind == .enemyShot })
        #expect(obscured.player.health == 100)
        #expect(obscured.playerSmokeVisibility(from: EnemyPose(obscured.enemies[0]).eyePosition).opaque)
        var detectedAfterFade = false
        for _ in 0..<1800 {
            advance(obscured,1)
            if obscured.enemies[0].seesPlayer { detectedAfterFade = true; break }
        }
        #expect(detectedAfterFade && obscured.elapsed > 7 && obscured.elapsed < 20)
    }

    @Test func confirmedContactStopsTrackingBothHiddenMovementDirectionsWithoutErasingTheSearch() throws {
        let definition = try map([emitter(delay: 2.5)])
        let left = scene(definition,enemy: true), right = scene(definition,enemy: true)
        advance(left,120); advance(right,120)
        #expect(left.enemies[0].seesPlayer && right.enemies[0].seesPlayer)
        for _ in 0..<600 {
            advance(left,1); advance(right,1)
            if !left.enemies[0].seesPlayer && left.playerSmokeVisibility(from: EnemyPose(left.enemies[0]).eyePosition).opaque { break }
        }
        try #require(!left.enemies[0].seesPlayer && left.enemies[0].awareness == .searching)
        #expect(left.enemies[0].windup == 0 && right.enemies[0].windup == 0)
        left.toggleProne(); right.toggleProne()
        var a = GameInput(), b = GameInput(); a.moveRight = -1; b.moveRight = 1
        let aEvents = advance(left,60,input: a), bEvents = advance(right,60,input: b)
        #expect(left.player.position.x < -0.4 && right.player.position.x > 0.4)
        #expect(!left.enemies[0].seesPlayer && !right.enemies[0].seesPlayer)
        #expect(left.enemies[0].awareness == .searching && right.enemies[0].awareness == .searching)
        #expect(left.enemies[0].position == right.enemies[0].position && left.enemies[0].yaw == right.enemies[0].yaw)
        #expect(!aEvents.contains { $0.kind == .enemyShot } && !bEvents.contains { $0.kind == .enemyShot })
    }

    @Test func hardOccludedHeadCannotOverrideOpaqueSmokeOnTheVisibleTorso() throws {
        let lintel = Obstacle(id: 50,kind: .bunker,position: SIMD3(0,1.45,-1.5),size: SIMD3(2,0.5,1))
        let game = scene(try map([emitter(radii: SIMD3(4,0.5,4))],obstacles: [lintel]))
        advance(game,240)
        let observer = SIMD3<Float>(0,1.65,-15)
        #expect(!game.clearLine(observer,game.eyePosition))
        #expect(!game.smokeVisibility(from: observer,to: game.eyePosition).opaque)
        #expect(game.clearLine(observer,game.player.position+SIMD3(0,game.player.height*0.62,0)))
        #expect(game.playerSmokeVisibility(from: observer).opaque)
    }

    @Test func distantSmokeCannotChangeHardCoverPerceptionCadenceDuringRealMovement() throws {
        let wall = Obstacle(id: 50,kind: .bunker,position: SIMD3(8,0,-12),size: SIMD3(1.5,5,30))
        let start = SIMD3<Float>(6,0,4)
        let clear = scene(try map([],obstacles: [wall],start: start),enemy: true)
        let smoke = scene(try map([emitter(position: SIMD3(-24,0,24),radii: SIMD3(1,1,1))],
                                  obstacles: [wall],start: start),enemy: true)
        var sawConfirmedContact = false, sawHardCoverLoss = false
        var firstDifference: Int?, maximumOpticalDepth: Float = 0
        // First earn real visual contact, then walk around the near end of a
        // wall. An unrelated cloud must not upgrade ordinary hard-LOS checks
        // from 10Hz to 120Hz, which previously changed search and combat timing.
        for tick in 0..<360 {
            var input = GameInput()
            if (120..<240).contains(tick) { input.moveRight = 1 }
            advance(clear,1,input: input); advance(smoke,1,input: input)
            let a = clear.enemies[0], b = smoke.enemies[0]
            if a.seesPlayer { sawConfirmedContact = true }
            if sawConfirmedContact && !a.seesPlayer && !clear.clearLine(EnemyPose(a).eyePosition,clear.eyePosition) {
                sawHardCoverLoss = true
            }
            for height in [smoke.player.height,smoke.player.height*0.62,smoke.player.height*0.3] {
                maximumOpticalDepth = max(maximumOpticalDepth,smoke.smokeOpticalDepth(from: EnemyPose(b).eyePosition,
                    to: smoke.player.position+SIMD3(0,height,0)))
            }
            if firstDifference == nil && (a.position != b.position || a.yaw != b.yaw || a.seesPlayer != b.seesPlayer ||
                a.awareness != b.awareness || a.detectionProgress != b.detectionProgress || a.windup != b.windup ||
                clear.player.health != smoke.player.health || clear.player.position != smoke.player.position) {
                firstDifference = tick+1
            }
        }
        #expect(sawConfirmedContact && sawHardCoverLoss)
        #expect(clear.player.position.x > 10 && smoke.smokeVolumes.count == 1 && smoke.smokeVolumes[0].density > 0)
        #expect(maximumOpticalDepth == 0)
        #expect(firstDifference == nil)
    }

    @Test func realGateMotionClipsSteamBeforeAndAfterOpeningAndPowerDoesNotExtendExistingClouds() throws {
        let generator = Obstacle(id: 23,kind: .container,position: SIMD3(12,0,8),size: SIMD3(1.6,1.4,1.2))
        let gate = Obstacle(id: 24,kind: .container,position: .zero,size: SIMD3(6,2.8,0.45))
        let devices = [WorldInteractableDefinition(id: 1001,kind: .generator,ownerObstacleID: 23,interactionPoints: [SIMD3(12,0,9.5)]),
            WorldInteractableDefinition(id: 1002,kind: .serviceGate,ownerObstacleID: 24,interactionPoints: [SIMD3(4,0,0)],generatorID: 1001,openOffset: SIMD3(0,3.4,0))]
        let source = emitter(position: SIMD3(0,0.1,1),radii: SIMD3(3,2,3),power: 1001)
        let game = scene(try map([source],obstacles: [generator,gate],devices: devices,start: SIMD3(4,0,0)))
        advance(game,240)
        let first = try #require(game.smokeVolumes.first), farPoint = SIMD3<Float>(0,1.4,-1)
        #expect(first.clipMinimum.z == 0.225 && first.density(at: farPoint) == 0)
        var held = GameInput(); held.interact = true
        advance(game,120,input: held); advance(game,245)
        let open = try #require(game.smokeVolumes.first)
        #expect(game.devices[1].gateProgress == 1 && open.id == first.id && open.createdAt == first.createdAt)
        #expect(open.density(at: farPoint) > 0 && game.clearLine(SIMD3(0,1.4,2),farPoint))
        advance(game,120,input: held); advance(game,245)
        #expect(game.devices[1].gateProgress == 0 && game.smokeVolumes[0].density(at: farPoint) == 0)
        game.damageCover(index: 0,amount: 10_000)
        let events = advance(game,2400)
        #expect(game.smokeVolumes.isEmpty && !game.devices[0].enabled)
        #expect(events.filter { $0.kind == .smokeDissipated && $0.id == first.id }.count == 1)
        #expect(!events.contains { $0.kind == .smokeActivated })
    }

    @Test func smokeLeavesBulletsGrenadeFlightExplosionDamageAndAcousticPropagationUnchanged() throws {
        let crate = Obstacle(id: 1,kind: .crate,position: SIMD3(0,0,-15),size: SIMD3(2,2,2))
        let clear = scene(try map([],obstacles: [crate])), smoke = scene(try map([emitter()],obstacles: [crate]))
        advance(clear,240); advance(smoke,240)
        #expect(smoke.smokeVisibility(from: smoke.eyePosition,to: SIMD3(0,1.6,-15)).opaque)
        for game in [clear,smoke] {
            #expect(game.traceShot(origin: game.eyePosition,direction: SIMD3(0,0,-1)).obstacleIndex == 0)
            #expect(game.clearLine(game.eyePosition,SIMD3(0,1.6,-12)))
            #expect(game.fire() && game.throwGrenade())
        }
        #expect(clear.obstacles[0].health == smoke.obstacles[0].health)
        let stimulus = HearingStimulus(id: 88,kind: .gunshot,position: SIMD3(0,1,-15),time: 2,strength: 1,range: 44,source: .world)
        #expect(clear.acousticSample(for: stimulus,listener: clear.eyePosition).gain == smoke.acousticSample(for: stimulus,listener: smoke.eyePosition).gain)
        advance(clear,120); advance(smoke,120)
        #expect(clear.grenades[0].position == smoke.grenades[0].position && clear.grenades[0].velocity == smoke.grenades[0].velocity)
        clear.explode(at: SIMD3(0,1,-2)); smoke.explode(at: SIMD3(0,1,-2))
        #expect(clear.player.health == smoke.player.health && clear.player.health < 100)
    }

    @Test func actualThrowsReserveFourSlotsHaveIndependentLifetimesAndFreezeAcrossPauseDeathAndRetry() throws {
        let definition = try map([emitter(id: 1,position: SIMD3(-8,0,-8),lifetime: 4,interval: 10),
                                  emitter(id: 2,position: SIMD3(8,0,-8),lifetime: 4,interval: 10)])
        let game = scene(definition)
        #expect(game.throwSmokeGrenade() && !game.throwSmokeGrenade() && game.smokeGrenadeCount == 1 && game.grenadeCount == 4)
        let firstID = try #require(game.smokeGrenades.first?.id)
        var events = advance(game,96)
        #expect(game.throwSmokeGrenade() && game.smokeGrenadeCount == 0 && !game.throwSmokeGrenade())
        let secondID = try #require(game.smokeGrenades.last?.id)
        events += advance(game,179)
        #expect(game.smokeGrenades.count == 1 && game.smokeGrenades[0].fuse == Float(1)/120)
        events += advance(game,1)
        #expect(game.smokeGrenades.isEmpty && game.smokeVolumes.count == 4)
        #expect(Set(game.smokeVolumes.map(\.id)).count == 4 && firstID != secondID)
        let age = game.smokeVolumes.map(\.age), positions = game.smokeVolumes.map(\.position), time = game.elapsed
        for dt in [Double(0),-1,.nan,.infinity] { game.step(deltaTime: dt,input: GameInput()) }
        #expect(game.elapsed == time && game.smokeVolumes.map(\.age) == age && game.smokeVolumes.map(\.position) == positions)
        for _ in 0..<1560 {
            events += advance(game,1)
            #expect(game.smokeVolumes.count + game.smokeGrenades.count <= 4)
        }
        #expect(game.smokeVolumes.isEmpty && game.smokeGrenades.isEmpty)
        for id in [firstID,secondID] {
            #expect(events.filter { $0.kind == .smokeActivated && $0.id == id }.count == 1)
            #expect(events.filter { $0.kind == .smokeDissipated && $0.id == id }.count == 1)
        }
        #expect(!events.contains { $0.kind == .explosion })
        let doomed = scene(definition); #expect(doomed.throwSmokeGrenade())
        advance(doomed,180); doomed.damagePlayer(amount: 1000,from: .zero)
        let frozen = doomed.smokeVolumes.map(\.age), stock = doomed.smokeGrenadeCount
        advance(doomed,360)
        #expect(doomed.state == .lost && doomed.smokeVolumes.map(\.age) == frozen)
        #expect(!doomed.throwSmokeGrenade() && doomed.smokeGrenadeCount == stock)
        let reset = scene(definition)
        #expect(reset.smokeGrenadeCount == reset.loadout.smokeGrenades && reset.smokeGrenades.isEmpty && reset.smokeVolumes.isEmpty && reset.elapsed == 0)
    }

    @Test func frameRatesAndAuthoredBudgetsCannotChangeTheOpticalOutcome() throws {
        let definition = try map([emitter()])
        var games: [CombatSimulation] = []
        for rate in [30,60,120] {
            let game = scene(definition)
            #expect(game.throwSmokeGrenade())
            for _ in 0..<rate*3 { game.step(deltaTime: 1/Double(rate),input: GameInput()) }
            games.append(game)
        }
        for game in games.dropFirst() {
            #expect(game.smokeVolumes.map(\.age) == games[0].smokeVolumes.map(\.age))
            #expect(game.smokeVolumes.map(\.position) == games[0].smokeVolumes.map(\.position))
            #expect(game.smokeOpticalDepth(from: SIMD3(0,1.6,-15),to: game.eyePosition) == games[0].smokeOpticalDepth(from: SIMD3(0,1.6,-15),to: games[0].eyePosition))
        }
        #expect(throws: MapValidationError.self) { try map([emitter(id: 1),emitter(id: 2),emitter(id: 3)]) }
        #expect(throws: MapValidationError.self) { try map([emitter(),emitter()]) }
        #expect(throws: MapValidationError.self) { try map([emitter(radii: SIMD3(4,0.1,4))]) }
        #expect(throws: MapValidationError.self) { try map([emitter(lifetime: 10,interval: 11)]) }
        #expect(throws: MapValidationError.self) { try map([emitter(power: 999)]) }
        #expect(CombatSimulation(world: []).map.environment.smokeEmitters.isEmpty)
        #expect(MapDefinition.blacksite.environment.smokeEmitters.count == 1)
    }
}
