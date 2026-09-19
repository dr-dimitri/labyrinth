import Foundation
import simd
import BlacksiteCore

/// Deterministic native render fixtures, available only through the smoke-test CLI.
@MainActor
enum NativeBattlefieldCheck {
    struct Result {
        let simulation: CombatSimulation
        let metadata: [String: Any]
    }
    private struct InvalidScene: LocalizedError {
        var errorDescription: String? { "--scene accepts soldiers, soldiers-side, squad, soldier-close, soldier-profile, soldier-back, soldier-crouch, soldier-dead, shadows-hill, shadows-roof, weapons, weapon-wall, impact-metal, impact-concrete, impact-wood, impact-soil, impact-asphalt, impact-miss, firefight, terrain or hollow." }
    }

    static func prepare(arguments: [String], renderer: NativeRenderer) throws -> Result? {
        func value(_ flag: String) -> String? {
            guard let i=arguments.firstIndex(of:flag), i+1<arguments.count else { return nil }
            return arguments[i+1]
        }
        guard let name=value("--scene") else { return nil }
        let terrain=TerrainProfile.battlefield
        var player=PlayerState(position:SIMD3(0,0,11))
        var enemies:[EnemyState]=[]
        var world = GameMap.obstacles
        var seconds:Double=0
        switch name {
        case "impact-metal", "impact-concrete", "impact-wood":
            let kind: ObstacleKind = name == "impact-metal" ? .container : name == "impact-wood" ? .crate : .barrier
            world = [Obstacle(id: 801, kind: kind, position: SIMD3(0, 0, 5), size: SIMD3(4, 2.4, 2))]
            player.position = SIMD3(0, 0, 9)
        case "impact-soil", "impact-asphalt", "impact-miss":
            world = []
            player.position = SIMD3(name == "impact-soil" ? 10 : 0, 0, 11)
            player.pitch = name == "impact-miss" ? 0.65 : -0.48
        case "weapons":
            player.position = SIMD3(0, 0, 32)
        case "weapon-wall":
            // The existing container's front is z=-3.2; the player's collision
            // capsule fits at this position, while an extended barrel would not.
            player.position = SIMD3(15, 0, -2.85)
        case "squad":
            player.position=SIMD3(0,0,14); player.pitch = -0.06
            for i in 0..<9 {
                let x=Float(i%3-1)*3.0, z=Float(i/3)*2.7+3
                var enemy=EnemyState(id:401+i,position:SIMD3(x,terrain.height(x:x,z:z),z))
                enemy.yaw=atan2(player.position.x-x,player.position.z-z)
                enemy.crouchAmount=i%3 == 1 ? 1:0
                enemy.isMoving=i%3 == 2; enemy.isRunning=enemy.isMoving
                enemy.walkCycle=Float(i)*0.73; enemy.aimBlend=1; enemy.seesPlayer=true
                enemies.append(enemy)
            }
        case "soldier-close", "soldier-profile", "soldier-back", "soldier-crouch", "soldier-dead":
            player.position=SIMD3(0,0,7.2); player.pitch = -0.20
            var enemy=EnemyState(id:301,position:SIMD3(0,0,5))
            enemy.aimBlend=1; enemy.seesPlayer=true
            if name == "soldier-profile" { enemy.yaw = .pi/2 }
            if name == "soldier-back" { enemy.yaw = .pi }
            if name == "soldier-crouch" { enemy.crouchAmount=1; player.pitch = -0.34 }
            if name == "soldier-dead" { enemy.health=0; enemy.deathTime = -1; player.pitch = -0.45 }
            enemy.aimPitch=atan2(player.height-0.1-EnemyPose(enemy).shoulderHeight,
                                 player.position.z-enemy.position.z)
            enemies=[enemy]
        case "soldiers", "soldiers-side":
            player.pitch = -0.06
            for i in 0..<3 {
                var enemy=EnemyState(id:301+i,position:SIMD3(Float(i-1)*2.3,0,5))
                enemy.aimBlend=1; enemy.seesPlayer=true
                enemy.yaw=atan2(player.position.x-enemy.position.x,player.position.z-enemy.position.z)
                if i==1 { enemy.crouchAmount=1 }
                if i==2 {
                    enemy.position.y=0.62; enemy.grounded=false
                    enemy.isMoving=true; enemy.isRunning=true; enemy.walkCycle=1.1
                    enemy.verticalVelocity=1.5; enemy.aimBlend=0.2
                }
                enemy.aimPitch=atan2(player.height-0.1-EnemyPose(enemy).shoulderHeight-enemy.position.y,
                                     simd_length(SIMD2(player.position.x-enemy.position.x,player.position.z-enemy.position.z)))
                if name == "soldiers-side" { enemy.yaw = .pi * 0.35 }
                enemies.append(enemy)
            }
        case "shadows-hill", "shadows-roof":
            let roof = terrain.height(x: 15, z: -5) + 3.1
            let points: [SIMD3<Float>]
            if name == "shadows-hill" {
                player.position = SIMD3(16, terrain.height(x: 16, z: 22), 22)
                points = [SIMD3(13, terrain.height(x: 13, z: 27), 27),
                          SIMD3(16, terrain.height(x: 16, z: 28), 28),
                          SIMD3(19, terrain.height(x: 19, z: 27), 27)]
            } else {
                player.position = SIMD3(18.8, roof, -3.85)
                points = [SIMD3(11.5, roof, -5.85), SIMD3(14, roof, -4), SIMD3(15.8, roof, -5.7)]
            }
            let target = points.reduce(.zero, +) / Float(points.count) + SIMD3(0, 0.7, 0)
            let offset = target - (player.position + SIMD3(0, player.height - 0.1, 0))
            player.yaw = atan2(-offset.x, -offset.z)
            player.pitch = atan2(offset.y, simd_length(SIMD2(offset.x, offset.z)))
            for (i, point) in points.enumerated() {
                var enemy = EnemyState(id: 501 + i, position: point)
                enemy.yaw = atan2(player.position.x - point.x, player.position.z - point.z)
                enemy.aimBlend = 1; enemy.seesPlayer = true
                if i == 1 { enemy.crouchAmount = 1 }
                if i == 2 {
                    enemy.position.y += 0.62; enemy.grounded = false
                    enemy.isMoving = true; enemy.isRunning = true; enemy.walkCycle = 1.1
                    enemy.verticalVelocity = 1.5; enemy.aimBlend = 0.2
                }
                enemies.append(enemy)
            }
        case "firefight":
            player.position=SIMD3(0,0,23)
            enemies=[EnemyState(id:301,position:SIMD3(-4,0,14)),
                     EnemyState(id:302,position:SIMD3(5,0,11)),
                     EnemyState(id:303,position:SIMD3(10,0,24)),
                     EnemyState(id:304,position:SIMD3(-12,0,30))]
            seconds=min(20,max(0,Double(value("--seconds") ?? "4") ?? 4))
        case "terrain":
            player.position=SIMD3(5.5,0,32); player.yaw = -0.62; player.pitch = 0.02
        case "hollow":
            player.position=SIMD3(24,0,0); player.yaw = -2.13; player.pitch = -0.30
        default: throw InvalidScene()
        }
        if let cameraOffset = Float(value("--camera-offset") ?? "0"), cameraOffset.isFinite {
            player.position.x += max(-0.5, min(0.5, cameraOffset))
        }
        let simulation=CombatSimulation(difficulty:.easy,seed:1745,world:world,
                                         startingPlayer:player,startingEnemies:enemies,startingWave:3,terrain:terrain)
        var observed=Set<String>(), shots=0
        var input=GameInput(); input.yaw=player.yaw; input.pitch=player.pitch
        if seconds.isFinite {
            for _ in 0..<Int(seconds*120) {
                simulation.step(deltaTime:1.0/120,input:input)
                let events=simulation.drainEvents()
                shots += events.filter { $0.kind == .enemyShot }.count
                renderer.handle(events:events,simulation:simulation)
                renderer.advanceEffects(deltaTime:1.0/120,simulation:simulation)
                for enemy in simulation.enemies {
                    if enemy.isRunning { observed.insert("running") }
                    if enemy.crouchAmount>0.6 { observed.insert("crouching") }
                    if !enemy.grounded { observed.insert("airborne") }
                    if enemy.aimBlend>0.8 { observed.insert("aiming") }
                }
            }
        }
        return Result(simulation:simulation,metadata:["scene":name,"enemyShots":shots,"matchState":simulation.state.rawValue,
                       "observedBehaviors":observed.sorted(),"terrain":"shared triangular heightfield",
                       "playerGroundHeight":terrain.height(x:simulation.player.position.x,z:simulation.player.position.z),
                       "enemyStates":simulation.enemies.map { e in
                           ["id":e.id,"crouch":e.crouchAmount,"running":e.isRunning,
                            "grounded":e.grounded,"aim":e.aimBlend,"height":e.position.y] as [String:Any]
                       }])
    }
}
