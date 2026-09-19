import Testing
import simd
@testable import BlacksiteCore

struct TerrainTests {
    private let terrain = TerrainProfile.battlefield

    @Test func flatProfilePreservesLevelScenariosAndPaddedContacts() {
        let flat = TerrainProfile.flat
        #expect(flat.height(x: 10, z: -20) == 0)
        #expect(flat.normal(x: -4, z: 2) == SIMD3<Float>(0, 1, 0))
        let hit = flat.rayIntersection(origin: SIMD3(3, 10, -4), direction: SIMD3(0, -3, 0), maximumDistance: 20, padding: 0.25)
        #expect(abs((hit?.distance ?? -1) - 9.75) < 0.0001)
        #expect(flat.rayIntersection(origin: SIMD3(0, 1, 0), direction: SIMD3(1, 0, 0), maximumDistance: 100) == nil)
        #expect(flat.rayIntersection(origin: SIMD3(0, -1, 0), direction: SIMD3(0, 1, 0), maximumDistance: 1)?.distance == 0)
    }

    @Test func roadSpawnAndExtractionRemainFlatWhileNearbyHillsAreVisible() {
        for x in stride(from: Float(-6.5), through: 6.5, by: 0.5) {
            for z in stride(from: Float(-42), through: 42, by: 1) {
                #expect(terrain.height(x: x, z: z) == 0)
            }
        }
        #expect(terrain.height(x: 0, z: 32) == 0)
        #expect(terrain.height(x: 0, z: -35) == 0)
        #expect(terrain.height(x: -13, z: 24) >= 3)
        #expect(terrain.height(x: 16, z: 24) >= 4)
        #expect(terrain.height(x: -30, z: -31) <= -1.5)
        #expect(terrain.height(x: 32, z: 5) <= -1)
    }

    @Test func completePlayableGridHasBoundedHeightsAndWalkableSlopes() {
        for z in -42..<42 { for x in -38..<38 {
            for offset: Float in [0.2, 0.8] {
                let px = Float(x) + offset, pz = Float(z) + offset
                let height = terrain.height(x: px, z: pz)
                let normal = terrain.normal(x: px, z: pz)
                #expect(height >= -2.001 && height <= 5.001)
                #expect(abs(simd_length(normal) - 1) < 0.0001)
                #expect(normal.y > 0.78) // Less than approximately 39 degrees.
            }
        } }
    }

    @Test func originalStructureFootprintsHaveLevelFoundations() {
        // Intentionally independent of GameMap: terrain construction must not
        // recurse through a map whose object bases query this same height field.
        let footprints: [(Float, Float, Float, Float)] = [
            (-22, -12, 13, 13), (24, -27, 12, 14),
            (-15, 14, 3.6, 11), (15, -5, 11, 3.6), (-25, 26, 9, 3.6),
            (-3.9, 18, 5.4, 0.85), (5.5, 6, 5.8, 0.85),
            (-4, -9, 5.8, 0.85), (4.5, -24, 5.4, 0.85),
            (20, 19, 3.2, 2.6), (-9, -25, 2.8, 2.8),
            (27, 7, 3, 3), (-29, 4, 3.2, 3.2),
            (-12, -35, 7, 0.8), (12, -35, 7, 0.8),
            (10, -1, 0.8, 0.8), (-11, 11, 0.8, 0.8),
            (18, 17, 0.8, 0.8), (-12, -22, 0.8, 0.8),
        ]
        for (x, z, width, depth) in footprints {
            let base = terrain.height(x: x, z: z)
            for u: Float in [-0.5, 0, 0.5] { for v: Float in [-0.5, 0, 0.5] {
                #expect(abs(terrain.height(x: x + u * width, z: z + v * depth) - base) < 0.0001)
            } }
        }
    }

    @Test func renderedTriangleInterpolationAndNormalsMatchQueries() {
        for cell: SIMD2<Float> in [SIMD2(11, 25), SIMD2(-32, 32), SIMD2(33, 4), SIMD2(72, -48)] {
            let a = terrain.height(x: cell.x, z: cell.y)
            let b = terrain.height(x: cell.x + 1, z: cell.y)
            let c = terrain.height(x: cell.x, z: cell.y + 1)
            let d = terrain.height(x: cell.x + 1, z: cell.y + 1)
            for uv: SIMD2<Float> in [SIMD2(0.2, 0.3), SIMD2(0.8, 0.7), SIMD2(0.25, 0.75)] {
                let upper = uv.x + uv.y > 1
                let expected = upper ? b + c - d + (d - c) * uv.x + (d - b) * uv.y : a + (b - a) * uv.x + (c - a) * uv.y
                let expectedNormal = simd_normalize(upper ? SIMD3(c - d, 1, b - d) : SIMD3(a - b, 1, a - c))
                #expect(abs(terrain.height(x: cell.x + uv.x, z: cell.y + uv.y) - expected) < 0.0001)
                #expect(simd_dot(terrain.normal(x: cell.x + uv.x, z: cell.y + uv.y), expectedNormal) > 0.9999)
            }
        }
    }

    @Test func verticalRayContactsMatchTheRenderedSurfaceAndPadding() {
        for point: SIMD2<Float> in [SIMD2(0, 32), SIMD2(12.3, 25.7), SIMD2(-30.2, -31.1), SIMD2(33.8, 4.8), SIMD2(72.1, -48.3)] {
            let hit = terrain.rayIntersection(origin: SIMD3(point.x, 25, point.y), direction: SIMD3(0, -4, 0), maximumDistance: 40, padding: 0.125)
            let expected = 25 - terrain.height(x: point.x, z: point.y) - 0.125
            #expect(hit != nil)
            #expect(abs((hit?.distance ?? -1) - expected) < 0.0001)
            #expect(simd_dot(hit?.normal ?? .zero, terrain.normal(x: point.x, z: point.y)) > 0.9999)
        }
    }

    @Test func horizontalShotsHitNearHillsInBothDirections() {
        for side: Float in [-1, 1] {
            let origin = SIMD3<Float>(0, 1, 24), direction = SIMD3<Float>(side, 0, 0)
            let hit = terrain.rayIntersection(origin: origin, direction: direction, maximumDistance: 36)
            #expect(hit != nil)
            let distance = hit?.distance ?? 0
            #expect(distance > 7 && distance < 18)
            #expect(abs(terrain.height(x: side * distance, z: 24) - 1) < 0.0002)
            #expect(terrain.rayIntersection(origin: origin, direction: direction, maximumDistance: distance - 0.01) == nil)
        }
    }

    @Test func CellTraversalFindsFirstContactRatherThanSkippingThinCrossings() {
        let scenarios: [(SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(0, 1.5, 24), SIMD3(1, 0, 0.04)),
            (SIMD3(0, 1.5, 24), SIMD3(-1, 0, -0.04)),
            (SIMD3(0, 6, 32), SIMD3(0.3, -0.12, -1)),
            (SIMD3(0, 2, 32), SIMD3(-0.25, 0.01, -1)),
            (SIMD3(30, 18, 36), SIMD3(-0.7, -0.35, -1)),
        ]
        for (origin, rawDirection) in scenarios {
            let direction = simd_normalize(rawDirection)
            let hit = terrain.rayIntersection(origin: origin, direction: rawDirection, maximumDistance: 120)
            var sampledDistance: Float?
            for index in 0...24_000 {
                let distance = Float(index) * 0.005, point = origin + direction * distance
                if point.y <= terrain.height(x: point.x, z: point.z) {
                    sampledDistance = distance; break
                }
            }
            #expect((hit == nil) == (sampledDistance == nil))
            if let hit, let sampledDistance {
                #expect(hit.distance <= sampledDistance + 0.0002)
                #expect(sampledDistance - hit.distance < 0.0052)
            }
        }
    }

    @Test func cacheBoundaryAndInvalidInputsRemainFinite() {
        for x: Float in [255.99, 256, 256.01, -256.01] {
            let value = terrain.height(x: x, z: 17.2)
            #expect(value.isFinite)
            #expect(value == terrain.height(x: x, z: 17.2))
            #expect(abs(value - terrain.height(x: x + 0.001, z: 17.2)) < 0.001)
        }
        #expect(terrain.height(x: .nan, z: 0) == 0)
        #expect(terrain.normal(x: 0, z: .infinity) == SIMD3<Float>(0, 1, 0))
        #expect(terrain.rayIntersection(origin: SIMD3(0, 20, 0), direction: SIMD3(1, 0, 0), maximumDistance: 500) == nil)
        #expect(terrain.rayIntersection(origin: SIMD3(0, 2, 0), direction: .zero, maximumDistance: 10) == nil)
        #expect(terrain.rayIntersection(origin: SIMD3(0, .nan, 0), direction: SIMD3(0, -1, 0), maximumDistance: 10) == nil)
        #expect(terrain.rayIntersection(origin: SIMD3(0, 2, 0), direction: SIMD3(0, -1, 0), maximumDistance: -.infinity) == nil)
    }
}
