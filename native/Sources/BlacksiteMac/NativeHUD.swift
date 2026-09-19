import AppKit
import QuartzCore
import BlacksiteCore
import simd

extension NSColor {
    convenience init(hex: Int, alpha: CGFloat = 1) {
        self.init(calibratedRed: CGFloat((hex >> 16) & 255) / 255,
                  green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
}

private let ink = NSColor(hex: 0xeff0dd)
private let muted = NSColor(hex: 0xaebca7)
private let accent = NSColor(hex: 0xf58046)

final class NativeButton: NSButton {
    var primary = false
    var actionHandler: (() -> Void)?
    init(_ title: String, primary: Bool = false, action: @escaping () -> Void) {
        super.init(frame: .zero)
        self.title = title; self.primary = primary; actionHandler = action
        isBordered = false; target = self; self.action = #selector(invoke)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { actionHandler?() }
    override func draw(_ dirtyRect: NSRect) {
        let fill = primary ? accent : NSColor(hex: 0x14231c, alpha: 0.82)
        fill.withAlphaComponent(isHighlighted ? 0.65 : 1).setFill()
        NSBezierPath(rect: bounds).fill()
        if !primary { NSColor(hex: 0x85977b, alpha: 0.35).setStroke(); NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke() }
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: primary ? NSColor(hex: 0x122018) : ink, .kern: 1.1]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: 18, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        if primary { ("↗" as NSString).draw(at: NSPoint(x: bounds.width - 35, y: (bounds.height - 26) / 2), withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor(hex: 0x122018)]) }
        if window?.firstResponder === self {
            ink.withAlphaComponent(0.8).setStroke(); let outline = NSBezierPath(rect: bounds.insetBy(dx: 3, dy: 3)); outline.lineWidth = 1; outline.stroke()
        }
    }
}

final class GameHUDView: NSView {
    weak var coordinator: GameCoordinator?
    private var startButton: NativeButton!
    private var settingsButton: NativeButton!
    private var helpButton: NativeButton!
    private var resumeButton: NativeButton!
    private var leaveButton: NativeButton!
    private var retryButton: NativeButton!
    private var pauseButton: NativeButton!
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.backgroundColor = NSColor.clear.cgColor
        startButton = NativeButton("EINSATZ STARTEN", primary: true) { [weak self] in self?.coordinator?.startMatch() }
        settingsButton = NativeButton("EINSTELLUNGEN") { [weak self] in self?.coordinator?.showSettings() }
        helpButton = NativeButton("STEUERUNG / ARSENAL") { [weak self] in self?.coordinator?.showHelp() }
        resumeButton = NativeButton("FORTSETZEN", primary: true) { [weak self] in self?.coordinator?.resume() }
        leaveButton = NativeButton("ZURÜCK ZUM HAUPTMENÜ") { [weak self] in self?.coordinator?.returnToMenu() }
        retryButton = NativeButton("ERNEUT ANTRETEN", primary: true) { [weak self] in self?.coordinator?.startMatch() }
        pauseButton = NativeButton("Ⅱ  ESC") { [weak self] in self?.coordinator?.pause() }
        for button in [startButton, settingsButton, helpButton, resumeButton, leaveButton, retryButton, pauseButton] { addSubview(button!) }
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Blacksite Spieloberfläche")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() {
        needsLayout = true; needsDisplay = true
        if let c = coordinator {
            let s = c.simulation
            let phase = c.mode == .menu ? "Hauptmenü" : c.mode == .paused ? "Pausiert" : c.mode == .result ? (s.state == .won ? "Mission erfüllt" : "Einsatz gescheitert") : "Einsatz läuft"
            let damage = c.combatFeedback.activeDamage(at: s.elapsed).map {
                "Beschuss \(ThreatBearing(source: $0.position, listener: s.eyePosition, yaw: s.player.yaw).label)"
            }
            let grenades = CombatFeedback.nearbyGrenades(s).map {
                "Granate \(ThreatBearing(source: $0.position, listener: s.eyePosition, yaw: s.player.yaw).label), \(String(format: "%.1f", $0.fuse)) Sekunden"
            }
            setAccessibilityValue("\(phase). Gesundheit \(Int(s.player.health)). Welle \(s.wave). \(s.aliveCount) Gegner im Gebiet, \(s.pendingReinforcements) Verstärkungen im Anmarsch. \(s.activeWeapon.displayName), \(s.weapons[s.activeWeapon]?.ammo ?? 0) Schuss. \(s.grenadeCount) Granaten. \(s.player.prone ? "Liegend" : "Stehend"). \(awarenessText(s)). \((damage + grenades).joined(separator: ". "))")
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for button in subviews where !button.isHidden {
            if button.frame.contains(local) { return button }
        }
        return nil
    }

    override func layout() {
        super.layout()
        layoutButtons(mode: coordinator?.mode ?? .menu, ready: coordinator?.ready == true)
    }

    // AppKit tracks a real mouse click from mouse-down until mouse-up. Hiding a
    // pressed button during an HUD refresh interrupts that tracking; AXPress
    // does not exercise this path. Keep each control stable between mode changes.
    func layoutButtons(mode: NativeRenderMode, ready: Bool) {
        let w = bounds.width, h = bounds.height, x = w * 0.07
        func update(_ button: NativeButton, visible: Bool, frame: NSRect? = nil) {
            let hidden = !ready || !visible
            if button.isHidden != hidden { button.isHidden = hidden }
            if let frame, button.frame != frame { button.frame = frame }
        }
        update(startButton, visible: mode == .menu,
               frame: NSRect(x: x, y: h * 0.70, width: 325, height: 54))
        update(helpButton, visible: mode == .menu,
               frame: NSRect(x: x, y: h * 0.70 + 68, width: 325, height: 40))
        update(pauseButton, visible: mode == .playing,
               frame: NSRect(x: w - 116, y: 144, width: 82, height: 31))
        update(resumeButton, visible: mode == .paused,
               frame: NSRect(x: w / 2 - 175, y: h / 2 + 38, width: 350, height: 52))
        update(retryButton, visible: mode == .result,
               frame: NSRect(x: w / 2 - 175, y: h / 2 + 94, width: 350, height: 52))
        update(settingsButton, visible: mode == .menu || mode == .paused,
               frame: mode == .paused
                   ? NSRect(x: w / 2 - 175, y: h / 2 + 104, width: 350, height: 43)
                   : NSRect(x: w - 235, y: 42, width: 190, height: 36))
        update(leaveButton, visible: mode == .paused || mode == .result,
               frame: NSRect(x: w / 2 - 175, y: h / 2 + 161, width: 350, height: 43))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); bounds.fill(using: .copy)
        guard let c = coordinator else { return }
        if !c.ready {
            NSColor(hex: 0x101d17).setFill(); bounds.fill()
            text("N / G", x: bounds.midX - 58, y: bounds.midY - 55, size: 39, weight: .heavy)
            text(c.loadingMessage, x: bounds.midX - 230, y: bounds.midY + 18, size: 12, color: muted, width: 460, alignment: .center)
            return
        }
        if c.mode == .menu { drawMenu(c); return }
        drawHUD(c)
        if c.mode == .paused || c.mode == .result { drawOverlay(c) }
    }

    private func drawMenu(_ c: GameCoordinator) {
        let w = bounds.width, h = bounds.height, x = w * 0.07
        NSGradient(starting: NSColor(hex: 0x091710, alpha: 0.96), ending: NSColor(hex: 0x071811, alpha: 0.10))?.draw(in: bounds, angle: 0)
        text("N / G", x: 44, y: 45, size: 23, weight: .heavy)
        text("NACHTGANG", x: 128, y: 43, size: 17, weight: .bold, tracking: 3)
        text("NATIVE TACTICAL OPERATIONS", x: 130, y: 68, size: 8, color: muted, tracking: 2, mono: true)
        let heroY = h * 0.19, titleSize = min(118, h * 0.151)
        fill(NSRect(x: x, y: heroY + 5, width: 23, height: 2), accent)
        text("OPERATION 001  //  KLASSIFIZIERT", x: x + 38, y: heroY, size: 9, color: muted, tracking: 2, mono: true)
        let font = NSFont(name: "AvenirNextCondensed-Heavy", size: titleSize) ?? .systemFont(ofSize: titleSize, weight: .black)
        text("BLACK", x: x - 4, y: heroY + 20, size: titleSize, font: font)
        text("SITE", x: x - 4, y: heroY + 20 + titleSize * 0.84, size: titleSize, font: font)
        fill(NSRect(x: x + titleSize * 1.75, y: heroY + titleSize * 1.69, width: titleSize * 0.13, height: titleSize * 0.13), accent)
        text("Kein Kontakt. Keine Verstärkung.\nNur du und dein Auftrag.", x: x, y: h * 0.505, size: 16, width: 400)
        text("Infiltriere den Außenposten. Überstehe drei Angriffswellen\nund erreiche die Evakuierung am Nordtor.", x: x, y: h * 0.603, size: 12, color: muted, width: 425)
        if w >= 1050 {
            let rect = NSRect(x: w - 336, y: h - 315, width: 276, height: 208)
            fill(rect, NSColor(hex: 0x101f18, alpha: 0.83)); stroke(rect, NSColor(hex: 0xc5d0b4, alpha: 0.25))
            text("●  EINSATZGEBIET", x: rect.minX + 22, y: rect.minY + 22, size: 9, color: accent, tracking: 1.6, mono: true)
            text("Der Außenposten", x: rect.minX + 22, y: rect.minY + 49, size: 23, weight: .semibold)
            text("SEKTOR 07  ·  06:42 LOKALZEIT", x: rect.minX + 22, y: rect.minY + 82, size: 9, color: muted, mono: true)
            line(x1: rect.minX + 22, y1: rect.minY + 112, x2: rect.maxX - 22, y2: rect.minY + 112, color: muted.withAlphaComponent(0.3))
            text("FEINDKONTAKT", x: rect.minX + 22, y: rect.minY + 135, size: 9, color: muted, mono: true)
            text("Bestätigt", x: rect.minX + 178, y: rect.minY + 135, size: 11, color: accent)
            text("EINSATZPROFIL", x: rect.minX + 22, y: rect.minY + 164, size: 9, color: muted, mono: true)
            text(c.settings.difficulty == .easy ? "Rekrut" : c.settings.difficulty == .hard ? "Veteran" : "Operator", x: rect.minX + 178, y: rect.minY + 163, size: 11)
        }
        line(x1: 42, y1: h - 56, x2: w - 42, y2: h - 56, color: muted.withAlphaComponent(0.25))
        text("●  NATIVES METAL  /  OFFLINE SPIELBAR", x: 43, y: h - 37, size: 8, color: muted, tracking: 1, mono: true)
        text(c.renderer?.deviceName ?? "Metal", x: w - 320, y: h - 37, size: 8, color: muted, width: 275, alignment: .right, mono: true)
    }

    private func awarenessText(_ simulation: CombatSimulation) -> String {
        var detection: Float = 0, investigating = false, searching = false
        for enemy in simulation.enemies where enemy.health > 0 {
            if enemy.seesPlayer { return "ENTDECKT · DECKUNG SUCHEN" }
            detection = max(detection, enemy.detectionProgress)
            investigating = investigating || enemy.awareness == .investigating
            searching = searching || enemy.awareness == .searching
        }
        if detection > 0 { return "VERDACHT · \(Int(detection * 100)) %" }
        if investigating { return "FEINDE PRÜFEN EIN GERÄUSCH" }
        if searching { return "KEIN SICHTKONTAKT · FEINDE SUCHEN" }
        return simulation.isHidden ? "VERSTECKT · WACHEN PATROUILLIEREN" : "SEKTOR BEOBACHTEN"
    }

    private func drawHUD(_ c: GameCoordinator) {
        let s = c.simulation, p = s.player, w = bounds.width, h = bounds.height, now = CACurrentMediaTime()
        let scoped = s.isAiming && s.activeWeapon == .sniper && c.mode == .playing
        if scoped { drawScope() }
        NSGradient(starting: NSColor.black.withAlphaComponent(0.65), ending: .clear)?.draw(in: NSRect(x: 0, y: 0, width: w, height: 160), angle: 90)
        let shadow: [NSColor] = [NSColor.black.withAlphaComponent(0), NSColor.black.withAlphaComponent(0.58)]
        NSGradient(colors: shadow)?.draw(in: NSRect(x: 0, y: h - 195, width: w, height: 195), angle: 90)
        text("OPERATION BLACKSITE", x: 32, y: 42, size: 9, color: accent, tracking: 1.8, mono: true)
        text(s.extractionReady ? "Erreiche die Evakuierung am Nordtor" : "Überstehe die Angriffswellen", x: 32, y: 64, size: 14, weight: .medium)
        let detail: String
        if s.extractionReady {
            detail = s.extractionProgress > 0 ? String(format: "Evakuierung in %.1f s", 3 - s.extractionProgress) : "\(Int(simd_distance(p.position, GameMap.extraction))) m bis zum Evakuierungspunkt"
        } else if s.pendingReinforcements > 0 {
            detail = "\(s.pendingReinforcements) Verstärkungen im Anmarsch"
        } else { detail = s.intermission > 0 ? "Verstärkung in \(Int(ceil(s.intermission))) s" : "\(s.kills) Abschüsse  ·  \(timeString(s.elapsed))" }
        text("●  " + detail, x: 32, y: 90, size: 10, color: muted, mono: true)
        text("ANGRIFFSWELLE", x: w - 210, y: 42, size: 8, color: muted, tracking: 2, width: 175, alignment: .right, mono: true)
        text(String(format: "%02d", max(1, s.wave)) + " / 03", x: w - 200, y: 61, size: 30, width: 165, alignment: .right, mono: true)
        text("\(s.remainingEnemies) FEINDE  ·  \(s.score) XP", x: w - 225, y: 109, size: 10, width: 190, alignment: .right, mono: true)
        if !scoped {
            let heading = Int(((-p.yaw * 180 / .pi).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360))
            let names = ["N", "NO", "O", "SO", "S", "SW", "W", "NW"], index = (Int(Float(heading) / 45 + 0.5)) % 8
            text("\(names[(index + 7) % 8])    ·    \(names[index])    ·    \(names[(index + 1) % 8])", x: w / 2 - 135, y: 38, size: 11, width: 270, alignment: .center, mono: true)
            line(x1: w / 2 - 125, y1: 60, x2: w / 2 + 125, y2: 60, color: muted.withAlphaComponent(0.45))
            text(String(format: "%03d°", heading), x: w / 2 - 50, y: 67, size: 10, color: accent, width: 100, alignment: .center, mono: true)
            if s.climbProgress == nil { drawCrosshair(aiming: s.isAiming) }
        }
        if now < c.hitUntil {
            let color = c.lastHitHeadshot ? accent : ink
            for sx: CGFloat in [-1, 1] { for sy: CGFloat in [-1, 1] { line(x1: w / 2 + sx * 5, y1: h / 2 + sy * 5, x2: w / 2 + sx * 11, y2: h / 2 + sy * 11, color: color, thickness: 2) } }
        }
        if now < c.killUntil { text(c.killText, x: w / 2 - 190, y: h / 2 + 38, size: 10, color: accent, tracking: 1, width: 380, alignment: .center, mono: true) }
        if now < c.bannerUntil {
            text(c.bannerLabel, x: w / 2 - 280, y: h * 0.215, size: 9, color: accent, tracking: 2, width: 560, alignment: .center, mono: true)
            text(c.bannerTitle, x: w / 2 - 300, y: h * 0.215 + 23, size: 29, weight: .bold, tracking: 2, width: 600, alignment: .center)
            text(c.bannerDetail, x: w / 2 - 280, y: h * 0.215 + 66, size: 11, color: muted, width: 560, alignment: .center)
        }
        let hx: CGFloat = 32, hy = h - 151, barWidth: CGFloat = 206
        text("✚  VIPER 01", x: hx, y: hy, size: 12, weight: .medium, tracking: 1)
        let stance = s.climbProgress != nil ? "KLETTERT" : p.prone ? "LIEGEND" : !p.grounded ? "IN DER LUFT" : s.isSprinting ? "SPRINT" : "STEHEND"
        text(stance, x: hx + 95, y: hy + 3, size: 8, color: muted, width: 110, alignment: .right, mono: true)
        text("GESUNDHEIT", x: hx, y: hy + 37, size: 8, color: muted, tracking: 1, mono: true)
        text("\(Int(ceil(p.health))) / 100", x: hx + 62, y: hy + 28, size: 20, width: 144, alignment: .right, mono: true)
        fill(NSRect(x: hx, y: hy + 60, width: barWidth, height: 7), NSColor(hex: 0x44211f))
        fill(NSRect(x: hx, y: hy + 60, width: barWidth * CGFloat(max(0, p.health) / 100), height: 7), NSColor(hex: 0xe95449))
        fill(NSRect(x: hx, y: hy + 74, width: barWidth, height: 2), muted.withAlphaComponent(0.15))
        fill(NSRect(x: hx, y: hy + 74, width: barWidth * CGFloat(p.stamina / 100), height: 2), muted)
        text("●  " + awarenessText(s), x: hx, y: hy + 87, size: 8, color: s.isHidden ? NSColor(hex: 0xa5e4b5) : muted, mono: true)
        let weapon = s.weapons[s.activeWeapon]!, ax = w - 273, aw: CGFloat = 240
        text(s.activeWeapon == .sniper ? "SCHARFSCHÜTZENGEWEHR" : "STURMGEWEHR", x: ax, y: hy - 10, size: 8, color: muted, tracking: 1.5, width: aw, alignment: .right, mono: true)
        text(s.activeWeapon.displayName, x: ax, y: hy + 7, size: 13, weight: .semibold, tracking: 1.6, width: aw, alignment: .right)
        text(String(format: "%02d", weapon.ammo), x: ax + 32, y: hy + 28, size: 48, weight: .heavy, color: weapon.ammo < 3 ? accent : ink, width: 115, alignment: .right, mono: true)
        text("/ \(weapon.reserve)", x: ax + 160, y: hy + 60, size: 18, color: muted, width: 80, alignment: .right, mono: true)
        line(x1: ax, y1: hy + 91, x2: ax + aw, y2: hy + 91, color: muted.withAlphaComponent(0.4))
        text("R NACHLADEN    ◈ \(s.grenadeCount)", x: ax, y: hy + 105, size: 9, width: aw, alignment: .right, mono: true)
        if weapon.reloadRemaining > 0 {
            text("NACHLADEN", x: ax, y: hy - 40, size: 9, color: accent, width: aw, alignment: .right, mono: true)
            fill(NSRect(x: ax, y: hy - 23, width: aw * CGFloat(1 - weapon.reloadRemaining / s.activeWeapon.reloadDuration), height: 2), accent)
        }
        if s.mantleAvailable && s.climbProgress == nil && !scoped {
            panelText("E  HOCHKLETTERN", detail: "Kante greifen · Position wechseln", y: h * 0.65)
        } else if let progress = s.climbProgress {
            panelText("KANTE GREIFEN", detail: "", y: h * 0.65)
            fill(NSRect(x: w / 2 - 125, y: h * 0.65 + 41, width: 250 * CGFloat(progress), height: 2), accent)
        }
        drawThreats(c)
        if !scoped && w > 1000 { text("G  Granate     C  Hinlegen     LEER  Springen     1 / 2  Waffen", x: w / 2 - 290, y: h - 31, size: 9, color: muted, width: 580, alignment: .center, mono: true) }
        if now < c.toastUntil { panelText(c.toastText, detail: "", y: h - 228) }
        if c.showPerformance { text(c.performanceText, x: w / 2 - 200, y: h - 54, size: 9, color: muted, width: 400, alignment: .center, mono: true) }
        if p.health < 35 || now < c.damageUntil {
            let strength = max(now < c.damageUntil ? 0.65 : 0, Double(35 - p.health) / 65)
            let red = NSColor(hex: 0x9b151b, alpha: min(0.7, strength))
            NSGradient(starting: red, ending: .clear)?.draw(in: NSRect(x: 0, y: 0, width: 95, height: h), angle: 0)
            NSGradient(starting: .clear, ending: red)?.draw(in: NSRect(x: w - 95, y: 0, width: 95, height: h), angle: 0)
        }
    }

    private func drawThreats(_ c: GameCoordinator) {
        let s = c.simulation
        let cues = c.combatFeedback.activeDamage(at: s.elapsed)
        for cue in cues {
            let bearing = ThreatBearing(source: cue.position, listener: s.eyePosition, yaw: s.player.yaw)
            threatArrow(bearing.direction, radius: 91, color: NSColor(hex: 0xf26357), label: nil)
        }
        if let cue = cues.last {
            let bearing = ThreatBearing(source: cue.position, listener: s.eyePosition, yaw: s.player.yaw)
            threatText("BESCHUSS · " + bearing.label, y: bounds.midY - 139, color: ink)
        }
        for (index, grenade) in CombatFeedback.nearbyGrenades(s).enumerated() {
            let bearing = ThreatBearing(source: grenade.position, listener: s.eyePosition, yaw: s.player.yaw)
            // Distinct numbered symbols keep overlapping grenade directions identifiable.
            threatArrow(bearing.direction, radius: CGFloat(125 + index * 19), color: accent, label: "\(index + 1)")
            threatText(String(format: "◈ %d · %@ · %.1f s", index + 1, bearing.label, grenade.fuse),
                       y: bounds.height * 0.75 + CGFloat(index * 21), color: ink)
        }
    }

    private func threatArrow(_ direction: SIMD2<Float>, radius: CGFloat, color: NSColor, label: String?) {
        guard simd_length_squared(direction) > 0.01 else { return }
        let d = NSPoint(x: CGFloat(direction.x), y: CGFloat(direction.y))
        let tip = NSPoint(x: bounds.midX + d.x * radius, y: bounds.midY + d.y * radius)
        let path = NSBezierPath()
        path.move(to: tip)
        path.line(to: NSPoint(x: tip.x - d.x * 14 - d.y * 7, y: tip.y - d.y * 14 + d.x * 7))
        path.line(to: NSPoint(x: tip.x - d.x * 10, y: tip.y - d.y * 10))
        path.line(to: NSPoint(x: tip.x - d.x * 14 + d.y * 7, y: tip.y - d.y * 14 - d.x * 7))
        path.close()
        NSColor.black.setStroke(); path.lineWidth = 5; path.stroke()
        color.setFill(); path.fill()
        ink.setStroke(); path.lineWidth = 1; path.stroke()
        if let label {
            let x = tip.x - d.x * 26 - 9, y = tip.y - d.y * 26 - 9
            fill(NSRect(x: x, y: y, width: 18, height: 18), NSColor.black.withAlphaComponent(0.8))
            text(label, x: x, y: y + 1, size: 11, width: 18, alignment: .center, mono: true)
        }
    }

    private func threatText(_ value: String, y: CGFloat, color: NSColor) {
        let width: CGFloat = 310
        fill(NSRect(x: bounds.midX - width / 2, y: y - 2, width: width, height: 19), NSColor.black.withAlphaComponent(0.8))
        text(value, x: bounds.midX - width / 2, y: y, size: 10, color: color, width: width, alignment: .center, mono: true)
    }

    private func drawScope() {
        let diameter = min(bounds.width, bounds.height) * 0.78
        let rect = NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
        let mask = NSBezierPath(rect: bounds); mask.appendOval(in: rect); mask.windingRule = .evenOdd
        NSColor(hex: 0x030805).setFill(); mask.fill()
        NSColor(hex: 0x24302a).setStroke(); let rim = NSBezierPath(ovalIn: rect); rim.lineWidth = 5; rim.stroke()
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3)).addClip()
        let black = NSColor(hex: 0x10170e)
        line(x1: rect.minX, y1: bounds.midY, x2: rect.maxX, y2: bounds.midY, color: black)
        line(x1: bounds.midX, y1: rect.minY, x2: bounds.midX, y2: rect.maxY, color: black)
        for i in -5...5 where i != 0 {
            let offset = CGFloat(i) * diameter * 0.055
            fill(NSRect(x: bounds.midX + offset - 1.5, y: bounds.midY - 1.5, width: 3, height: 3), black)
            line(x1: bounds.midX - 4, y1: bounds.midY + offset, x2: bounds.midX + 4, y2: bounds.midY + offset, color: black)
        }
        accent.setFill(); NSBezierPath(ovalIn: NSRect(x: bounds.midX - 2, y: bounds.midY - 2, width: 4, height: 4)).fill()
        text("SENTINEL · 6× OPTIK", x: bounds.midX - 110, y: rect.maxY - diameter * 0.17, size: 9, width: 220, alignment: .center, mono: true)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCrosshair(aiming: Bool) {
        let x = bounds.midX, y = bounds.midY
        if !aiming {
            for sign: CGFloat in [-1, 1] {
                line(x1: x + sign * 6, y1: y, x2: x + sign * 13, y2: y, color: ink)
                line(x1: x, y1: y + sign * 6, x2: x, y2: y + sign * 13, color: ink)
            }
        }
        fill(NSRect(x: x - 1, y: y - 1, width: 2, height: 2), ink)
    }

    private func drawOverlay(_ c: GameCoordinator) {
        fill(bounds, NSColor(hex: 0x0b1912, alpha: 0.88))
        let x = bounds.midX - 175, y = bounds.midY - 190, won = c.simulation.state == .won
        text(c.mode == .paused ? "VERBINDUNG GEHALTEN" : won ? "EXTRAKTION ERFOLGREICH" : "SIGNAL VERLOREN", x: x, y: y, size: 10, color: accent, tracking: 2, mono: true)
        text(c.mode == .paused ? "EINSATZ\nPAUSIERT." : won ? "MISSION\nERFÜLLT." : "EINSATZ\nGESCHEITERT.", x: x, y: y + 31, size: 44, weight: .heavy, width: 440)
        if c.mode == .paused {
            text("Ein Moment Ruhe. Dann geht es weiter.", x: x, y: y + 163, size: 13, color: muted)
        } else {
            let s = c.simulation
            text("\(s.kills) ABSCHÜSSE     \(s.score) XP     \(timeString(s.elapsed))", x: x, y: y + 164, size: 12, mono: true)
            text(won ? "Außenposten gesichert. Willkommen zurück." : "Nutze Deckung, Containerdächer und Granaten.", x: x, y: y + 207, size: 12, color: muted, width: 400)
        }
    }

    private func panelText(_ title: String, detail: String, y: CGFloat) {
        let width: CGFloat = min(520, max(270, CGFloat(title.count) * 7 + 44)), x = bounds.midX - width / 2
        fill(NSRect(x: x, y: y, width: width, height: detail.isEmpty ? 35 : 48), NSColor(hex: 0x10231a, alpha: 0.92))
        text(title, x: x + 10, y: y + 10, size: 10, width: width - 20, alignment: .center, mono: true)
        if !detail.isEmpty { text(detail, x: x + 10, y: y + 28, size: 9, color: muted, width: width - 20, alignment: .center) }
    }
    private func timeString(_ value: Double) -> String { String(format: "%02d:%02d", Int(value) / 60, Int(value) % 60) }
    private func fill(_ rect: NSRect, _ color: NSColor) { color.setFill(); NSBezierPath(rect: rect).fill() }
    private func stroke(_ rect: NSRect, _ color: NSColor) { color.setStroke(); NSBezierPath(rect: rect).stroke() }
    private func line(x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat, color: NSColor, thickness: CGFloat = 1) {
        color.setStroke(); let path = NSBezierPath(); path.lineWidth = thickness
        path.move(to: NSPoint(x: x1, y: y1)); path.line(to: NSPoint(x: x2, y: y2)); path.stroke()
    }
    private func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular,
                      color: NSColor = ink, tracking: CGFloat = 0, width: CGFloat = 1000,
                      alignment: NSTextAlignment = .left, mono: Bool = false, font: NSFont? = nil) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = alignment; paragraph.lineSpacing = 4
        let chosen = font ?? (mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight))
        (string as NSString).draw(in: NSRect(x: x, y: y, width: width, height: size * 3.5), withAttributes: [.font: chosen, .foregroundColor: color, .kern: tracking, .paragraphStyle: paragraph])
    }
}
