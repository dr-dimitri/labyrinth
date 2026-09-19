import Testing
import simd
@testable import BlacksiteCore

struct RunStatisticsTests {
    private func advance(_ game: CombatSimulation, ticks: Int, input: GameInput = GameInput()) {
        for _ in 0..<ticks { game.step(deltaTime: 1.0 / 120, input: input) }
    }

    private func device(_ kind: WorldDeviceKind, id: Int = 1001) -> WorldInteractableState {
        WorldInteractableState(id: id, kind: kind, ownerObstacleID: 23,
                               interactionPoints: [.zero], closedPosition: .zero)
    }

    @Test func recordsConsumptionAndMarksOnlyFromTheCompletedActionEvents() {
        var statistics = RunStatistics()
        for kind: GameEvent.Kind in [.enemyShot, .explosion, .reload, .supply, .waveCleared,
                                     .smokeActivated, .decoyPulse, .breachChargeDetonated, .damage] {
            statistics.record(GameEvent(kind: kind, weapon: .rifle), map: .blacksite)
        }
        #expect(statistics == RunStatistics())
        for kind: GameEvent.Kind in [.throwGrenade, .throwSmoke, .decoyThrown, .breachChargePlaced, .reconMarked] {
            statistics.record(GameEvent(kind: kind), map: .blacksite)
        }
        statistics.record(GameEvent(kind: .shot, weapon: .rifle), map: .blacksite)
        statistics.record(GameEvent(kind: .shot, weapon: .sniper), map: .blacksite)
        statistics.record(GameEvent(kind: .shot), map: .blacksite)
        statistics.record(GameEvent(kind: .reconMarked), map: .blacksite)
        #expect(statistics.rifleShots == 1 && statistics.sniperShots == 1)
        #expect(statistics.fragmentationGrenadesThrown == 1 && statistics.smokeGrenadesThrown == 1)
        #expect(statistics.decoysThrown == 1 && statistics.breachChargesPlaced == 1)
        #expect(statistics.reconMarks == 2)
    }

    @Test func reportsCountDeliveredChannelsAndKillsCountOnlyFatalHits() {
        var statistics = RunStatistics()
        for channel in [ContactReportChannel.radio, .localShout] {
            let report = ContactReport(id: 1, enemyID: 2, contactPosition: .zero,
                                       contactTime: 1, transmittedAt: 2, expiresAt: 8, channel: channel)
            for kind in [GameEvent.Kind.contactReportStarted, .contactReportInterrupted, .contactReportTransmitted] {
                statistics.record(GameEvent(kind: kind, contactReport: report), map: .blacksite)
            }
        }
        statistics.record(GameEvent(kind: .contactReportTransmitted), map: .blacksite)
        statistics.record(GameEvent(kind: .shot, headshot: true, weapon: .rifle), map: .blacksite)
        statistics.record(GameEvent(kind: .kill), map: .blacksite)
        statistics.record(GameEvent(kind: .kill, headshot: true), map: .blacksite)
        #expect(statistics.radioReports == 1 && statistics.shouts == 1)
        #expect(statistics.kills == 2 && statistics.headshotKills == 1)
    }

    @Test func completedGeneratorAndGatePreparationIsUniqueAcrossRepeatedCommands() {
        var statistics = RunStatistics(), generator = device(.generator), gate = device(.serviceGate, id: 1002)
        generator.enabled = false
        statistics.record(GameEvent(kind: .deviceActivated, id: generator.id, device: generator), map: .blacksite)
        generator.enabled = true
        statistics.record(GameEvent(kind: .deviceActivated, id: generator.id, device: generator), map: .blacksite)
        generator.enabled = false
        statistics.record(GameEvent(kind: .deviceActivated, id: generator.id, device: generator), map: .blacksite)
        gate.gateProgress = 0.5
        statistics.record(GameEvent(kind: .gateStopped, id: gate.id, device: gate), map: .blacksite)
        statistics.record(GameEvent(kind: .deviceActivated, id: gate.id, device: gate), map: .blacksite)
        #expect(statistics.openedGateIDs.isEmpty)
        gate.gateProgress = 1
        statistics.record(GameEvent(kind: .gateStopped, id: gate.id, device: gate), map: .blacksite)
        statistics.record(GameEvent(kind: .gateStopped, id: gate.id, device: gate), map: .blacksite)
        gate.gateProgress = 0
        statistics.record(GameEvent(kind: .gateStopped, id: gate.id, device: gate), map: .blacksite)
        #expect(statistics.disabledGeneratorIDs == [1001] && statistics.openedGateIDs == [1002])
        #expect(statistics.deviceActivations == 4 && statistics.maintenanceSwitches == 0)
    }

    @Test func coupledGateCompletionRecordsItsActualOpenGateWithoutAnotherActivation() throws {
        let map = MapDefinition.kessel9
        let definition = try #require(map.environment.devices.first { $0.kind == .maintenanceSwitch })
        var controller = device(.maintenanceSwitch, id: definition.id), statistics = RunStatistics()
        controller.enabled = false; controller.isMoving = true
        statistics.record(GameEvent(kind: .deviceActivated, id: controller.id, device: controller), map: map)
        controller.gateProgress = 0.5; controller.isMoving = false
        statistics.record(GameEvent(kind: .gateStopped, id: controller.id, device: controller), map: map)
        #expect(statistics.openedGateIDs.isEmpty)
        for enabled in [true, false, true] {
            controller.enabled = enabled; controller.gateProgress = enabled ? 1 : 0
            statistics.record(GameEvent(kind: .gateStopped, id: controller.id, device: controller), map: map)
        }
        #expect(statistics.openedGateIDs == definition.linkedGateIDs)
        #expect(statistics.deviceActivations == 1 && statistics.maintenanceSwitches == 1)
    }

    @Test func destructionRequiresAnAuthoritativeStateBeforeClaimingPowerOrGatePreparation() {
        var statistics = RunStatistics(), generator = device(.generator), gate = device(.serviceGate, id: 1002)
        statistics.record(GameEvent(kind: .deviceDestroyed, id: 77), map: .blacksite)
        #expect(statistics.destroyedDeviceIDs == [77])
        #expect(statistics.disabledGeneratorIDs.isEmpty && statistics.openedGateIDs.isEmpty)
        generator.destroyed = true; generator.enabled = false
        gate.destroyed = true; gate.gateProgress = 1
        for snapshot in [generator, gate, generator] {
            statistics.record(GameEvent(kind: .deviceDestroyed, id: snapshot.id, device: snapshot), map: .blacksite)
        }
        #expect(statistics.destroyedDeviceIDs == [77, 1001, 1002])
        #expect(statistics.disabledGeneratorIDs == [1001] && statistics.openedGateIDs == [1002])
        #expect(statistics.deviceActivations == 0)
    }

    @Test func objectivesAreUniqueAndExitSelectionDoesNotPretendTheRunHasSucceeded() {
        var statistics = RunStatistics()
        for complete in [false, true, true] {
            let objective = OperationTargetSnapshot(id: "data", title: "Daten", stageID: "recover",
                kind: .collectData, position: .zero, completed: complete)
            statistics.record(GameEvent(kind: .operationObjectiveCompleted, operationObjective: objective), map: .blacksite)
        }
        statistics.record(GameEvent(kind: .extractionSelected, extractionID: "north"), map: .blacksite)
        statistics.record(GameEvent(kind: .extractionSelected, extractionID: "service"), map: .blacksite)
        statistics.record(GameEvent(kind: .lose), map: .blacksite)
        #expect(statistics.completedObjectiveIDs == ["data"] && statistics.selectedExtractionID == "service")
    }

    @Test func simulationKeepsConsumptionAcrossPickupRefillsAndEventDrains() throws {
        let start = SIMD3<Float>(0, 0, 32)
        let enemies = (1...3).map { EnemyState(id: $0, position: start + SIMD3(0, 0, 1)) }
        let game = CombatSimulation(world: [], startingPlayer: PlayerState(position: start),
                                    startingEnemies: enemies, startingWave: 3)
        #expect(game.fire() && !game.fire())
        game.selectWeapon(.sniper)
        #expect(game.fire() && !game.fire())
        let rifleReserve = try #require(game.weapons[.rifle]?.reserve)
        for index in game.enemies.indices { game.damageEnemy(index: index, amount: 10_000) }
        advance(game, ticks: 1)
        let events = game.drainEvents()
        #expect(events.filter { $0.kind == .supply }.count == 1)
        #expect(game.weapons[.rifle]?.reserve == min(300, rifleReserve + 45))
        #expect(game.runStatistics.rifleShots == 1 && game.runStatistics.sniperShots == 1)
        #expect(game.runStatistics.kills == 3)
        let recorded = game.runStatistics
        #expect(game.drainEvents().isEmpty && game.runStatistics == recorded)
        let reset = CombatSimulation(world: [], startingWave: 3)
        #expect(reset.runStatistics == RunStatistics())
    }

    @Test func waveRefillDoesNotEraseThrownGrenadesOrCountFailedThrows() {
        let game = CombatSimulation(world: [])
        advance(game, ticks: 170)
        #expect(game.wave == 1 && !game.enemies.isEmpty)
        #expect(game.throwGrenade() && !game.throwGrenade())
        for index in game.enemies.indices { game.damageEnemy(index: index, amount: 10_000) }
        advance(game, ticks: 1)
        #expect(game.drainEvents().contains { $0.kind == .waveCleared })
        #expect(game.grenadeCount == game.loadout.fragmentationGrenades)
        #expect(game.runStatistics.fragmentationGrenadesThrown == 1)
    }

    @Test func smokeAndDecoyAttemptsCountOnlySuccessfullyEmittedActions() {
        let assault = CombatSimulation(world: [], startingWave: 3)
        #expect(assault.useClassGadget() && !assault.throwSmokeGrenade())
        #expect(!assault.throwNoiseDecoy())
        #expect(assault.runStatistics.smokeGrenadesThrown == 1 && assault.runStatistics.decoysThrown == 0)
        let recon = CombatSimulation(world: [], startingWave: 3, loadout: .init(operatorClass: .recon))
        #expect(recon.throwNoiseDecoy() && !recon.throwNoiseDecoy())
        #expect(!recon.useClassGadget())
        #expect(recon.runStatistics.decoysThrown == 1 && recon.runStatistics.reconMarks == 0)
    }

    @Test func actualMaintenanceMotorCompletionCountsOnlyNewlyOpenedPassages() throws {
        let map = MapDefinition.kessel9
        let game = CombatSimulation(world: map.obstacles,
            startingPlayer: PlayerState(position: map.grounded(Kessel9Definition.switchPoint)), startingWave: 3, map: map)
        let definition = try #require(map.environment.devices.first { $0.kind == .maintenanceSwitch })
        #expect(game.runStatistics.openedGateIDs.isEmpty)
        var held = GameInput(); held.interact = true
        advance(game, ticks: 120, input: held)
        #expect(game.runStatistics.deviceActivations == 1 && game.runStatistics.maintenanceSwitches == 1)
        #expect(game.runStatistics.openedGateIDs.isEmpty)
        advance(game, ticks: 245)
        #expect(game.runStatistics.openedGateIDs == [definition.linkedGateIDs[0]])
        advance(game, ticks: 120, input: held)
        advance(game, ticks: 245)
        #expect(game.runStatistics.openedGateIDs == definition.linkedGateIDs)
        #expect(game.runStatistics.deviceActivations == 2 && game.runStatistics.maintenanceSwitches == 2)
    }

    @Test func fatalBarrelShotIsStillRecordedAfterTheLossEvent() throws {
        var barrel = Obstacle(id: 1, kind: .barrel, position: SIMD3(0, 0, -1.6), size: SIMD3(0.8, 1.15, 0.8))
        barrel.health = 20
        var player = PlayerState(position: .zero)
        player.health = 1; player.pitch = -0.5
        let game = CombatSimulation(world: [barrel], startingPlayer: player, startingWave: 3)
        #expect(game.fire())
        let events = game.drainEvents()
        let loss = try #require(events.firstIndex { $0.kind == .lose })
        let shot = try #require(events.firstIndex { $0.kind == .shot })
        #expect(loss < shot && game.state == .lost)
        #expect(game.runStatistics.rifleShots == 1 && game.weapons[.rifle]?.ammo == 29)
        #expect(!game.fire() && game.runStatistics.rifleShots == 1)
    }
}
