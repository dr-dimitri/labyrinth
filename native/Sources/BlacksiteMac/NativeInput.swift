import AppKit
import MetalKit
import CoreGraphics
import BlacksiteCore

final class NativeGameView: MTKView {
    weak var coordinator: GameCoordinator?
    private var mouseTracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { true }
    override func updateTrackingAreas() {
        if let mouseTracking { removeTrackingArea(mouseTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); mouseTracking = area
        super.updateTrackingAreas()
    }
    override func keyDown(with event: NSEvent) { coordinator?.keyDown(event) }
    override func keyUp(with event: NSEvent) { coordinator?.keyUp(event) }
    override func flagsChanged(with event: NSEvent) { coordinator?.flagsChanged(event) }
    override func mouseMoved(with event: NSEvent) { coordinator?.mouseMoved(event) }
    override func mouseDragged(with event: NSEvent) { coordinator?.mouseMoved(event) }
    override func rightMouseDragged(with event: NSEvent) { coordinator?.mouseMoved(event) }
    override func otherMouseDragged(with event: NSEvent) { coordinator?.mouseMoved(event) }
    override func mouseDown(with event: NSEvent) { coordinator?.mouseButton(0, down: true) }
    override func mouseUp(with event: NSEvent) { coordinator?.mouseButton(0, down: false) }
    override func rightMouseDown(with event: NSEvent) { coordinator?.mouseButton(1, down: true) }
    override func rightMouseUp(with event: NSEvent) { coordinator?.mouseButton(1, down: false) }
    override func otherMouseDown(with event: NSEvent) { coordinator?.mouseButton(event.buttonNumber, down: true) }
    override func otherMouseUp(with event: NSEvent) { coordinator?.mouseButton(event.buttonNumber, down: false) }
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > 0.5 else { return }
        coordinator?.scrollInput(event.scrollingDeltaY > 0 ? .up : .down)
    }
}

struct NativeSettings {
    static let defaultSensitivity: Float = 0.0023
    static let sensitivityRange: ClosedRange<Float> = 0.0001...0.006
    var difficulty: Difficulty = .normal
    var selectedMission: MissionKind = .waves
    var selectedCamouflage: CamouflagePattern = .none
    var highQuality = true
    var musicVolume: Float = 0.45
    var effectsVolume: Float = 0.45
    var sensitivity: Float = 0.0023
    var adsSensitivity: Float = 0.0023 * 0.65
    var scopeSensitivity: Float = 0.0023 * 0.19
    var invertY = false
    var aimMode: NativeActionMode = .hold
    var sprintMode: NativeActionMode = .hold
    var bindings = NativeBindings.defaults
    var fps = 60

    init(defaults: UserDefaults = .standard) {
        defaults.register(defaults: ["native.difficulty": "normal", "native.highQuality": true,
                                    "native.volume": 0.45, "native.sensitivity": 0.0023, "native.fps": 60])
        difficulty = Difficulty(rawValue: defaults.string(forKey: "native.difficulty") ?? "normal") ?? .normal
        selectedMission = MissionKind(rawValue: defaults.string(forKey: "native.mission") ?? "waves") ?? .waves
        selectedCamouflage = CamouflagePattern(rawValue: defaults.string(forKey: "native.camouflage") ?? "none") ?? .none
        highQuality = defaults.bool(forKey: "native.highQuality")
        let legacyVolume = defaults.float(forKey: "native.volume")
        musicVolume = max(0, min(1, defaults.object(forKey: "native.musicVolume") == nil ? legacyVolume : defaults.float(forKey: "native.musicVolume")))
        effectsVolume = max(0, min(1, defaults.object(forKey: "native.effectsVolume") == nil ? legacyVolume : defaults.float(forKey: "native.effectsVolume")))
        sensitivity = Self.clampSensitivity(defaults.float(forKey: "native.sensitivity"), fallback: Self.defaultSensitivity)
        adsSensitivity = Self.clampSensitivity(defaults.object(forKey: "native.adsSensitivity") == nil ? sensitivity * 0.65 : defaults.float(forKey: "native.adsSensitivity"), fallback: sensitivity * 0.65)
        scopeSensitivity = Self.clampSensitivity(defaults.object(forKey: "native.scopeSensitivity") == nil ? sensitivity * 0.19 : defaults.float(forKey: "native.scopeSensitivity"), fallback: sensitivity * 0.19)
        invertY = defaults.bool(forKey: "native.invertY")
        aimMode = NativeActionMode(rawValue: defaults.string(forKey: "native.aimMode") ?? "hold") ?? .hold
        sprintMode = NativeActionMode(rawValue: defaults.string(forKey: "native.sprintMode") ?? "hold") ?? .hold
        if let data = defaults.data(forKey: "native.bindings.v1"), let decoded = try? JSONDecoder().decode(NativeBindings.self, from: data) { bindings = decoded }
        fps = defaults.integer(forKey: "native.fps") == 120 ? 120 : 60
    }
    func save(defaults: UserDefaults = .standard) {
        defaults.set(difficulty.rawValue, forKey: "native.difficulty")
        defaults.set(selectedMission.rawValue, forKey: "native.mission")
        defaults.set(selectedCamouflage.rawValue, forKey: "native.camouflage")
        defaults.set(highQuality, forKey: "native.highQuality")
        defaults.set(musicVolume, forKey: "native.musicVolume")
        defaults.set(effectsVolume, forKey: "native.effectsVolume")
        defaults.set(sensitivity, forKey: "native.sensitivity")
        defaults.set(adsSensitivity, forKey: "native.adsSensitivity")
        defaults.set(scopeSensitivity, forKey: "native.scopeSensitivity")
        defaults.set(invertY, forKey: "native.invertY")
        defaults.set(aimMode.rawValue, forKey: "native.aimMode")
        defaults.set(sprintMode.rawValue, forKey: "native.sprintMode")
        if let data = try? JSONEncoder().encode(bindings) { defaults.set(data, forKey: "native.bindings.v1") }
        defaults.set(fps, forKey: "native.fps")
    }

    mutating func resetControls() {
        sensitivity = Self.defaultSensitivity
        adsSensitivity = Self.defaultSensitivity * 0.65
        scopeSensitivity = Self.defaultSensitivity * 0.19
        invertY = false; aimMode = .hold; sprintMode = .hold; bindings = .defaults
    }

    func mouseLookDelta(dx: Float, dy: Float, aiming: Bool, weapon: WeaponKind) -> SIMD2<Float> {
        let value = aiming ? weapon == .sniper ? scopeSensitivity : adsSensitivity : sensitivity
        let scale = Self.clampSensitivity(value, fallback: Self.defaultSensitivity)
        return SIMD2(dx.isFinite ? -dx * scale : 0, dy.isFinite ? (invertY ? dy : -dy) * scale : 0)
    }

    private static func clampSensitivity(_ value: Float, fallback: Float) -> Float {
        guard value.isFinite else { return min(sensitivityRange.upperBound, max(sensitivityRange.lowerBound, fallback)) }
        return min(sensitivityRange.upperBound, max(sensitivityRange.lowerBound, value))
    }
}
