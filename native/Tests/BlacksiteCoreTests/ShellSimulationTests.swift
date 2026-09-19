import Testing
import simd
@testable import BlacksiteCore

struct ShellSimulationTests {
    private let identity = SIMD4<Float>(0, 0, 0, 1)
    private func container(destroyed: Bool = false) -> Obstacle {
        var obstacle = Obstacle(id: 17, kind: .container, position: .zero, size: SIMD3(4, 2, 4))
        obstacle.destroyed = destroyed
        return obstacle
    }
    @discardableResult private func advance(_ simulation: inout ShellSimulation, seconds: Int,
                                            framesPerSecond: Int = 120, obstacles: [Obstacle] = []) -> [ShellImpact] {
        var impacts: [ShellImpact] = []
        for _ in 0..<(seconds * framesPerSecond) {
            impacts += simulation.step(deltaTime: 1 / Float(framesPerSecond), obstacles: obstacles)
        }
        return impacts
    }

    @Test func poolKeepsNewestNinetySixShellsAndOriginalWeapon() {
        var simulation = ShellSimulation()
        for id in 1...140 {
            simulation.eject(weapon: id.isMultiple(of: 2) ? .sniper : .rifle,
                             position: SIMD3(0, 2, 0), velocity: .zero, orientation: identity)
        }
        #expect(simulation.casings.count == 96)
        #expect(simulation.casings.first?.id == 45)
        #expect(simulation.casings.last?.id == 140)
        #expect(simulation.casings.last?.weapon == .sniper)
    }

    @Test func expiryAndResetClearPoolAndReplaySeed() {
        var simulation = ShellSimulation(seed: 19)
        simulation.eject(weapon: .rifle, position: SIMD3(0, 2, 0), velocity: SIMD3(2, 1, 0), orientation: identity)
        advance(&simulation, seconds: 1)
        let first = simulation.casings[0]
        simulation.reset()
        #expect(simulation.casings.isEmpty)
        simulation.eject(weapon: .rifle, position: SIMD3(0, 2, 0), velocity: SIMD3(2, 1, 0), orientation: identity)
        advance(&simulation, seconds: 1)
        #expect(simulation.casings[0].id == first.id)
        #expect(simulation.casings[0].position == first.position)
        #expect(simulation.casings[0].orientation == first.orientation)
        advance(&simulation, seconds: 14)
        #expect(simulation.casings.isEmpty)
    }

    @Test func groundImpactBouncesThenRestsHorizontally() {
        var simulation = ShellSimulation(seed: 7)
        simulation.eject(weapon: .rifle, position: SIMD3(0, 0.4, 0), velocity: SIMD3(1.2, -1, 0.3), orientation: identity)
        var bounced = false
        var impacts: [ShellImpact] = []
        for _ in 0..<360 {
            impacts += simulation.step(deltaTime: 1 / 120, obstacles: [])
            if simulation.casings[0].velocity.y > 0.1 { bounced = true }
        }
        let casing = simulation.casings[0]
        #expect(bounced)
        #expect(impacts.contains { $0.speed > 1 })
        #expect(impacts.count < 12)
        #expect(casing.resting)
        #expect(casing.velocity == .zero)
        #expect(abs(casing.position.y - casing.radius) < 0.0001)
        let axis = simd_quatf(vector: casing.orientation).act(SIMD3<Float>(0, 1, 0))
        #expect(abs(axis.y) < 0.0001)
    }

    @Test func shellRestsOnContainerTopAndFallsWhenItIsDestroyed() {
        var simulation = ShellSimulation(seed: 3)
        simulation.eject(weapon: .sniper, position: SIMD3(0, 3, 0), velocity: SIMD3(0.1, -1, 0), orientation: identity)
        let impacts = advance(&simulation, seconds: 3, obstacles: [container()])
        #expect(!impacts.isEmpty)
        #expect(simulation.casings[0].resting)
        #expect(abs(simulation.casings[0].position.y - 2.007) < 0.0001)
        advance(&simulation, seconds: 3, obstacles: [container(destroyed: true)])
        #expect(simulation.casings[0].resting)
        #expect(abs(simulation.casings[0].position.y - 0.007) < 0.0001)
    }

    @Test func destroyedCoverDoesNotBlockFlight() {
        var simulation = ShellSimulation()
        simulation.eject(weapon: .rifle, position: SIMD3(0, 3, 0), velocity: SIMD3(0, -1, 0), orientation: identity)
        advance(&simulation, seconds: 3, obstacles: [container(destroyed: true)])
        #expect(simulation.casings[0].resting)
        #expect(simulation.casings[0].position.y < 0.01)
    }

    @Test func fastCaseBouncesFromThinWallWithoutTunnelling() {
        let wall = Obstacle(id: 9, kind: .barrier, position: SIMD3(1, 0, 0), size: SIMD3(0.1, 3, 4))
        var simulation = ShellSimulation()
        simulation.eject(weapon: .rifle, position: SIMD3(0, 1, 0), velocity: SIMD3(25, 0, 0), orientation: identity)
        let impacts = simulation.step(deltaTime: 0.1, obstacles: [wall])
        #expect(impacts.contains { $0.speed > 20 })
        #expect(simulation.casings[0].velocity.x < 0)
        #expect(simulation.casings[0].position.x < 0.95)
    }

    @Test func fixedStepsMatchAcrossPresentationRates() {
        var slow = ShellSimulation(seed: 42), fast = ShellSimulation(seed: 42)
        for weapon in WeaponKind.allCases {
            slow.eject(weapon: weapon, position: SIMD3(0, 3, 0), velocity: SIMD3(3, 2, -1), orientation: identity)
            fast.eject(weapon: weapon, position: SIMD3(0, 3, 0), velocity: SIMD3(3, 2, -1), orientation: identity)
        }
        let slowImpacts = advance(&slow, seconds: 4, framesPerSecond: 30, obstacles: [container()])
        let fastImpacts = advance(&fast, seconds: 4, framesPerSecond: 120, obstacles: [container()])
        #expect(slowImpacts.count == fastImpacts.count)
        for index in slow.casings.indices {
            #expect(simd_distance(slow.casings[index].position, fast.casings[index].position) < 0.0001)
            #expect(simd_distance(slow.casings[index].orientation, fast.casings[index].orientation) < 0.0001)
            #expect(abs(slow.casings[index].age - fast.casings[index].age) < 0.0001)
            #expect(slow.casings[index].resting == fast.casings[index].resting)
        }
    }

    @Test func shellsRestOnHillsAndBelowZeroInDepressions() {
        let terrain = TerrainProfile.battlefield
        var hill = SIMD3<Float>(0,-100,0), hollow = SIMD3<Float>(0,100,0)
        for x in stride(from: Float(-34), through: 34, by: 1) {
            for z in stride(from: Float(-38), through: 38, by: 1) {
                let y = terrain.height(x: x, z: z)
                if y > hill.y { hill = SIMD3(x,y,z) }
                if y < hollow.y { hollow = SIMD3(x,y,z) }
            }
        }
        #expect(hill.y > 2)
        #expect(hollow.y < -0.5)
        for start in [hill, hollow] {
            var simulation = ShellSimulation(seed: 3)
            simulation.eject(weapon: .rifle, position: start + SIMD3(0,0.5,0), velocity: .zero, orientation: identity)
            for _ in 0..<600 { simulation.step(deltaTime: 1 / 120, obstacles: [], terrain: terrain) }
            let shell = simulation.casings[0]
            let height = terrain.height(x: shell.position.x, z: shell.position.z)
            #expect(shell.resting)
            #expect(shell.position.y >= height)
            #expect(shell.position.y - height < 0.035)
            let normal = terrain.normal(x: shell.position.x, z: shell.position.z)
            let axis = simd_quatf(vector: shell.orientation).act(SIMD3<Float>(0,1,0))
            #expect(abs(simd_dot(axis,normal)) < 0.001)
        }
    }

    @Test func zeroAndInvalidTimeFreezeAllState() {
        var simulation = ShellSimulation()
        simulation.eject(weapon: .rifle, position: SIMD3(0, 2, 0), velocity: SIMD3(2, 2, 1), orientation: identity)
        for delta in [Float(0), -1, .nan, .infinity] {
            #expect(simulation.step(deltaTime: delta, obstacles: []).isEmpty)
        }
        #expect(simulation.casings[0].age == 0)
        #expect(simulation.casings[0].position == SIMD3(0, 2, 0))
        #expect(simulation.casings[0].orientation == identity)
        simulation.eject(weapon: .rifle, position: SIMD3(.nan, 0, 0), velocity: .zero, orientation: identity)
        #expect(simulation.casings.count == 1)
        simulation.eject(weapon: .sniper, position: SIMD3(0, 2, 0), velocity: .zero,
                         orientation: SIMD4(repeating: Float.greatestFiniteMagnitude))
        #expect(abs(simd_length_squared(simulation.casings[1].orientation) - 1) < 0.0001)
    }
}
