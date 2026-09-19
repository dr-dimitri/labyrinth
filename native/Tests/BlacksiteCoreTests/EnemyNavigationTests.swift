import Testing
import simd
@testable import BlacksiteCore

struct EnemyNavigationTests {
    private func westPanelScene(open: Bool) throws -> CombatSimulation {
        let map = MapDefinition.blacksite
        var player = PlayerState(position: map.grounded(SIMD3(-14.8, 0, 1.5)))
        player.yaw = -.pi / 2
        var enemy = EnemyState(id: 999, position: map.grounded(SIMD3(-16.8, 0, 1.5)))
        enemy.yaw = .pi / 2
        let game = CombatSimulation(difficulty: .easy, seed: 41, world: map.obstacles,
            startingPlayer: player, startingEnemies: [enemy], startingWave: 3, map: map)
        if open {
            let panel = try #require(game.obstacles.firstIndex { $0.id == 25 })
            game.damageCover(index: panel, amount: 10_000)
        }
        #expect(!game.blocked(player.position) && !game.blocked(enemy.position))
        #expect(game.hasReachableRoute(from: enemy.position, to: player.position))
        // Shoot away from the pane. The investigation must use the actual
        // heard source, with movement, terrain and enemy perception running.
        var shot = GameInput(); shot.yaw = player.yaw; shot.fire = true
        game.step(deltaTime: 1.0 / 120, input: shot)
        #expect(game.enemies[0].lastHeard?.kind == .gunshot)
        #expect(game.enemies[0].awareness == .investigating)
        return game
    }

    @Test func nearbySoundBehindIntactPanelUsesTheWalkableDetour() throws {
        let game = try westPanelScene(open: false)
        let panel = try #require(game.obstacles.first { $0.id == 25 })
        var input = GameInput(); input.yaw = game.player.yaw
        var crossing: SIMD3<Float>?
        for _ in 0..<720 {
            game.step(deltaTime: 1.0 / 120, input: input)
            let position = game.enemies[0].position
            if position.x > panel.maximum.x + 0.38 {
                crossing = position
                break
            }
        }
        let reached = try #require(crossing, "Guard should walk around the intact panel, not stop against it: \(game.enemies[0].position)")
        #expect(reached.z > 6.48, "The actual crossing must clear the southern frame ending at z=6.1")
        #expect(!game.obstacles.first(where: { $0.id == 25 })!.destroyed)
    }

    @Test func nearbySoundThroughOpenedPanelKeepsTheDirectApproach() throws {
        let game = try westPanelScene(open: true)
        let start = game.enemies[0].position
        var input = GameInput(); input.yaw = game.player.yaw
        for _ in 0..<20 { game.step(deltaTime: 1.0 / 120, input: input) }
        let position = game.enemies[0].position
        #expect(position.x > start.x + 0.7)
        #expect(abs(position.z - start.z) < 0.01)
        #expect(horizontalDistance(position, game.player.position) < 1.2)
        #expect(game.obstacles.first(where: { $0.id == 25 })!.destroyed)
    }
}
