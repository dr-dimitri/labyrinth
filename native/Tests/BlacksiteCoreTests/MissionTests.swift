import Testing
import simd
@testable import BlacksiteCore

struct MissionTests {
    private func scene(_ kind: MissionKind, position: SIMD3<Float>? = nil, world: [Obstacle] = [],
                       enemies: [EnemyState] = []) -> CombatSimulation {
        CombatSimulation(difficulty: .easy, seed: 41, world: world,
                         startingPlayer: PlayerState(position: position ?? (kind == .recoverData ? GameMap.dataSite : GameMap.radioSite)),
                         startingEnemies: enemies, startingWave: 3, mission: kind)
    }
    @discardableResult private func advance(_ game: CombatSimulation, ticks: Int, input: GameInput = GameInput(),
                                           eliminate: Bool = false, preserveID: Int? = nil) -> [GameEvent] {
        var events: [GameEvent] = []
        for _ in 0..<ticks {
            game.step(deltaTime: 1.0/120, input: input)
            if eliminate {
                for index in game.enemies.indices where game.enemies[index].health > 0 && game.enemies[index].id != preserveID {
                    game.damageEnemy(index: index, amount: 10_000)
                }
            }
            events += game.drainEvents()
        }
        return events
    }
    private var held: GameInput { var input = GameInput(); input.interact = true; return input }
    private func walk(_ game: CombatSimulation, to target: SIMD2<Float>, eliminate: Bool = false) -> Bool {
        for _ in 0..<2400 {
            let delta = target - SIMD2(game.player.position.x,game.player.position.z)
            if simd_length(delta) < 0.08 { return true }
            var input = GameInput(); input.moveForward = 1; input.yaw = atan2(-delta.x,-delta.y)
            advance(game, ticks: 1, input: input, eliminate: eliminate)
        }
        return false
    }

    @Test func heldDataInteractionResetsOnReleaseAndCompletesOnlyOnce() {
        let game = scene(.recoverData)
        #expect(game.wave == 0 && game.missionKind == .recoverData)
        #expect(game.missionInteractionAvailable && game.missionStatus.interruption == .interactionReleased)
        var events = advance(game, ticks: 60, input: held)
        #expect(abs(game.missionStatus.progress - 0.5) < 0.00001)
        let clock = game.elapsed
        for dt in [Double(0),-1,.nan,.infinity] { game.step(deltaTime: dt, input: held) }
        #expect(game.elapsed == clock && game.missionStatus.progress == 0.5)
        events += advance(game, ticks: 1)
        #expect(game.missionStatus.progress == 0 && game.missionStatus.interruption == .interactionReleased)
        events += advance(game, ticks: 95, input: held)
        #expect(game.missionStatus.phase == .collectData && !game.extractionReady)
        events += advance(game, ticks: 1, input: held)
        #expect(game.missionStatus.phase == .extract && game.extractionReady)
        #expect(game.missionStatus.objectivePosition == game.extractionPosition)
        #expect(!game.missionInteractionAvailable)
        events += advance(game, ticks: 120, input: held)
        #expect(game.aliveCount + game.pendingReinforcements == 7)
        #expect(events.filter { $0.kind == .missionPhaseChanged }.compactMap(\.missionPhase) == [.collectData,.extract])
        #expect(!events.contains { $0.kind == .waveStarted || $0.kind == .waveCleared || $0.kind == .extractionUnlocked })
        game.spawnWave()
        #expect(game.wave == 0 && game.remainingEnemies == 7)
    }

    @Test func interactionNeedsNearbyGroundContactAndJumpingCancelsItsLoad() {
        let distant = scene(.recoverData, position: GameMap.dataSite + SIMD3(1.7,0,0))
        #expect(!distant.missionInteractionAvailable && distant.missionStatus.interruption == .outOfRange)
        advance(distant, ticks: 100, input: held, eliminate: true)
        #expect(distant.missionStatus.phase == .collectData && distant.missionStatus.progress == 0)
        let game = scene(.recoverData)
        advance(game, ticks: 30, input: held, eliminate: true)
        #expect(game.missionStatus.progress == 0.25 && game.jump())
        advance(game, ticks: 1, input: held)
        #expect(!game.missionInteractionAvailable && game.missionStatus.interruption == .notGrounded)
        #expect(game.missionStatus.progress == 0)
    }

    @Test func dataExtractionDoesNotRequireKillingLivingOrPendingEnemies() {
        // Every authored reinforcement entry is occupied. A real narrow path
        // remains walkable, so reaching the gate must not wait on spawn retries.
        let blockers = GameMap.reinforcementEntries.enumerated().map { index, point in
            Obstacle(id: 1000+index, kind: .bunker, position: point, size: SIMD3(1.3,3,1.3))
        }
        let distantGuard = EnemyState(id: 50, position: SIMD3(34,0,34))
        let game = scene(.recoverData, world: blockers, enemies: [distantGuard])
        advance(game, ticks: 96, input: held)
        #expect(game.extractionReady && game.aliveCount == 1 && game.pendingReinforcements == 7)
        #expect(walk(game, to: SIMD2(-31,-35)))
        #expect(walk(game, to: SIMD2(0,-35)))
        let events = advance(game, ticks: 360)
        #expect(game.state == .won && game.missionStatus.phase == .completed)
        #expect(game.aliveCount == 1 && game.pendingReinforcements == 7)
        #expect(events.filter { $0.kind == .win }.count == 1)
        #expect(events.filter { $0.kind == .missionPhaseChanged }.compactMap(\.missionPhase) == [.completed])
    }

    @Test func radioCompletesExactlyFourFiniteReinforcementBatchesAndThreePhases() {
        let game = scene(.secureRadio)
        var events = advance(game, ticks: 119, input: held, eliminate: true)
        #expect(game.missionStatus.phase == .activateRadio && game.missionStatus.progress < 1)
        events += advance(game, ticks: 1, input: held, eliminate: true)
        #expect(game.missionStatus.phase == .holdRadio && game.missionStatus.progress == 0)
        #expect(!game.extractionReady && !game.missionInteractionAvailable)
        #expect(events.filter { $0.kind == .reinforcementsArrived }.count == 5)
        events += advance(game, ticks: 1799, eliminate: true)
        #expect(events.filter { $0.kind == .reinforcementsArrived }.count == 5)
        events += advance(game, ticks: 1, eliminate: true)
        #expect(game.missionStatus.progress == 15)
        #expect(events.filter { $0.kind == .reinforcementsArrived }.count == 7)
        events += advance(game, ticks: 1800, eliminate: true)
        #expect(game.missionStatus.progress == 30)
        #expect(events.filter { $0.kind == .reinforcementsArrived }.count == 9)
        events += advance(game, ticks: 1799, eliminate: true)
        #expect(game.state == .active && game.missionStatus.progress < 45)
        events += advance(game, ticks: 1, eliminate: true)
        #expect(game.state == .won && game.kills == 9 && game.pendingReinforcements == 0)
        #expect(events.filter { $0.kind == .missionPhaseChanged }.compactMap(\.missionPhase) == [.activateRadio,.holdRadio,.completed])
        #expect(events.filter { $0.kind == .win }.count == 1)
        let clock = game.elapsed
        #expect(advance(game, ticks: 120).isEmpty && game.elapsed == clock)
    }

    @Test func outsideAirborneAndPausedRadioTimeNeverResetAccumulatedControl() {
        let game = scene(.secureRadio)
        advance(game, ticks: 120, input: held, eliminate: true)
        advance(game, ticks: 60, eliminate: true)
        let beforeJump = game.missionStatus.progress
        #expect(game.jump())
        advance(game, ticks: 12, eliminate: true)
        #expect(game.missionStatus.progress == beforeJump && game.missionStatus.interruption == .notGrounded)
        advance(game, ticks: 120, eliminate: true)
        #expect(walk(game, to: SIMD2(37.4,5), eliminate: true))
        let outsideProgress = game.missionStatus.progress
        #expect(game.missionStatus.interruption == .outOfRange && outsideProgress > beforeJump)
        advance(game, ticks: 120, eliminate: true)
        #expect(game.missionStatus.progress == outsideProgress)
        for dt in [Double(0),-1,.nan,.infinity] { game.step(deltaTime: dt, input: held) }
        #expect(game.missionStatus.progress == outsideProgress)
        #expect(walk(game, to: SIMD2(32,5), eliminate: true))
        advance(game, ticks: 120, eliminate: true)
        #expect(game.missionStatus.progress > outsideProgress && game.missionStatus.phase == .holdRadio)
    }

    @Test func aLivingEnemyContestsTheRadioUntilRemoved() {
        let guardID = 50
        let defender = EnemyState(id: guardID, position: GameMap.radioSite + SIMD3(0.2,0,0))
        let game = scene(.secureRadio, enemies: [defender])
        advance(game, ticks: 120, input: held, eliminate: true, preserveID: guardID)
        #expect(game.missionStatus.phase == .holdRadio && game.missionStatus.interruption == .contested)
        let progress = game.missionStatus.progress
        advance(game, ticks: 30, eliminate: true, preserveID: guardID)
        #expect(game.missionStatus.progress == progress && game.missionStatus.interruption == .contested)
        for index in game.enemies.indices where game.enemies[index].id == guardID { game.damageEnemy(index: index, amount: 1000) }
        advance(game, ticks: 120, eliminate: true)
        #expect(game.missionStatus.progress == progress + 1 && game.missionStatus.interruption == nil)
    }

    @Test func objectiveReinforcementsRetrySafelyAfterTheirInitialEntriesWereBlocked() {
        let sealed = Obstacle(id: 1, kind: .crate, position: .zero, size: SIMD3(76,3,84))
        let game = scene(.recoverData, world: [sealed])
        advance(game, ticks: 96, input: held)
        #expect(game.pendingReinforcements == 7 && game.aliveCount == 0 && game.extractionReady)
        game.damageCover(index: 0, amount: 1000)
        advance(game, ticks: 30)
        #expect(game.pendingReinforcements == 7 && game.aliveCount == 0)
        let events = advance(game, ticks: 31)
        let arrivals = events.filter { $0.kind == .reinforcementsArrived }
        #expect(arrivals.count == 7 && Set(arrivals.map(\.id)).count == 7)
        #expect(game.pendingReinforcements == 0 && game.wave == 0)
        #expect(arrivals.allSatisfy { game.reinforcementIsHidden(at: $0.position) &&
            !game.blocked($0.position, height: 2, radius: 0.6) && horizontalDistance($0.position,$0.endPosition) >= 14 })
        #expect(!events.contains { $0.kind == .waveStarted || $0.kind == .win })
    }

    @Test func lethalExplosionOnTheLastRadioTickWinsOverMissionCompletion() {
        let barrel = Obstacle(id: 1, kind: .barrel, position: GameMap.radioSite + SIMD3(0,0,-2.5), size: SIMD3(0.8,1.15,0.8))
        let game = scene(.secureRadio, world: [barrel])
        advance(game, ticks: 120, input: held, eliminate: true)
        advance(game, ticks: 5399, eliminate: true)
        #expect(game.state == .active && abs(game.missionStatus.progress - Float(5399)/120) < 0.00001)
        game.damageCover(index: 0, amount: 54)
        game.damagePlayer(amount: 99, from: game.player.position)
        _ = game.drainEvents()
        var input = GameInput(); input.fire = true; input.pitch = atan2(0.55 - 1.62,2.5)
        let events = advance(game, ticks: 1, input: input)
        #expect(game.state == .lost && game.player.health == 0)
        #expect(game.missionStatus.phase == .holdRadio && game.missionStatus.progress < 45)
        #expect(events.contains { $0.kind == .explosion } && events.contains { $0.kind == .lose })
        #expect(!events.contains { $0.kind == .win || ($0.kind == .missionPhaseChanged && $0.missionPhase == .completed) })
    }

    @Test func restartResetsEveryMissionTimerAndWavesKeepTheirOriginalEventContract() {
        for kind in [MissionKind.recoverData,.secureRadio] {
            let game = scene(kind)
            advance(game, ticks: 30, input: held)
            #expect(game.missionStatus.progress > 0)
            let restarted = scene(kind)
            #expect(restarted.elapsed == 0 && restarted.missionStatus.progress == 0)
            #expect(restarted.pendingReinforcements == 0 && restarted.aliveCount == 0)
            #expect(restarted.missionStatus.interruption == .interactionReleased && restarted.state == .active)
            let events = advance(restarted, ticks: 1)
            #expect(events.filter { $0.kind == .missionPhaseChanged }.count == 1)
            #expect(restarted.remainingEnemies == (kind == .recoverData ? 4 : 3))
        }
        let waves = CombatSimulation(world: [], startingWave: 0)
        #expect(waves.missionKind == .waves && waves.missionStatus.phase == .waves)
        let events = advance(waves, ticks: 180)
        #expect(waves.wave == 1 && waves.remainingEnemies == 5)
        #expect(!events.contains { $0.kind == .missionPhaseChanged })
        #expect(events.filter { $0.kind == .waveStarted }.count == 1)
    }
}
