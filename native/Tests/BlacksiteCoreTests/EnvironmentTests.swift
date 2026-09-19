import Foundation
import Testing
import simd
@testable import BlacksiteCore

@Suite(.serialized)
struct EnvironmentTests {
    private func zone(id: String = "brush", center: SIMD2<Float> = SIMD2(0, 15),
                      radii: SIMD2<Float> = SIMD2(3, 4), height: Float = 1.2) -> EnvironmentZone {
        EnvironmentZone(id: id, center: center, radii: radii, height: height, density: 0.7, kind: .brush)
    }
    private func map(zones: [EnvironmentZone], terrain: TerrainProfile = .flat,
                     offset: SIMD2<Float> = .zero, obstacles: [Obstacle] = []) throws -> MapDefinition {
        func p(_ x: Float, _ z: Float) -> SIMD3<Float> { SIMD3(x + offset.x, 0, z + offset.y) }
        var environment = MapEnvironmentDefinition(); environment.vegetationZones = zones
        return try MapDefinition(id: "vegetation-test", displayName: "Vegetation", minimum: p(-24,-24), maximum: p(24,24),
            terrain: terrain, obstacles: obstacles, playerStart: PlayerState(position: p(0,15)),
            reinforcementEntries: [p(0,-20)], waveStaging: [p(0,-12)], extraction: p(0,-20),
            dataSite: p(-12,10), radioSite: p(12,10),
            roads: [MapSurfaceRegion(minimum: offset + SIMD2(10,5), maximum: offset + SIMD2(14,20), material: .asphalt)],
            environment: environment)
    }
    private func game(map: MapDefinition, prone: Bool = false, playerPosition: SIMD3<Float>? = nil,
                      enemies: Bool = true) -> CombatSimulation {
        var player = PlayerState(position: playerPosition ?? map.grounded(map.playerStart.position))
        player.prone = prone; player.height = prone ? 0.57 : 1.72
        return CombatSimulation(seed: 41, world: map.obstacles, startingPlayer: player,
            startingEnemies: enemies ? [EnemyState(id: 1, position: SIMD3(player.position.x, 0, player.position.z - 15))] : [],
            startingWave: 3, map: map)
    }
    private func advance(_ game: CombatSimulation, ticks: Int, input: GameInput = GameInput()) {
        for _ in 0..<ticks { game.step(deltaTime: 1.0 / 120, input: input) }
    }

    @Test func finiteSegmentsMeasureActualEllipseChordsAndOnlyVegetationBeforeTheTarget() {
        let patch = zone(center: .zero, radii: SIMD2(2,3))
        #expect(abs(patch.pathLength(from: SIMD3(-5,0.5,0), to: SIMD3(5,0.5,0), terrain: .flat) - 4) < 0.0001)
        #expect(abs(patch.pathLength(from: SIMD3(0,0.5,-5), to: SIMD3(0,0.5,5), terrain: .flat) - 6) < 0.0001)
        #expect(abs(patch.pathLength(from: SIMD3(0,0.5,0), to: SIMD3(5,0.5,0), terrain: .flat) - 2) < 0.0001)
        #expect(patch.pathLength(from: SIMD3(-5,0.5,0), to: SIMD3(-3,0.5,0), terrain: .flat) == 0)
        #expect(patch.pathLength(from: SIMD3(-5,0.5,3), to: SIMD3(5,0.5,3), terrain: .flat) == 0)
        #expect(patch.pathLength(from: SIMD3(0,0.5,0), to: SIMD3(0,0.5,0), terrain: .flat) == 0)
        #expect(patch.pathLength(from: SIMD3(0,2,0), to: SIMD3(0,4,0), terrain: .flat) == 0)
        let center = patch.opticalDepth(from: SIMD3(-5,0.5,0), to: SIMD3(5,0.5,0), terrain: .flat)
        let edge = patch.opticalDepth(from: SIMD3(-5,0.5,2.9), to: SIMD3(5,0.5,2.9), terrain: .flat)
        #expect(center > 2 && center < 2.8 && edge > 0 && edge < center * 0.1)
        for end in [SIMD3<Float>(5,0.6,4), SIMD3(-5,0.4,4), SIMD3(1,0.5,-5)] {
            let start = SIMD3<Float>(-4,0.8,-4)
            #expect(abs(patch.pathLength(from: start, to: end, terrain: .flat) - patch.pathLength(from: end, to: start, terrain: .flat)) < 0.0001)
            #expect(abs(patch.opticalDepth(from: start, to: end, terrain: .flat) - patch.opticalDepth(from: end, to: start, terrain: .flat)) < 0.0001)
        }
        #expect(patch.pathLength(from: SIMD3(.nan,0,0), to: .zero, terrain: .flat) == 0)
    }

    @Test func terrainRelativePlantLayersClipAcrossHighSlopesAndRealTriangleBoundaries() throws {
        let field = try TerrainHeightField(origin: SIMD2(100,200), width: 10, depth: 10,
            samples: (0..<100).map { 45 + Float($0 % 10) * 0.3 + Float($0 / 10) * 0.1 })
        let terrain = TerrainProfile.heightField(field)
        let patch = zone(center: SIMD2(104,204), radii: SIMD2(3,3), height: 1)
        let from = SIMD3<Float>(100,46.9,204), to = SIMD3<Float>(108,46.9,204)
        #expect(abs(patch.pathLength(from: from, to: to, terrain: terrain) - 10.0 / 3) < 0.0001)
        #expect(abs(patch.pathLength(from: from, to: to, terrain: terrain) - patch.pathLength(from: to, to: from, terrain: terrain)) < 0.0001)
        #expect(patch.pathLength(from: SIMD3(100,1,204), to: SIMD3(108,1,204), terrain: terrain) == 0)
        let hill = zone(center: SIMD2(-11,30), radii: SIMD2(3,4))
        let a = SIMD3<Float>(-15,2.4,26), b = SIMD3<Float>(-7,2.1,34)
        var sampled: Float = 0
        for i in 0..<20000 {
            if hill.contains(a + (b - a) * ((Float(i) + 0.5) / 20000), terrain: .battlefield) { sampled += simd_distance(a,b) / 20000 }
        }
        #expect(abs(hill.pathLength(from: a, to: b, terrain: .battlefield) - sampled) < 0.002)
        #expect(abs(hill.pathLength(from: a, to: b, terrain: .battlefield) - hill.pathLength(from: b, to: a, terrain: .battlefield)) < 0.0001)
    }

    @Test func localSamplesSeparateGroundLeavesAndLiveRoofSupport() throws {
        let patch = zone(), roof = Obstacle(id: 19, kind: .container, position: SIMD3(0,0,15), size: SIMD3(4,2.8,6))
        let definition = try map(zones: [patch], obstacles: [roof]), simulation = game(map: definition, enemies: false)
        let ground = simulation.environmentSample(at: SIMD3(0,0,15))
        #expect(ground.surfaceMaterial == .soil && ground.camouflageGround == .vegetation && ground.foliageDensity == 0.7)
        let top = simulation.environmentSample(at: SIMD3(0,2.8,15))
        #expect(top.surfaceMaterial == .metal && top.camouflageGround == .none && top.foliageDensity == 0)
        #expect(top.supportingObstacleID == 19 && top.supportHeight == 2.8)
        let high = simulation.environmentSample(at: SIMD3(2.5,1.5,15))
        #expect(high.camouflageGround == .none && high.foliageDensity == 0)
        let road = simulation.environmentSample(at: SIMD3(12,0,15))
        #expect(road.surfaceMaterial == .asphalt && road.camouflageGround == .none && road.foliageDensity == 0)
        simulation.damageCover(index: 0, amount: 10_000)
        #expect(simulation.environmentSample(at: SIMD3(0,2.8,15)).supportingObstacleID == nil)
        #expect(simulation.environmentSample(at: SIMD3(0,0,15)).camouflageGround == .vegetation)

        let terrain = MapDefinition.testRange.terrain, elevated = zone(center: SIMD2(110,215))
        let foreign = try map(zones: [elevated], terrain: terrain, offset: SIMD2(110,200))
        let highGame = game(map: foreign, enemies: false)
        let feet = SIMD3<Float>(110,terrain.height(x:110,z:215),215)
        let sample = highGame.environmentSample(at: feet)
        #expect(sample.groundHeight > 18 && sample.camouflageGround == .vegetation && sample.foliageDensity > 0)
        #expect(highGame.environmentSample(at: feet + SIMD3(0,1.3,0)).foliageDensity == 0)
    }

    @Test func bodyHeightAndActualViewDirectionDetermineRecognitionWithoutRoofBonuses() throws {
        let definition = try map(zones: [zone()])
        let standing = game(map: definition), prone = game(map: definition, prone: true)
        for offset in [SIMD3<Float>(0,1.65,-15), SIMD3(0,1.65,15), SIMD3(15,1.65,0), SIMD3(-15,1.65,0)] {
            let observer = SIMD3<Float>(0,0,15) + offset
            let standFactor = standing.vegetationRecognitionFactor(from: observer)
            let proneFactor = prone.vegetationRecognitionFactor(from: observer)
            #expect(standFactor > proneFactor && standFactor > 0.5 && standFactor <= 1)
            #expect(proneFactor >= 0.25 && proneFactor < 0.8)
        }
        let high = game(map: definition, playerPosition: SIMD3(0,2.8,15))
        #expect(high.vegetationRecognitionFactor(from: SIMD3(0,3.5,0)) == 1)
        let outside = game(map: definition, playerPosition: SIMD3(5,0,15))
        #expect(outside.vegetationRecognitionFactor(from: SIMD3(5,1.65,0)) == 1)
        let wall = Obstacle(id: 8, kind: .bunker, position: SIMD3(0,0,7), size: SIMD3(12,4,1))
        let blocked = game(map: try map(zones: [zone()], obstacles: [wall]))
        #expect(blocked.vegetationRecognitionFactor(from: SIMD3(0,1.65,0)) == 0)
        advance(blocked, ticks: 120)
        #expect(blocked.enemies[0].detectionProgress == 0 && !blocked.enemies[0].seesPlayer)
    }

    @Test func quietProneRecognitionIsDelayedButFiniteAndContactStaysConfirmed() throws {
        let open = try map(zones: []), foliage = try map(zones: [zone()])
        func detect(_ simulation: CombatSimulation) -> Double {
            for _ in 0..<720 {
                simulation.step(deltaTime: 1.0 / 120, input: GameInput())
                if simulation.enemies[0].seesPlayer { return simulation.elapsed }
            }
            return .infinity
        }
        let openStanding = detect(game(map: open)), openProne = detect(game(map: open, prone: true))
        let brushStanding = detect(game(map: foliage)), brushProneGame = game(map: foliage, prone: true)
        let brushProne = detect(brushProneGame)
        #expect(openStanding < openProne && openProne < brushProne)
        #expect(brushStanding < brushProne && brushProne < 4)
        #expect(brushStanding >= openStanding)
        let alerts = brushProneGame.drainEvents().filter { $0.kind == .enemyAlert }.count
        #expect(alerts == 1)
        advance(brushProneGame, ticks: 60)
        #expect(brushProneGame.enemies[0].seesPlayer && brushProneGame.enemies[0].awareness == .engaged)
        #expect(!brushProneGame.drainEvents().contains { $0.kind == .enemyAlert })
    }

    @Test func plantsDoNotChangeShotsBlastDamageOrHardGeometry() throws {
        let open = game(map: try map(zones: [])), plants = game(map: try map(zones: [zone()]))
        for simulation in [open,plants] {
            let direction = simd_normalize(EnemyPose(simulation.enemies[0]).bodyCenter - simulation.eyePosition)
            #expect(simulation.traceShot(origin: simulation.eyePosition, direction: direction).enemyIndex == 0)
            #expect(simulation.clearLine(simulation.eyePosition, EnemyPose(simulation.enemies[0]).eyePosition))
            #expect(simulation.fire())
        }
        #expect(open.enemies[0].health == plants.enemies[0].health && open.enemies[0].health < 100)
        #expect(open.drainEvents().filter { $0.kind == .shot }.map(\.endPosition) == plants.drainEvents().filter { $0.kind == .shot }.map(\.endPosition))
        open.explode(at: SIMD3(0,1,2)); plants.explode(at: SIMD3(0,1,2))
        #expect(open.enemies[0].health == plants.enemies[0].health && open.player.health == plants.player.health)
    }

    @Test func boundedOverlapsValidationAndLegacyIsolationKeepQueriesFinite() throws {
        let zones = (0..<16).map { zone(id: "patch-\($0)", radii: SIMD2(1.7,2.7)) }, definition = try map(zones: zones)
        let game = game(map: definition, prone: true)
        #expect(definition.vegetationOpticalDepth(from: SIMD3(0,0.4,0), to: SIMD3(0,0.4,15)) == 12)
        #expect(game.vegetationRecognitionFactor(from: SIMD3(0,1.65,0)) >= 0.25)
        #expect(throws: MapValidationError.self) { try map(zones: zones + [zone(id: "17")]) }
        #expect(throws: MapValidationError.self) { try map(zones: [zone(), zone()]) }
        #expect(throws: MapValidationError.self) { try map(zones: [zone(radii: SIMD2(17,1))]) }
        #expect(zone().requiredPlantCount == 83)
        #expect(zones.allSatisfy { $0.requiredPlantCount == 32 })
        #expect(zones.reduce(0) { $0 + $1.requiredPlantCount } == EnvironmentZone.maximumTotalPlantCount)
        // Each zone is valid alone, but seven 83-plant patches exceed the map budget.
        #expect(throws: MapValidationError.self) { try map(zones: (0..<7).map { zone(id: "large-\($0)") }) }
        #expect(throws: MapValidationError.self) { try map(zones: [zone(radii: SIMD2(4,4))]) }
        for radii in [SIMD2<Float>(0.02,1), SIMD2(1,0.02)] {
            #expect(throws: MapValidationError.self) { try map(zones: [zone(radii: radii)]) }
        }
        #expect(throws: MapValidationError.self) { try map(zones: [zone(height: 0.2)]) }
        let box = EnvironmentZone(id: "box", minimum: SIMD3(-1,0,-1), maximum: SIMD3(1,1,1), density: 0.5)
        #expect(box.requiredPlantCount == 9)
        #expect(zone(radii: SIMD2(.infinity,1)).requiredPlantCount == Int.max)
        #expect(CombatSimulation(world: []).map.environment.vegetationZones.isEmpty)
        let blacksite = MapDefinition.blacksite
        #expect(blacksite.environment.vegetationZones.count == 5)
        let actual = CombatSimulation(map: blacksite)
        for patch in blacksite.environment.vegetationZones {
            let point = SIMD3(patch.center.x, blacksite.terrain.height(x:patch.center.x,z:patch.center.y), patch.center.y)
            #expect(actual.environmentSample(at: point).camouflageGround == .vegetation)
            #expect(actual.environmentSample(at: point).foliageDensity > 0)
            #expect(!actual.obstacles.contains { point.x >= $0.minimum.x && point.x <= $0.maximum.x && point.z >= $0.minimum.z && point.z <= $0.maximum.z })
        }
    }

    @Test func recognitionAndPauseRemainDeterministicAcrossRenderFrameRates() throws {
        let definition = try map(zones: [zone()])
        let slow = game(map: definition, prone: true), fast = game(map: definition, prone: true)
        for _ in 0..<90 { slow.step(deltaTime: 1.0 / 30, input: GameInput()) }
        advance(fast, ticks: 360)
        #expect(slow.enemies[0].position == fast.enemies[0].position)
        #expect(slow.enemies[0].awareness == fast.enemies[0].awareness)
        #expect(slow.enemies[0].detectionProgress == fast.enemies[0].detectionProgress)
        let progress = fast.enemies[0].detectionProgress, time = fast.elapsed
        for _ in 0..<100 { fast.step(deltaTime: 0, input: GameInput()) }
        #expect(fast.elapsed == time && fast.enemies[0].detectionProgress == progress)
    }
}
