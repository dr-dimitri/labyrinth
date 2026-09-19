import Testing
import simd
@testable import BlacksiteCore

struct CoverDebrisTests {
    private func scene(_ world: [Obstacle], player: SIMD3<Float> = SIMD3(0,0,30), enemies: [EnemyState] = []) -> CombatSimulation {
        CombatSimulation(world: world, startingPlayer: PlayerState(position: player), startingEnemies: enemies, startingWave: 3)
    }
    private func advance(_ game: CombatSimulation, _ seconds: Double) {
        for _ in 0..<Int((seconds*120).rounded()) { game.step(deltaTime: 1.0/120, input: GameInput()) }
    }
    private func barrier(id: Int = 70, position: SIMD3<Float> = .zero, height: Float = 1.05) -> Obstacle {
        Obstacle(id: id, kind: .barrier, position: position, size: SIMD3(6,height,0.85))
    }

    @Test func healthStagesAreDeterministicAndDamagedCoverStaysClosed() {
        for kind in [ObstacleKind.crate,.barrel,.barrier,.container] {
            var box = Obstacle(id: 1, kind: kind, position: .zero, size: SIMD3(3,2,1))
            #expect(box.damageStage == .intact)
            box.health = box.maximumHealth*0.5 + 0.01
            #expect(box.damageStage == .intact)
            box.health = box.maximumHealth*0.5
            #expect(box.damageStage == .damaged)
            box.health = 0
            #expect(box.damageStage == .destroyed)
            box.health = box.maximumHealth;box.destroyed = true
            #expect(box.damageStage == .destroyed)
        }
        let bunker = Obstacle(id: 2, kind: .bunker, position: .zero, size: SIMD3(4,4,4))
        #expect(bunker.damageStage == .intact)
        let original = barrier(height: 2), game = scene([original])
        game.damageCover(index: 0, amount: original.maximumHealth*0.5)
        #expect(game.obstacles[0].damageStage == .damaged)
        #expect(game.obstacles[0].position == original.position && game.obstacles[0].size == original.size)
        #expect(game.blocked(.zero))
        #expect(!game.clearLine(SIMD3(0,1.4,4), SIMD3(0,1.4,-4)))
        #expect(game.coverDebris.isEmpty && game.score == 0)
    }

    @Test func remnantsUseDistinctIDsAndBlockOnlyTheirActualLowVolume() throws {
        let original = barrier(id: 1000, height: 2)
        let enemy = EnemyState(id: 1001, position: SIMD3(30,0,30))
        let game = scene([original], player: SIMD3(0,0,3), enemies: [enemy])
        game.damageCover(index: 0, amount: 1000)
        let record = try #require(game.coverDebris.first), id = try #require(record.solidObstacleID)
        let index = try #require(game.obstacles.firstIndex { $0.id == id })
        let solid = game.obstacles[index]
        #expect(record.sourceObstacleID == 1000 && id != 1000 && id != 1001)
        #expect(record.position == original.position && record.size == original.size)
        #expect(solid.position == original.position && solid.size == SIMD3(original.size.x,0.5,original.size.z))
        #expect(solid.health == .infinity && !solid.destroyed)
        let low = game.wallHit(origin: SIMD3(0,0.25,3), direction: SIMD3(0,0,-1), maximumDistance: 6)
        #expect(low.obstacleIndex == index)
        let high = game.wallHit(origin: SIMD3(0,0.75,3), direction: SIMD3(0,0,-1), maximumDistance: 6)
        #expect(high.obstacleIndex == nil && high.distance == 6)
        #expect(game.blocked(.zero) && !game.blocked(SIMD3(0,0.5,0)))
        _ = game.drainEvents()
        game.damageCover(index: index, amount: 1_000_000)
        #expect(game.coverDebris.count == 1 && game.score == 25)
        #expect(game.drainEvents().isEmpty)
        var input = GameInput();input.pitch = -0.49;input.aim = true
        game.step(deltaTime: 1.0/120, input: input)
        #expect(game.fire())
        let events = game.drainEvents(), shots = events.filter { $0.kind == .shot }
        #expect(shots.count == 1 && shots.first?.surfaceImpact?.obstacleID == id)
        #expect(!events.contains { $0.kind == .coverDestroyed || $0.kind == .explosion })
        #expect(game.score == 25 && game.coverDebris.count == 1 && game.weapons[.rifle]?.ammo == 29)
    }

    @Test func hillsideConcreteExtendsBelowTerrainWithoutChangingItsTop() throws {
        let terrain = TerrainProfile.battlefield
        let original = Obstacle(id: 801, kind: .barrier, position: SIMD3(14,0,29), size: SIMD3(5.4,1.05,0.85))
        let game = CombatSimulation(world: [original], startingWave: 3, terrain: terrain)
        let originalBase = game.obstacles[0].position.y
        game.damageCover(index: 0, amount: 1000)
        let id = try #require(game.coverDebris.first?.solidObstacleID)
        let index = try #require(game.obstacles.firstIndex { $0.id == id })
        let solid = game.obstacles[index]
        #expect(solid.minimum.y < originalBase - 0.1)
        #expect(abs(solid.maximum.y - (originalBase + 0.5)) < 0.00001)
        #expect(solid.size.x == original.size.x && solid.size.z == original.size.z)
        // Include exact corners and interior points on both halves of the
        // height-field triangles, not only the centre used for original cover.
        for row in 0...8 { for column in 0...32 {
            let x = min(solid.maximum.x, solid.minimum.x + solid.size.x * Float(column)/32)
            let z = min(solid.maximum.z, solid.minimum.z + solid.size.z * Float(row)/8)
            let ground = terrain.height(x: x, z: z)
            #expect(solid.minimum.y <= ground + 0.00001)
            let origin = SIMD3(x, solid.maximum.y + 3, z)
            let hit = game.wallHit(origin: origin, direction: SIMD3(0,-1,0), maximumDistance: 10)
            let expected = origin.y - max(ground, solid.maximum.y)
            #expect(abs(hit.distance - expected) < 0.0001)
            if ground < solid.maximum.y - 0.0001 { #expect(hit.obstacleIndex == index) }
            else if ground > solid.maximum.y + 0.0001 { #expect(hit.hitGround) }
        } }
        var filledSideHits = 0
        for column in 1..<32 {
            let x = solid.minimum.x + solid.size.x * Float(column)/32
            let faceZ = solid.maximum.z
            let faceGround = terrain.height(x: x, z: faceZ)
            let rayY = (faceGround + originalBase)*0.5
            let origin = SIMD3(x,rayY,faceZ + 0.04)
            guard faceGround < originalBase - 0.05,
                  terrain.height(x: x, z: origin.z) < rayY - 0.001 else { continue }
            let hit = game.wallHit(origin: origin, direction: SIMD3(0,0,-1), maximumDistance: 0.08)
            #expect(hit.obstacleIndex == index && abs(hit.distance - 0.04) < 0.0001)
            filledSideHits += 1
        }
        #expect(filledSideHits > 0)
    }

    @Test func raisedConcreteRemainsDoNotGrowAColumnDownToTerrain() throws {
        let original = barrier(position: SIMD3(14,4,29))
        let game = CombatSimulation(world: [original], startingWave: 3, terrain: .battlefield)
        let originalBase = game.obstacles[0].position
        game.damageCover(index: 0, amount: 1000)
        let id = try #require(game.coverDebris.first?.solidObstacleID)
        let solid = try #require(game.obstacles.first { $0.id == id })
        #expect(solid.position == originalBase && solid.size.y == 0.5)
        let origin = SIMD3(originalBase.x,originalBase.y - 0.2,solid.maximum.z + 1)
        let hit = game.wallHit(origin: origin, direction: SIMD3(0,0,-1), maximumDistance: 2)
        #expect(hit.obstacleIndex == nil && hit.distance == 2)
    }

    @Test func aWholeBarrelChainFinishesBeforeNewConcreteCanShieldIt() throws {
        let first = Obstacle(id: 10, kind: .barrel, position: SIMD3(-2,0,-2), size: SIMD3(0.8,1.15,0.8))
        let second = Obstacle(id: 11, kind: .barrel, position: SIMD3(0,0,-2), size: SIMD3(0.8,1.15,0.8))
        let wall = Obstacle(id: 12, kind: .barrier, position: .zero, size: SIMD3(6,1.05,0.4))
        let hidden = Obstacle(id: 13, kind: .crate, position: SIMD3(0,0,2), size: SIMD3(1,0.25,0.8))
        let game = scene([first,second,wall,hidden])
        game.damageCover(index: 0, amount: 60)
        #expect(game.obstacles.prefix(4).allSatisfy { $0.destroyed })
        #expect(game.score == 100 && game.coverDebris.count == 4)
        let events = game.drainEvents()
        #expect(events.filter { $0.kind == .explosion }.count == 2)
        #expect(Set(events.filter { $0.kind == .coverDestroyed }.map(\.id)) == Set([10,11,12,13]))
        // This exact second-blast path is blocked by the newly added rest. The
        // crate's destruction above proves the rest was absent during the chain.
        #expect(!game.clearLine(SIMD3(0,0.73,-2), SIMD3(0,0.25,1.6)))
        let concrete = try #require(game.coverDebris.first { $0.sourceObstacleID == 12 })
        #expect(concrete.solidObstacleID != nil)
        game.damageCover(index: 0, amount: 1000);game.damageCover(index: 1, amount: 1000)
        #expect(game.drainEvents().isEmpty && game.score == 100 && game.coverDebris.count == 4)
    }

    @Test func lifetimesFollowObjectTypesAndDecorativePiecesNeverBlock() {
        let kinds: [ObstacleKind] = [.crate,.barrel,.container,.barrier]
        let world = kinds.enumerated().map { i,kind in
            Obstacle(id: 30+i, kind: kind, position: SIMD3(Float(i)*15-25,0,0), size: SIMD3(2,2,1))
        }
        let game = scene(world)
        for index in world.indices { game.damageCover(index: index, amount: 1000) }
        #expect(game.coverDebris.map(\.lifetime) == [12,8,15,20])
        #expect(game.coverDebris.prefix(3).allSatisfy { $0.solidObstacleID == nil })
        #expect(game.coverDebris.allSatisfy { $0.createdAt == 0 })
        #expect(!game.blocked(world[0].position) && !game.blocked(world[1].position) && !game.blocked(world[2].position))
        advance(game, 8.1)
        #expect(Set(game.coverDebris.map(\.kind)) == Set([.crate,.container,.barrier]))
        advance(game, 4)
        #expect(Set(game.coverDebris.map(\.kind)) == Set([.container,.barrier]))
        advance(game, 3)
        #expect(game.coverDebris.count == 1 && game.coverDebris.first?.kind == .barrier)
        advance(game, 5)
        #expect(game.coverDebris.isEmpty && game.obstacles.count == world.count)
        #expect(game.score == 100)
    }

    @Test func playerLandsOnTheRestPauseFreezesItAndExpirationRemovesSupport() throws {
        let game = scene([barrier(height: 2)], player: SIMD3(0,2,0))
        game.damageCover(index: 0, amount: 1000)
        let id = try #require(game.coverDebris.first?.solidObstacleID)
        advance(game, 0.7)
        #expect(game.player.grounded && abs(game.player.position.y - 0.5) < 0.0001)
        let before = game.elapsed
        for delta in [Double(0), -1, .nan, .infinity] { game.step(deltaTime: delta, input: GameInput()) }
        #expect(game.elapsed == before && game.coverDebris.count == 1)
        advance(game, 19.35)
        #expect(game.coverDebris.isEmpty && !game.obstacles.contains { $0.id == id })
        #expect(!game.player.grounded && game.player.position.y < 0.5)
        advance(game, 0.5)
        #expect(game.player.grounded && abs(game.player.position.y) < 0.0001)
        #expect(game.score == 25)
        #expect(game.drainEvents().filter { $0.kind == .coverDestroyed }.count == 1)
    }

    @Test func destructionStillCancelsMantlingOntoTheOriginalObject() {
        let container = Obstacle(id: 6, kind: .container, position: .zero, size: SIMD3(4,3.1,8))
        let game = scene([container], player: SIMD3(0,0,5))
        #expect(game.mantle())
        advance(game, 0.3)
        game.damageCover(index: 0, amount: 1000)
        advance(game, 0.9)
        #expect(game.climbProgress == nil && game.player.grounded)
        #expect(abs(game.player.position.y) < 0.0001)
        #expect(game.coverDebris.count == 1 && game.coverDebris[0].solidObstacleID == nil)
    }

    @Test func thePursuingSoldierActuallyJumpsTheConcreteRestAndLands() {
        let wall = barrier(position: SIMD3(0,0,1))
        var enemy = EnemyState(id: 1, position: SIMD3(0,0,4));enemy.yaw = .pi
        let game = scene([wall], player: SIMD3(0,0,-38), enemies: [enemy])
        game.damageCover(index: 0, amount: 1000)
        var jumps = 0, grounded = true, highest: Float = 0
        for _ in 0..<360 {
            game.step(deltaTime: 1.0/120, input: GameInput())
            let current = game.enemies[0]
            if grounded && !current.grounded && current.verticalVelocity > 0 { jumps += 1 }
            grounded = current.grounded;highest = max(highest,current.position.y)
        }
        #expect(jumps == 1 && highest > 1)
        #expect(game.enemies[0].position.z < 0.2 && game.enemies[0].grounded)
    }

    @Test func navigationRefreshesForTheNewTraversableRest() {
        let wall = Obstacle(id: 8, kind: .barrier, position: .zero, size: SIMD3(76,2,0.85))
        let game = scene([wall]), from = SIMD3<Float>(0,0,-10), to = SIMD3<Float>(0,0,10)
        #expect(!game.hasReachableRoute(from: from, to: to))
        game.damageCover(index: 0, amount: 1000)
        #expect(game.hasReachableRoute(from: from, to: to))
        #expect(game.blocked(.zero))
        advance(game, 20.1)
        #expect(!game.blocked(.zero) && game.hasReachableRoute(from: from, to: to))
    }

    @Test func evictionExpirationAndRestartKeepBothStateAndCollidersBounded() throws {
        let world = (0..<32).map { i in
            barrier(id: 500+i, position: SIMD3(Float(i%8)*6-21,0,Float(i/8)*12-18))
        }
        let game = scene(world)
        for original in world {
            let index = try #require(game.obstacles.firstIndex { $0.id == original.id })
            game.damageCover(index: index, amount: 1000)
            #expect(game.coverDebris.count <= CoverDebrisState.maximumCount)
            #expect(game.obstacles.count <= world.count + CoverDebrisState.maximumCount)
        }
        #expect(game.coverDebris.count == 24)
        let ids = game.coverDebris.compactMap(\.solidObstacleID)
        #expect(ids.count == 24 && Set(ids).count == 24)
        #expect(Set(ids).isDisjoint(with: Set(world.map(\.id))))
        #expect(game.coverDebris.first?.sourceObstacleID == world[8].id)
        advance(game, 20.1)
        #expect(game.coverDebris.isEmpty && game.obstacles.count == world.count)
        #expect(game.score == world.count*25)
        let restarted = scene(world)
        #expect(restarted.coverDebris.isEmpty && restarted.obstacles.count == world.count)
        #expect(restarted.obstacles.allSatisfy { $0.damageStage == .intact && $0.health == $0.maximumHealth })
    }
}
