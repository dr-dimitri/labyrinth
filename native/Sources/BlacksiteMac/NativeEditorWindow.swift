import AppKit
import BlacksiteCore

@MainActor
final class EditorColumn: NSStackView { override var isFlipped: Bool { true } }

@MainActor
final class EditorButton: NSButton {
    var invoke: () -> Void
    init(_ title: String, _ invoke: @escaping () -> Void) {
        self.invoke = invoke; super.init(frame: .zero)
        self.title = title; bezelStyle = .rounded; target = self; action = #selector(run)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    @objc private func run() { invoke() }
}

@MainActor
final class EditorField: NSTextField, NSTextFieldDelegate {
    var changed: (String) -> Void
    init(_ value: String, label: String, changed: @escaping (String) -> Void) {
        self.changed = changed; super.init(frame: .zero); stringValue = value
        delegate = self; setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    func controlTextDidEndEditing(_ obj: Notification) { changed(stringValue) }
}

@MainActor
final class NativeEditorWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var session: LevelEditingSession
    var fileURL: URL?
    let store: LevelFileStore
    var recoveryToken = UUID(), recoveryTimer: Timer?, lastRecovery: LevelDocument?, offeredRecovery = false
    var onClose: (() -> Void)?
    let canvas = NativeEditorScene(frame: .zero)
    let inspector = EditorColumn(), catalogPanel = EditorColumn(), tools = NSStackView()
    let objects = NSTableView(), status = NSTextField(wrappingLabelWithString: "")
    let catalog = NSPopUpButton(), recent = NSPopUpButton()
    let catalogPreview = EditorCatalogPreview(frame: .zero), catalogInfo = NSTextField(wrappingLabelWithString: "")
    var visibleCatalog: [LevelCatalogItem] = [], catalogCategory: LevelCatalogCategory?
    var catalogQuery = "", favoritesOnly = false
    var catalogFavorites = Set(UserDefaults.standard.stringArray(forKey: "editor.favorites") ?? [])
    var rows: [(id: String, title: String)] = []
    var refreshing = false
    var placement: String?
    var inspectorSection = 0
    var markerPlacement: LevelMarkerKind?
    var diagnostics: [LevelPlayIssue] = [], diagnosticIndex = 0
    let progress = NSProgressIndicator()
    var operationID = UUID(), cancelWork: (() -> Void)?
    var playtestWindow: NSWindow?, playtestCoordinator: GameCoordinator?
    var gridSnap = true, groundSnap = true, angleStep = 1, placementTurns = 0
    var dragOrigin: SIMD3<Float>?, dragOriginals: [LevelObject] = [], dragHandle = "move"
    var terrainTool: EditorTerrainTool = .select
    var brushRadius: Float = 3, brushStrength: Float = 0.3, brushHeight: Float = 0
    var paintID = "", paintStart: SIMD2<Float>?
    var extraInspector: ((NSStackView) -> Void)?
    var extraTools: ((NSStackView) -> Void)?
    var undoButton: NSButton!, redoButton: NSButton!
    var changed: (() -> Void)?
    init(document: LevelDocument? = nil, fileURL: URL? = nil, store: LevelFileStore? = nil) {
        self.store = store ?? Self.defaultStore
        session = LevelEditingSession(document: document ?? LevelDocument(), saved: fileURL != nil || document == nil); self.fileURL = fileURL
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1260,height: 820), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        super.init(window: window); window.delegate = self; window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1100,height: 720); window.title = "Leveleditor"; window.center()
        window.acceptsMouseMovedEvents = true
        buildUI(); configureCanvas(); refresh(); startRecovery()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    func stack(_ orientation: NSUserInterfaceLayoutOrientation = .vertical) -> NSStackView {
        let stack = NSStackView(); stack.orientation = orientation; stack.alignment = .leading; stack.spacing = 7; return stack
    }
    @discardableResult func button(_ title: String, in stack: NSStackView, _ action: @escaping () -> Void) -> NSButton {
        let button = EditorButton(title, action); stack.addArrangedSubview(button); return button
    }
    func label(_ text: String, in stack: NSStackView) { let label = NSTextField(wrappingLabelWithString: text); stack.addArrangedSubview(label); label.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true }
    @discardableResult func field(_ title: String, value: String, in stack: NSStackView, _ action: @escaping (String) -> Void) -> EditorField {
        label(title, in: stack)
        let field = EditorField(value, label: title, changed: action); stack.addArrangedSubview(field)
        field.widthAnchor.constraint(equalToConstant: 230).isActive = true; return field
    }
    func scroll(_ view: NSView, width: CGFloat? = nil) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        view.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = view
        if let width { scroll.widthAnchor.constraint(equalToConstant: width).isActive = true; view.widthAnchor.constraint(equalToConstant: width - 20).isActive = true }
        return scroll
    }
    func buildUI() {
        let root = stack(); root.edgeInsets = NSEdgeInsets(top: 10,left: 10,bottom: 10,right: 10)
        root.translatesAutoresizingMaskIntoConstraints = false; window?.contentView = root
        tools.orientation = .horizontal; tools.spacing = 6
        button("Neues Level", in: tools) { [weak self] in self?.newDocument() }
        button("Öffnen …", in: tools) { [weak self] in self?.openDocument(nil) }
        button("Speichern", in: tools) { [weak self] in self?.saveDocument(nil) }
        button("Speichern unter …", in: tools) { [weak self] in self?.save(as: true) }
        undoButton = button("Rückgängig", in: tools) { [weak self] in self?.undo(nil) }
        redoButton = button("Wiederholen", in: tools) { [weak self] in self?.redo(nil) }
        button("3D / Draufsicht", in: tools) { [weak self] in self?.canvas.topDown.toggle() }
        button("Auswahl fokussieren", in: tools) { [weak self] in self?.focusSelection() }
        root.addArrangedSubview(tools)
        let workflow = stack(.horizontal); buildGameplayTools(in: workflow); root.addArrangedSubview(workflow)
        button("Eigene Levels",in: workflow) { [weak self] in self?.showLibrary() }
        button("In Bibliothek speichern",in: workflow) { [weak self] in self?.saveToLibrary() }
        button("Exportieren …",in: workflow) { [weak self] in self?.exportLevel() }
        button("Kurzanleitung",in: workflow) { [weak self] in self?.showEditorHelp() }
        let body = stack(.horizontal); body.alignment = .top; body.distribution = .fill
        catalogPanel.orientation = .vertical; catalogPanel.alignment = .leading; catalogPanel.spacing = 7
        inspector.orientation = .vertical; inspector.alignment = .leading; inspector.spacing = 7
        label("OBJEKTKATALOG", in: catalogPanel)
        let example = EditorPopup(LevelExample.allCases.map(\.title),label:"Beispiellevel") { _ in }; catalogPanel.addArrangedSubview(example)
        button("Beispiel erstellen …",in:catalogPanel) { [weak self,weak example] in
            guard let self,let index = example?.indexOfSelectedItem else { return }; self.createExample(LevelExample.allCases[index])
        }
        configureCatalog()
        button("Objekt platzieren", in: catalogPanel) { [weak self] in
            guard let self, let item = self.catalogPreview.item else { return }; self.placement = item.id; self.markerPlacement = nil; self.terrainTool = .select
            self.status.stringValue = "Linksklick auf das Gelände platziert das Objekt. Escape bricht ab."
        }
        label("OBJEKTE UND MARKER · ⇧ Mehrfachauswahl", in: catalogPanel)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")); column.width = 220; objects.addTableColumn(column)
        objects.headerView = nil; objects.allowsMultipleSelection = true; objects.delegate = self; objects.dataSource = self
        objects.setAccessibilityLabel("Objekte und Marker")
        let list = NSScrollView(); list.documentView = objects; list.hasVerticalScroller = true
        list.widthAnchor.constraint(equalToConstant: 240).isActive = true; list.heightAnchor.constraint(equalToConstant: 235).isActive = true
        catalogPanel.addArrangedSubview(list)
        button("Auswahl löschen", in: catalogPanel) { [weak self] in self?.perform { try self?.session.deleteSelection() } }
        buildObjectTools()
        label("ZULETZT GEÖFFNET", in: catalogPanel); catalogPanel.addArrangedSubview(recent)
        button("Zuletzt bearbeitetes öffnen", in: catalogPanel) { [weak self] in
            guard let self, let path = self.recent.selectedItem?.representedObject as? String else { return }
            self.open(URL(fileURLWithPath: path))
        }
        label("Kamera: Rechtsziehen dreht, mittlere Taste verschiebt, Mausrad zoomt. Linksklick wählt. Entf löscht, F fokussiert. Texteingaben bleiben im Eingabefeld. Raster: 1 m.", in: catalogPanel)
        body.addArrangedSubview(scroll(catalogPanel,width: 260)); body.addArrangedSubview(canvas); body.addArrangedSubview(scroll(inspector,width: 260))
        canvas.widthAnchor.constraint(greaterThanOrEqualToConstant: 500).isActive = true
        canvas.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        for side in [body.arrangedSubviews.first!, body.arrangedSubviews.last!] { side.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true }
        root.addArrangedSubview(body); body.widthAnchor.constraint(equalTo: root.widthAnchor,constant: -20).isActive = true
        body.heightAnchor.constraint(greaterThanOrEqualToConstant: 560).isActive = true
        status.font = .systemFont(ofSize: 11); root.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        body.setContentHuggingPriority(.defaultLow, for: .vertical)
        refreshRecent()
    }
    func configureCanvas() {
        canvas.picked = { [weak self] id, point, event in
            guard let self else { return }
            if let kind = self.markerPlacement,let point { self.placeMarker(kind,point: point); return }
            if self.placement == nil, self.terrainTool == .select, let id, id.hasPrefix("handle:"),let point { self.beginObjectDrag(point,handle: String(id.dropFirst(7))); return }
            if self.terrainTool != .select, let point { self.beginTerrain(at: point); return }
            if let template = self.placement, let point {
                var object = LevelObject(catalogID: template,position: LevelVector(self.gridSnap ? point.x.rounded() : point.x,self.groundSnap ? 0 : point.y,self.gridSnap ? point.z.rounded() : point.z))
                object.quarterTurns = self.placementTurns; object.heightMode = self.groundSnap ? .ground : .absolute
                self.perform { try self.session.edit("Platzieren") { $0.objects.append(object) }; self.session.selection = [object.id] }
                self.placement = nil; self.canvas.clearGhost()
            } else {
                self.session.selectObject(id,extending: event.modifierFlags.contains(.shift))
                if let id,self.session.document.markers.contains(where: { $0.id == id }) { self.inspectorSection = 2 }
                self.refresh()
                if id != nil,let point { self.beginObjectDrag(point) }
            }
        }
        canvas.hovered = { [weak self] point in
            guard let self,let id = self.placement else { return }
            var object = LevelObject(id: "preview",catalogID: id,position: .init(self.gridSnap ? point.x.rounded() : point.x,0,self.gridSnap ? point.z.rounded() : point.z))
            object.quarterTurns = self.placementTurns
            if !self.groundSnap { object.heightMode = .absolute; object.position.y = point.y }
            self.canvas.showGhost(object)
        }
        canvas.dragged = { [weak self] p,_ in
            guard let self else { return }
            if self.terrainTool != .select { self.applyTerrain(at: p) } else { self.dragObjects(to: p) }
        }
        canvas.released = { [weak self] in self?.session.endGesture(); self?.dragOrigin = nil; self?.refresh(); self?.changed?() }
        canvas.cancelled = { [weak self] in self?.placement = nil; self?.markerPlacement = nil; self?.canvas.clearGhost(); self?.dragOrigin = nil; self?.session.endGesture(cancel: true); self?.refresh() }
        canvas.keyAction = { [weak self] code in
            if code == 51 || code == 117 { self?.perform { try self?.session.deleteSelection() } }
            if code == 3 { self?.focusSelection() }
            if code == 15, let self {
                if self.placement != nil { self.placementTurns = (self.placementTurns+self.angleStep)%4 }
                else { self.perform { try self.session.transformSelection(quarterTurns: self.angleStep) } }
            }
        }
    }
    func perform(_ operation: () throws -> Void) {
        do { try operation(); refresh(); changed?() } catch { show(error) }
    }
    func refresh() {
        guard !refreshing else { return }; refreshing = true; defer { refreshing = false }
        session.reconcileSelection()
        window?.title = "\(session.document.name) — Leveleditor"; window?.isDocumentEdited = session.isDirty
        let warnings = (try? session.document.placementWarnings()) ?? []
        let warned = Set(warnings.map(\.id))
        rows = session.document.objects.map { ($0.id, (warned.contains($0.id) ? "⚠ " : "") + ($0.locked ? "🔒 " : "") + ($0.hidden ? "◌ " : "") + (LevelObjectCatalog.item(id: $0.catalogID)?.name ?? $0.catalogID)) }
        rows += session.document.markers.map { ($0.id, "◆ " + $0.kind.title) }
        objects.reloadData(); objects.selectRowIndexes(IndexSet(rows.indices.filter { session.selection.contains(rows[$0].id) }), byExtendingSelection: false)
        undoButton.isEnabled = session.canUndo; redoButton.isEnabled = session.canRedo
        inspector.arrangedSubviews.forEach { inspector.removeArrangedSubview($0); $0.removeFromSuperview() }
        field("Levelname", value: session.document.name, in: inspector) { [weak self] value in self?.perform { try self?.session.edit("Name") { $0.name = value } } }
        label("\(session.document.bounds.width) × \(session.document.bounds.depth) m · \(session.document.objects.count)/1000 Objekte\nReferenz: 500 gemischte Objekte auf 128 × 128 m.\nGelände: 1-m-Raster · 40 Undo-Schritte", in: inspector)
        inspector.addArrangedSubview(EditorPopup(["Objekte", "Landschaft", "Spiel & Prüfung"],selected: inspectorSection,label: "Eigenschaftenbereich") { [weak self] index in self?.inspectorSection = index; if index == 0 { self?.terrainTool = .select }; self?.refresh() })
        if inspectorSection == 1 { buildTerrainInspector() }
        if inspectorSection == 2 { buildGameplayInspector() }
        if inspectorSection == 0, let id = session.selection.first, session.selection.count == 1, let object = session.document.objects.first(where: { $0.id == id }) {
            label(LevelObjectCatalog.item(id: object.catalogID)?.name ?? object.catalogID, in: inspector)
            for (axis,title) in ["X (m)","Höhenversatz (m)","Z (m)"].enumerated() {
                field(title,value: String(object.position.value[axis]),in: inspector) { [weak self] value in
                    self?.perform {
                        guard let number = Float(value.replacingOccurrences(of: ",",with: ".")), number.isFinite else { throw LevelDocumentError("Bitte eine endliche Zahl eingeben.") }
                        try self?.session.edit("Position") { doc in
                            guard let index = doc.objects.firstIndex(where: { $0.id == id }), !doc.objects[index].locked else { return }
                            switch axis { case 0: doc.objects[index].position.x = number; case 1: doc.objects[index].position.y = number; default: doc.objects[index].position.z = number }
                        }
                    }
                }
            }
        }
        if inspectorSection == 0 { buildObjectInspector() }
        extraInspector?(inspector)
        do {
            try canvas.rebuild(session.document, selection: session.selection)
            status.stringValue = session.isDirty ? "Ungesicherte Änderungen. ⌘S speichert. Entwürfe benötigen noch keine Spielmarker."
                : fileURL == nil ? "Neuer leerer Entwurf. ⌘S legt eine Leveldatei an." : "Gespeichert."
        }
        catch { status.stringValue = "Vorschau: " + error.localizedDescription }
        if let warning = warnings.first(where: { session.selection.contains($0.id) }) ?? warnings.first { status.stringValue += "  ⚠ \(warning.message) (\(warnings.count) Hinweise)." }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { NSTextField(labelWithString: rows[row].title) }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !refreshing else { return }; session.selection = Set(objects.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
        if session.document.markers.contains(where: { session.selection.contains($0.id) }) { inspectorSection = 2 }
        refresh()
    }
    func focusSelection() {
        if let id = session.selection.first {
            let object = session.document.objects.first { $0.id == id }
            let p = object?.position ?? session.document.markers.first { $0.id == id }?.position
            if let p {
                var point = p.value
                if object?.heightMode != .absolute,let terrain = try? session.document.terrainProfile() { point.y += terrain.height(x: p.x,z: p.z) }
                canvas.focus(point); return
            }
        }
        let b = session.document.bounds; canvas.focus(SIMD3(Float(b.x)+Float(b.width)/2,0,Float(b.z)+Float(b.depth)/2))
    }
    @objc func undo(_ sender: Any?) { session.undo(); refresh(); changed?() }
    @objc func redo(_ sender: Any?) { session.redo(); refresh(); changed?() }
    @objc func saveDocument(_ sender: Any?) { _ = save(as: false) }
    @discardableResult func save(as saveAs: Bool) -> Bool {
        window?.makeFirstResponder(nil)
        var destination = saveAs ? nil : fileURL
        if destination == nil {
            let panel = NSSavePanel(); panel.nameFieldStringValue = session.document.name + ".blacksite-level.json"
            try? store.prepare(); panel.directoryURL = store.levels
            guard panel.runModal() == .OK, let url = panel.url else { return false }; destination = url
        }
        do {
            try LevelFileStore.save(session.document,to: destination!)
            fileURL = destination; session.markSaved(); store.removeRecovery(recoveryToken); lastRecovery = nil
            remember(destination!); refresh(); return true
        } catch { show(error); return false }
    }
    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    @discardableResult func open(_ url: URL) -> Bool {
        do {
            // Reject invalid targets before asking to discard any current work.
            _ = try Self.read(url)
            guard confirmDiscard() else { return false }
            // Saving may have replaced this very file, including when opened
            // through another path. Only the post-confirmation read is current.
            let document = try Self.read(url)
            resetInteraction(); try session.replace(with: document,saved: true); fileURL = url; remember(url)
            lastRecovery = nil; refresh(); focusSelection(); return true
        } catch { show(error); return false }
    }
    static func read(_ url: URL) throws -> LevelDocument {
        try LevelFileStore.read(url)
    }
    func newDocument() {
        guard confirmDiscard() else { return }
        resetInteraction(); session = LevelEditingSession(document:LevelDocument(),saved:true); fileURL = nil; lastRecovery = nil; refresh(); focusSelection()
    }
    func confirmDiscard() -> Bool {
        window?.makeFirstResponder(nil)
        guard session.isDirty else { store.removeRecovery(recoveryToken); return true }
        let alert = NSAlert(); alert.messageText = "Änderungen an „\(session.document.name)“ speichern?"
        alert.informativeText = "Der aktuelle Entwurf enthält ungesicherte Änderungen."
        alert.addButton(withTitle: "Speichern"); alert.addButton(withTitle: "Verwerfen"); alert.addButton(withTitle: "Abbrechen")
        switch alert.runModal() { case .alertFirstButtonReturn: return save(as: false); case .alertSecondButtonReturn: store.removeRecovery(recoveryToken); lastRecovery = nil; return true; default: return false }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmDiscard() }
    func windowWillClose(_ notification: Notification) { recoveryTimer?.invalidate(); recoveryTimer = nil; cancelOperation(); playtestWindow?.performClose(nil); onClose?() }
    func show(_ error: Error) { let alert = NSAlert(); alert.messageText = "Level konnte nicht geändert werden"; alert.informativeText = error.localizedDescription; alert.runModal() }
    func remember(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: "editor.recent") ?? []; paths.removeAll { $0 == url.path }; paths.insert(url.path,at: 0)
        UserDefaults.standard.set(Array(paths.prefix(12)),forKey: "editor.recent"); refreshRecent()
    }
    func refreshRecent() {
        recent.removeAllItems()
        for path in UserDefaults.standard.stringArray(forKey: "editor.recent") ?? [] {
            let item = NSMenuItem(title: URL(fileURLWithPath: path).lastPathComponent,action: nil,keyEquivalent: ""); item.representedObject = path; recent.menu?.addItem(item)
        }
        recent.isEnabled = recent.numberOfItems > 0
    }
}
