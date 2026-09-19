import Foundation
import BlacksiteCore

enum NativeLoadoutCheck {
    private struct InvalidPattern: LocalizedError {
        var errorDescription: String? { "--camouflage accepts none, vegetation or mineral." }
    }
    static func loadout(arguments: [String]) throws -> LoadoutDefinition {
        guard let index = arguments.firstIndex(of: "--camouflage") else { return .init() }
        guard index + 1 < arguments.count, let pattern = CamouflagePattern(rawValue: arguments[index + 1]) else {
            throw InvalidPattern()
        }
        return LoadoutDefinition(camouflage: pattern)
    }
}
