import AppKit
import BlacksiteCore
import simd

extension NativeEditorWindow {
    func buildGameplayTools(in row: NSStackView) {
        button("Level prüfen",in: row) { [weak self] in self?.validateLevel(start: false) }
        button("Testen",in: row) { [weak self] in self?.validateLevel(start: true) }
        button("Vorgang abbrechen",in: row) { [weak self] in self?.cancelOperation() }
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false; row.addArrangedSubview(progress)
    }
    func buildGameplayInspector() {
        let panel = inspector, doc = session.document
        panel.addArrangedSubview(EditorPopup(LevelMission.allCases.map(\.title),selected: LevelMission.allCases.firstIndex(of: doc.mission ?? .waves) ?? 0,label: "Spielmodus") { [weak self] index in
            self?.perform { try self?.session.edit("Spielmodus") { $0.mission = LevelMission.allCases[index] } }
        })
        button("Pflichtmarker als Vorlage setzen …",in: panel) { [weak self] in
            guard let self else { return }; let alert = NSAlert(); alert.messageText = "Gameplay-Marker ersetzen?"
            alert.informativeText = "Setzt alle sieben Pflichtanker passend zur Kartengröße. Objekte bleiben erhalten. Anschließend Erreichbarkeit prüfen."
            alert.addButton(withTitle: "Marker setzen"); alert.addButton(withTitle: "Abbrechen")
            if alert.runModal() == .alertFirstButtonReturn { self.perform { try self.session.edit("Spielvorlage") { $0.installGameplayTemplate($0.mission ?? .waves) } } }
        }
        let marker = EditorPopup(LevelMarkerKind.allCases.map(\.title),label: "Markertyp") { _ in }; panel.addArrangedSubview(marker)
        button("Marker platzieren",in: panel) { [weak self,weak marker] in
            guard let self,let index = marker?.indexOfSelectedItem else { return }
            self.markerPlacement = LevelMarkerKind.allCases[index]; self.placement = nil; self.canvas.clearGhost(); self.terrainTool = .select
            self.status.stringValue = "Linksklick setzt \(self.markerPlacement!.title). Escape bricht ab. Vorhandene einzelne Pflichtanker werden versetzt."
        }
        if session.selection.count == 1,let id = session.selection.first,let marker = doc.markers.first(where: { $0.id == id }) {
            label(marker.kind.title,in: panel)
            for axis in [0,2] {
                field(axis == 0 ? "Marker X (m)" : "Marker Z (m)",value: String(marker.position.value[axis]),in: panel) { [weak self] text in
                    self?.editMarker(id,text: text) { value,number in if axis == 0 { value.position.x = number } else { value.position.z = number } }
                }
            }
            if marker.kind == .playerStart { field("Blickrichtung (Grad, 0 = Norden)",value: String(marker.yaw*180 / .pi),in: panel) { [weak self] text in self?.editMarker(id,text: text) { $0.yaw = $1 * .pi / 180 } } }
            if marker.kind == .extraction { field("Evakuierungsradius (m)",value: String(marker.radius),in: panel) { [weak self] text in self?.editMarker(id,text: text) { $0.radius = $1 } } }
        }
        label("Spieltest: Escape pausiert; „Zurück zum Editor“ beendet den Test. Entwurf und Kamera bleiben erhalten.",in: panel)
        if !diagnostics.isEmpty {
            label("\(diagnostics.count) Hinweise verhindern den Spieltest",in: panel)
            let list = EditorPopup(diagnostics.map(\.message),label: "Prüfergebnisse") { [weak self] index in self?.diagnosticIndex = index }
            panel.addArrangedSubview(list); list.widthAnchor.constraint(equalToConstant: 230).isActive = true
            button("Zum Hinweis springen",in: panel) { [weak self] in
                guard let self,self.diagnostics.indices.contains(self.diagnosticIndex) else { return }
                let issue = self.diagnostics[self.diagnosticIndex]
                self.session.selection = issue.itemID.map { [$0] } ?? []
                if let p = issue.position { self.canvas.focus(p.value) }
                self.refresh(); self.status.stringValue = issue.message
            }
        }
        label("Schaltbare Geräte: Generator und Hubtor aus dem Katalog. Hubtore über „Objekte“ mit einem vorhandenen Generator verbinden; ohne Verbindung Handbetrieb. Dekorative Tore/Schilder sind keine Missionsziele.",in: panel)
    }
    func editMarker(_ id: String,text: String,_ change: (inout LevelMarker,Float)->Void) {
        perform {
            guard let value = Float(text.replacingOccurrences(of: ",",with: ".")),value.isFinite else { throw LevelDocumentError("Bitte eine endliche Zahl eingeben.") }
            try session.edit("Marker bearbeiten") { doc in if let i = doc.markers.firstIndex(where: { $0.id == id }) { change(&doc.markers[i],value) } }
        }
    }
    func placeMarker(_ kind: LevelMarkerKind,point: SIMD3<Float>) {
        perform {
            try session.edit("Marker setzen") { $0.setMarker(kind,at: .init(gridSnap ? point.x.rounded() : point.x,0,gridSnap ? point.z.rounded() : point.z)) }
            let matching = session.document.markers.filter { $0.kind == kind }
            session.selection = Set((kind.isSingleton ? matching.first : matching.last).map { [$0.id] } ?? [])
        }
        markerPlacement = nil
    }
    func cancelOperation() {
        operationID = UUID(); cancelWork?(); cancelWork = nil; progress.stopAnimation(nil)
        status.stringValue = "Vorgang abgebrochen; Dokument unverändert."
    }
    func validateLevel(start: Bool) {
        window?.makeFirstResponder(nil); cancelOperation()
        let snapshot = session.document, token = UUID(); operationID = token
        progress.startAnimation(nil); status.stringValue = "Karte und erreichbare Wege werden geprüft … Abbruch jederzeit möglich."
        let worker = Task.detached(priority: .userInitiated) { () -> ([LevelPlayIssue],NativeLoadedLevel?) in
            let issues = snapshot.playIssues()
            guard issues.isEmpty,start,!Task.isCancelled else { return (issues,nil) }
            do { return ([],try NativeLoadedLevel(document: snapshot)) }
            catch { return ([LevelPlayIssue(message: error.localizedDescription,itemID: nil,position: nil)],nil) }
        }
        cancelWork = { worker.cancel() }
        Task { @MainActor [weak self] in
            let (issues,loaded) = await worker.value
            guard let self,self.operationID == token else { return }
            self.cancelWork = nil; self.progress.stopAnimation(nil)
            guard self.session.document == snapshot else { self.status.stringValue = "Dokument inzwischen geändert; bitte erneut prüfen."; return }
            self.diagnostics = issues; self.diagnosticIndex = 0; self.inspectorSection = 2; self.refresh()
            if issues.isEmpty {
                self.status.stringValue = "Level ist spielbar."
                if let loaded { self.startPlaytest(loaded) }
            } else { self.status.stringValue = issues[0].message }
        }
    }
    func startPlaytest(_ loaded: NativeLoadedLevel) {
        guard playtestWindow == nil else { return }
        let gameWindow = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1280,height: 800),styleMask: [.titled,.closable,.resizable],backing: .buffered,defer: false)
        gameWindow.title = "Spieltest — \(loaded.document.name)"; gameWindow.isReleasedWhenClosed = false; gameWindow.minSize = NSSize(width: 960,height: 640); gameWindow.center()
        let coordinator = GameCoordinator(window: gameWindow,importedLevel: loaded,editorTestMission: loaded.document.missionKind)
        coordinator.onEditorTestFinished = { [weak self] in
            self?.playtestCoordinator = nil; self?.playtestWindow = nil
            self?.window?.makeKeyAndOrderFront(nil); self?.status.stringValue = "Zurück aus dem Spieltest. Entwurf und Kamera unverändert."
        }
        playtestWindow = gameWindow; playtestCoordinator = coordinator
        window?.orderOut(nil); gameWindow.makeKeyAndOrderFront(nil)
    }
}

extension NativeEditorWindow {
    func createExample(_ example: LevelExample) {
        guard confirmDiscard() else { return }
        resetInteraction(); let token = UUID(); operationID = token
        let previous = session.document
        progress.startAnimation(nil); status.stringValue = "Beispiel wird aufgebaut … Abbruch jederzeit möglich."
        let worker = Task.detached(priority:.userInitiated) { try example.makeDocument() }
        cancelWork = { worker.cancel() }
        Task { @MainActor [weak self] in
            let result = await worker.result
            guard let self,self.operationID == token else { return }
            self.cancelWork = nil; self.progress.stopAnimation(nil)
            guard self.session.document == previous else { self.status.stringValue = "Entwurf inzwischen geändert; Beispiel nicht übernommen."; return }
            do {
                let document = try result.get()
                try self.session.replace(with:document,saved:false); self.fileURL = nil; self.lastRecovery = nil
                self.refresh(); self.canvas.distance = Float(document.bounds.width)*0.9; self.focusSelection()
            } catch { self.show(error) }
        }
    }
}

extension NativeEditorWindow {
    func showEditorHelp() {
        let alert = NSAlert(); alert.messageText = "Mein erstes Level"
        let instructions = "1. Rechts den Namen eingeben. Unter Landschaft Größe, Vorlage und Seed wählen; danach Höhen/Material mit der linken Maustaste malen.\n\n2. Links ein Objekt suchen, „Objekt platzieren“ drücken und in die Karte klicken. R dreht, Escape bricht ab. Shift wählt mehrere, ⌘D dupliziert, ⌘Z macht rückgängig. Rechts unter Objekte stehen genaue Maße und Gruppenwerkzeuge.\n\n3. Unter Spiel & Prüfung den Auftrag wählen und Pflichtmarker als Vorlage setzen. Start/Ziele frei und erreichbar halten. „Level prüfen“ zeigt anspringbare Fehler.\n\n4. „In Bibliothek speichern“ sichert den Entwurf. ⌘S speichert Änderungen. Eigene Levels zeigt Vorschau/Datum und bietet Bearbeiten, Spielen und Import. Export schreibt eine portable Kopie.\n\n5. „Testen“ startet das Spiel. Escape → Zurück zum Editor erhält Entwurf und Kamera.\n\nKamera: Rechtsziehen dreht, mittlere Taste verschiebt, Mausrad zoomt. F fokussiert. Beispiele stehen links oben. Automatische Wiederherstellung alle 20 Sekunden; nach einem Absturz beim nächsten Editorstart angeboten.\n\nGrenzen: 12–128 m je Achse, 1000 Objekte, acht Boden- und vier flache Wasserflächen. Gemessene Referenz: 500 gemischte Objekte auf 128 × 128 m. Prüfen, Bibliothek und Beispielaufbau sind abbrechbar."
        alert.informativeText = "Bauen, speichern und direkt ausprobieren. Die Anleitung lässt sich nach unten scrollen."
        let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:500,height:340)); scroll.hasVerticalScroller = true
        let text = NSTextView(frame:scroll.bounds); text.isEditable = false; text.drawsBackground = false
        text.font = .systemFont(ofSize:13); text.string = instructions; text.isVerticallyResizable = true
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        scroll.documentView = text; alert.accessoryView = scroll
        alert.addButton(withTitle:"Verstanden"); alert.runModal()
    }
}
