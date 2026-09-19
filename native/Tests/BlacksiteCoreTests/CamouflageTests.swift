import Foundation
import Testing
import simd
@testable import BlacksiteCore

@Suite(.serialized)
struct CamouflageTests {
    private func map(vegetation: Bool = false, distance: Float = 15, world: [Obstacle] = []) throws -> MapDefinition {
        var environment = MapEnvironmentDefinition()
        if vegetation {
            environment.vegetationZones = [EnvironmentZone(id: "grass", center: SIMD2(0,distance), radii: SIMD2(3,4),
                                                            height: 1.2, density: 0.7, kind: .brush)]
        }
        return try MapDefinition(id: "camo-test", displayName: "Tarnprüfung", minimum: SIMD3(-42,0,-42), maximum: SIMD3(42,0,42),
            terrain: .flat, obstacles: world, playerStart: PlayerState(position: SIMD3(0,0,distance)),
            reinforcementEntries: [SIMD3(0,0,-38)], waveStaging: [SIMD3(0,0,-20)], extraction: SIMD3(0,0,-38),
            dataSite: SIMD3(-20,0,20), radioSite: SIMD3(20,0,20), environment: environment)
    }
    private func game(pattern: CamouflagePattern = .mineral, vegetation: Bool = false, distance: Float = 15,
                      prone: Bool = true, world: [Obstacle] = [], player: PlayerState? = nil,
                      enemies: [EnemyState] = []) throws -> CombatSimulation {
        let map = try map(vegetation: vegetation, distance: distance, world: world)
        var start = player ?? map.playerStart
        if player == nil { start.prone = prone; start.height = prone ? 0.57 : 1.72 }
        return CombatSimulation(seed: 41, world: world, startingPlayer: start, startingEnemies: enemies,
                                startingWave: 3, map: map, loadout: LoadoutDefinition(camouflage: pattern))
    }
    private func advance(_ game: CombatSimulation, ticks: Int, input: GameInput = GameInput()) {
        for _ in 0..<ticks { game.step(deltaTime: 1.0 / 120, input: input) }
    }
    private func multiplier(_ game: CombatSimulation, distance: Float) -> Float {
        ConcealmentEvaluation(status: game.concealmentStatus, observerDistance: distance).recognitionMultiplier
    }

    @Test func loadoutCapacityAndFreshSimulationAgreeForEveryPattern() throws {
        for pattern in CamouflagePattern.allCases {
            let loadout = LoadoutDefinition(camouflage: pattern), expected = pattern == .none ? 4 : 3
            let main = CombatSimulation(loadout: loadout)
            let legacy = CombatSimulation(terrain: .flat, loadout: loadout)
            let scenario = try game(pattern: pattern)
            #expect(loadout.fragmentationGrenades == expected)
            #expect(main.grenadeCount == expected && legacy.grenadeCount == expected && scenario.grenadeCount == expected)
            scenario.throwGrenade()
            #expect(scenario.grenadeCount == expected - 1 && scenario.loadout == loadout)
            let restarted = try game(pattern: pattern)
            #expect(restarted.grenadeCount == expected && restarted.concealmentStatus.settleProgress == 0)
            #expect(restarted.concealmentStatus.localStrength == 0)
        }
        let resupply = CombatSimulation(world: [], loadout: LoadoutDefinition(camouflage: .mineral))
        resupply.spawnWave()
        #expect(resupply.remainingEnemies > 0)
        resupply.throwGrenade()
        for index in resupply.enemies.indices { resupply.damageEnemy(index: index, amount: 1000) }
        advance(resupply, ticks: 1)
        #expect(resupply.grenadeCount == 3)
        #expect(LoadoutDefinition().camouflage == .none)
        #expect(CamouflagePattern.mineral.matches(.earth) && CamouflagePattern.mineral.matches(.rubble))
        #expect(!CamouflagePattern.vegetation.matches(.earth) && !CamouflagePattern.mineral.matches(.none))
    }

    @Test func matchingSuitActivatesAfterOneAndAHalfSecondsWithSmoothDistanceAndPostureLimits() throws {
        let matched = try game(pattern: .vegetation, vegetation: true)
        let mismatch = try game(pattern: .mineral, vegetation: true)
        let ordinary = try game(pattern: .none, vegetation: true)
        let standing = try game(pattern: .vegetation, vegetation: true, prone: false)
        advance(matched, ticks: 179)
        #expect(matched.concealmentStatus.reason == .settling && matched.concealmentStatus.localStrength == 0)
        advance(matched, ticks: 1)
        #expect(matched.concealmentStatus.reason == .ready && matched.concealmentStatus.settleProgress == 1)
        #expect(matched.concealmentStatus.localStrength == 1)
        for game in [mismatch,ordinary,standing] { advance(game, ticks: 180) }
        #expect(mismatch.concealmentStatus.reason == .unsuitableGround)
        #expect(ordinary.concealmentStatus.reason == .noSuit)
        for distance: Float in [5,6] { #expect(multiplier(matched, distance: distance) == 1) }
        #expect(multiplier(matched, distance: 15) < 1 && multiplier(matched, distance: 15) > multiplier(matched, distance: 30))
        #expect(abs(multiplier(matched, distance: 30) - 0.45) < 0.00001)
        #expect(multiplier(standing, distance: 30) > multiplier(matched, distance: 30))
        #expect(multiplier(mismatch, distance: 30) == 1 && multiplier(ordinary, distance: 30) == 1)
        let evaluation = ConcealmentEvaluation(status: matched.concealmentStatus, observerDistance: 30)
        #expect(evaluation.combinedRecognition(vegetation: 0.25) == ConcealmentEvaluation.minimumCombinedRecognition)
        #expect(evaluation.combinedRecognition(vegetation: 0) == 0)
        #expect(evaluation.combinedRecognition(vegetation: .nan) == 0)
        #expect(multiplier(matched, distance: .infinity) == 1)
    }

    @Test func actualMotionAndPostureInterruptButWalkingIntoAWallCanBecomeStill() throws {
        let moving = try game()
        advance(moving, ticks: 180)
        var walk = GameInput(); walk.moveRight = 0.1
        advance(moving, ticks: 1, input: walk)
        #expect(moving.player.position.x > 0 && moving.concealmentStatus.reason == .moving)
        #expect(moving.concealmentStatus.settleProgress == 0)
        advance(moving, ticks: 180)
        #expect(moving.concealmentStatus.reason == .ready)
        moving.toggleProne()
        #expect(moving.concealmentStatus.settleProgress == 0)
        advance(moving, ticks: 30)
        #expect(moving.concealmentStatus.localStrength == 0)
        advance(moving, ticks: 240)
        #expect(moving.concealmentStatus.reason == .ready)
        var sprint = GameInput(); sprint.moveForward = 1; sprint.sprint = true
        advance(moving, ticks: 1, input: sprint)
        #expect(moving.isSprinting && moving.concealmentStatus.reason == .moving)

        let wall = Obstacle(id: 7, kind: .bunker, position: SIMD3(0,0,14.4), size: SIMD3(4,3,0.2))
        let blocked = try game(world: [wall])
        var intoWall = GameInput(); intoWall.moveForward = 1
        advance(blocked, ticks: 360, input: intoWall)
        #expect(blocked.player.position.z > 14.8 && blocked.player.position.z < 14.9)
        #expect(blocked.concealmentStatus.reason == .ready)
    }

    @Test func JumpFallMantleAndRoofCannotInheritGroundCamouflage() throws {
        let jumping = try game(prone: false)
        advance(jumping, ticks: 180)
        #expect(jumping.jump())
        #expect(jumping.concealmentStatus.reason == .airborne && jumping.concealmentStatus.settleProgress == 0)
        advance(jumping, ticks: 30)
        #expect(jumping.player.position.y > 1 && jumping.concealmentStatus.localStrength == 0)
        var fallingPlayer = PlayerState(position: SIMD3(0,1,15)); fallingPlayer.grounded = false
        let falling = try game(player: fallingPlayer)
        advance(falling, ticks: 20)
        #expect(falling.player.position.y < 1 && falling.concealmentStatus.reason == .airborne)

        let roof = Obstacle(id: 9, kind: .container, position: SIMD3(0,0,15), size: SIMD3(4,2.8,6))
        let rooftop = try game(pattern: .vegetation, vegetation: true, world: [roof], player: PlayerState(position: SIMD3(0,2.8,15)))
        advance(rooftop, ticks: 240)
        #expect(rooftop.concealmentStatus.surfaceMaterial == .metal)
        #expect(rooftop.concealmentStatus.reason == .unsuitableGround && !rooftop.concealmentStatus.matchesGround)
        #expect(multiplier(rooftop, distance: 30) == 1)
        let climbing = try game(prone: false, world: [roof], player: PlayerState(position: SIMD3(0,0,18.7)))
        advance(climbing, ticks: 180)
        #expect(climbing.mantle())
        #expect(climbing.concealmentStatus.reason == .airborne && climbing.concealmentStatus.settleProgress == 0)
        advance(climbing, ticks: 30)
        #expect(climbing.climbProgress != nil && climbing.concealmentStatus.localStrength == 0)
    }

    @Test func RealShotsInterruptImmediatelyAndReloadOrEmptyTriggerDoNotRenewTheLockout() throws {
        let simulation = try game()
        advance(simulation, ticks: 180)
        #expect(simulation.fire())
        #expect(simulation.concealmentStatus.reason == .recentShot && simulation.concealmentStatus.settleProgress == 0)
        #expect(!simulation.fire())
        #expect(simulation.reload())
        #expect(!simulation.fire())
        advance(simulation, ticks: 359)
        #expect(simulation.concealmentStatus.reason == .recentShot)
        advance(simulation, ticks: 2)
        #expect(simulation.concealmentStatus.reason == .settling)
        advance(simulation, ticks: 180)
        #expect(simulation.concealmentStatus.reason == .ready)
        #expect(!simulation.reload()) // full magazine; no invented disturbance
        #expect(simulation.concealmentStatus.reason == .ready)

        // Consume the actual magazine. Repeated dry clicks only request reload;
        // they must not keep extending the last real shot's timestamp.
        let empty = try game()
        for _ in 0..<WeaponKind.rifle.capacity {
            #expect(empty.fire()); advance(empty, ticks: 13)
        }
        #expect(empty.weapons[.rifle]?.ammo == 0)
        #expect(!empty.fire())
        advance(empty, ticks: 120)
        #expect(!empty.fire())
        advance(empty, ticks: 240)
        #expect(empty.concealmentStatus.reason != .recentShot)
    }

    @Test func SlowLookAndAlternatingTurnSpamHaveTheSameOutcomeAtEveryFrameRate() throws {
        var stable: [(Float, Float)] = []
        for rate in [30,60,120] {
            let simulation = try game()
            for frame in 0..<(rate * 3) {
                var input = GameInput(); input.yaw = Float(frame + 1) / Float(rate) * 0.16
                simulation.step(deltaTime: 1 / Double(rate), input: input)
            }
            #expect(simulation.concealmentStatus.reason == .ready)
            stable.append((simulation.concealmentStatus.settleProgress, simulation.concealmentStatus.localStrength))
            for frame in 0..<rate {
                var input = GameInput(); input.yaw = (frame / max(1,rate / 10)).isMultiple(of: 2) ? 0.7 : -0.7
                simulation.step(deltaTime: 1 / Double(rate), input: input)
            }
            #expect(simulation.concealmentStatus.reason == .turning && simulation.concealmentStatus.localStrength == 0)
            advance(simulation, ticks: 260)
            #expect(simulation.concealmentStatus.reason == .ready)
        }
        #expect(stable.allSatisfy { $0.0 == 1 && abs($0.1 - 1) < 0.0001 })
    }

    @Test func PreparedCamouflageDelaysRealRecognitionWithoutErasingConfirmedContactOrHearing() throws {
        var guardState = EnemyState(id: 1, position: .zero); guardState.yaw = .pi
        for distance: Float in [5,15,30] {
            var times: [CamouflagePattern: Double] = [:]
            for pattern in [CamouflagePattern.none,.mineral,.vegetation] {
                let simulation = try game(pattern: pattern, vegetation: true, distance: distance, enemies: [guardState])
                advance(simulation, ticks: 180)
                #expect(!simulation.enemies[0].seesPlayer)
                simulation.explode(at: SIMD3(0,1,10))
                #expect(simulation.enemies[0].awareness == .investigating)
                for _ in 0..<1200 {
                    simulation.step(deltaTime: 1.0 / 120, input: GameInput())
                    if simulation.enemies[0].seesPlayer { break }
                }
                #expect(simulation.enemies[0].seesPlayer && simulation.elapsed < 10)
                times[pattern] = simulation.elapsed
                let awareness = simulation.enemies[0].awareness
                advance(simulation, ticks: 30)
                #expect(awareness == .engaged && simulation.enemies[0].seesPlayer)
            }
            #expect(times[.none] == times[.mineral])
            if distance == 5 { #expect(times[.vegetation] == times[.none]) }
            else { #expect(try #require(times[.vegetation]) > #require(times[.none])) }
        }

        // Suit activation after a contact is already established cannot erase it.
        let visible = try game(pattern: .mineral, prone: false, enemies: [EnemyState(id:1,position:.zero)])
        advance(visible, ticks: 90)
        #expect(visible.enemies[0].seesPlayer)
        advance(visible, ticks: 90)
        #expect(visible.concealmentStatus.reason == .ready && visible.enemies[0].seesPlayer)
        #expect(visible.enemies[0].awareness == .engaged)
        let wall = Obstacle(id: 10, kind: .bunker, position: SIMD3(0,0,7), size: SIMD3(20,4,1))
        let hidden = try game(world: [wall], enemies: [EnemyState(id:1,position:.zero)])
        advance(hidden, ticks: 240)
        #expect(hidden.concealmentStatus.reason == .ready && !hidden.enemies[0].seesPlayer)
        #expect(hidden.enemies[0].detectionProgress == 0)
    }

    @Test func PauseAndRestartCannotAgeOrCarryTheSuitState() throws {
        let simulation = try game()
        advance(simulation, ticks: 120)
        let progress = simulation.concealmentStatus.settleProgress, elapsed = simulation.elapsed
        var input = GameInput(); input.yaw = 2; input.fire = true; input.moveForward = 1
        for _ in 0..<120 { simulation.step(deltaTime: 0, input: input) }
        #expect(simulation.elapsed == elapsed && simulation.concealmentStatus.settleProgress == progress)
        #expect(simulation.grenadeCount == 3 && simulation.weapons[.rifle]?.ammo == 30)
        let restarted = try game()
        #expect(restarted.concealmentStatus.settleProgress == 0 && restarted.concealmentStatus.reason == .settling)
    }
}
