import Foundation
import Testing
@testable import BlacksiteCore

struct LevelFileStoreTests {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url,withIntermediateDirectories: true); return url
    }
    @Test func interruptedSaveAndInvalidDataPreserveOriginalAndDirtyState() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("original.json"), original = LevelDocument()
        try LevelFileStore.save(original,to:url)
        var session = LevelEditingSession(document: original,saved:true)
        try session.edit("Änderung") { $0.name = "Geändert" }
        #expect(throws: LevelDocumentError.self) {
            try LevelFileStore.save(session.document,to:url) { throw LevelDocumentError("Simulierter Abbruch vor Ersetzen") }
        }
        #expect(session.isDirty); #expect(try LevelFileStore.read(url) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["original.json"])
        let second = root.appendingPathComponent("copy.json")
        try LevelFileStore.save(session.document,to:second); session.markSaved()
        #expect(!session.isDirty); #expect(try LevelFileStore.read(url) == original)
        #expect(try LevelFileStore.read(second) == session.document)
        #expect(throws: (any Error).self) { try LevelFileStore.save(original,to:root) }
        #expect(try LevelFileStore.read(url) == original)
    }
    @Test func recoveryOffersOnlyNewerUnsavedContentAndLibrarySurvivesNewStore() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let store = LevelFileStore(root:root), token = UUID(), original = LevelDocument()
        let url = try store.libraryURL(); try LevelFileStore.save(original,to:url)
        var doc = original; doc.name = "Wiederhergestellt"; doc.installGameplayTemplate(.recoverData)
        try store.recover(doc,source:url,token:token,date:Date().addingTimeInterval(10))
        let reopened = LevelFileStore(root:root), recovery = try #require(try reopened.recoveries().first?.1)
        #expect(recovery.document == doc && recovery.source == url)
        #expect(try reopened.list().first?.name == original.name)
        try LevelFileStore.save(doc,to:url)
        #expect(try reopened.recoveries().isEmpty)
        try store.recover(original,source:url,token:token,date:.distantPast)
        #expect(try reopened.recoveries().isEmpty)
        try store.recover(doc,source:nil,token:token)
        #expect(try reopened.recoveries().count == 1)
        store.removeRecovery(token); #expect(try reopened.recoveries().isEmpty)
    }
    @Test func portableDraftsAndCorruptFutureOversizeAndUnknownResources() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("import.json"), draft = LevelDocument()
        try LevelFileStore.save(draft,to:file)
        let bytes = try Data(contentsOf:file)
        #expect(!String(decoding:bytes,as:UTF8.self).contains(root.path))
        #expect(try LevelFileStore.read(file) == draft)
        for data in [Data("broken".utf8),Data("{\"formatVersion\":999}".utf8),Data(repeating:65,count:LevelDocument.maximumFileBytes+1)] {
            try data.write(to:file); #expect(throws:LevelDocumentError.self) { try LevelFileStore.read(file) }
        }
        var unknown = draft; unknown.resourceSet = "missing"
        try JSONEncoder().encode(unknown).write(to:file)
        #expect(throws:LevelDocumentError.self) { try LevelFileStore.read(file) }
    }
}
