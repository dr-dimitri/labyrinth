import Foundation
import MetalKit
import BlacksiteCore

/// One validated import, retained by value for this application session.
struct NativeLoadedLevel: Sendable {
    let document: LevelDocument
    let map: MapDefinition

    init(document: LevelDocument) throws {
        self.map = try document.makeMap()
        self.document = document
    }

    static func load(_ url: URL) throws -> Self {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw LevelDocumentError("Bitte eine reguläre Leveldatei auswählen.") }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: LevelDocument.maximumFileBytes + 1) ?? Data()
        return try Self(document: LevelDocument.decode(data))
    }

    static func from(arguments: [String]) throws -> Self? {
        guard let index = arguments.firstIndex(of: "--level-file") else { return nil }
        guard arguments.filter({ $0 == "--level-file" }).count == 1, index + 1 < arguments.count,
              !arguments[index + 1].hasPrefix("--") else {
            throw LevelDocumentError("--level-file benötigt genau einen Dateipfad.")
        }
        let incompatible: Set<String> = ["--map", "--scene", "--map-cycles", "--briefing-check", "--report-check"]
        guard incompatible.isDisjoint(with: arguments) else {
            throw LevelDocumentError("--level-file kann nicht mit einer eingebauten Karte oder Diagnoseszene kombiniert werden.")
        }
        return try load(URL(fileURLWithPath: arguments[index + 1]))
    }

    @MainActor func check(arguments: [String]) throws {
        func dimension(_ flag: String, fallback: Int) -> Int {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count,
                  let value = Int(arguments[index + 1]) else { return fallback }
            return min(3840, max(320, value))
        }
        let width = dimension("--width", fallback: 1280), height = dimension("--height", fallback: 800)
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)), device: MTLCreateSystemDefaultDevice())
        let renderer = try NativeRenderer(view: view, assetRoot: NativeResources.assetRoot,
            highQuality: !arguments.contains("--balanced"), map: map)
        let seed = arguments.contains("--seed") ? try NativeRunSeed.from(arguments: arguments) : document.terrain.seed
        let simulation = CombatSimulation(map: map, difficulty: .easy, seed: seed, mission: document.missionKind)
        var result: [String: Any] = ["result": "pass", "mapID": map.id, "formatVersion": document.formatVersion,
            "objects": document.objects.count, "markers": document.markers.count, "seed": String(seed)]
        if arguments.contains("--graphics-benchmark") {
            result.merge(try renderer.benchmark(simulation: simulation, width: width, height: height, frames: 120)) { _, new in new }
        } else {
            let output: String
            if let index = arguments.firstIndex(of: "--output"), index + 1 < arguments.count { output = arguments[index + 1] }
            else { output = "native-level.png" }
            try renderer.renderOffscreen(simulation: simulation, width: width, height: height, to: URL(fileURLWithPath: output))
            result["screenshot"] = output
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
