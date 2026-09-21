import Foundation
import Testing
@testable import BlacksiteCore

struct LevelExampleTests {
    @Test func recipesRoundTripIntoPlayableMapsAndDeterministicReferenceScene() throws {
        for example in LevelExample.allCases {
            let doc = try example.makeDocument()
            #expect(doc.playIssues().isEmpty, "\(example): \(doc.playIssues().map(\.message))")
            let decoded = try LevelDocument.decode(doc.encoded())
            #expect(decoded == doc)
            let game = CombatSimulation(map:try decoded.makeMap(),mission:decoded.missionKind)
            game.step(deltaTime:1.0/60,input:GameInput())
            #expect(game.state == .active)
            if example == .woodland {
                #expect(doc.bounds.width == 128 && doc.bounds.depth == 128 && doc.objects.count == 500)
                #expect(Set(doc.objects.compactMap { LevelObjectCatalog.item(id:$0.catalogID)?.category }).count == 4)
                #expect(try example.makeDocument() == doc)
            }
        }
    }
}
