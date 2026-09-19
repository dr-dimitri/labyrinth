import Foundation
import simd
import BlacksiteCore

/// A translated, elevated map and repeated actual GPU map changes. These are
/// diagnostics, not a second production map or a shortcut around validation.
@MainActor
enum NativeMapCheck {
    struct Result {
        let simulation: CombatSimulation
        let metadata: [String: Any]
    }
    private struct CheckFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static func prepare(arguments: [String], renderer: NativeRenderer, loadout: LoadoutDefinition = .init()) throws -> Result? {
        guard let index=arguments.firstIndex(of:"--scene"),index+1<arguments.count,
              arguments[index+1]=="map-test" else { return nil }
        if arguments.contains("--map-cycles") {
            let incompatible:Set<String>=["--shots","--impact-shots","--explosions","--effects-reset","--effect-age","--effect-seconds","--reload-preview","--reload-progress","--destruction-phase","--destruction-reset","--prone","--aim"]
            guard incompatible.isDisjoint(with:arguments) else {
                throw CheckFailure(message:"--map-cycles performs full resets and cannot be combined with shot, effect, destruction or weapon-pose fixtures.")
            }
        }
        let map=MapDefinition.testRange
        try renderer.setMap(map)
        var player=map.playerStart
        player.pitch = -0.09
        let enemies=map.waveStaging.enumerated().map { index,point -> EnemyState in
            var enemy=EnemyState(id:801+index,position:map.grounded(point))
            enemy.yaw=atan2(player.position.x-point.x,player.position.z-point.z)
            enemy.aimBlend=1;enemy.seesPlayer=true
            return enemy
        }
        let simulation=CombatSimulation(difficulty:.easy,seed:1745,world:map.obstacles,
            startingPlayer:player,startingEnemies:enemies,startingWave:3,map:map,loadout:loadout)
        return Result(simulation:simulation,metadata:["scene":"map-test","fixtureMapID":map.id,
            "playerGroundHeight":simulation.player.position.y,"fixtureRoadMaterial":map.groundMaterial(at:player.position).rawValue,
            "fixtureMinimum":[map.minimum.x,map.minimum.z],"fixtureMaximum":[map.maximum.x,map.maximum.z]])
    }

    static func cycles(arguments:[String],renderer:NativeRenderer,simulation:CombatSimulation,width:Int,height:Int)throws->[String:Any] {
        guard let index=arguments.firstIndex(of:"--map-cycles") else { return [:] }
        guard index+1<arguments.count,let cycles=Int(arguments[index+1]),(1...10).contains(cycles) else {
            throw CheckFailure(message:"--map-cycles accepts 1 to 10 complete map round trips.")
        }
        guard let scene=arguments.firstIndex(of:"--scene"),scene+1<arguments.count,["map-test", "fjord-overview", "sundkai-overview"].contains(arguments[scene+1]) else {
            throw CheckFailure(message:"--map-cycles requires --scene map-test, fjord-overview or sundkai-overview; map changes deliberately clear other fixture effects.")
        }
        let initial=simulation.map
        var measurements:[[String:Any]]=[]
        for transition in 0..<(cycles*2) {
            let next=transition.isMultiple(of:2)
                ? (initial.id == MapDefinition.blacksite.id ? MapDefinition.testRange : MapDefinition.blacksite)
                : initial
            try autoreleasepool { try renderer.setMap(next) }
            let candidate=CombatSimulation(map:next,difficulty:.easy,seed:1745,loadout:simulation.loadout)
            var measurement=try autoreleasepool {
                try renderer.benchmark(simulation:candidate,width:width,height:height,frames:1)
            }
            measurement.merge(renderer.characterDiagnostics) { _,new in new }
            measurement["transition"]=transition+1
            measurements.append(measurement)
        }
        return ["mapCycleCount":cycles,"mapCycleMeasurements":measurements]
    }
}
