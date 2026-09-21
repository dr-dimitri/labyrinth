import Foundation
import simd

extension LevelEditingSession {
    public mutating func selectObject(_ id: String?, extending: Bool = false) {
        guard let id else { if !extending { selection = [] }; return }
        var ids: Set<String> = [id]
        if let group = document.objects.first(where: { $0.id == id })?.groupID {
            ids.formUnion(document.objects.filter { $0.groupID == group }.map(\.id))
        }
        if extending { if ids.isSubset(of: selection) { selection.subtract(ids) } else { selection.formUnion(ids) } }
        else { selection = ids }
    }
    public mutating func duplicateSelection() throws {
        let originals = document.objects.filter { selection.contains($0.id) }
        guard !originals.isEmpty else { return }
        var groups: [String:String] = [:]
        for original in originals { if let id = original.groupID, groups[id] == nil { groups[id] = UUID().uuidString } }
        let copies = originals.map { original -> LevelObject in
            var copy = original; copy.id = UUID().uuidString; copy.position.x += 2; copy.position.z += 2
            copy.groupID = original.groupID.flatMap { groups[$0] }; copy.locked = false; return copy
        }
        try edit("Duplizieren") { doc in
            for (old,new) in groups { doc.groups.append(LevelGroup(id: new,name: String((doc.groups.first { $0.id == old }?.name ?? "Gruppe").prefix(114)) + " Kopie")) }
            doc.objects += copies
        }
        selection = Set(copies.map(\.id))
    }
    public mutating func groupSelection() throws {
        let ids = selection; guard document.objects.filter({ ids.contains($0.id) && !$0.locked }).count >= 2 else { throw LevelDocumentError("Zum Gruppieren mindestens zwei ungesperrte Objekte auswählen.") }
        try edit("Gruppieren") { doc in
            let group = LevelGroup(name: "Gruppe \(doc.groups.count+1)"); doc.groups.append(group)
            for i in doc.objects.indices where ids.contains(doc.objects[i].id) && !doc.objects[i].locked { doc.objects[i].groupID = group.id }
            let used = Set(doc.objects.compactMap(\.groupID)); doc.groups.removeAll { !used.contains($0.id) }
        }
    }
    public mutating func ungroupSelection() throws {
        let ids = selection
        try edit("Gruppe auflösen") { doc in
            for i in doc.objects.indices where ids.contains(doc.objects[i].id) && !doc.objects[i].locked { doc.objects[i].groupID = nil }
            let used = Set(doc.objects.compactMap(\.groupID)); doc.groups.removeAll { !used.contains($0.id) }
        }
    }
    public mutating func setLocked(_ locked: Bool) throws {
        let ids = selection; try edit(locked ? "Sperren" : "Entsperren") { doc in
            for i in doc.objects.indices where ids.contains(doc.objects[i].id) { doc.objects[i].locked = locked }
        }
    }
    public mutating func setHidden(_ hidden: Bool) throws {
        let ids = selection; try edit(hidden ? "Ausblenden" : "Einblenden") { doc in
            for i in doc.objects.indices where ids.contains(doc.objects[i].id) && !doc.objects[i].locked { doc.objects[i].hidden = hidden }
        }
    }
    public mutating func transformSelection(translation: SIMD3<Float> = .zero, quarterTurns: Int = 0, scale: Float = 1, originals: [LevelObject]? = nil) throws {
        guard translation.x.isFinite,translation.y.isFinite,translation.z.isFinite, (0...3).contains(quarterTurns),scale.isFinite,scale > 0,scale <= 16 else { throw LevelDocumentError("Ungültige Transformation.") }
        let ids = selection
        let selected = (originals ?? document.objects).filter { ids.contains($0.id) && !$0.locked }
        guard !selected.isEmpty else { return }
        let center = selected.reduce(SIMD3<Float>.zero) { $0+$1.position.value } / Float(selected.count)
        let originalByID = Dictionary(uniqueKeysWithValues: selected.map { ($0.id,$0) })
        try edit("Transformieren") { doc in
            for i in doc.objects.indices {
                guard let original = originalByID[doc.objects[i].id], !doc.objects[i].locked else { continue }
                var delta = original.position.value-center; delta.x *= scale; delta.z *= scale
                for _ in 0..<quarterTurns { delta = SIMD3(delta.z,delta.y,-delta.x) }
                let p = center+delta+translation
                doc.objects[i].position = LevelVector(p.x,p.y,p.z)
                doc.objects[i].quarterTurns = (original.quarterTurns+quarterTurns)%4
                doc.objects[i].scale = LevelVector(original.scale.x*scale,original.scale.y*scale,original.scale.z*scale)
            }
        }
    }
}
