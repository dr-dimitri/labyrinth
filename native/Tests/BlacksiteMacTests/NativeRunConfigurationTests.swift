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
        #expect(PublishedMapRegistry.maps.map(\.id) == [MapDefinition.blacksite.id])
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
        #expect(retry.grenadeCount == 3 && retry.noiseDecoyCount == 2 && retry.grenades.isEmpty)
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
