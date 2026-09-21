import AppKit
import BlacksiteCore
import simd

@MainActor
final class EditorPopup: NSPopUpButton {
    let changed: (Int) -> Void
    init(_ titles: [String], selected: Int = 0, label: String, changed: @escaping (Int) -> Void) {
        self.changed = changed; super.init(frame: .zero,pullsDown: false)
        for title in titles { menu?.addItem(NSMenuItem(title: title,action: nil,keyEquivalent: "")) }
        selectItem(at: selected); target = self; action = #selector(update); setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    @objc private func update() { changed(indexOfSelectedItem) }
}

enum EditorTerrainTool: Int, CaseIterable {
    case select, raise, lower, smooth, flatten, earth, grass, rock, asphalt, water
    var title: String { ["Auswählen", "Heben", "Senken", "Glätten", "Einebnen", "Erde malen", "Gras malen", "Fels malen", "Asphalt malen", "Flachwasserbecken"][rawValue] }
}

extension NativeEditorWindow {
    func buildTerrainInspector() {
        let panel = inspector, doc = session.document
        label("KARTENGRÖSSE · 12–128 m je Achse",in: panel)
        let width = field("Breite (m)",value: String(doc.bounds.width),in: panel) { _ in }
        let depth = field("Tiefe (m)",value: String(doc.bounds.depth),in: panel) { _ in }
        let anchor = EditorPopup(LevelResizeAnchor.allCases.map(\.rawValue),label: "Verankerung") { _ in }; panel.addArrangedSubview(anchor)
        for preset in [32,64,128] { button("\(preset) × \(preset) m",in: panel) { [weak self] in self?.resize(width: preset,depth: preset,anchor: .center) } }
        button("Größe übernehmen …",in: panel) { [weak self, weak width, weak depth, weak anchor] in
            guard let self, let w = Int(width?.stringValue ?? ""), let d = Int(depth?.stringValue ?? "") else { self?.show(LevelDocumentError("Bitte ganze Meter eingeben.")); return }
            self.resize(width: w,depth: d,anchor: anchor?.indexOfSelectedItem == 1 ? .center : .origin)
        }
        label("LANDSCHAFT",in: panel)
        let landscape = EditorPopup(LevelLandscape.allCases.map(\.rawValue),label: "Landschaftsvorlage") { _ in }; panel.addArrangedSubview(landscape)
        let seed = field("Seed",value: String(doc.terrain.seed),in: panel) { _ in }
        button("Landschaft erzeugen …",in: panel) { [weak self, weak seed, weak landscape] in
            guard let self, let seed = UInt64(seed?.stringValue ?? ""), let index = landscape?.indexOfSelectedItem else { self?.show(LevelDocumentError("Der Seed benötigt eine positive ganze Zahl.")); return }
            let alert = NSAlert(); alert.messageText = "Landschaft neu erzeugen?"; alert.informativeText = "Ersetzt Höhen, Bodenflächen, Wasser und Vegetation. Objekte und Marker bleiben erhalten. Rückgängig ist möglich."
            alert.addButton(withTitle: "Erzeugen"); alert.addButton(withTitle: "Abbrechen")
            if alert.runModal() == .alertFirstButtonReturn { self.perform { try self.session.edit("Landschaft") { $0.generate(LevelLandscape.allCases[index],seed: seed) } } }
        }
        label("PINSEL · Linke Taste ziehen, Escape verwirft den Strich",in: panel)
        let tool = EditorPopup(EditorTerrainTool.allCases.map(\.title),selected: terrainTool.rawValue,label: "Terrainwerkzeug") { [weak self] in self?.terrainTool = EditorTerrainTool(rawValue: $0) ?? .select; self?.placement = nil }
        panel.addArrangedSubview(tool)
        field("Pinselradius (0,5–16 m)",value: String(brushRadius),in: panel) { [weak self] in self?.setBrush($0,kind: 0) }
        field("Pinselstärke (0,01–2 m)",value: String(brushStrength),in: panel) { [weak self] in self?.setBrush($0,kind: 1) }
        field("Ziel-/Wasserhöhe (m)",value: String(brushHeight),in: panel) { [weak self] in self?.setBrush($0,kind: 2) }
        label("Material: rechteckige Pinselspuren, maximal 8 Flächen. Wasser: maximal 4 Becken à 500 m², 30 cm tief. Eine Geste = ein Undo-Schritt.",in: panel)
        button("Bodenflächen entfernen",in: panel) { [weak self] in self?.perform { try self?.session.edit("Bodenflächen entfernen") { $0.environment.surfaces = [] } } }
        button("Wasserflächen entfernen",in: panel) { [weak self] in self?.perform { try self?.session.edit("Wasser entfernen") { $0.environment.water = [] } } }
        field("Vegetationsdichte (0–1)",value: String(doc.environment.vegetationDensity),in: panel) { [weak self] text in self?.environmentNumber(text) { $0.vegetationDensity = $1 } }
        field("Sonnenlicht (0–1)",value: String(doc.environment.sunIntensity),in: panel) { [weak self] text in self?.environmentNumber(text) { $0.sunIntensity = $1 } }
        for axis in 0..<3 {
            field("Sonnenrichtung \(["X","Y","Z"][axis])",value: String(doc.environment.sunDirection.value[axis]),in: panel) { [weak self] text in
                self?.environmentNumber(text) { environment,value in
                    switch axis { case 0: environment.sunDirection.x = value; case 1: environment.sunDirection.y = value; default: environment.sunDirection.z = value }
                }
            }
            field("Nebelfarbe \(["Rot","Grün","Blau"][axis]) (0–1)",value: String(doc.environment.fogColor.value[axis]),in: panel) { [weak self] text in
                self?.environmentNumber(text) { environment,value in
                    switch axis { case 0: environment.fogColor.x = value; case 1: environment.fogColor.y = value; default: environment.fogColor.z = value }
                }
            }
        }
    }
    func environmentNumber(_ text: String,_ set: (inout LevelEnvironment,Float)->Void) {
        perform { guard let value = Float(text.replacingOccurrences(of: ",",with: ".")),value.isFinite else { throw LevelDocumentError("Bitte eine endliche Zahl eingeben.") }
            try session.edit("Umgebung") { set(&$0.environment,value) }
        }
    }
    func setBrush(_ text: String,kind: Int) {
        guard let value = Float(text.replacingOccurrences(of: ",",with: ".")),value.isFinite,
              (kind == 0 ? (0.5...16).contains(value) : kind == 1 ? (0.01...2).contains(value) : abs(value) <= 1000) else {
            show(LevelDocumentError("Ungültiger Pinselwert; bitte den angezeigten Bereich verwenden.")); return
        }
        switch kind { case 0: brushRadius = value; case 1: brushStrength = value; default: brushHeight = value }
    }
    func resize(width: Int,depth: Int,anchor: LevelResizeAnchor) {
        guard (12...128).contains(width),(12...128).contains(depth) else { show(LevelDocumentError("Kartengröße: 12–128 Meter je Achse.")); return }
        let count = session.document.outsideContentCount(width: width,depth: depth,anchor: anchor)
        let alert = NSAlert(); alert.messageText = "Karte auf \(width) × \(depth) m ändern?"
        alert.informativeText = "Verankerung: \(anchor.rawValue), auf volle Meter gerundet. \(count) Inhalte liegen anschließend ganz oder teilweise außerhalb. Sie bleiben erhalten; vor dem Spieltest müssen sie verschoben oder ausdrücklich gelöscht werden."
        alert.addButton(withTitle: "Größe ändern"); alert.addButton(withTitle: "Abbrechen")
        if alert.runModal() == .alertFirstButtonReturn { perform { try session.edit("Kartengröße") { try $0.resize(width: width,depth: depth,anchor: anchor) } } }
    }
    func beginTerrain(at p: SIMD3<Float>) {
        session.beginGesture(terrainTool.title); paintID = UUID().uuidString; paintStart = SIMD2(p.x,p.z)
        applyTerrain(at: p)
    }
    func applyTerrain(at p: SIMD3<Float>) {
        guard terrainTool != .select else { return }
        do {
            try session.edit(terrainTool.title) { doc in
                let point = SIMD2(p.x,p.z)
                if terrainTool.rawValue <= 4 {
                    try doc.brush(LevelTerrainBrush.allCases[terrainTool.rawValue-1],at: point,radius: brushRadius,strength: brushStrength,target: brushHeight)
                } else if terrainTool == .water {
                    guard !doc.environment.water.contains(where: { $0.id == paintID }) else { return }
                    let x = max(doc.bounds.x,Int(p.x.rounded())-Int(brushRadius)), z = max(doc.bounds.z,Int(p.z.rounded())-Int(brushRadius))
                    let width = min(20,min(Int(brushRadius*2),doc.bounds.x+doc.bounds.width-x)), depth = min(20,min(Int(brushRadius*2),doc.bounds.z+doc.bounds.depth-z))
                    try doc.addWater(x: x,z: z,width: max(1,width),depth: max(1,depth),surfaceHeight: brushHeight)
                    doc.environment.water[doc.environment.water.count-1].id = paintID
                } else {
                    let b = doc.bounds, start = paintStart ?? point
                    let x = max(Float(b.x),min(start.x,p.x)-brushRadius), z = max(Float(b.z),min(start.y,p.z)-brushRadius)
                    let right = min(Float(b.x+b.width),max(start.x,p.x)+brushRadius), back = min(Float(b.z+b.depth),max(start.y,p.z)+brushRadius)
                    let surface = LevelSurface(id: paintID,x: x,z: z,width: right-x,depth: back-z,material: LevelGroundMaterial.allCases[terrainTool.rawValue-5])
                    if let index = doc.environment.surfaces.firstIndex(where: { $0.id == paintID }) { doc.environment.surfaces[index] = surface } else { doc.environment.surfaces.append(surface) }
                }
            }
            // Keep focused controls and gesture alive while only the scene changes.
            try canvas.rebuild(session.document,selection: session.selection); window?.isDocumentEdited = session.isDirty
        } catch { session.endGesture(cancel: true); terrainTool = .select; show(error); refresh() }
    }
}
