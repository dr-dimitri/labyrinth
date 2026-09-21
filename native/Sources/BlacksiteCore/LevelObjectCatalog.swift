import simd

/// Initial building blocks for the document adapter. The full editor catalog is #40.
public struct LevelCatalogItem: Sendable {
    public let id: String
    public let name: String
    public let kind: ObstacleKind
    public let size: SIMD3<Float>
}

public enum LevelObjectCatalog {
    public static let items: [LevelCatalogItem] = [
        .init(id: "core.crate", name: "Holzkiste", kind: .crate, size: SIMD3(1.2, 1.2, 1.2)),
        .init(id: "core.barrier", name: "Betonbarriere", kind: .barrier, size: SIMD3(3, 1.3, 0.6)),
        .init(id: "core.container", name: "Container", kind: .container, size: SIMD3(6, 2.6, 2.5)),
        .init(id: "core.block", name: "Massiver Baublock", kind: .bunker, size: SIMD3(3, 3, 3))
    ]
    public static func item(id: String) -> LevelCatalogItem? { items.first { $0.id == id } }
}
