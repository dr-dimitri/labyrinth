import Foundation
import Darwin

/// Persistence is independent of gameplay validity and of AppKit. A sibling
/// temporary file is fully written and synchronized before the atomic rename.
public struct LevelFileStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public var levels: URL { root.appendingPathComponent("Levels",isDirectory: true) }
    public var recoveryDirectory: URL { root.appendingPathComponent("Recovery",isDirectory: true) }
    public func prepare() throws {
        for url in [levels,recoveryDirectory] { try FileManager.default.createDirectory(at: url,withIntermediateDirectories: true) }
    }
    public static func read(_ url: URL) throws -> LevelDocument {
        try LevelDocument.decode(readBounded(url,limit: LevelDocument.maximumFileBytes))
    }
    private static func readBounded(_ url: URL,limit: Int) throws -> Data {
        guard url.isFileURL,try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw LevelDocumentError("Bitte eine reguläre lokale Leveldatei auswählen.")
        }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let data = try file.read(upToCount: limit+1) ?? Data()
        guard data.count <= limit else { throw LevelDocumentError("Die Datei überschreitet die erlaubte Größe (Level: 8 MiB).") }
        return data
    }
    public static func save(_ document: LevelDocument,to url: URL,beforeCommit: () throws -> Void = {}) throws {
        try atomicWrite(document.encoded(),to: url,beforeCommit: beforeCommit)
    }
    static func atomicWrite(_ data: Data,to url: URL,beforeCommit: () throws -> Void = {}) throws {
        guard url.isFileURL else { throw LevelDocumentError("Speichern benötigt einen lokalen Dateipfad.") }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".blacksite-write-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary,options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.synchronize(); try handle.close() } catch { try? handle.close(); throw error }
        try beforeCommit()
        guard rename(temporary.path,url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain,code: Int(errno),userInfo: [NSFilePathErrorKey:url.path])
        }
    }
    public struct Entry: Sendable {
        public let url: URL, name: String, modified: Date, objectCount: Int, width: Int, depth: Int
    }
    public func list() throws -> [Entry] {
        try prepare()
        return try FileManager.default.contentsOfDirectory(at: levels,includingPropertiesForKeys: [.contentModificationDateKey],options: [.skipsHiddenFiles])
            .filter { $0.lastPathComponent.hasSuffix(".blacksite-level.json") }
            .compactMap { url in
                guard let doc = try? Self.read(url) else { return nil }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return Entry(url: url,name: doc.name,modified: date,objectCount: doc.objects.count,width: doc.bounds.width,depth: doc.bounds.depth)
            }.sorted { $0.modified > $1.modified }
    }
    public func libraryURL() throws -> URL { try prepare(); return levels.appendingPathComponent(UUID().uuidString+".blacksite-level.json") }
    public struct Recovery: Codable, Sendable {
        public let document: LevelDocument
        public let source: URL?
        public let date: Date
    }
    public func recoveryURL(_ token: UUID) -> URL { recoveryDirectory.appendingPathComponent(token.uuidString+".json") }
    public func recover(_ document: LevelDocument,source: URL?,token: UUID,date: Date = Date()) throws {
        try prepare(); _ = try document.encoded()
        let snapshot = Recovery(document: document,source: source,date: date)
        try Self.atomicWrite(JSONEncoder().encode(snapshot),to: recoveryURL(token))
    }
    public func recoveries() throws -> [(URL,Recovery)] {
        try prepare()
        return try FileManager.default.contentsOfDirectory(at: recoveryDirectory,includingPropertiesForKeys: nil,options: [.skipsHiddenFiles]).compactMap { url in
            guard let data = try? Self.readBounded(url,limit: LevelDocument.maximumFileBytes+65536),
                  let recovery = try? JSONDecoder().decode(Recovery.self,from: data),
                  (try? recovery.document.validateDraft()) != nil else { return nil }
            if let source = recovery.source,let saved = try? Self.read(source) {
                if saved == recovery.document { return nil }
                let modified = (try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if modified >= recovery.date { return nil }
            }
            return (url,recovery)
        }.sorted { $0.1.date > $1.1.date }
    }
    public func removeRecovery(_ token: UUID) { try? FileManager.default.removeItem(at: recoveryURL(token)) }
}
