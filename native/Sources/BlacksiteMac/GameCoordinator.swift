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
    private(set) var selectedMap = MapDefinition.blacksite
    var isAimPresented: Bool { simulation.isAiming && !(renderer?.weaponAimObstructed ?? false) }
    var mode: NativeRenderMode = .menu
    var settings = NativeSettings()
    var ready = false
    var loadingMessage = "Metal-Einsatzgebiet wird vorbereitet …"
    var bannerLabel = "", bannerTitle = "", bannerDetail = "", toastText = "", killText = ""
    var bannerUntil: Double = 0, toastUntil: Double = 0, hitUntil: Double = 0, killUntil: Double = 0, damageUntil: Double = 0
    var lastHitHeadshot = false
    var combatFeedback = CombatFeedback()
    var showPerformance = false
    var performanceText = ""
    private var inputState = NativeInputState()
    private var modifierBridge = NativeModifierBridge()
    private var mouseCaptured = false
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
        inputState.reconfigure(bindings: settings.bindings, aimMode: settings.aimMode, sprintMode: settings.sprintMode)
        window.delegate = self; window.acceptsMouseMovedEvents = true
        let root = NSView(frame: view.frame)
        root.wantsLayer = true; root.layer?.backgroundColor = NSColor.black.cgColor
        view.autoresizingMask = [.width, .height]; hud.autoresizingMask = [.width, .height]
        root.addSubview(view); root.addSubview(hud); window.contentView = root
        view.coordinator = self; hud.coordinator = self
        view.preferredFramesPerSecond = 30; view.delegate = self
        audio.setVolumes(music: settings.musicVolume, effects: settings.effectsVolume)
        hud.refresh()
        DispatchQueue.main.async { [weak self] in self?.initializeGraphics() }
    }

    private func initializeGraphics() {
        do {
            renderer = try NativeRenderer(view: view, assetRoot: NativeResources.assetRoot, highQuality: settings.highQuality, map: selectedMap)
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
            let controls = inputState.snapshot()
            let aimFactor: Float = isAimPresented && simulation.activeWeapon == .sniper ? 0.3 : 1
            yaw += controls.yawAxis * Float(delta) * 1.65 * aimFactor
            pitch = max(-1.45, min(1.45, pitch + controls.pitchAxis * Float(delta)))
            var input = GameInput()
            input.yaw = yaw; input.pitch = pitch
            input.moveForward = controls.moveForward; input.moveRight = controls.moveRight
            input.sprint = controls.sprint; input.fire = controls.fire
            input.aim = controls.aim; input.interact = controls.interact
            let previousTime = simulation.elapsed
            simulation.step(deltaTime: delta, input: input)
            if simulation.elapsed > previousTime { inputState.didAdvanceSimulation() }
            let events = simulation.drainEvents()
            renderer.handle(events: events, simulation: simulation); audio.handle(events, simulation: simulation); process(events)
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
        guard prepareMap(selectedMap) else { return }
        simulation = CombatSimulation(map: selectedMap, difficulty: settings.difficulty, seed: UInt64(Date().timeIntervalSince1970 * 1000), mission: settings.selectedMission)
        yaw = simulation.player.yaw; pitch = simulation.player.pitch
        renderer?.reset(); combatFeedback.reset()
        bannerUntil = 0
        if settings.selectedMission == .waves {
            banner("VIPER 01 · VERBINDUNG STEHT", "EINSATZ BEGINNT", "Drei Wellen. Ein Ausgang. Bleib in Bewegung.", duration: 4)
        }
        toastUntil = 0; hitUntil = 0; killUntil = 0; damageUntil = 0
        setMode(.playing)
    }

    func selectMission(_ mission: MissionKind) {
        guard mode == .menu, window.attachedSheet == nil else { return }
        settings.selectedMission = mission; settings.save(); hud.refresh()
    }

    /// Prepare resources before replacing the live scene. A failed load keeps
    /// the previous map and its simulation available in the menu.
    func selectMap(_ map: MapDefinition) {
        guard ready, mode == .menu, window.attachedSheet == nil, prepareMap(map) else { return }
        selectedMap = map
        simulation = CombatSimulation(map: map)
        renderer?.reset(); combatFeedback.reset()
        bannerUntil = 0; toastUntil = 0
        clearInput(); hud.refresh()
    }

    private func prepareMap(_ map: MapDefinition) -> Bool {
        do {
            try renderer?.setMap(map)
            return true
        } catch {
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = "Einsatzgebiet konnte nicht geladen werden"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window)
            return false
        }
    }

    func pause() { if mode == .playing { setMode(.paused) } }
    func resume() { if mode == .paused && window.attachedSheet == nil { setMode(.playing) } }
    func returnToMenu() {
        renderer?.reset(); simulation = CombatSimulation(map: selectedMap); combatFeedback.reset()
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
        var arrivalSectors = Set<Int>(), arrivals = 0
        for event in events {
            switch event.kind {
            case .shot:
                if event.amount > 0 { hitUntil = now + 0.14; lastHitHeadshot = event.headshot }
            case .damage:
                damageUntil = now + 0.4
                combatFeedback.record(event, time: simulation.elapsed)
            case .kill:
                killUntil = now + 1.6
                killText = "\(event.headshot ? "KOPFTREFFER" : "ZIEL AUSGESCHALTET")  +\(Int(event.amount)) XP"
            case .waveStarted: banner("FEINDLICHE VERSTÄRKUNG", String(format: "WELLE %02d", event.count), "\(Int(event.amount)) Kontakte angekündigt")
            case .reinforcementsArrived:
                let offset = event.position - event.endPosition
                let angle = atan2(offset.x, -offset.z)
                let sector = (Int((angle / (.pi / 4)).rounded()) + 8) % 8
                arrivalSectors.insert(sector); arrivals += 1
            case .waveCleared:
                banner("SEKTOR VORERST GESICHERT", "DURCHATMEN.", "Nachschub erhalten · Nächste Welle in 7 Sekunden", duration: 4)
            case .extractionUnlocked:
                banner("ALLE KONTAKTE NEUTRALISIERT", "ZUR EVAKUIERUNG", "Erreiche den grünen Ring am Nordtor.", duration: 6)
            case .missionPhaseChanged:
                if let phase = event.missionPhase, let notice = NativeMissionPresentation.banner(for: phase, interactionLabel: NativeControlLabels.label(for: .interact, bindings: settings.bindings)) {
                    banner(notice.label, notice.title, notice.detail, duration: 4)
                }
            case .supply: toast("NACHSCHUB  +45 Sturmgewehr · +5 Scharfschützengewehr")
            case .coverDestroyed: toast("DECKUNG ZERSTÖRT  +25 XP", duration: 1.7)
            case .win, .lose: setMode(.result)
            default: break
            }
        }
        if arrivals > 0 {
            let names = ["NORD", "NORDOST", "OST", "SÜDOST", "SÜD", "SÜDWEST", "WEST", "NORDWEST"]
            let directions = arrivalSectors.sorted().map { names[$0] }.joined(separator: " / ")
            toast("\(arrivals) NEUE KONTAKTE · \(directions)", duration: 3.5)
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
        performInputActions(inputState.press(.key(event.keyCode), isRepeat: event.isARepeat))
    }
    func keyUp(_ event: NSEvent) { inputState.release(.key(event.keyCode)) }
    func flagsChanged(_ event: NSEvent) {
        guard mode == .playing else { return }
        if event.modifierFlags.contains(.command) { clearInput(); return }
        guard let (button, down) = modifierBridge.change(keyCode: event.keyCode, flags: event.modifierFlags) else { return }
        if down { performInputActions(inputState.press(button)) } else { inputState.release(button) }
    }
    func mouseMoved(_ event: NSEvent) {
        guard mode == .playing, mouseCaptured else { return }
        let delta = settings.mouseLookDelta(dx: Float(event.deltaX), dy: Float(event.deltaY), aiming: isAimPresented, weapon: simulation.activeWeapon)
        yaw += delta.x; pitch = max(-1.45, min(1.45, pitch + delta.y))
    }
    func mouseButton(_ button: Int, down: Bool) {
        guard mode == .playing else { return }
        if down {
            performInputActions(inputState.press(.mouse(button)))
            captureMouse()
        } else { inputState.release(.mouse(button)) }
    }
    func scrollInput(_ direction: NativeWheelDirection) {
        guard mode == .playing else { return }
        performInputActions(inputState.pulse(direction))
    }
    private func performInputActions(_ actions: [NativeInputAction]) {
        for action in actions {
            switch action {
            case .jump: simulation.jump()
            case .prone: simulation.toggleProne()
            case .interact: if !simulation.missionInteractionAvailable { simulation.mantle() }
            case .grenade: simulation.throwGrenade()
            case .reload: simulation.reload()
            case .rifle: simulation.selectWeapon(.rifle)
            case .sniper: simulation.selectWeapon(.sniper)
            case .nextWeapon: switchWeapon()
            default: break
            }
        }
        if !actions.isEmpty { hud.refresh() }
    }
    func switchWeapon() {
        guard mode == .playing, CACurrentMediaTime() - lastScroll > 0.22 else { return }
        lastScroll = CACurrentMediaTime(); simulation.selectWeapon(simulation.activeWeapon == .rifle ? .sniper : .rifle)
    }
    private func clearInput() {
        inputState.clear(); modifierBridge.synchronize(flags: NSEvent.modifierFlags)
    }
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
    func windowWillClose(_ notification: Notification) { clearInput(); releaseMouse(); audio.setPaused(true) }
    func shutdown() { clearInput(); releaseMouse(); audio.setPaused(true); view.isPaused = true }

    @objc func newMatchMenu(_ sender: Any?) { startMatch() }
    @objc func pauseMenu(_ sender: Any?) { mode == .paused ? resume() : pause() }
    @objc func settingsMenu(_ sender: Any?) { showSettings() }
    @objc func helpMenu(_ sender: Any?) { showHelp() }

    func showHelp() {
        guard window.attachedSheet == nil else { return }
        pause(); clearInput()
        let mission = mode == .menu ? settings.selectedMission : simulation.missionKind
        let interact = NativeControlLabels.label(for: .interact, bindings: settings.bindings)
        let alert = NSAlert(); alert.messageText = "Dein Feldhandbuch"
        alert.informativeText = NativeControlLabels.help(settings: settings) + "\n\nAuftrag: \(NativeMissionPresentation.name(mission))\n" +
            NativeMissionPresentation.rules(mission, interactionLabel: interact) +
            "\n\nAR-4: 30 Schuss, automatisch. M82: 5 Schuss, 6× Zielfernrohr.\nKopftreffer verursachen zusätzlichen Schaden. Granaten: 2,8 s Zündzeit.\nDeckung schützt vor Sicht, Beschuss und Granaten. Fässer explodieren.\nAn einer Kante hebt Interagieren dich auf Containerdächer.\nGesundheit regeneriert nach 5,5 Sekunden ohne Treffer."
        alert.addButton(withTitle: "Verstanden"); alert.beginSheetModal(for: window)
    }

    func showSettings() {
        guard window.attachedSheet == nil else { return }
        pause(); clearInput()
        let panel = NativeSettingsPanel(settings: settings)
        panel.settingsView.onCancel = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.clearInput(); self.window.endSheet(panel); self.sheet = nil
        }
        panel.settingsView.onSave = { [weak self, weak panel] draft in
            guard let self, let panel else { return }
            do {
                try self.renderer?.setQuality(draft.highQuality)
            } catch {
                let alert = NSAlert(); alert.alertStyle = .warning
                alert.messageText = "Grafikqualität konnte nicht gewechselt werden"
                alert.informativeText = "Die bisherigen Einstellungen bleiben erhalten. Dein Entwurf bleibt geöffnet.\n\n" + error.localizedDescription
                alert.addButton(withTitle: "OK"); alert.beginSheetModal(for: panel)
                return
            }
            self.settings = draft; self.settings.save()
            self.inputState.reconfigure(bindings: draft.bindings, aimMode: draft.aimMode, sprintMode: draft.sprintMode)
            self.clearInput()
            self.audio.setVolumes(music: draft.musicVolume, effects: draft.effectsVolume)
            self.window.endSheet(panel); self.sheet = nil
            self.hud.refresh(); self.view.setNeedsDisplay(self.view.bounds)
        }
        sheet = panel; window.beginSheet(panel)
    }
}
