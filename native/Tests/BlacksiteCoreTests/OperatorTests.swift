import Foundation
import Testing
import simd
@testable import BlacksiteCore

@Suite(.serialized)
struct OperatorTests {
    private func fixture(pane: BreachVisibility? = nil, paneKind: ObstacleKind = .glass, extra: [Obstacle] = [], smoke: Bool = false,
                         terrain: TerrainProfile = .flat, start: SIMD3<Float> = SIMD3(0,0,6)) throws -> MapDefinition {
        var world = extra, breaches: [MapBreachDefinition] = []
        if let pane {
            world.append(Obstacle(id: 1,kind: paneKind,position: .zero,size: SIMD3(3.2,2.8,0.18)))
            breaches = [MapBreachDefinition(ownerObstacleID: 1,kind: paneKind == .glass ? .glass : .lightPanel,visibility: pane)]
        }
        var environment = MapEnvironmentDefinition()
        if smoke { environment.smokeEmitters = [SmokeEmitterDefinition(id: 9001,position: SIMD3(0,0,-2),radii: SIMD3(4,2,4),density: 4,startDelay: 0)] }
        return try MapDefinition(id: "operator-test",displayName: "Klassenprüfung",minimum: SIMD3(-30,0,-30),maximum: SIMD3(30,0,30),
            terrain: terrain,obstacles: world,playerStart: PlayerState(position: start),reinforcementEntries: [SIMD3(24,0,24)],
            waveStaging: [SIMD3(20,0,20)],extraction: SIMD3(0,0,-26),dataSite: SIMD3(-20,0,20),radioSite: SIMD3(20,0,20),
            environment: environment,breaches: breaches)
    }
    private func scene(_ map: MapDefinition, role: OperatorClass, enemies: [EnemyState] = []) -> CombatSimulation {
        CombatSimulation(difficulty: .easy,seed: 41,world: map.obstacles,startingEnemies: enemies,startingWave: 3,map: map,
                         loadout: .init(operatorClass: role))
    }
    private func witness(_ id: Int = 8, at point: SIMD3<Float> = SIMD3(0,0,-10)) -> EnemyState {
        var enemy = EnemyState(id: id,position: point); enemy.yaw = .pi; return enemy
    }
    private func aim(_ game: CombatSimulation, at point: SIMD3<Float>) -> GameInput {
        let delta = point-game.eyePosition
        var input = GameInput(); input.aim = true
        input.yaw = atan2(-delta.x,-delta.z); input.pitch = atan2(delta.y,hypot(delta.x,delta.z))
        return input
    }
    @discardableResult private func advance(_ game: CombatSimulation, _ ticks: Int, input: GameInput = GameInput(),
                                            isolateCombat: Bool = false) -> [GameEvent] {
        var events: [GameEvent] = []
        for _ in 0..<ticks {
            game.step(deltaTime: 1.0/120,input: input)
            if isolateCombat { for index in game.enemies.indices where game.enemies[index].health > 0 { game.damageEnemy(index: index,amount: 10_000) } }
            events += game.drainEvents()
        }
        return events
    }
    private func walk(_ game: CombatSimulation, through points: [SIMD2<Float>], events: inout [GameEvent], isolateCombat: Bool = false) throws {
        for point in points {
            var reached = false
            for _ in 0..<3000 {
                let delta = point-SIMD2(game.player.position.x,game.player.position.z)
                if simd_length(delta) < 0.08 { reached = true; break }
                var input = GameInput(); input.moveForward = 1; input.yaw = atan2(-delta.x,-delta.y)
                events += advance(game,1,input: input,isolateCombat: isolateCombat)
            }
            try #require(reached,"role=\(game.loadout.operatorClass), target=\(point), player=\(game.player.position)")
        }
    }

    @Test func eachImmutableKitOwnsItsActualInventoryReserveAndCamouflageTradeoff() {
        for role in OperatorClass.allCases { for camouflage in CamouflagePattern.allCases {
            let kit = LoadoutDefinition(operatorClass: role,camouflage: camouflage)
            let game = CombatSimulation(world: [],startingWave: 3,loadout: kit)
            #expect(game.loadout == kit && game.player.health == 100)
            #expect(game.grenadeCount == (role == .recon ? 3 : 4)-(camouflage == .none ? 0 : 1))
            #expect(game.noiseDecoyCount == (role == .recon ? 1 : 0))
            #expect(game.smokeGrenadeCount == (role == .assault ? 2 : 0))
            #expect(game.breachChargeCount == (role == .engineer ? 1 : 0))
            #expect(game.weapons[.rifle]?.reserve == (role == .recon ? 210 : role == .engineer ? 120 : 270))
            #expect(game.weapons[.sniper]?.reserve == 35 && game.weapons[.sniper]?.ammo == 5 && game.weapons[.rifle]?.ammo == 30)
            #expect(kit.deviceInteractionTicks(manual: false) == (role == .engineer ? 78 : 120))
            #expect(kit.deviceInteractionTicks(manual: true) == (role == .engineer ? 156 : 240))
        } }
        #expect(LoadoutDefinition().operatorClass == .assault)
    }

    @Test func observationRequiresADSAndActualSightIncludingGlassAndOpaqueSmoke() throws {
        for visibility in [BreachVisibility.clear,.opaque] {
            let game = scene(try fixture(pane: visibility),role: .recon,enemies: [witness()])
            #expect(!game.useClassGadget() && game.reconMarks.isEmpty)
            let input = aim(game,at: EnemyPose(game.enemies[0]).bodyCenter)
            advance(game,1,input: input)
            #expect(game.useClassGadget() == (visibility == .clear))
            #expect(game.reconMarks.count == (visibility == .clear ? 1 : 0))
            #expect(!game.useClassGadget())
            #expect(game.weapons[.rifle]?.ammo == 30 && game.noiseDecoyCount == 1)
        }
        let smoky = scene(try fixture(smoke: true),role: .recon,enemies: [witness()])
        advance(smoky,240)
        let input = aim(smoky,at: EnemyPose(smoky.enemies[0]).bodyCenter)
        advance(smoky,1,input: input)
        #expect(smoky.smokeVisibility(from: smoky.eyePosition,to: EnemyPose(smoky.enemies[0]).bodyCenter).opaque)
        #expect(!smoky.useClassGadget() && smoky.reconMarks.isEmpty)
        let empty = scene(try fixture(),role: .recon)
        var ads = GameInput(); ads.aim = true; advance(empty,1,input: ads)
        #expect(!empty.useClassGadget() && empty.reconMarks.isEmpty)
    }

    @Test func observedPointsStayFrozenHideBehindCoverExpireAndNeverTrackTheTarget() throws {
        let wall = Obstacle(id: 2,kind: .bunker,position: SIMD3(2,0,-8),size: SIMD3(0.5,4,18))
        let game = scene(try fixture(extra: [wall]),role: .recon,enemies: [witness()])
        advance(game,1,input: aim(game,at: EnemyPose(game.enemies[0]).bodyCenter))
        #expect(game.useClassGadget())
        let mark = try #require(game.reconMarks.first), enemyStart = game.enemies[0].position
        #expect(game.visibleReconMarks == [mark])
        game.damageEnemy(index: 0,amount: 0.01,from: SIMD3(-8,0,-10))
        var move = GameInput(); move.moveRight = 1
        advance(game,240,input: move)
        #expect(game.enemies[0].position != enemyStart && game.reconMarks == [mark])
        #expect(game.player.position.x > 9 && game.visibleReconMarks.isEmpty)
        let elapsed = game.elapsed
        for dt in [Double(0),-1,.nan,.infinity] { game.step(deltaTime: dt,input: move) }
        #expect(game.elapsed == elapsed && game.reconMarks == [mark])
        move.moveRight = -1; advance(game,240,input: move)
        #expect(game.reconMarks == [mark] && game.visibleReconMarks == [mark])
        advance(game,960)
        #expect(game.reconMarks.isEmpty && game.visibleReconMarks.isEmpty)
    }

    @Test func observationPoolDedupeAndCooldownAreBoundedByExplicitNewObservations() throws {
        let enemies = [-6,-2,2,6].enumerated().map { witness(100+$0.offset,at: SIMD3(Float($0.element),0,-16)) }
        let game = scene(try fixture(),role: .recon,enemies: enemies)
        var events: [GameEvent] = []
        for index in game.enemies.indices {
            events += advance(game,1,input: aim(game,at: EnemyPose(game.enemies[index]).bodyCenter))
            #expect(game.useClassGadget() && !game.useClassGadget()); events += game.drainEvents()
            #expect(game.reconMarks.count <= 3)
            events += advance(game,90)
        }
        #expect(game.reconMarks.count == 3 && !game.reconMarks.contains { $0.targetID == 100 })
        let oldID = try #require(game.reconMarks.first { $0.targetID == 103 }?.id)
        advance(game,1,input: aim(game,at: EnemyPose(game.enemies[3]).bodyCenter))
        #expect(game.useClassGadget())
        #expect(game.reconMarks.count == 3 && game.reconMarks.last?.targetID == 103 && game.reconMarks.last?.id != oldID)
        #expect(events.filter { $0.kind == .reconMarked }.count == 4)
    }

    @Test func chargePlacementRejectsInvalidSurfacesRangeEdgesAndAirborneWithoutConsumption() throws {
        let far = scene(try fixture(pane: .clear),role: .engineer)
        #expect(!far.useClassGadget() && far.breachChargeCount == 1)
        let empty = scene(try fixture(start: SIMD3(0,0,1.6)),role: .engineer)
        #expect(!empty.useClassGadget() && empty.breachChargeCount == 1)
        let edge = scene(try fixture(pane: .clear,start: SIMD3(1.58,0,1.6)),role: .engineer)
        #expect(!edge.useClassGadget() && edge.breachChargeCount == 1)
        let jumping = scene(try fixture(pane: .clear,start: SIMD3(0,0,1.6)),role: .engineer)
        jumping.jump()
        #expect(!jumping.useClassGadget() && jumping.breachChargeCount == 1)
        let wall = Obstacle(id: 2,kind: .bunker,position: SIMD3(0,0,0.8),size: SIMD3(2,3,0.2))
        let blocked = scene(try fixture(pane: .clear,extra: [wall],start: SIMD3(0,0,1.6)),role: .engineer)
        #expect(!blocked.useClassGadget() && blocked.breachChargeCount == 1)
        for game in [far,empty,edge,jumping,blocked] { #expect(game.breachCharges.isEmpty && !game.drainEvents().contains { $0.kind == .breachChargePlaced }) }
    }

    @Test func oneThreeSecondChargeFreezesDuringPauseOpensItsOwnerAndUsesRealSelfDamage() throws {
        for rate in [30,60,120] {
            let game = scene(try fixture(pane: .clear,start: SIMD3(0,0,1.6)),role: .engineer)
            #expect(game.useClassGadget() && !game.useClassGadget() && game.breachChargeCount == 0)
            let charge = try #require(game.breachCharges.first)
            #expect(charge.fuse == 3 && charge.attached && charge.normal == SIMD3<Float>(0,0,1))
            #expect(abs(charge.position.z-0.14) < 0.0001)
            for _ in 0..<120 { game.step(deltaTime: 0,input: GameInput()) }
            #expect(game.breachCharges[0].fuse == 3 && game.elapsed == 0)
            for _ in 0..<(3*rate-1) { game.step(deltaTime: 1/Double(rate),input: GameInput()) }
            #expect(!game.breaches[0].isOpen && game.breachCharges.count == 1 && game.player.health == 100)
            game.step(deltaTime: 1/Double(rate),input: GameInput())
            #expect(game.breachCharges.isEmpty && game.breaches[0].isOpen && game.state == .lost)
            let events = game.drainEvents()
            #expect(events.filter { $0.kind == .breachChargePlaced }.count == 1)
            #expect(events.filter { $0.kind == .breachChargeDetonated }.count == 1)
            #expect(events.filter { $0.kind == .explosion }.count == 1 && events.filter { $0.kind == .lose }.count == 1)
            #expect(events.first { $0.kind == .breachChargeDetonated }?.charge?.fuse == 0)
            #expect(game.grenadeCount == 4 && game.weapons[.rifle]?.ammo == 30 && !game.useClassGadget())
        }
    }

    @Test func prematurelyDestroyedOwnerReleasesTheSameChargeOntoItsActualSupport() throws {
        let game = scene(try fixture(pane: .clear,start: SIMD3(0,0,1.6)),role: .engineer)
        #expect(game.useClassGadget())
        let id = try #require(game.breachCharges.first?.id)
        game.damageCover(index: 0,amount: 1000)
        var retreat = GameInput(); retreat.moveForward = -1
        advance(game,300,input: retreat)
        let charge = try #require(game.breachCharges.first)
        #expect(charge.id == id && !charge.attached && charge.normal == SIMD3<Float>(0,1,0))
        #expect(abs(charge.position.y-0.031) < 0.002 && charge.fuse == 0.5)
        let events = advance(game,60)
        #expect(game.breachCharges.isEmpty && events.filter { $0.kind == .breachChargeDetonated }.count == 1)
        #expect(game.player.health == 100 && game.state == .active)
        let reset = scene(game.map,role: .engineer)
        #expect(reset.breachChargeCount == 1 && reset.breachCharges.isEmpty && reset.breaches[0].damageStage == .intact)

        let field = try TerrainHeightField(origin: SIMD2(-32,-32),width: 65,depth: 65,
            samples: (0..<(65*65)).map { Float($0%65-32)*0.2 })
        let slope = scene(try fixture(pane: .clear,terrain: .heightField(field),start: SIMD3(0,0,1.6)),role: .engineer)
        #expect(slope.useClassGadget()); slope.damageCover(index: 0,amount: 1000)
        advance(slope,300,input: retreat)
        let resting = try #require(slope.breachCharges.first)
        let normal = slope.terrain.normal(x: resting.position.x,z: resting.position.z)
        let floor = SIMD3<Float>(resting.position.x,slope.terrain.height(x: resting.position.x,z: resting.position.z),resting.position.z)
        #expect(simd_distance(resting.normal,normal) < 0.001)
        #expect(abs(simd_dot(resting.position-floor,normal)-0.031) < 0.002)
    }

    @Test func realChargeOpensTheFullStrengthPanelWhilePermanentCoverProtectsTheRetreat() throws {
        let wall = Obstacle(id: 2,kind: .bunker,position: SIMD3(2,0,1.5),size: SIMD3(0.3,4,5))
        var health: [Float] = []
        for covered in [false,true] {
            let game = scene(try fixture(pane: .opaque,paneKind: .accessPanel,extra: covered ? [wall] : [],start: SIMD3(0,0,1.6)),role: .engineer)
            #expect(game.obstacles.first { $0.id == 1 }?.health == 160 && game.useClassGadget())
            var events = game.drainEvents()
            try walk(game,through: [SIMD2(0,4.5),SIMD2(3,4.5),SIMD2(3,1.6)],events: &events)
            try #require(game.elapsed < 3 && !game.breachCharges.isEmpty)
            events += advance(game,360-Int((game.elapsed*120).rounded()))
            #expect(game.breaches[0].isOpen && events.filter { $0.kind == .breachChargeDetonated }.count == 1)
            #expect(game.score == 25 && game.grenadeCount == 4)
            health.append(game.player.health)
        }
        #expect(health[0] > 0 && health[0] < 60 && health[1] == 100)
    }

    @Test func assaultUsesTheExistingSmokeActionAndCannotDuplicateInventoryThroughTwoBindings() throws {
        let game = scene(try fixture(),role: .assault)
        #expect(game.useClassGadget() && !game.throwSmokeGrenade() && !game.useClassGadget())
        advance(game,96)
        #expect(game.throwSmokeGrenade() && !game.useClassGadget())
        #expect(game.smokeGrenadeCount == 0 && game.smokeGrenades.count == 2 && game.grenadeCount == 4)
        #expect(!game.throwNoiseDecoy() && game.reconMarks.isEmpty && game.breachCharges.isEmpty)
        let events = advance(game,180)
        #expect(game.smokeVolumes.count == 2 && !events.contains { $0.kind == .explosion })
    }

    @Test func engineerDeviceDurationsUseTheSameExactTickCountAsTheirStatus() throws {
        var environment = MapEnvironmentDefinition()
        environment.devices = [WorldInteractableDefinition(id: 1001,kind: .generator,ownerObstacleID: 23,interactionPoints: [SIMD3(6,0,9.5)]),
            WorldInteractableDefinition(id: 1002,kind: .serviceGate,ownerObstacleID: 24,interactionPoints: [SIMD3(4,0,0)],generatorID: 1001,openOffset: SIMD3(0,3.4,0))]
        let map = try MapDefinition(id: "operator-device",displayName: "Bedienprüfung",minimum: SIMD3(-30,0,-30),maximum: SIMD3(30,0,30),terrain: .flat,
            obstacles: [Obstacle(id: 23,kind: .container,position: SIMD3(6,0,8),size: SIMD3(1.6,1.4,1.2)),
                        Obstacle(id: 24,kind: .container,position: .zero,size: SIMD3(6,2.8,0.45))],
            playerStart: PlayerState(position: SIMD3(6,0,9.5)),reinforcementEntries: [SIMD3(24,0,24)],waveStaging: [SIMD3(20,0,20)],
            extraction: SIMD3(0,0,-26),dataSite: SIMD3(-20,0,20),radioSite: SIMD3(20,0,20),environment: environment)
        for role in OperatorClass.allCases {
            let game = scene(map,role: role)
            var hold = GameInput(); hold.interact = true
            let ticks = game.loadout.deviceInteractionTicks(manual: false)
            #expect(game.deviceInteractionStatus?.requiredProgress == Float(ticks)/120)
            advance(game,ticks-1,input: hold); #expect(game.devices[0].enabled)
            let events = advance(game,1,input: hold)
            #expect(!game.devices[0].enabled && events.filter { $0.kind == .deviceActivated }.count == 1)
            advance(game,120,input: hold); #expect(!game.devices[0].enabled)
            var walked: [GameEvent] = []
            try walk(game,through: [SIMD2(4,9.5),SIMD2(4,0)],events: &walked)
            let manual = game.loadout.deviceInteractionTicks(manual: true)
            #expect(game.deviceInteractionStatus?.manual == true && game.deviceInteractionStatus?.requiredProgress == Float(manual)/120)
            advance(game,manual-1,input: hold); #expect(!game.devices[1].isMoving)
            advance(game,1,input: hold); #expect(game.devices[1].isMoving)
        }
    }

    @Test func allThreeKitsCompleteARealBlacksiteOperationWithTheirToolAndAReachableExit() throws {
        // Combat is deliberately isolated here. Real walking, tool use, terrain,
        // collisions, device timing, mission actions and extraction remain live.
        for role in OperatorClass.allCases {
            let map = MapDefinition.blacksite
            let observer = witness(91_000,at: SIMD3(0,0,16))
            let game = CombatSimulation(difficulty: .easy,seed: 41,world: map.obstacles,
                startingEnemies: role == .recon ? [observer] : [],mission: .operation,map: map,loadout: .init(operatorClass: role))
            var events: [GameEvent] = []
            if role == .recon {
                events += advance(game,1,input: aim(game,at: EnemyPose(game.enemies[0]).bodyCenter))
                #expect(game.useClassGadget() && game.throwNoiseDecoy()); events += game.drainEvents()
            } else if role == .assault {
                #expect(game.useClassGadget()); events += game.drainEvents()
            }
            events += advance(game,1,isolateCombat: true)
            try walk(game,through: [SIMD2(-8,32),SIMD2(-18,32),SIMD2(-31,31)],events: &events,isolateCombat: true)
            var hold = GameInput(); hold.interact = true
            events += advance(game,96,input: hold,isolateCombat: true)
            try #require(game.missionStatus.phase == .extract)
            if role == .engineer {
                try walk(game,through: [SIMD2(-32,22),SIMD2(-30,14),SIMD2(-25,8),SIMD2(-20,8),SIMD2(-20,4),SIMD2(-17.2,1.5)],events: &events,isolateCombat: true)
                var facing = GameInput(); facing.yaw = -.pi/2
                events += advance(game,1,input: facing,isolateCombat: true)
                #expect(game.useClassGadget()); events += game.drainEvents()
                try walk(game,through: [SIMD2(-24,1.5)],events: &events,isolateCombat: true)
                events += advance(game,360,isolateCombat: true)
                try #require(game.breaches.first { $0.id == 25 }?.isOpen == true)
                try walk(game,through: [SIMD2(-12,1.5),SIMD2(0,1.5),SIMD2(0,-12),SIMD2(6.9,-12),SIMD2(6.9,-13.8)],events: &events,isolateCombat: true)
                try #require(game.deviceInteractionStatus?.id == 1002)
                events += advance(game,78,input: hold,isolateCombat: true); events += advance(game,245,isolateCombat: true)
                #expect(game.devices.first { $0.id == 1002 }?.gateProgress == 1)
                try walk(game,through: [SIMD2(0,-12),SIMD2(0,-18),SIMD2(0,-35)],events: &events,isolateCombat: true)
            } else if role == .assault {
                try walk(game,through: [SIMD2(-18,32),SIMD2(-8,32),SIMD2(0,32),SIMD2(8,32),SIMD2(21,29),SIMD2(29,21),
                    SIMD2(32,13),SIMD2(32,5),SIMD2(32,-3),SIMD2(29,-10),SIMD2(33,-18),SIMD2(33,-28),SIMD2(33,-37)],events: &events,isolateCombat: true)
            } else {
                try walk(game,through: [SIMD2(-32,22),SIMD2(-30,14),SIMD2(-32,4),SIMD2(-33,-6),SIMD2(-33,-20),
                    SIMD2(-28,-25),SIMD2(-20,-26),SIMD2(-12,-28),SIMD2(-7,-32),SIMD2(0,-35)],events: &events,isolateCombat: true)
            }
            events += advance(game,360,isolateCombat: true)
            #expect(game.state == .won && events.filter { $0.kind == .win }.count == 1)
            #expect(game.missionStatus.extractionID == (role == .assault ? "service" : "north"))
            #expect(events.filter { $0.kind == .reconMarked }.count == (role == .recon ? 1 : 0))
            #expect(events.filter { $0.kind == .breachChargePlaced }.count == (role == .engineer ? 1 : 0))
            #expect(events.filter { $0.kind == .throwSmoke }.count == (role == .assault ? 1 : 0))
            #expect(game.noiseDecoyCount == 0 && game.breachChargeCount == 0 && game.smokeGrenadeCount == (role == .assault ? 1 : 0))
            let reset = CombatSimulation(map: map,mission: .operation,loadout: game.loadout)
            #expect(reset.loadout == game.loadout && reset.breachCharges.isEmpty && reset.reconMarks.isEmpty)
            #expect(reset.breachChargeCount == game.loadout.breachCharges && reset.noiseDecoyCount == game.loadout.noiseDecoys)
        }
    }
}
