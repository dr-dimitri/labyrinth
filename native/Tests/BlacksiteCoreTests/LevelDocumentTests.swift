import Foundation
import Testing
import simd
@testable import BlacksiteCore

struct LevelDocumentTests {
    private func example() throws -> LevelDocument {
        let native = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try LevelDocument.decode(Data(contentsOf: native.appendingPathComponent("Examples/training-ground.blacksite-level.json")))
    }

    @Test func completeDocumentRoundTripPreservesEveryField() throws {
        var document = try example()
        document.terrain.seed = UInt64.max
        document.revision = 7
        document.groups = [LevelGroup(id: "group", name: "Hof")]
        document.objects[0].groupID = "group"
        document.objects[0].heightMode = .absolute
        document.objects[0].quarterTurns = 1
        document.objects[0].scale = LevelVector(1.5, 0.8, 2)
        document.objects[0].locked = true
        document.objects[0].hidden = true
        let decoded = try LevelDocument.decode(document.encoded())
        #expect(decoded == document)
        #expect(try decoded.encoded() == document.encoded())
    }

    @Test func unfinishedDraftCanBeSavedAndPreviewedButCannotStart() throws {
        let document = LevelDocument(id: "draft")
        #expect(try LevelDocument.decode(document.encoded()) == document)
        #expect(try document.makeMap(purpose: .preview).id == "custom.draft")
        #expect(throws: LevelDocumentError.self) { try document.makeMap() }
        #expect(document.markers.isEmpty)
    }

    @Test func fileVersionIsCheckedBeforeItsPayload() throws {
        let future = Data(#"{"formatVersion":999,"unknownFuturePayload":true}"#.utf8)
        do {
            _ = try LevelDocument.decode(future)
            Issue.record("Future version was accepted")
        } catch let error as LevelDocumentError { #expect(error.message.contains("999")) }
        #expect(throws: LevelDocumentError.self) { try LevelDocument.decode(Data("not JSON".utf8)) }
        #expect(throws: LevelDocumentError.self) {
            try LevelDocument.decode(Data(repeating: 0, count: LevelDocument.maximumFileBytes + 1))
        }
    }

    @Test func rejectsInvalidIDsReferencesAndNumbersWithoutTraps() throws {
        let original = try example()
        var document = original
        document.objects[1].id = document.objects[0].id
        #expect(throws: LevelDocumentError.self) { try document.encoded() }
        document = original; document.objects[0].groupID = "missing"
        #expect(throws: LevelDocumentError.self) { try document.encoded() }
        document = original; document.objects[0].catalogID = "missing.asset"
        #expect(throws: LevelDocumentError.self) { try document.encoded() }
        document = original; document.resourceSet = "../../Assets"
        #expect(throws: LevelDocumentError.self) { try document.makeMap() }
        document = original; document.terrain.heights[0] = .nan
        #expect(throws: LevelDocumentError.self) { try document.encoded() }
        document = original; document.objects[0].position.x = .infinity
        #expect(throws: LevelDocumentError.self) { try document.encoded() }
        document = original; document.bounds.width = Int.max
        #expect(throws: LevelDocumentError.self) { try document.makeMap() }
        let enormous = LevelDocument(bounds: LevelBounds(width: Int.max, depth: Int.max))
        #expect(throws: LevelDocumentError.self) { try enormous.encoded() }
        document = original; document.terrain.heights.removeLast()
        #expect(throws: LevelDocumentError.self) { try document.makeMap() }
        document = original; document.environment.sunDirection = .init()
        #expect(throws: LevelDocumentError.self) { try document.encoded() }
        document = original; document.objects[0].quarterTurns = 7
        #expect(throws: LevelDocumentError.self) { try document.encoded() }
        document = original; document.objects[0].scale.y = 0
        #expect(throws: LevelDocumentError.self) { try document.makeMap() }
    }

    @Test func translatedRectangularTerrainUsesStoredSamplesAndSharedCollision() throws {
        var document = LevelDocument(id: "translated", bounds: .init(x: 120, z: -80, width: 24, depth: 40))
        for z in 0...40 { for x in 0...24 { document.terrain.heights[z * 25 + x] = 18 + Float(x) * 0.1 } }
        let map = try document.makeMap(purpose: .preview)
        #expect(map.minimum.x == 120 && map.maximum.x == 144)
        #expect(map.minimum.z == -80 && map.maximum.z == -40)
        #expect(abs(map.terrain.height(x: 123.5, z: -72.1) - 18.35) < 0.0001)
        let hit = try #require(map.terrain.rayIntersection(origin: SIMD3(123.5, 30, -72.1), direction: SIMD3(0, -1, 0), maximumDistance: 30))
        #expect(abs(hit.distance - 11.65) < 0.0001)
    }

    @Test func rotationsAbsoluteHeightAndIDsSurviveReordering() throws {
        var document = try example()
        document.terrain.heights = document.terrain.heights.map { _ in 7 }
        document.objects[0].quarterTurns = 1
        document.objects[0].heightMode = .absolute
        document.objects[0].position.y = 9
        let first = try document.makeMap()
        let id = LevelDocument.obstacleID(document.objects[0].id)
        let before = try #require(first.obstacles.first { $0.id == id })
        #expect(before.size == SIMD3(2.5, 2.6, 6))
        #expect(before.position.y == 2)
        #expect(first.grounded(before.position).y == 9)
        document.objects.reverse()
        let after = try #require(document.makeMap().obstacles.first { $0.id == id })
        #expect(before.position == after.position && before.size == after.size)
    }

    @Test func blockedMarkersAndOutOfBoundsObjectsFailOnlyAtPlayTime() throws {
        var document = try example()
        let index = try #require(document.markers.firstIndex { $0.kind == .playerStart })
        document.markers[index].position = document.objects[0].position
        _ = try document.encoded()
        #expect(throws: MapValidationError.self) { try document.makeMap() }
        document = try example(); document.objects[0].position.x = 100
        _ = try document.encoded()
        _ = try document.makeMap(purpose: .preview)
        #expect(throws: LevelDocumentError.self) { try document.makeMap() }
        document = try example(); document.markers.append(document.markers[0])
        document.markers[document.markers.count - 1].id = "other-start"
        _ = try document.encoded()
        #expect(throws: LevelDocumentError.self) { try document.makeMap() }
    }

    @Test func actualCombatAndDestructionNeverModifyTheAuthoringDocument() throws {
        let document = try example(), data = try document.encoded()
        let map = try document.makeMap()
        let game = CombatSimulation(map: map, difficulty: .easy, seed: 15)
        var input = GameInput(); input.moveForward = 1
        let initial = game.player.position
        for _ in 0..<120 { game.step(deltaTime: 1.0 / 120, input: input) }
        #expect(simd_distance(initial, game.player.position) > 1)
        game.damageCover(index: 0, amount: 1000)
        #expect(game.obstacles[0].destroyed)
        #expect(try document.encoded() == data)
        #expect(try document.makeMap().obstacles[0].health > 0)
        #expect(!map.obstacles[0].destroyed)
    }

    @Test func editorVisibilityDoesNotRemovePlayableObjects() throws {
        var document = try example()
        document.objects[0].hidden = true; document.objects[0].locked = true
        #expect(try document.makeMap().obstacles.count == document.objects.count)
        #expect(try document.makeMap().groundMaterial(at: SIMD3(0, 0, 0)) == .asphalt)
    }
}
