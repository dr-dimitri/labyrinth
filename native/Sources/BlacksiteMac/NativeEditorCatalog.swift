import AppKit
import BlacksiteCore
import simd

@MainActor
final class EditorSearchField: NSSearchField, NSSearchFieldDelegate {
    var changed: ((String)->Void)?
    override init(frame: NSRect) { super.init(frame: frame); delegate = self; setAccessibilityLabel("Katalog durchsuchen") }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    func controlTextDidChange(_ obj: Notification) { changed?(stringValue) }
}

/// Isometric geometry thumbnail: exactly the same catalog parts as the editor
/// and game, with no downloaded assets or separate preview models.
@MainActor
final class EditorCatalogPreview: NSView {
    var item: LevelCatalogItem? { didSet { needsDisplay = true; setAccessibilityLabel(item.map { "Vorschau: " + $0.name } ?? "Keine Vorlage") } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex: 0x263333).setFill(); bounds.fill()
        guard let item else { return }
        let scale = min(bounds.width/(CGFloat(item.size.x+item.size.z)*0.8+2),bounds.height/(CGFloat(item.size.y+(item.size.x+item.size.z)*0.35)+2))*0.8
        func project(_ p: SIMD3<Float>) -> NSPoint { NSPoint(x: bounds.midX+CGFloat((p.x-p.z)*0.8)*scale,y: bounds.height*0.75-CGFloat(p.y+(p.x+p.z)*0.35)*scale) }
        for part in item.parts.sorted(by: { $0.center.x+$0.center.z > $1.center.x+$1.center.z }) {
            let p = part.center,s = part.size/2
            let faces: [[SIMD3<Float>]] = [
                [p+SIMD3(-s.x,s.y,-s.z),p+SIMD3(s.x,s.y,-s.z),p+SIMD3(s.x,s.y,s.z),p+SIMD3(-s.x,s.y,s.z)],
                [p+SIMD3(-s.x,-s.y,s.z),p+SIMD3(s.x,-s.y,s.z),p+SIMD3(s.x,s.y,s.z),p+SIMD3(-s.x,s.y,s.z)],
                [p+SIMD3(s.x,-s.y,-s.z),p+SIMD3(s.x,-s.y,s.z),p+SIMD3(s.x,s.y,s.z),p+SIMD3(s.x,s.y,-s.z)]]
            for (index,face) in faces.enumerated() {
                let c = part.color*([1.2,0.9,0.7] as [Float])[index]
                NSColor(calibratedRed: CGFloat(min(1,c.x)),green: CGFloat(min(1,c.y)),blue: CGFloat(min(1,c.z)),alpha: 1).setFill()
                let path = NSBezierPath(); path.move(to: project(face[0])); for vertex in face.dropFirst() { path.line(to: project(vertex)) }; path.close(); path.fill()
            }
        }
    }
}

extension NativeEditorWindow {
    func configureCatalog() {
        catalogPanel.addArrangedSubview(EditorPopup(["Alle Kategorien"]+LevelCatalogCategory.allCases.map(\.rawValue),label: "Katalogkategorie") { [weak self] index in self?.catalogCategory = index == 0 ? nil : LevelCatalogCategory.allCases[index-1]; self?.filterCatalog() })
        let search = EditorSearchField(frame: .zero); search.placeholderString = "Objekt suchen"; search.widthAnchor.constraint(equalToConstant: 235).isActive = true
        search.changed = { [weak self] in self?.catalogQuery = $0; self?.filterCatalog() }; catalogPanel.addArrangedSubview(search)
        button("Alle / Favoriten",in: catalogPanel) { [weak self] in self?.favoritesOnly.toggle(); self?.filterCatalog() }
        catalog.target = self; catalog.action = #selector(catalogChoiceChanged)
        catalog.setAccessibilityLabel("Objektvorlage"); catalogPanel.addArrangedSubview(catalog)
        catalogPreview.widthAnchor.constraint(equalToConstant: 235).isActive = true; catalogPreview.heightAnchor.constraint(equalToConstant: 135).isActive = true
        catalogPanel.addArrangedSubview(catalogPreview); catalogInfo.font = .systemFont(ofSize: 11); catalogPanel.addArrangedSubview(catalogInfo)
        catalogInfo.widthAnchor.constraint(equalToConstant: 235).isActive = true
        button("Favorit umschalten",in: catalogPanel) { [weak self] in
            guard let self,let item = self.catalogPreview.item else { return }
            if !self.catalogFavorites.insert(item.id).inserted { self.catalogFavorites.remove(item.id) }
            UserDefaults.standard.set(Array(self.catalogFavorites),forKey: "editor.favorites"); self.filterCatalog()
        }
        filterCatalog()
    }
    func filterCatalog() {
        let previous = catalogPreview.item?.id
        visibleCatalog = LevelObjectCatalog.items.filter { item in
            (catalogCategory == nil || item.category == catalogCategory) && (!favoritesOnly || catalogFavorites.contains(item.id))
                && (catalogQuery.isEmpty || item.name.localizedCaseInsensitiveContains(catalogQuery) || item.guidance.localizedCaseInsensitiveContains(catalogQuery))
        }
        catalog.removeAllItems(); catalog.addItems(withTitles: visibleCatalog.map(\.name))
        if let index = visibleCatalog.firstIndex(where: { $0.id == previous }) { catalog.selectItem(at: index) }
        catalogChoiceChanged()
    }
    @objc func catalogChoiceChanged() {
        let item = visibleCatalog.indices.contains(catalog.indexOfSelectedItem) ? visibleCatalog[catalog.indexOfSelectedItem] : nil
        catalogPreview.item = item
        if let item {
            catalogInfo.stringValue = "\(catalogFavorites.contains(item.id) ? "★ " : "")\(item.name) · \(item.category.rawValue)\n\(String(format: "%.1f × %.1f × %.1f m",item.size.x,item.size.y,item.size.z))\n\(item.guidance)\nSkalierung: \(item.minimumScale)–4, Drehung: 90°"
        } else { catalogInfo.stringValue = "Keine passenden Vorlagen. Suche/Kategorie oder Favoritenfilter ändern." }
    }
}
