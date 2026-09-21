import AppKit
import BlacksiteCore
import simd

extension NativeEditorWindow {
    func buildObjectTools() {
        label("BEARBEITEN",in: catalogPanel)
        button("Duplizieren (⌘D)",in: catalogPanel) { [weak self] in self?.perform { try self?.session.duplicateSelection() } }
        button("Gruppieren",in: catalogPanel) { [weak self] in self?.perform { try self?.session.groupSelection() } }
        button("Gruppe auflösen",in: catalogPanel) { [weak self] in self?.perform { try self?.session.ungroupSelection() } }
        button("Sperren / Entsperren",in: catalogPanel) { [weak self] in
            guard let self else { return }; let selected = self.session.document.objects.filter { self.session.selection.contains($0.id) }
            self.perform { try self.session.setLocked(selected.contains { !$0.locked }) }
        }
        button("Ausblenden / Einblenden",in: catalogPanel) { [weak self] in
            guard let self else { return }; let selected = self.session.document.objects.filter { self.session.selection.contains($0.id) }
            self.perform { try self.session.setHidden(selected.contains { !$0.hidden }) }
        }
    }
    func buildObjectInspector() {
        let panel = inspector
        panel.addArrangedSubview(EditorPopup(["Raster 1 m", "Freie Position"],selected: gridSnap ? 0 : 1,label: "Rastersnapping") { [weak self] in self?.gridSnap = $0 == 0 })
        panel.addArrangedSubview(EditorPopup(["Bodengebunden platzieren", "Absolute Höhe platzieren"],selected: groundSnap ? 0 : 1,label: "Bodensnapping") { [weak self] in self?.groundSnap = $0 == 0 })
        panel.addArrangedSubview(EditorPopup(["Winkelschritt 90°", "Winkelschritt 180°"],selected: angleStep == 1 ? 0 : 1,label: "Winkelsnapping") { [weak self] in self?.angleStep = $0 == 0 ? 1 : 2 })
        let selected = session.document.objects.filter { session.selection.contains($0.id) }
        guard !selected.isEmpty else { label("Vorlage wählen und platzieren. Linksklick wählt Gruppen; ⇧ erweitert die Auswahl.",in: panel); return }
        label("\(selected.count) Objekte ausgewählt. Ziehen verschiebt. R dreht. Farbgriffe: Rot X, Blau Z, Gelb Größe, Türkis Drehen. Gesperrte Objekte bleiben unverändert.",in: panel)
        button("Auswahl drehen",in: panel) { [weak self] in guard let self else { return }; self.perform { try self.session.transformSelection(quarterTurns: self.angleStep) } }
        let factor = field("Gruppenskalierung (Faktor)",value: "1",in: panel) { _ in }
        button("Gruppe skalieren",in: panel) { [weak self,weak factor] in
            guard let self,let scale = Float(factor?.stringValue.replacingOccurrences(of: ",",with: ".") ?? "") else { return }
            self.perform { try self.session.transformSelection(scale: scale) }
        }
        if selected.count == 1,let object = selected.first {
            let id = object.id
            if object.catalogID == "device.lift-gate" {
                let generators = session.document.objects.filter { $0.catalogID == "device.generator" }
                let titles = ["Ohne Versorgung (Handbetrieb)"] + generators.enumerated().map { "Generator \($0.offset+1) · X \($0.element.position.x), Z \($0.element.position.z)" }
                let selected = object.powerSourceID.flatMap { id in generators.firstIndex { $0.id == id }.map { $0+1 } } ?? 0
                panel.addArrangedSubview(EditorPopup(titles,selected: selected,label: "Torversorgung") { [weak self] index in
                    self?.perform { try self?.session.edit("Tor verbinden") { doc in
                        guard let i = doc.objects.firstIndex(where: { $0.id == id }),!doc.objects[i].locked else { return }
                        doc.objects[i].powerSourceID = index == 0 ? nil : generators[index-1].id
                    } }
                })
                label("Hubtor: nur 0°/180°; Maßstab 1–1,5. E am Tor öffnet/schließt; der Generator beeinflusst den Antrieb.",in: panel)
            }
            panel.addArrangedSubview(EditorPopup(["Geländerelativer Versatz", "Absolute Welthöhe"],selected: object.heightMode == .ground ? 0 : 1,label: "Höhenbezug") { [weak self] index in
                guard let self else { return }
                self.perform {
                    let terrain = try self.session.document.terrainProfile()
                    try self.session.edit("Höhenbezug") { doc in
                        guard let i = doc.objects.firstIndex(where: { $0.id == id }),!doc.objects[i].locked else { return }
                        let mode: LevelHeightMode = index == 0 ? .ground : .absolute
                        guard doc.objects[i].heightMode != mode else { return }
                        let p = doc.objects[i].position
                        doc.objects[i].position.y += (mode == .absolute ? 1 : -1)*terrain.height(x: p.x,z: p.z)
                        doc.objects[i].heightMode = mode
                    }
                }
            })
            panel.addArrangedSubview(EditorPopup(["0°", "90°", "180°", "270°"],selected: object.quarterTurns,label: "Drehung") { [weak self] turns in
                self?.perform { try self?.session.edit("Drehen") { doc in if let i = doc.objects.firstIndex(where: { $0.id == id }),!doc.objects[i].locked { doc.objects[i].quarterTurns = turns } } }
            })
            for axis in 0..<3 {
                field("Skalierung \(["X","Y","Z"][axis])",value: String(object.scale.value[axis]),in: panel) { [weak self] text in
                    self?.perform {
                        guard let value = Float(text.replacingOccurrences(of: ",",with: ".")),value.isFinite else { throw LevelDocumentError("Ungültige Skalierung.") }
                        try self?.session.edit("Skalieren") { doc in
                            guard let i = doc.objects.firstIndex(where: { $0.id == id }),!doc.objects[i].locked else { return }
                            switch axis { case 0: doc.objects[i].scale.x = value; case 1: doc.objects[i].scale.y = value; default: doc.objects[i].scale.z = value }
                        }
                    }
                }
            }
        }
    }
    func beginObjectDrag(_ point: SIMD3<Float>,handle: String = "move") {
        dragOrigin = point; dragOriginals = session.document.objects; dragHandle = handle; session.beginGesture("Objekt ziehen")
    }
    func dragObjects(to point: SIMD3<Float>) {
        guard let start = dragOrigin else { return }
        var delta = point-start; delta.y = 0
        if gridSnap { delta.x = delta.x.rounded(); delta.z = delta.z.rounded() }
        if dragHandle == "move.x" { delta.z = 0 }; if dragHandle == "move.z" { delta.x = 0 }
        do {
            if dragHandle == "scale" {
                let factor = max(0.25,min(4,1+(point.x-start.x)*0.15))
                try session.transformSelection(scale: factor,originals: dragOriginals)
            } else if dragHandle == "rotate" {
                let turns = ((Int(((point.x-start.x)/2).rounded())%4)+4)%4
                try session.transformSelection(quarterTurns: turns,originals: dragOriginals)
            } else { try session.transformSelection(translation: delta,originals: dragOriginals) }
            try canvas.rebuild(session.document,selection: session.selection); window?.isDocumentEdited = session.isDirty
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc func duplicate(_ sender: Any?) { perform { try session.duplicateSelection() } }
}
