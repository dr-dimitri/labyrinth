import AppKit
import BlacksiteCore

@MainActor
final class EditorLevelPreview: NSView {
    var document: LevelDocument? { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex: 0x30423a).setFill(); bounds.fill()
        guard let doc = document else { return }
        let b = doc.bounds, scale = min(bounds.width/CGFloat(b.width),bounds.height/CGFloat(b.depth))*0.88
        func point(_ x: Float,_ z: Float) -> NSPoint {
            NSPoint(x: bounds.midX+(CGFloat(x)-CGFloat(b.x)-CGFloat(b.width)/2)*scale,
                y: bounds.midY-(CGFloat(z)-CGFloat(b.z)-CGFloat(b.depth)/2)*scale)
        }
        NSColor.systemGray.setStroke()
        let corner = point(Float(b.x),Float(b.z+b.depth))
        NSBezierPath(rect: NSRect(x: corner.x,y: corner.y,width: CGFloat(b.width)*scale,height: CGFloat(b.depth)*scale)).stroke()
        for object in doc.objects {
            guard let item = LevelObjectCatalog.item(id: object.catalogID) else { continue }
            let p = point(object.position.x,object.position.z)
            var size = item.size*object.scale.value
            if !object.quarterTurns.isMultiple(of: 2) { let width = size.x; size.x = size.z; size.z = width }
            (item.category == .nature ? NSColor.systemGreen : .systemOrange).setFill()
            NSRect(x: p.x-CGFloat(size.x)*scale/2,y: p.y-CGFloat(size.z)*scale/2,width: max(2,CGFloat(size.x)*scale),height: max(2,CGFloat(size.z)*scale)).fill()
        }
        NSColor.systemCyan.setFill()
        for marker in doc.markers { let p = point(marker.position.x,marker.position.z); NSBezierPath(ovalIn: NSRect(x:p.x-3,y:p.y-3,width:6,height:6)).fill() }
    }
}

extension NativeEditorWindow {
    static var defaultStore: LevelFileStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,in: .userDomainMask)[0]
        return LevelFileStore(root: support.appendingPathComponent("Blacksite/Editor",isDirectory: true))
    }
    func startRecovery() {
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 20,repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.writeRecovery() }
        }
    }
    func writeRecovery() {
        guard session.isDirty else { store.removeRecovery(recoveryToken); lastRecovery = nil; return }
        let document = session.document
        guard document != lastRecovery else { return }
        do { try store.recover(document,source: fileURL,token: recoveryToken); lastRecovery = document }
        catch { status.stringValue = "Wiederherstellungskopie fehlgeschlagen: \(error.localizedDescription). Bitte manuell speichern." }
    }
    func offerRecovery() {
        guard !offeredRecovery else { return }; offeredRecovery = true
        do {
            for (url,recovery) in try store.recoveries() where url != store.recoveryURL(recoveryToken) {
                let alert = NSAlert(); alert.messageText = "Entwurf „\(recovery.document.name)“ wiederherstellen?"
                alert.informativeText = "Ungesicherte Kopie vom \(DateFormatter.localizedString(from: recovery.date,dateStyle: .short,timeStyle: .short)). Die Originaldatei bleibt erhalten."
                alert.addButton(withTitle: "Wiederherstellen"); alert.addButton(withTitle: "Später"); alert.addButton(withTitle: "Kopie verwerfen")
                let choice = alert.runModal()
                if choice == .alertFirstButtonReturn {
                    guard confirmDiscard() else { return }
                    resetInteraction(); try session.replace(with: recovery.document,saved: false); fileURL = recovery.source
                    // Only retire the previous recovery after our replacement exists.
                    try store.recover(recovery.document,source: recovery.source,token: recoveryToken)
                    try? FileManager.default.removeItem(at: url); lastRecovery = recovery.document
                    refresh(); focusSelection(); return
                }
                if choice == .alertThirdButtonReturn { try FileManager.default.removeItem(at: url) }
            }
        } catch { show(error) }
    }
    func resetInteraction() {
        cancelOperation(); session.endGesture(cancel: true); dragOrigin = nil; dragOriginals = []
        placement = nil; markerPlacement = nil; terrainTool = .select; canvas.clearGhost(); diagnostics = []; diagnosticIndex = 0
    }
    func saveToLibrary() {
        window?.makeFirstResponder(nil)
        do {
            let destination = try store.libraryURL()
            try LevelFileStore.save(session.document,to: destination)
            fileURL = destination; session.markSaved(); store.removeRecovery(recoveryToken); lastRecovery = nil
            remember(destination); refresh(); status.stringValue = "In „Eigene Levels“ gespeichert."
        } catch { show(error) }
    }
    func exportLevel() {
        window?.makeFirstResponder(nil)
        let panel = NSSavePanel(); panel.nameFieldStringValue = session.document.name+".blacksite-level.json"
        guard panel.runModal() == .OK,let url = panel.url else { return }
        do { try LevelFileStore.save(session.document,to: url); status.stringValue = "Level exportiert. Arbeitsdatei und Änderungsstatus bleiben erhalten." }
        catch { show(error) }
    }
    func showLibrary() {
        cancelOperation(); let token = UUID(); operationID = token
        progress.startAnimation(nil); status.stringValue = "Levelbibliothek wird gelesen …"
        let store = store
        let worker = Task.detached(priority:.userInitiated) { try store.list() }
        cancelWork = { worker.cancel() }
        Task { @MainActor [weak self] in
            let result = await worker.result
            guard let self,self.operationID == token else { return }
            self.cancelWork = nil; self.progress.stopAnimation(nil)
            do { self.presentLibrary(try result.get()) } catch { self.show(error) }
        }
    }
    private func presentLibrary(_ entries: [LevelFileStore.Entry]) {
        do {
            let alert = NSAlert()
            alert.messageText = "Eigene Levels"; alert.informativeText = "Lokale Levelbibliothek. Import legt eine unabhängige Kopie an. Externe Dateien lassen sich über „Öffnen“ bearbeiten."
            let panel = stack(); let preview = EditorLevelPreview(frame: NSRect(x:0,y:0,width:440,height:200))
            let info = NSTextField(wrappingLabelWithString: "Noch keine gespeicherten Levels.")
            var choice = 0
            func update() {
                guard entries.indices.contains(choice) else { return }
                let entry = entries[choice]; preview.document = try? LevelFileStore.read(entry.url)
                info.stringValue = "\(entry.width) × \(entry.depth) m · \(entry.objectCount) Objekte · \(DateFormatter.localizedString(from:entry.modified,dateStyle:.medium,timeStyle:.short))"
            }
            let picker = EditorPopup(entries.map(\.name),label:"Eigenes Level") { choice = $0; update() }
            picker.widthAnchor.constraint(equalToConstant:440).isActive = true; panel.addArrangedSubview(picker)
            panel.addArrangedSubview(preview); preview.widthAnchor.constraint(equalToConstant:440).isActive = true; preview.heightAnchor.constraint(equalToConstant:200).isActive = true
            panel.addArrangedSubview(info); info.widthAnchor.constraint(equalToConstant:440).isActive = true
            panel.frame = NSRect(x:0,y:0,width:440,height:270); alert.accessoryView = panel; update()
            alert.addButton(withTitle:"Bearbeiten"); alert.addButton(withTitle:"Spielen"); alert.addButton(withTitle:"Importieren …"); alert.addButton(withTitle:"Schließen")
            alert.buttons[0].isEnabled = !entries.isEmpty; alert.buttons[1].isEnabled = !entries.isEmpty
            let result = alert.runModal()
            if result == .alertThirdButtonReturn {
                let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                if panel.runModal() == .OK,let url = panel.url {
                    let doc = try LevelFileStore.read(url), destination = try store.libraryURL()
                    try LevelFileStore.save(doc,to:destination); status.stringValue = "„\(doc.name)“ importiert. Unter „Eigene Levels“ verfügbar."
                }
            } else if result == .alertFirstButtonReturn || result == .alertSecondButtonReturn,entries.indices.contains(choice) {
                if open(entries[choice].url),result == .alertSecondButtonReturn { validateLevel(start:true) }
            }
        } catch { show(error) }
    }
}
