import Foundation
import BlacksiteCore

/// Repeated quality changes share one renderer, with completed GPU frames
/// between changes so measurements exclude resources still used by old frames.
@MainActor
enum NativeTextureCheck {
    private struct CheckFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func prepare(arguments: [String], renderer: NativeRenderer, simulation: CombatSimulation,
                        width: Int, height: Int, initialHighQuality: Bool) throws -> [String: Any] {
        guard let index = arguments.firstIndex(of: "--quality-cycles") else { return [:] }
        guard index + 1 < arguments.count, let cycles = Int(arguments[index + 1]), (1...10).contains(cycles) else {
            throw CheckFailure(message: "--quality-cycles accepts 1 to 10 complete round trips.")
        }
        var measurements: [[String: Any]] = []
        for transition in 0..<(cycles * 2) {
            let high = transition.isMultiple(of: 2) ? !initialHighQuality : initialHighQuality
            try autoreleasepool { try renderer.setQuality(high) }
            var measurement = try autoreleasepool {
                try renderer.benchmark(simulation: simulation, width: width, height: height, frames: 1)
            }
            measurement["transition"] = transition + 1
            measurement["quality"] = high ? "high" : "balanced"
            measurements.append(measurement)
        }
        return ["qualityCycleCount": cycles, "qualityCycleMeasurements": measurements]
    }
}
