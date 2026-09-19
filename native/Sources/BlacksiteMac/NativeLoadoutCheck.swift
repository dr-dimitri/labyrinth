import Foundation
import BlacksiteCore

enum NativeLoadoutCheck {
    private struct InvalidSelection: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static func loadout(arguments: [String]) throws -> LoadoutDefinition {
        let rawClass = try value(for: "--class", arguments: arguments) ?? "assault"
        let rawPattern = try value(for: "--camouflage", arguments: arguments) ?? "none"
        guard let operatorClass = OperatorClass(rawValue: rawClass) else {
            throw InvalidSelection(message: "--class accepts recon, engineer or assault.")
        }
        guard let pattern = CamouflagePattern(rawValue: rawPattern) else {
            throw InvalidSelection(message: "--camouflage accepts none, vegetation or mineral.")
        }
        return LoadoutDefinition(operatorClass: operatorClass, camouflage: pattern)
    }

    private static func value(for flag: String, arguments: [String]) throws -> String? {
        var found: String?
        for (index, argument) in arguments.enumerated() {
            let value: String
            if argument == flag {
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    throw InvalidSelection(message: "\(flag) requires one selection.")
                }
                value = arguments[index + 1]
            } else if argument.hasPrefix(flag + "=") {
                value = String(argument.dropFirst(flag.count + 1))
            } else { continue }
            guard found == nil, !value.isEmpty else {
                throw InvalidSelection(message: "Supply \(flag) once with one nonempty selection.")
            }
            found = value
        }
        return found
    }
}
