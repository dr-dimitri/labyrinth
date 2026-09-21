import AppKit
import Testing
import BlacksiteCore
@testable import BlacksiteMac

struct NativeLevelFileTests {
    private func example() throws -> LevelDocument {
        let native = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try LevelDocument.decode(Data(contentsOf: native.appendingPathComponent("Examples/training-ground.blacksite-level.json")))
    }

    @MainActor @Test func briefingKeepsDistinctMapsWithTheSameDisplayName() throws {
        _ = NSApplication.shared
        var document = try example()
        document.name = MapDefinition.blacksite.displayName
        let imported = try NativeLoadedLevel(document: document)
        let maps = [imported.map] + PublishedMapRegistry.maps
        let draft = NativeBriefingDraft(map: imported.map, mission: .waves, difficulty: .easy, camouflage: .mineral)
        let panel = NativeBriefingPanel(draft: draft, interactionLabel: "E", maps: maps)
        let view = panel.briefingView
        #expect(view.mapChoice.numberOfItems == maps.count)
        #expect(view.draft.map.id == imported.map.id)
        view.mapChoice.selectItem(at: maps.count - 1)
        view.updatePreview()
        #expect(view.draft.map.id == maps.last?.id)
        view.mapChoice.selectItem(at: 0)
        view.updatePreview()
        #expect(view.startButton.isEnabled)
        #expect(view.draft.map.id == imported.map.id)
    }

    @Test func importedLevelUsesTheRealMapAndRetainsARetrySnapshot() throws {
        var document = try example()
        let imported = try NativeLoadedLevel(document: document)
        let configuration = ActiveRunConfiguration(map: imported.map, seed: 77, mission: .recoverData,
            difficulty: .easy, loadout: .init(), levelDocument: document)
        document.objects.removeAll(); document.markers.removeAll(); document.name = "Geänderter Entwurf"
        let game = try configuration.makeSimulation()
        #expect(game.map.id == imported.map.id)
        #expect(game.map.displayName == imported.document.name)
        #expect(game.map.obstacles.count == imported.document.objects.count)
        #expect(game.missionKind == .recoverData)
        #expect(try configuration.restoreMap(availableMaps: []).id == imported.map.id)
        let retry = try configuration.makeSimulation()
        #expect(retry.player.position == game.player.position)
        #expect(retry.map.obstacles.map(\.id) == game.map.obstacles.map(\.id))
    }

    @Test func mismatchedMapIdentityOrRevisionCannotSilentlyLoadAnotherLevel() throws {
        let document = try example(), imported = try NativeLoadedLevel(document: example())
        let wrongID = ActiveRunConfiguration(map: .blacksite, seed: 1, mission: .waves,
            difficulty: .easy, loadout: .init(), levelDocument: document)
        #expect(throws: NativeRunConfigurationError.self) { try wrongID.makeSimulation() }
        var changed = document; changed.revision += 1
        let wrongRevision = ActiveRunConfiguration(map: imported.map, seed: 1, mission: .waves,
            difficulty: .easy, loadout: .init(), levelDocument: changed)
        #expect(throws: NativeRunConfigurationError.self) { try wrongRevision.makeSimulation() }
    }

    @Test func loaderRejectsInvalidArgumentsAndFilesWithoutChangingTheLoadedValue() throws {
        #expect(try NativeLoadedLevel.from(arguments: ["Blacksite"]) == nil)
        #expect(throws: LevelDocumentError.self) { try NativeLoadedLevel.from(arguments: ["Blacksite", "--level-file"]) }
        #expect(throws: LevelDocumentError.self) {
            try NativeLoadedLevel.from(arguments: ["Blacksite", "--level-file", "a.json", "--map", "blacksite"])
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("test.blacksite-level.json")
        let document = try example()
        try document.encoded().write(to: file)
        let loaded = try #require(try NativeLoadedLevel.from(arguments: ["Blacksite", "--level-file", file.path]))
        #expect(loaded.document == document)
        try Data("broken".utf8).write(to: file)
        #expect(throws: LevelDocumentError.self) { try NativeLoadedLevel.load(file) }
        #expect(throws: LevelDocumentError.self) { try NativeLoadedLevel.load(directory) }
        #expect(loaded.document == document)
        try FileManager.default.removeItem(at: file)
        #expect(try loaded.document.makeMap().id == loaded.map.id)
    }
}
