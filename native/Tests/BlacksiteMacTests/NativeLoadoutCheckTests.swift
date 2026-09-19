import Testing
import BlacksiteCore
@testable import BlacksiteMac

struct NativeLoadoutCheckTests {
    @Test func independentClassAndCamouflageSelectionsPreserveTheSameCoreKit() throws {
        #expect(try NativeLoadoutCheck.loadout(arguments: []) == LoadoutDefinition())
        for role in OperatorClass.allCases {
            for pattern in CamouflagePattern.allCases {
                let kit = try NativeLoadoutCheck.loadout(arguments: ["--scene", "squad", "--camouflage", pattern.rawValue,
                    "--class", role.rawValue, "--output", "/tmp/image.png"])
                #expect(kit == LoadoutDefinition(operatorClass: role, camouflage: pattern))
                #expect(try NativeLoadoutCheck.loadout(arguments: ["--class=\(role.rawValue)", "--camouflage=\(pattern.rawValue)"]) == kit)
            }
        }
        #expect(try NativeLoadoutCheck.loadout(arguments: ["--class", "recon"]).camouflage == .none)
        #expect(try NativeLoadoutCheck.loadout(arguments: ["--camouflage", "mineral"]).operatorClass == .assault)
    }

    @Test func malformedOrDuplicateKnownOptionsNeverSilentlyFallBackToAnotherKit() {
        let invalid: [[String]] = [
            ["--class"], ["--camouflage"], ["--class", "--camouflage", "mineral"],
            ["--camouflage", "--class", "recon"], ["--class", "unknown"], ["--camouflage", "urban"],
            ["--class", ""], ["--camouflage="], ["--class", "recon", "--class", "assault"],
            ["--class=recon", "--class", "recon"], ["--camouflage=none", "--camouflage=vegetation"],
            ["--class", "engineer", "--camouflage", ""], ["--camouflage", "mineral", "--class", ""]
        ]
        for arguments in invalid {
            #expect(throws: (any Error).self) { try NativeLoadoutCheck.loadout(arguments: arguments) }
        }
    }
}
