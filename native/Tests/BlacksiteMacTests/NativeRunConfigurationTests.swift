import Foundation
import Testing
import BlacksiteCore
@testable import BlacksiteMac

@Suite(.serialized)
@MainActor
struct NativeRunConfigurationTests {
    @Test func publishedMapsExcludeDiagnosticsAndStalePreferencesNormalize() {
        let name = "Blacksite.RunConfigurationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(PublishedMapRegistry.maps.map(\.id) == [MapDefinition.blacksite.id, MapDefinition.nebelwacht.id, MapDefinition.sundkai.id, MapDefinition.kessel9.id])
        #expect(PublishedMapRegistry.map(id: MapDefinition.testRange.id) == nil)
        for storedID in ["missing-map", "", MapDefinition.testRange.id, MapDefinition.blacksite.id] {
            defaults.set(storedID, forKey: "native.mapID")
            var settings = NativeSettings(defaults: defaults)
            #expect(settings.selectedMapID == MapDefinition.blacksite.id)
            settings.selectedMapID = storedID
            settings.save(defaults: defaults)
            #expect(defaults.string(forKey: "native.mapID") == MapDefinition.blacksite.id)
        }
    }

    @Test func fjordSelectionAndRetryKeepThePublishedMapAndItsKit() throws {
        let name = "Blacksite.FjordRunTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = NativeSettings(defaults: defaults)
        settings.selectedMapID = "nebelwacht"; settings.selectedMission = .operation
        settings.selectedClass = .engineer; settings.selectedCamouflage = .mineral
        settings.save(defaults: defaults)
        let restored = NativeSettings(defaults: defaults)
        #expect(restored.selectedMapID == "nebelwacht" && restored.selectedClass == .engineer)
        let map = try #require(PublishedMapRegistry.map(id: restored.selectedMapID))
        let run = ActiveRunConfiguration(map: map, seed: 1745, mission: restored.selectedMission,
            difficulty: restored.difficulty, loadout: LoadoutDefinition(operatorClass: restored.selectedClass, camouflage: restored.selectedCamouflage))
        let initial = try run.makeSimulation()
        #expect(initial.throwGrenade())
        settings.selectedMapID = "blacksite"; settings.selectedClass = .recon; settings.save(defaults: defaults)
        let retry = try run.makeSimulation()
        #expect(retry.map.id == "nebelwacht" && retry.map.version == map.version)
        #expect(retry.loadout.operatorClass == .engineer && retry.loadout.camouflage == .mineral)
        #expect(retry.grenadeCount == 3 && retry.elapsed == 0 && retry.breachChargeCount == 1)
        #expect(retry.missionStatus.phase == .prepareOperation)
    }

    @Test func sundkaiSelectionAndRetryRestoreUnfinishedRelaysAndOriginalKit() throws {
        let name = "Blacksite.SundkaiRunTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = NativeSettings(defaults: defaults)
        settings.selectedMapID = "sundkai"; settings.selectedMission = .operation
        settings.selectedClass = .assault; settings.selectedCamouflage = .vegetation
        settings.save(defaults: defaults)
        let restored = NativeSettings(defaults: defaults)
        let map = try #require(PublishedMapRegistry.map(id: restored.selectedMapID))
        let run = ActiveRunConfiguration(map: map, seed: 1745, mission: restored.selectedMission,
            difficulty: restored.difficulty, loadout: LoadoutDefinition(operatorClass: restored.selectedClass, camouflage: restored.selectedCamouflage))
        let original = try run.makeSimulation()
        #expect(original.throwGrenade())
        settings.selectedMapID = "blacksite"; settings.selectedClass = .recon; settings.save(defaults: defaults)
        let retry = try run.makeSimulation()
        #expect(retry.map.id == "sundkai" && retry.map.version == map.version && run.seed == 1745)
        #expect(retry.loadout.operatorClass == .assault && retry.loadout.camouflage == .vegetation)
        #expect(retry.grenadeCount == 3 && retry.smokeGrenadeCount == 2 && retry.elapsed == 0)
        let relays = try #require(retry.operationStatus?.stages.first)
        #expect(relays.active && relays.targets.count == 2 && relays.targets.allSatisfy { !$0.completed })
        #expect(retry.operationStatus?.extractions.allSatisfy { !$0.unlocked } == true)
    }

    @Test func retryRejectsMissingMapsChangedVersionsAndUnsupportedMissions() throws {
        let map = MapDefinition.testRange
        let run = ActiveRunConfiguration(map: map, seed: 77, mission: .recoverData,
                                         difficulty: .easy, loadout: .init())
        #expect(throws: NativeRunConfigurationError.unavailableMap(map.id)) { try run.makeSimulation() }
        #expect(throws: NativeRunConfigurationError.unavailableMap(map.id)) { try run.restoreMap(availableMaps: []) }
        let revised = try MapDefinition(id: map.id, version: map.version + 1, displayName: map.displayName,
            minimum: map.minimum, maximum: map.maximum, terrain: map.terrain,
            obstacles: map.obstacles, playerStart: map.playerStart,
            reinforcementEntries: map.reinforcementEntries, waveStaging: map.waveStaging,
            extraction: map.extraction, dataSite: map.dataSite, radioSite: map.radioSite)
        #expect(throws: NativeRunConfigurationError.unavailableVersion(mapID: map.id, requested: map.version, available: revised.version)) {
            try run.restoreMap(availableMaps: [revised])
        }
        let unsupported = ActiveRunConfiguration(map: map, seed: 77, mission: .operation,
                                                 difficulty: .easy, loadout: .init())
        #expect(throws: NativeRunConfigurationError.unsupportedMission(mapID: map.id, mission: .operation)) {
            try unsupported.restoreMap(availableMaps: [map])
        }
        #expect(try run.restoreMap(availableMaps: [map]).id == map.id)
    }

    @Test func immutableRunRecreatesOriginalWorldAndRandomStreamAfterMenuChanges() throws {
        let name = "Blacksite.RunConfigurationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var settings = NativeSettings(defaults: defaults)
        settings.selectedMission = .operation; settings.difficulty = .hard; settings.selectedCamouflage = .mineral
        let run = ActiveRunConfiguration(map: .blacksite, seed: 0x193A7,
            mission: settings.selectedMission, difficulty: settings.difficulty,
            loadout: LoadoutDefinition(camouflage: settings.selectedCamouflage))
        let original = try run.makeSimulation()
        settings.selectedMission = .waves; settings.difficulty = .easy; settings.selectedCamouflage = .none
        settings.save(defaults: defaults)
        #expect(original.throwGrenade())
        original.step(deltaTime: 1.0 / 120, input: GameInput())
        #expect(original.grenadeCount == 2 && original.elapsed > 0)

        let retry = try run.makeSimulation(), replay = try run.makeSimulation()
        #expect(retry.map.id == run.mapID && retry.map.version == run.mapVersion)
        #expect(run.seed == 0x193A7 && run.difficulty == .hard)
        #expect(retry.missionKind == .operation && retry.missionStatus.phase == .prepareOperation)
        #expect(retry.loadout == LoadoutDefinition(camouflage: .mineral))
        #expect(retry.grenadeCount == 3 && retry.noiseDecoyCount == run.loadout.noiseDecoys && retry.grenades.isEmpty)
        #expect(retry.elapsed == 0 && retry.player.health == 100 && retry.selectedExtractionID == nil)
        var input = GameInput(); input.yaw = retry.player.yaw; input.pitch = retry.player.pitch
        for tick in 0..<240 {
            input.moveRight = tick < 80 ? 0.5 : 0
            retry.step(deltaTime: 1.0 / 120, input: input)
            replay.step(deltaTime: 1.0 / 120, input: input)
            #expect(retry.player.position == replay.player.position && retry.player.health == replay.player.health)
            #expect(retry.enemies.map(\.position) == replay.enemies.map(\.position))
            #expect(retry.drainEvents().map(\.kind) == replay.drainEvents().map(\.kind))
        }
        #expect(!retry.enemies.isEmpty)
    }
}
