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
    override func mouseDown(with event: NSEvent) { coordinator?.mouseButton(0, down: true) }
    override func mouseUp(with event: NSEvent) { coordinator?.mouseButton(0, down: false) }
    override func rightMouseDown(with event: NSEvent) { coordinator?.mouseButton(1, down: true) }
    override func rightMouseUp(with event: NSEvent) { coordinator?.mouseButton(1, down: false) }
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > 0.5 else { return }
        coordinator?.switchWeapon()
    }
}

struct NativeSettings {
    var difficulty: Difficulty = .normal
    var highQuality = true
    var musicVolume: Float = 0.45
    var effectsVolume: Float = 0.45
    var sensitivity: Float = 0.0023
    var fps = 60

    init(defaults: UserDefaults = .standard) {
        defaults.register(defaults: ["native.difficulty": "normal", "native.highQuality": true,
                                    "native.volume": 0.45, "native.sensitivity": 0.0023, "native.fps": 60])
        difficulty = Difficulty(rawValue: defaults.string(forKey: "native.difficulty") ?? "normal") ?? .normal
        highQuality = defaults.bool(forKey: "native.highQuality")
        let legacyVolume = defaults.float(forKey: "native.volume")
        musicVolume = max(0, min(1, defaults.object(forKey: "native.musicVolume") == nil ? legacyVolume : defaults.float(forKey: "native.musicVolume")))
        effectsVolume = max(0, min(1, defaults.object(forKey: "native.effectsVolume") == nil ? legacyVolume : defaults.float(forKey: "native.effectsVolume")))
        sensitivity = max(0.0006, min(0.006, defaults.float(forKey: "native.sensitivity")))
        fps = defaults.integer(forKey: "native.fps") == 120 ? 120 : 60
    }
    func save(defaults: UserDefaults = .standard) {
        defaults.set(difficulty.rawValue, forKey: "native.difficulty")
        defaults.set(highQuality, forKey: "native.highQuality")
        defaults.set(musicVolume, forKey: "native.musicVolume")
        defaults.set(effectsVolume, forKey: "native.effectsVolume")
        defaults.set(sensitivity, forKey: "native.sensitivity")
        defaults.set(fps, forKey: "native.fps")
    }
}
