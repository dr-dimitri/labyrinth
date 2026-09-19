import AppKit
import MetalKit
import BlacksiteCore

enum NativeResources {
    static var assetRoot: URL? {
        let fm = FileManager.default
        if let resources = Bundle.main.resourceURL {
            let url = resources.appendingPathComponent("Assets")
            if fm.fileExists(atPath: url.appendingPathComponent("textures/floor/color.jpg").path) { return url }
        }
        if let path = ProcessInfo.processInfo.environment["BLACKSITE_ASSET_DIR"] { return URL(fileURLWithPath: path) }
        for start in [URL(fileURLWithPath: fm.currentDirectoryPath), Bundle.main.bundleURL] {
            var directory = start
            for _ in 0..<9 {
                for relative in ["native/Assets", "Assets"] {
                    let url = directory.appendingPathComponent(relative)
                    if fm.fileExists(atPath: url.appendingPathComponent("textures/floor/color.jpg").path) { return url }
                }
                directory.deleteLastPathComponent()
            }
        }
        return nil
    }
}

@MainActor
final class BlacksiteAppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: GameCoordinator?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "NACHTGANG — BLACKSITE"
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 960, height: 640)
        window.backgroundColor = NSColor(hex: 0x101c16)
        window.isReleasedWhenClosed = false; window.collectionBehavior = [.fullScreenPrimary]
        window.appearance = NSAppearance(named: .darkAqua)
        if let screen = NSScreen.main, window.frame.height > screen.visibleFrame.height {
            window.setContentSize(NSSize(width: min(1280, screen.visibleFrame.width - 50), height: screen.visibleFrame.height - 55))
        }
        window.center()
        coordinator = GameCoordinator(window: window)
        installMenu()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { coordinator?.shutdown() }

    private func installMenu() {
        let main = NSMenu()
        let applicationItem = NSMenuItem(); main.addItem(applicationItem)
        let appMenu = NSMenu(title: "Blacksite"); applicationItem.submenu = appMenu
        appMenu.addItem(withTitle: "Über Blacksite", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Einstellungen …", action: #selector(GameCoordinator.settingsMenu(_:)), keyEquivalent: ","); settings.target = coordinator
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Blacksite ausblenden", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Blacksite beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let gameItem = NSMenuItem(); main.addItem(gameItem)
        let game = NSMenu(title: "Einsatz"); gameItem.submenu = game
        let start = game.addItem(withTitle: "Neuer Einsatz", action: #selector(GameCoordinator.newMatchMenu(_:)), keyEquivalent: "n"); start.target = coordinator
        let pause = game.addItem(withTitle: "Pause / Fortsetzen", action: #selector(GameCoordinator.pauseMenu(_:)), keyEquivalent: "p"); pause.target = coordinator
        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Fenster"); windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimieren", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let fullscreen = windowMenu.addItem(withTitle: "Vollbild", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f"); fullscreen.keyEquivalentModifierMask = [.command, .control]
        let helpItem = NSMenuItem(); main.addItem(helpItem)
        let helpMenu = NSMenu(title: "Hilfe"); helpItem.submenu = helpMenu
        let help = helpMenu.addItem(withTitle: "Steuerung und Arsenal", action: #selector(GameCoordinator.helpMenu(_:)), keyEquivalent: "?"); help.target = coordinator
        NSApp.mainMenu = main; NSApp.windowsMenu = windowMenu; NSApp.helpMenu = helpMenu
    }
}

@main
struct BlacksiteMain {
    @MainActor static func main() {
        let args = CommandLine.arguments
        let app = NSApplication.shared
        if args.contains("--smoke-test") || args.contains("--graphics-benchmark") {
            app.setActivationPolicy(.prohibited)
            do {
                let output: String
                if let index = args.firstIndex(of: "--output"), index + 1 < args.count { output = args[index + 1] }
                else { output = FileManager.default.currentDirectoryPath + "/native-smoke.png" }
                func dimension(_ flag: String, fallback: Int) -> Int {
                    guard let index = args.firstIndex(of: flag), index + 1 < args.count, let number = Int(args[index + 1]) else { return fallback }
                    return min(3840, max(320, number))
                }
                let benchmark = args.contains("--graphics-benchmark")
                let width = dimension("--width", fallback: benchmark ? 2560 : 1280)
                let height = dimension("--height", fallback: benchmark ? 1600 : 800)
                let view = MTKView(frame: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)), device: MTLCreateSystemDefaultDevice())
                let highQuality = !args.contains("--balanced")
                let renderer = try NativeRenderer(view: view, assetRoot: NativeResources.assetRoot, highQuality: highQuality)
                let loadout = try NativeLoadoutCheck.loadout(arguments: args)
                let mapCheck = try NativeMapCheck.prepare(arguments: args, renderer: renderer, loadout: loadout)
                let soundCheck = mapCheck == nil ? try NativeSoundCheck.prepare(arguments: args, renderer: renderer, loadout: loadout) : nil
                let environmentCheck = mapCheck == nil && soundCheck == nil ? try NativeEnvironmentCheck.prepare(arguments: args, renderer: renderer, loadout: loadout) : nil
                let missionCheck = mapCheck == nil && soundCheck == nil && environmentCheck == nil ? try NativeMissionCheck.prepare(arguments: args, renderer: renderer, loadout: loadout) : nil
                let sceneCheck = mapCheck == nil && soundCheck == nil && environmentCheck == nil && missionCheck == nil ? try NativeBattlefieldCheck.prepare(arguments: args, renderer: renderer, loadout: loadout) : nil
                var simulation = mapCheck?.simulation ?? soundCheck?.simulation ?? environmentCheck?.simulation ?? missionCheck?.simulation ?? sceneCheck?.simulation ?? CombatSimulation(difficulty: .easy, seed: 1745, loadout: loadout)
                if mapCheck == nil && soundCheck == nil && environmentCheck == nil && sceneCheck == nil && missionCheck == nil {
                    for _ in 0..<240 { simulation.step(deltaTime: 1.0 / 120, input: GameInput()) }
                }
                renderer.handle(events: simulation.drainEvents(), simulation: simulation)
                let weaponCheck = try NativeWeaponCheck.prepare(arguments: args, renderer: renderer, simulation: simulation)
                let effectsCheck = try NativeEffectsCheck.prepare(arguments: args, renderer: renderer, simulation: simulation)
                let destructionCheck = try NativeDestructionCheck.prepare(arguments: args, renderer: renderer, simulation: simulation)
                if let destructionCheck { simulation = destructionCheck.simulation }
                let textureCheck = try NativeTextureCheck.prepare(arguments: args, renderer: renderer, simulation: simulation,
                                                                  width: width, height: height, initialHighQuality: highQuality)
                let mapCycles = try NativeMapCheck.cycles(arguments: args, renderer: renderer, simulation: simulation, width: width, height: height)
                if benchmark {
                    var result = try renderer.benchmark(simulation: simulation, width: width, height: height, frames: 120)
                    result.merge(renderer.characterDiagnostics) { _, value in value }
                    result["loadoutCamouflage"] = simulation.loadout.camouflage.rawValue
                    result["loadoutFragmentationGrenades"] = simulation.loadout.fragmentationGrenades
                    result.merge(sceneCheck?.metadata ?? [:]) { _, value in value }
                    result.merge(missionCheck?.metadata ?? [:]) { _, value in value }
                    result.merge(effectsCheck) { _, value in value }
                    result.merge(destructionCheck?.metadata ?? [:]) { _, value in value }
                    result.merge(textureCheck) { _, value in value }
                    result.merge(mapCheck?.metadata ?? [:]) { _, value in value }
                    result.merge(environmentCheck?.metadata ?? [:]) { _, value in value }
                    result.merge(soundCheck?.metadata ?? [:]) { _, value in value }
                    result.merge(mapCycles) { _, value in value }
                    let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                    print(String(decoding: json, as: UTF8.self)); return
                }
                try renderer.renderOffscreen(simulation: simulation, width: width, height: height, to: URL(fileURLWithPath: output))
                var result: [String: Any] = ["result": "pass", "backend": "native Metal", "device": renderer.deviceName,
                                           "enemyCount": simulation.aliveCount, "screenshot": output,
                                           "width": width, "height": height,
                                           "assets": NativeResources.assetRoot?.path ?? "missing"]
                result.merge(weaponCheck) { _, value in value }
                result.merge(effectsCheck) { _, value in value }
                result.merge(destructionCheck?.metadata ?? [:]) { _, value in value }
                result.merge(textureCheck) { _, value in value }
                result.merge(mapCheck?.metadata ?? [:]) { _, value in value }
                result.merge(environmentCheck?.metadata ?? [:]) { _, value in value }
                result.merge(soundCheck?.metadata ?? [:]) { _, value in value }
                result.merge(mapCycles) { _, value in value }
                result.merge(renderer.characterDiagnostics) { _, value in value }
                result["loadoutCamouflage"] = simulation.loadout.camouflage.rawValue
                result["loadoutFragmentationGrenades"] = simulation.loadout.fragmentationGrenades
                result.merge(sceneCheck?.metadata ?? [:]) { _, value in value }
                result.merge(missionCheck?.metadata ?? [:]) { _, value in value }
                let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: json, as: UTF8.self)); return
            } catch {
                fputs("Native Metal smoke test failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        app.setActivationPolicy(.regular)
        let delegate = BlacksiteAppDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
