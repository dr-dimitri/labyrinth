import Testing
import simd
@testable import BlacksiteCore

@Suite(.serialized)
struct MapDefinitionTests {
    private func fixture(obstacles: [Obstacle] = [], start: SIMD3<Float> = SIMD3(110, 0, 230),
                         entries: [SIMD3<Float>] = [SIMD3(110, 0, 202)], scenery: MapSceneryDefinition? = nil,
                         resources: MapResourceReferences = MapResourceReferences()) throws -> MapDefinition {
        try MapDefinition(id: "validation-fixture", displayName: "Validation", minimum: SIMD3(98, 0, 198), maximum: SIMD3(122, 0, 234),
                          terrain: MapDefinition.testRange.terrain, obstacles: obstacles, playerStart: PlayerState(position: start),
                          reinforcementEntries: entries, waveStaging: [SIMD3(118, 0, 220)],
                          extraction: SIMD3(110, 0, 202), dataSite: SIMD3(102, 0, 228), radioSite: SIMD3(118, 0, 218),
                          scenery: scenery, resources: resources)
    }
    private func advance(_ game: CombatSimulation, ticks: Int, input: GameInput = GameInput(), eliminate: Bool = false) {
        for _ in 0..<ticks {
            game.step(deltaTime: 1.0 / 120, input: input)
            if eliminate {
                for index in game.enemies.indices where game.enemies[index].health > 0 { game.damageEnemy(index: index, amount: 10_000) }
            }
        }
    }
    private func walk(_ game: CombatSimulation, to target: SIMD2<Float>) -> Bool {
        for _ in 0..<2000 {
            let delta = target - SIMD2(game.player.position.x, game.player.position.z)
            if simd_length(delta) < 0.08 { return true }
            var input = GameInput(); input.moveForward = 1; input.yaw = atan2(-delta.x, -delta.y)
            advance(game, ticks: 1, input: input, eliminate: true)
        }
        return false
    }

    @Test func migratedBlacksitePreservesItsAuthoredContractAndValidates() throws {
        let map = MapDefinition.blacksite
        try map.validateGameplay()
        #expect(map.id == "blacksite" && map.version == 1)
        #expect(map.obstacles.count == 25 && map.minimum == GameMap.minimum && map.maximum == GameMap.maximum)
        #expect(map.extraction == GameMap.extraction && map.dataSite == GameMap.dataSite && map.radioSite == GameMap.radioSite)
        #expect(map.environment.shadowExtent == 65 && map.environment.shadowTarget == .zero)
        let first = CombatSimulation(seed: 41), second = CombatSimulation(map: .blacksite, seed: 41)
        advance(first, ticks: 240); advance(second, ticks: 240)
        #expect(first.player.position == second.player.position && first.wave == second.wave)
        #expect(first.enemies.map(\.position) == second.enemies.map(\.position))
        #expect(first.enemies.map(\.id) == second.enemies.map(\.id))
    }

    @Test func translatedElevatedMapOwnsActorGroundingBoundsRoutesAndSafeEntries() throws {
        let map = MapDefinition.testRange
        try map.validateGameplay()
        let game = CombatSimulation(map: map, seed: 41)
        #expect(game.player.position == map.grounded(map.playerStart.position))
        #expect(game.player.position.y > 18 && game.extractionPosition == map.grounded(map.extraction))
        #expect(game.obstacles.allSatisfy { $0.position.x >= map.minimum.x && $0.position.z >= map.minimum.z && $0.position.y > 18 })
        let route = game.findPath(from: game.player.position, to: game.extractionPosition)
        #expect(!route.isEmpty && game.hasReachableRoute(from: game.player.position, to: game.extractionPosition))
        #expect(route.allSatisfy { $0.x > map.minimum.x && $0.x < map.maximum.x && $0.z > map.minimum.z && $0.z < map.maximum.z && $0.y > 18 })
        game.spawnWave()
        #expect(game.aliveCount > 0 && game.remainingEnemies == 5)
        #expect(game.enemies.allSatisfy { map.reinforcementEntries.contains(SIMD3($0.position.x, 0, $0.position.z)) && game.reinforcementIsHidden(at: $0.position) })
        var right = GameInput(); right.moveRight = 1
        advance(game, ticks: 600, input: right, eliminate: true)
        #expect(game.player.position.x > 120 && game.player.position.x <= map.maximum.x - 0.32 + 0.001)
    }

    @Test func profileOverridesStayConsistentWithThePublishedMapAndLegacyScenarios() {
        let legacy = CombatSimulation(terrain: .flat)
        #expect(legacy.terrain == .flat && legacy.map.terrain == .flat && legacy.player.position.y == 0)
        let isolated = CombatSimulation(world: [])
        #expect(isolated.terrain == .flat && isolated.map.terrain == .flat)
        let translated = CombatSimulation(map: .testRange, terrainOverride: .flat)
        #expect(translated.map.id == "test-range" && translated.terrain == translated.map.terrain)
        #expect(translated.player.position == MapDefinition.testRange.playerStart.position)
        #expect(translated.obstacles.allSatisfy { $0.position.y == 0 })
        #expect(translated.hasReachableRoute(from: translated.player.position, to: translated.extractionPosition))
    }

    @Test func customTerrainRaysUseActualCeilingAndTheSameTriangleNormal() throws {
        let terrain = MapDefinition.testRange.terrain
        let origin = SIMD3<Float>(110, 18.9, 224)
        let hit = try #require(terrain.rayIntersection(origin: origin, direction: SIMD3(1, 0, 0), maximumDistance: 12))
        let point = origin + SIMD3(hit.distance, 0, 0)
        #expect(hit.distance > 2 && hit.distance < 4)
        #expect(abs(point.y - terrain.height(x: point.x, z: point.z)) < 0.0001)
        #expect(simd_distance(hit.normal, terrain.normal(x: point.x, z: point.z)) < 0.0001)
        let down = try #require(terrain.rayIntersection(origin: SIMD3(110, 80, 224), direction: SIMD3(0, -3, 0), maximumDistance: 100))
        #expect(abs(down.distance - 61.2) < 0.0001)
        #expect(terrain.rayIntersection(origin: SIMD3(110, 80, 224), direction: SIMD3(1, 0, 0), maximumDistance: 100) == nil)
    }

    @Test func surfaceMaterialAndRaisedSupportsBelongToSelectedMapInsteadOfOldRoad() throws {
        let map = MapDefinition.testRange, game = CombatSimulation(map: .testRange)
        #expect(map.groundMaterial(at: SIMD3(110, 0, 224)) == .concrete)
        #expect(map.groundMaterial(at: .zero) == .soil)
        let surface = try #require(map.groundedSupportSurfaces.first)
        #expect(surface.position.y > 18 && abs(surface.maximum.y - 18.815) < 0.0001)
        let roof = try #require(game.obstacles.first { $0.id == 301 })
        let origin = roof.position + SIMD3(0, roof.size.y + 2, 0)
        let hit = game.traceShot(origin: origin, direction: SIMD3(0, -1, 0))
        let impact = try #require(game.makeSurfaceImpact(for: hit, at: origin + SIMD3(0, -hit.distance, 0)))
        #expect(impact.obstacleID == 301 && impact.material == .metal)
        #expect(map.levelProp(for: roof) == nil)
    }

    @Test func malformedDefinitionsExplainBadBoundsIDsEntriesAndDisconnectedGoals() throws {
        #expect(throws: MapValidationError.self) { try fixture(start: .zero) }
        #expect(throws: MapValidationError.self) { try fixture(entries: []) }
        let duplicate = Obstacle(id: 7, kind: .crate, position: SIMD3(104, 0, 210), size: SIMD3(1, 1, 1))
        #expect(throws: MapValidationError.self) { try fixture(obstacles: [duplicate, duplicate]) }
        let wall = Obstacle(id: 8, kind: .bunker, position: SIMD3(110, 0, 214), size: SIMD3(24, 5, 1))
        let disconnected = try fixture(obstacles: [wall])
        do { try disconnected.validateGameplay(); Issue.record("A sealed extraction route must fail validation") }
        catch let error as MapValidationError { #expect(error.message.contains("Evakuierung") && error.message.contains("erreichbar")) }
        #expect(throws: TerrainDefinitionError.self) { try TerrainHeightField(origin: .zero, width: 2, depth: 2, samples: [0, 1, 2, .nan]) }
        #expect(throws: TerrainDefinitionError.self) { try TerrainHeightField(origin: SIMD2(0.5, 0), width: 2, depth: 2, samples: [0, 0, 0, 0]) }
    }

    @Test func translatedDataMissionUsesItsOwnAnchorsAndCanFinish() {
        let map = MapDefinition.testRange
        let game = CombatSimulation(difficulty: .easy, seed: 41, world: map.obstacles,
            startingPlayer: PlayerState(position: map.grounded(map.dataSite)), mission: .recoverData, map: map)
        #expect(game.missionInteractionAvailable && game.missionStatus.objectivePosition == map.grounded(map.dataSite))
        var held = GameInput(); held.interact = true
        advance(game, ticks: 96, input: held, eliminate: true)
        #expect(game.missionStatus.phase == .extract && game.missionStatus.objectivePosition == map.grounded(map.extraction))
        #expect(walk(game, to: SIMD2(110, 228)))
        #expect(walk(game, to: SIMD2(110, 202)))
        advance(game, ticks: 360, eliminate: true)
        #expect(game.state == .won && game.missionStatus.phase == .completed)
    }

    @Test func rendererMetadataFailsEarlyForUnboundedGeometryAndInvalidReferences() throws {
        let derived = try fixture()
        #expect(derived.scenery.denseMinimum.x == 98 && derived.scenery.denseMinimum.y == 198)
        #expect(derived.environment.shadowTarget.x == 110 && derived.environment.shadowTarget.y > 18)
        var scenery = MapDefinition.testRange.scenery
        scenery.renderMaximum.x = .infinity
        #expect(throws: MapValidationError.self) { try fixture(scenery: scenery) }
        scenery = MapDefinition.testRange.scenery
        scenery.denseMaximum.x = 500
        #expect(throws: MapValidationError.self) { try fixture(scenery: scenery) }
        scenery = MapDefinition.testRange.scenery
        scenery.signs = [MapSign(position: .zero, width: 2, materialID: 21, ownerID: 999)]
        #expect(throws: MapValidationError.self) { try fixture(scenery: scenery) }
        #expect(throws: MapValidationError.self) { try fixture(resources: MapResourceReferences(texturePaths: [24: "textures/ignored.jpg"])) }
        #expect(throws: MapValidationError.self) { try fixture(resources: MapResourceReferences(soldierAsset: "../outside.glb")) }
        let paths = [9: "textures/atlas.jpg"]
        let cropped = try fixture(resources: MapResourceReferences(texturePaths: paths, textureCrops: [9: SIMD4(0, 0, 0.25, 0.5)]))
        #expect(cropped.resources.textureCrops[9] == SIMD4(0, 0, 0.25, 0.5))
        #expect(throws: MapValidationError.self) {
            try fixture(resources: MapResourceReferences(texturePaths: paths, textureCrops: [9: SIMD4(0.8, 0, 0.25, 0.5)]))
        }
        #expect(throws: MapValidationError.self) {
            try fixture(resources: MapResourceReferences(textureCrops: [9: SIMD4(0, 0, 0.25, 0.5)]))
        }
        #expect(throws: MapValidationError.self) {
            try fixture(resources: MapResourceReferences(texturePaths: paths, textureCrops: [9: SIMD4(0, 0, .nan, 0.5)]))
        }
    }

    @Test func newSimulationOnAnotherMapClearsMutableWorldAndMissionState() {
        let old = CombatSimulation(map: .blacksite, mission: .recoverData)
        old.damageCover(index: 9, amount: 10_000); old.spawnWave()
        advance(old, ticks: 120)
        #expect(!old.coverDebris.isEmpty && old.elapsed > 0)
        let next = CombatSimulation(map: .testRange, mission: .secureRadio)
        #expect(next.elapsed == 0 && next.coverDebris.isEmpty && next.grenades.isEmpty && next.enemies.isEmpty)
        #expect(next.score == 0 && next.pendingReinforcements == 0 && next.missionStatus.phase == .activateRadio)
        #expect(next.obstacles.map(\.id) == [301, 302] && next.obstacles.allSatisfy { !$0.destroyed })
        #expect(next.map.scenery.trees.isEmpty && next.map.resources.texturePaths[9] == nil)
        #expect(next.hasReachableRoute(from: next.player.position, to: next.extractionPosition))
    }
}
