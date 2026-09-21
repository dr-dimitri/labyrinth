import AppKit
import Testing
import BlacksiteCore
@testable import BlacksiteMac

struct NativeEditorTests {
    @MainActor @Test func openingEditorDoesNotPretendTheUntouchedBlankIsAnUnsavedEdit() throws {
        _ = NSApplication.shared
        let editor = NativeEditorWindow()
        defer { editor.recoveryTimer?.invalidate(); editor.window?.orderOut(nil) }
        #expect(!editor.session.isDirty)
        try editor.session.edit("Name") { $0.name = "Mein Level" }
        #expect(editor.session.isDirty)
    }
    @MainActor @Test func selectingKeepsGeometryButEditingRebuildsIt() throws {
        _ = NSApplication.shared
        var document = try LevelExample.training.makeDocument()
        let scene = NativeEditorScene(frame:.zero)
        try scene.rebuild(document,selection:[])
        let ground = try #require(scene.world.childNode(withName:"ground",recursively:false))
        let object = try #require(scene.world.childNode(withName:document.objects[0].id,recursively:false))
        try scene.rebuild(document,selection:[document.objects[0].id])
        #expect(scene.world.childNode(withName:"ground",recursively:false) === ground)
        #expect(scene.world.childNode(withName:document.objects[0].id,recursively:false) === object)
        #expect(object.geometry?.firstMaterial?.diffuse.contents as? NSColor == .systemOrange)
        try scene.rebuild(document,selection:[])
        #expect(object.geometry?.firstMaterial?.diffuse.contents as? NSColor != .systemOrange)
        document.objects[0].position.x += 1
        try scene.rebuild(document,selection:[])
        #expect(scene.world.childNode(withName:document.objects[0].id,recursively:false) !== object)
    }
    @MainActor @Test(.enabled(if:ProcessInfo.processInfo.environment["BLACKSITE_TEST_EDITOR_PLAYTEST"] == "1"))
    func repeatedRealPlaytestsReleaseCoordinatorAndRetainAuthoringState() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let document = try LevelExample.training.makeDocument()
        let editor = NativeEditorWindow(document:document,store:LevelFileStore(root:root))
        defer { editor.recoveryTimer?.invalidate(); editor.window?.orderOut(nil) }
        editor.canvas.target = SIMD3(3,4,5); editor.canvas.distance = 33
        for _ in 0..<3 {
            editor.startPlaytest(try NativeLoadedLevel(document:document))
            for _ in 0..<300 {
                if editor.playtestCoordinator?.ready == true { break }
                try await Task.sleep(nanoseconds:20_000_000)
            }
            weak var coordinator = editor.playtestCoordinator
            #expect(coordinator?.ready == true && coordinator?.isEditorPlaytest == true)
            #expect(coordinator?.simulation.missionKind == document.missionKind)
            editor.playtestWindow?.performClose(nil)
            await Task.yield()
            #expect(editor.playtestWindow == nil && editor.playtestCoordinator == nil)
            #expect(coordinator == nil)
            #expect(editor.session.document == document)
            #expect(editor.canvas.target == SIMD3(3,4,5) && editor.canvas.distance == 33)
        }
    }
    @MainActor @Test func editorPersistenceAndDocumentSwitchResetTransientTools() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LevelFileStore(root:root); try store.prepare()
        defer { try? FileManager.default.removeItem(at:root) }
        let url = try store.libraryURL(), doc = LevelDocument()
        try LevelFileStore.save(doc,to:url)
        let editor = NativeEditorWindow(document:doc,fileURL:url,store:store)
        defer { editor.recoveryTimer?.invalidate(); editor.window?.orderOut(nil) }
        try editor.session.edit("Name") { $0.name = "Gesichert" }
        editor.writeRecovery()
        #expect(try store.recoveries().first?.1.document == editor.session.document)
        #expect(editor.save(as:false))
        #expect(!editor.session.isDirty); #expect(try store.recoveries().isEmpty)
        #expect(try LevelFileStore.read(url).name == "Gesichert")
        editor.placement = "core.crate"; editor.markerPlacement = .patrol
        editor.session.beginGesture("Offene Geste")
        #expect(editor.open(url))
        #expect(editor.placement == nil && editor.markerPlacement == nil && !editor.session.canUndo)
    }
    @MainActor @Test func popupMenuActionsSelectAndNotifyEvenForDuplicateTitles() throws {
        _ = NSApplication.shared
        var selected = -1
        let popup = EditorPopup(["Gleich", "Gleich", "Dritter"],label: "Test") { selected = $0 }
        let menu = try #require(popup.menu)
        #expect(popup.numberOfItems == 3)
        menu.performActionForItem(at: 1)
        #expect(selected == 1 && popup.indexOfSelectedItem == 1)
        menu.performActionForItem(at: 2)
        #expect(selected == 2 && popup.indexOfSelectedItem == 2)
    }
}
