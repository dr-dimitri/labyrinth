import AppKit
import MetalKit
import QuartzCore
import CoreGraphics
import BlacksiteCore

@MainActor
final class GameCoordinator: NSObject, MTKViewDelegate, NSWindowDelegate {
    let window: NSWindow
    let view: NativeGameView
    let hud: GameHUDView
    var renderer: NativeRenderer?
    var simulation = CombatSimulation()
    var mode: NativeRenderMode = .menu
    var settings = NativeSettings()
    var ready = false
    var loadingMessage = "Metal-Einsatzgebiet wird vorbereitet …"
    var bannerLabel = "", bannerTitle = "", bannerDetail = "", toastText = "", killText = ""
    var bannerUntil: Double = 0, toastUntil: Double = 0, hitUntil: Double = 0, killUntil: Double = 0, damageUntil: Double = 0
    var lastHitHeadshot = false
    var showPerformance = false
    var performanceText = ""
    private var keys = Set<UInt16>()
    private var mouseButtons = Set<Int>()
    private var pendingFire = false
    private var shiftDown = false, controlDown = false, mouseCaptured = false
    private var yaw: Float = 0, pitch: Float = 0
    private var lastFrame = CACurrentMediaTime(), lastHUD: Double = 0, lastScroll: Double = 0
    private var frameCounter = 0, statsStart = CACurrentMediaTime()
    private let audio = NativeAudio()
    private var sheet: NSPanel?

    init(window: NSWindow) {
        self.window = window
        view = NativeGameView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), device: MTLCreateSystemDefaultDevice())
        hud = GameHUDView(frame: view.frame)
        super.init()
        window.delegate = self; window.acceptsMouseMovedEvents = true
        let root = NSView(frame: view.frame)
        root.wantsLayer = true; root.layer?.backgroundColor = NSColor.black.cgColor
        view.autoresizingMask = [.width, .height]; hud.autoresizingMask = [.width, .height]
        root.addSubview(view); root.addSubview(hud); window.contentView = root
        view.coordinator = self; hud.coordinator = self
        view.preferredFramesPerSecond = 30; view.delegate = self
        audio.setVolume(settings.volume)
        hud.refresh()
        DispatchQueue.main.async { [weak self] in self?.initializeGraphics() }
    }

    private func initializeGraphics() {
        do {
            renderer = try NativeRenderer(view: view, assetRoot: NativeResources.assetRoot)
            renderer?.setQuality(settings.highQuality)
            ready = true; lastFrame = CACurrentMediaTime(); hud.refresh()
        } catch {
            loadingMessage = "Die Grafik konnte nicht gestartet werden."
            view.isPaused = true; hud.refresh()
            let alert = NSAlert(); alert.alertStyle = .critical
            alert.messageText = "Blacksite konnte nicht starten"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Beenden")
            alert.beginSheetModal(for: window) { _ in NSApplication.shared.terminate(nil) }
        }
    }

    func draw(in view: MTKView) {
        guard ready, let renderer else { return }
        let now = CACurrentMediaTime(), delta = min(0.1, max(0, now - lastFrame)); lastFrame = now
        if mode == .playing {
            let aimFactor: Float = simulation.isAiming && simulation.activeWeapon == .sniper ? 0.3 : 1
            yaw += Float((keys.contains(123) ? 1 : 0) - (keys.contains(124) ? 1 : 0)) * Float(delta) * 1.65 * aimFactor
            pitch = max(-1.45, min(1.45, pitch + Float((keys.contains(116) ? 1 : 0) - (keys.contains(121) ? 1 : 0)) * Float(delta)))
            var input = GameInput()
            input.yaw = yaw; input.pitch = pitch
            input.moveForward = Float((keys.contains(13) || keys.contains(126) ? 1 : 0) - (keys.contains(1) || keys.contains(125) ? 1 : 0))
            input.moveRight = Float((keys.contains(2) ? 1 : 0) - (keys.contains(0) ? 1 : 0))
            input.sprint = shiftDown; input.fire = pendingFire || mouseButtons.contains(0) || keys.contains(12)
            input.aim = mouseButtons.contains(1) || keys.contains(6)
            let previousTime = simulation.elapsed
            simulation.step(deltaTime: delta, input: input)
            if simulation.elapsed > previousTime { pendingFire = false }
            let events = simulation.drainEvents()
            renderer.handle(events: events, simulation: simulation); audio.handle(events); process(events)
            audio.update(delta: Float(delta), simulation: simulation)
        }
        renderer.draw(in: view, simulation: simulation, mode: mode, deltaTime: mode == .paused || mode == .result ? 0 : Float(delta))
        audio.handleShellImpacts(renderer.drainShellImpacts(), simulation: simulation)
        frameCounter += 1
        if now - statsStart >= 1 {
            performanceText = "\(Int(Double(frameCounter) / (now - statsStart))) FPS  ·  \(renderer.deviceName)  ·  \(settings.highQuality ? "HOCH" : "AUSGEWOGEN")"
            frameCounter = 0; statsStart = now
        }
        if now - lastHUD >= 1.0 / 30 { hud.refresh(); lastHUD = now }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { hud.refresh() }

    func startMatch() {
        guard ready, window.attachedSheet == nil else { return }
        simulation = CombatSimulation(difficulty: settings.difficulty, seed: UInt64(Date().timeIntervalSince1970 * 1000))
        yaw = 0; pitch = 0; renderer?.reset()
        banner("VIPER 01 · VERBINDUNG STEHT", "EINSATZ BEGINNT", "Drei Wellen. Ein Ausgang. Bleib in Bewegung.", duration: 4)
        toastUntil = 0; hitUntil = 0; killUntil = 0; damageUntil = 0
        setMode(.playing)
    }

    func pause() { if mode == .playing { setMode(.paused) } }
    func resume() { if mode == .paused && window.attachedSheet == nil { setMode(.playing) } }
    func returnToMenu() {
        renderer?.reset(); simulation = CombatSimulation()
        bannerUntil = 0; toastUntil = 0; setMode(.menu)
    }

    private func setMode(_ next: NativeRenderMode) {
        mode = next; clearInput(); lastFrame = CACurrentMediaTime()
        if next == .playing {
            view.enableSetNeedsDisplay = false; view.isPaused = false
            view.preferredFramesPerSecond = settings.fps
            window.makeFirstResponder(view); captureMouse(); audio.setPaused(false)
        } else {
            releaseMouse(); audio.setPaused(true)
            view.preferredFramesPerSecond = next == .menu ? 30 : settings.fps
            view.isPaused = next != .menu
            view.enableSetNeedsDisplay = next != .menu
            view.setNeedsDisplay(view.bounds)
        }
        hud.refresh()
    }

    private func process(_ events: [GameEvent]) {
        let now = CACurrentMediaTime()
        for event in events {
            switch event.kind {
            case .shot:
                if event.amount > 0 { hitUntil = now + 0.14; lastHitHeadshot = event.headshot }
            case .damage: damageUntil = now + 0.4
            case .kill:
                killUntil = now + 1.6
                killText = "\(event.headshot ? "KOPFTREFFER" : "ZIEL AUSGESCHALTET")  +\(Int(event.amount)) XP"
            case .waveStarted: banner("FEINDLICHE VERSTÄRKUNG", String(format: "WELLE %02d", event.count), "\(Int(event.amount)) Kontakte im Einsatzgebiet")
            case .waveCleared:
                if event.count == 3 { banner("ALLE KONTAKTE NEUTRALISIERT", "ZUR EVAKUIERUNG", "Erreiche den grünen Ring am Nordtor.", duration: 6) }
                else { banner("SEKTOR VORERST GESICHERT", "DURCHATMEN.", "Nachschub erhalten · Nächste Welle in 7 Sekunden", duration: 4) }
            case .supply: toast("NACHSCHUB  +45 Sturmgewehr · +5 Scharfschützengewehr")
            case .coverDestroyed: toast("DECKUNG ZERSTÖRT  +25 XP", duration: 1.7)
            case .win, .lose: setMode(.result)
            default: break
            }
        }
    }

    private func banner(_ label: String, _ title: String, _ detail: String, duration: Double = 3) {
        bannerLabel = label; bannerTitle = title; bannerDetail = detail; bannerUntil = CACurrentMediaTime() + duration
    }
    private func toast(_ message: String, duration: Double = 2.5) { toastText = message; toastUntil = CACurrentMediaTime() + duration }

    func keyDown(_ event: NSEvent) {
        if event.modifierFlags.contains(.command) { return }
        if event.keyCode == 53 {
            guard !event.isARepeat else { return }
            if mode == .playing { pause() } else if mode == .paused { resume() }; return
        }
        if event.keyCode == 96 && !event.isARepeat { showPerformance.toggle(); hud.refresh(); return }
        guard mode == .playing else { return }
        keys.insert(event.keyCode)
        guard !event.isARepeat else { return }
        switch event.keyCode {
        case 12: pendingFire = true
        case 49: simulation.jump()
        case 8: simulation.toggleProne()
        case 14: simulation.mantle()
        case 5: simulation.throwGrenade()
        case 15: simulation.reload()
        case 18: simulation.selectWeapon(.rifle)
        case 19: simulation.selectWeapon(.sniper)
        default: break
        }
        hud.refresh()
    }
    func keyUp(_ event: NSEvent) { keys.remove(event.keyCode) }
    func flagsChanged(_ event: NSEvent) {
        let control = event.modifierFlags.contains(.control)
        if mode == .playing && control && !controlDown { simulation.toggleProne() }
        controlDown = control; shiftDown = event.modifierFlags.contains(.shift)
    }
    func mouseMoved(_ event: NSEvent) {
        guard mode == .playing, mouseCaptured else { return }
        let factor: Float = simulation.isAiming ? simulation.activeWeapon == .sniper ? 0.19 : 0.65 : 1
        yaw -= Float(event.deltaX) * settings.sensitivity * factor
        pitch = max(-1.45, min(1.45, pitch - Float(event.deltaY) * settings.sensitivity * factor))
    }
    func mouseButton(_ button: Int, down: Bool) {
        guard mode == .playing else { return }
        if down {
            mouseButtons.insert(button)
            if button == 0 { pendingFire = true }
            captureMouse()
        } else { mouseButtons.remove(button) }
    }
    func switchWeapon() {
        guard mode == .playing, CACurrentMediaTime() - lastScroll > 0.22 else { return }
        lastScroll = CACurrentMediaTime(); simulation.selectWeapon(simulation.activeWeapon == .rifle ? .sniper : .rifle)
    }
    private func clearInput() { keys.removeAll(keepingCapacity: true); mouseButtons.removeAll(keepingCapacity: true); pendingFire = false; shiftDown = false; controlDown = false }
    private func captureMouse() {
        guard !mouseCaptured, window.isKeyWindow else { return }
        let center = window.convertPoint(toScreen: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
        let desktopHeight = CGDisplayBounds(CGMainDisplayID()).height
        CGWarpMouseCursorPosition(CGPoint(x: center.x, y: desktopHeight - center.y))
        if CGAssociateMouseAndMouseCursorPosition(0) == .success { NSCursor.hide(); mouseCaptured = true }
    }
    func releaseMouse() {
        guard mouseCaptured else { return }
        CGAssociateMouseAndMouseCursorPosition(1); NSCursor.unhide(); mouseCaptured = false
    }

    func windowDidResignKey(_ notification: Notification) {
        pause(); clearInput(); releaseMouse(); audio.setPaused(true)
        view.isPaused = true
    }
    func windowDidBecomeKey(_ notification: Notification) {
        if mode == .menu { view.enableSetNeedsDisplay = false; view.isPaused = false; lastFrame = CACurrentMediaTime() }
    }
    func windowWillClose(_ notification: Notification) { releaseMouse(); audio.setPaused(true) }
    func shutdown() { releaseMouse(); audio.setPaused(true); view.isPaused = true }

    @objc func newMatchMenu(_ sender: Any?) { startMatch() }
    @objc func pauseMenu(_ sender: Any?) { mode == .paused ? resume() : pause() }
    @objc func settingsMenu(_ sender: Any?) { showSettings() }
    @objc func helpMenu(_ sender: Any?) { showHelp() }

    func showHelp() {
        guard window.attachedSheet == nil else { return }
        pause()
        let alert = NSAlert(); alert.messageText = "Dein Feldhandbuch"
        alert.informativeText = "W A S D – Bewegen     Maus – Umsehen\nShift – Sprinten     Leertaste – Springen\nC / Strg – Hinlegen oder aufstehen\nE – An einer Kante hochklettern\nLinksklick / Q – Schießen\nRechtsklick / Z halten – Zielen / 6× Zielfernrohr\n1 / 2 / Mausrad – Waffe wechseln\nR – Nachladen     G – Granate (2,8 s)\nEsc – Pause     F5 – Leistungsanzeige\n\nAR-4: 30 Schuss, automatisches Feuer.\nM82: 5 Schuss, sechsfaches Zielfernrohr.\nKopftreffer verursachen zusätzlichen Schaden.\n\nDeckung unterbricht die Sicht der Gegner. Kisten, Barrieren und Container sind zerstörbar; Fässer explodieren. Mit E erreichst du Containerdächer. Intakte Deckung schützt auch vor Granaten.\n\nGesundheit regeneriert nach 5,5 Sekunden ohne Treffer. Nach der dritten Welle: Den grünen Evakuierungsring am Nordtor drei Sekunden halten."
        alert.addButton(withTitle: "Verstanden"); alert.beginSheetModal(for: window)
    }

    func showSettings() {
        guard window.attachedSheet == nil else { return }
        pause()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 490, height: 390), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Blacksite – Einstellungen"; panel.appearance = NSAppearance(named: .darkAqua)
        let content = panel.contentView!
        func label(_ value: String, y: CGFloat) {
            let field = NSTextField(labelWithString: value); field.frame = NSRect(x: 28, y: y, width: 210, height: 23); field.font = .systemFont(ofSize: 13); content.addSubview(field)
        }
        label("Schwierigkeit", y: 329)
        let difficulty = NSPopUpButton(frame: NSRect(x: 255, y: 326, width: 205, height: 28)); difficulty.addItems(withTitles: ["Rekrut", "Operator", "Veteran"]); difficulty.selectItem(at: settings.difficulty == .easy ? 0 : settings.difficulty == .hard ? 2 : 1); content.addSubview(difficulty)
        let note = NSTextField(labelWithString: "Schwierigkeit gilt ab dem nächsten Einsatz."); note.frame = NSRect(x: 28, y: 300, width: 420, height: 20); note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor; content.addSubview(note)
        label("Grafikqualität", y: 256)
        let quality = NSPopUpButton(frame: NSRect(x: 255, y: 253, width: 205, height: 28)); quality.addItems(withTitles: ["Ausgewogen", "Hoch"]); quality.selectItem(at: settings.highQuality ? 1 : 0); content.addSubview(quality)
        label("Bildratenlimit", y: 207)
        let frameRate = NSPopUpButton(frame: NSRect(x: 255, y: 204, width: 205, height: 28)); frameRate.addItems(withTitles: ["60 FPS – sparsam", "120 FPS – flüssig"]); frameRate.selectItem(at: settings.fps == 120 ? 1 : 0); content.addSubview(frameRate)
        label("Mausempfindlichkeit", y: 158)
        let sensitivity = NSSlider(value: Double(settings.sensitivity), minValue: 0.0006, maxValue: 0.006, target: nil, action: nil); sensitivity.frame = NSRect(x: 255, y: 154, width: 205, height: 28); sensitivity.setAccessibilityLabel("Mausempfindlichkeit"); content.addSubview(sensitivity)
        label("Lautstärke", y: 109)
        let volume = NSSlider(value: Double(settings.volume), minValue: 0, maxValue: 1, target: nil, action: nil); volume.frame = NSRect(x: 255, y: 105, width: 205, height: 28); volume.setAccessibilityLabel("Lautstärke"); content.addSubview(volume)
        let done = NativeButton("EINSTELLUNGEN SPEICHERN", primary: true) { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.settings.difficulty = [Difficulty.easy, .normal, .hard][difficulty.indexOfSelectedItem]
            self.settings.highQuality = quality.indexOfSelectedItem == 1
            self.settings.fps = frameRate.indexOfSelectedItem == 1 ? 120 : 60
            self.settings.volume = Float(volume.doubleValue); self.settings.sensitivity = Float(sensitivity.doubleValue)
            self.settings.save(); self.renderer?.setQuality(self.settings.highQuality); self.audio.setVolume(self.settings.volume)
            self.window.endSheet(panel); self.sheet = nil; self.hud.refresh(); self.view.setNeedsDisplay(self.view.bounds)
        }
        done.frame = NSRect(x: 28, y: 28, width: 432, height: 46); content.addSubview(done)
        sheet = panel; window.beginSheet(panel)
    }
}
