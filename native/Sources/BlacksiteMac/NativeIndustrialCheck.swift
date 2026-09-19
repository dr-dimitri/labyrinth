import Foundation
import simd
import BlacksiteCore

/// Short, reproducible views of authored industrial maps. These retain normal
/// combat and expose their limits; physical mission runs belong to Core tests.
@MainActor
enum NativeIndustrialCheck {
    struct Result {
        let simulation: CombatSimulation
        let metadata: [String: Any]
    }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static func prepare(arguments: [String], renderer: NativeRenderer, loadout: LoadoutDefinition) throws -> Result? {
        guard let index = arguments.firstIndex(of: "--scene"), index+1 < arguments.count,
              (arguments[index+1].hasPrefix("kessel-") || arguments[index+1].hasPrefix("sirocco-")) else { return nil }
        return try makeScenario(scene: arguments[index+1],loadout: loadout,renderer: renderer)
    }
    static func makeScenario(scene: String, loadout: LoadoutDefinition = .init(), renderer: NativeRenderer? = nil) throws -> Result {
        if scene.hasPrefix("sirocco-") { return try makeSiroccoScenario(scene: scene,loadout: loadout,renderer: renderer) }
        guard ["kessel-overview","kessel-gates","kessel-switched","kessel-aftermath"].contains(scene) else {
            throw Failure(message: "Unknown industrial view: \(scene)")
        }
        let map = MapDefinition.kessel9
        var player = map.playerStart
        if scene != "kessel-overview" { player.position = map.grounded(SIMD3(0,0,23.2)) }
        player.yaw = 0; player.pitch = -0.05
        let enemies = map.spawns.enumerated().map { EnemyState(id: 29000+$0.offset,position: map.grounded($0.element)) }
        let game = CombatSimulation(difficulty: .easy,seed: 1745,world: map.obstacles,
            startingPlayer: player,startingEnemies: enemies,startingWave: 3,map: map,loadout: loadout)
        try renderer?.setMap(map); renderer?.reset()
        var input = GameInput()
        input.interact = scene == "kessel-switched"
        input.pitch = player.pitch
        var events: [GameEvent] = []
        let ticks = scene == "kessel-switched" ? 540 : scene == "kessel-aftermath" ? 540 : 1
        for tick in 0..<ticks {
            if scene == "kessel-aftermath", [0,90,180].contains(tick) { _ = game.throwGrenade() }
            game.step(deltaTime: 1.0/120,input: input)
            let batch = game.drainEvents(); events += batch
            renderer?.handle(events: batch,simulation: game)
            renderer?.advanceEffects(deltaTime: 1.0/120,simulation: game)
        }
        guard game.state == .active else { throw Failure(message: "Industrial diagnostic ended during ordinary combat.") }
        if scene == "kessel-switched" {
            guard game.devices.first(where: { $0.id == 2951 })?.gateProgress == 1,
                  game.devices.first(where: { $0.id == 2952 })?.gateProgress == 0 else {
                throw Failure(message: "The ordinary held interaction did not exchange the bulkheads.")
            }
        }
        return Result(simulation: game,metadata: [
            "scene": scene, "mapID": map.id, "mapVersion": map.version, "seed": 1745,
            "initialGuardCount": enemies.count,"livingGuardCount": game.aliveCount,
            "elapsed": game.elapsed,"explosions": events.filter { $0.kind == .explosion }.count,
            "fixtureScope": "short native view with nine authored normal guards and actual held input; not a complete combat playthrough",
            "devices": game.devices.map { ["id": $0.id,"open": $0.gateProgress,"moving": $0.isMoving,"blocked": $0.blockedByActor] as [String: Any] }
        ])
    }
    private static func makeSiroccoScenario(scene: String,loadout: LoadoutDefinition,renderer: NativeRenderer?) throws -> Result {
        guard ["sirocco-overview","sirocco-glass","sirocco-clear","sirocco-damaged","sirocco-opened","sirocco-aftermath","sirocco-ruins"].contains(scene) else {
            throw Failure(message: "Unknown Sirocco view: \(scene)")
        }
        let map = MapDefinition.sirocco
        var player = map.playerStart
        player.pitch = -0.05
        if scene != "sirocco-overview" && scene != "sirocco-ruins" && scene != "sirocco-aftermath" {
            player.position = map.grounded(SIMD3(-16,0,scene == "sirocco-clear" ? 6.9:11.5))
            player.yaw = -.pi/2; player.pitch = -0.025
        }
        if scene == "sirocco-aftermath" { player.yaw = 0.45; player.pitch = 0.04 }
        var world = map.obstacles
        if scene == "sirocco-ruins" {
            for index in world.indices where world[index].kind == .glass {
                world[index].health = 0; world[index].destroyed = true
            }
        }
        let enemies = map.spawns.enumerated().map { EnemyState(id: 30000+$0.offset,position: map.grounded($0.element)) }
        let game = CombatSimulation(difficulty: .easy,seed: 1745,world: world,
            startingPlayer: player,startingEnemies: enemies,startingWave: 3,map: map,loadout: loadout)
        try renderer?.setMap(map); renderer?.reset()
        var events: [GameEvent] = []
        var input = GameInput(); input.yaw = player.yaw; input.pitch = player.pitch
        func tick() {
            game.step(deltaTime: 1.0/120,input: input)
            let batch = game.drainEvents(); events += batch
            renderer?.handle(events: batch,simulation: game)
            renderer?.advanceEffects(deltaTime: 1.0/120,simulation: game)
        }
        if scene == "sirocco-damaged" || scene == "sirocco-opened" {
            input.fire = true; tick(); input.fire = false
            if scene == "sirocco-opened" { for _ in 0..<24 { tick() }; input.fire = true; tick(); input.fire = false }
        } else if scene == "sirocco-aftermath" {
            for frame in 0..<530 {
                if [0,90,180].contains(frame) { _ = game.throwGrenade() }
                tick()
            }
        } else { tick() }
        guard game.state == .active else { throw Failure(message: "Sirocco view ended during ordinary combat.") }
        let panel = game.obstacles.first { $0.id == 3006 }!
        if scene == "sirocco-damaged", panel.damageStage != .damaged {
            throw Failure(message: "The actual rifle shot did not damage the selected pane.")
        }
        if scene == "sirocco-opened", !panel.destroyed {
            throw Failure(message: "The actual rifle shots did not open the selected passage.")
        }
        return Result(simulation: game,metadata: [
            "scene": scene,"mapID": map.id,"mapVersion": map.version,"seed": 1745,
            "initialGuardCount": enemies.count,"livingGuardCount": game.aliveCount,"elapsed": game.elapsed,
            "openedPanes": game.breaches.filter(\.isOpen).count,
            "shots": events.filter { $0.kind == .shot }.count,"explosions": events.filter { $0.kind == .explosion }.count,
            "fixtureScope": scene == "sirocco-ruins" ? "explicit fully destroyed pane snapshot; not a destruction or mission playthrough" : "short real firing/grenade view with normal guards; not a complete mission playthrough"
        ])
    }
}
