import Foundation

/// All editing tools transact through this value. A drag/brush stroke is one
/// transaction; failed changes never replace the last valid authoring state.
public struct LevelEditingSession {
    public private(set) var document: LevelDocument
    public var selection: Set<String> = []
    public private(set) var savedDocument: LevelDocument?
    private struct Snapshot { let document: LevelDocument; let selection: Set<String>; let title: String }
    private var past: [Snapshot] = [], future: [Snapshot] = []
    private var gesture: Snapshot?
    public var isDirty: Bool { savedDocument != document }
    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    public var undoTitle: String { past.last?.title ?? "" }
    public var redoTitle: String { future.last?.title ?? "" }
    public init(document: LevelDocument = LevelDocument(), saved: Bool = false) {
        self.document = document; savedDocument = saved ? document : nil
    }
    public mutating func replace(with document: LevelDocument, saved: Bool) throws {
        try document.validateDraft()
        self = Self(document: document, saved: saved)
    }
    public mutating func markSaved() { savedDocument = document }
    public mutating func edit(_ title: String, _ change: (inout LevelDocument) throws -> Void) throws {
        var candidate = document
        try change(&candidate); try candidate.validateDraft()
        guard candidate != document else { return }
        if gesture == nil { record(Snapshot(document: document, selection: selection, title: title)) }
        document = candidate; reconcileSelection()
    }
    public mutating func beginGesture(_ title: String) {
        guard gesture == nil else { return }
        gesture = Snapshot(document: document, selection: selection, title: title)
    }
    public mutating func endGesture(cancel: Bool = false) {
        guard let start = gesture else { return }; gesture = nil
        if cancel { document = start.document; selection = start.selection }
        else if start.document != document { record(start) }
    }
    private mutating func record(_ snapshot: Snapshot) {
        past.append(snapshot); if past.count > 40 { past.removeFirst() }; future.removeAll()
    }
    public mutating func undo() {
        endGesture(); guard let snapshot = past.popLast() else { return }
        future.append(Snapshot(document: document, selection: selection, title: snapshot.title))
        document = snapshot.document; selection = snapshot.selection; reconcileSelection()
    }
    public mutating func redo() {
        endGesture(); guard let snapshot = future.popLast() else { return }
        past.append(Snapshot(document: document, selection: selection, title: snapshot.title))
        document = snapshot.document; selection = snapshot.selection; reconcileSelection()
    }
    public mutating func reconcileSelection() {
        selection.formIntersection(Set(document.objects.map(\.id) + document.markers.map(\.id)))
    }
    public mutating func deleteSelection() throws {
        let ids = selection
        try edit("Löschen") { doc in
            if doc.objects.contains(where: { object in
                object.locked && object.powerSourceID.map { source in
                    ids.contains(source) && doc.objects.contains { $0.id == source && !$0.locked }
                } == true
            }) { throw LevelDocumentError("Ein gesperrtes Tor verwendet diesen Generator. Zuerst das Tor entsperren oder seine Verbindung lösen.") }
            doc.objects.removeAll { ids.contains($0.id) && !$0.locked }
            doc.markers.removeAll { ids.contains($0.id) }
            let remaining = Set(doc.objects.map(\.id))
            for i in doc.objects.indices { if let source = doc.objects[i].powerSourceID,!remaining.contains(source) { doc.objects[i].powerSourceID = nil } }
        }
    }
}
