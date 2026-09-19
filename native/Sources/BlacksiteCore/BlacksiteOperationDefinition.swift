import simd

/// Authored choices use the existing ground routes and the north bunker's real
/// cover. Neither exit requires climbing or keeping a destructible prop alive.
public enum BlacksiteOperation {
    public static let definition = MapOperationDefinition(
        preparations: [
            OperationPreparationDefinition(kind: .disableRadio, deviceID: 1001),
            OperationPreparationDefinition(kind: .openGate, deviceID: 1002)
        ],
        extractions: [
            ExtractionDefinition(id: "north", title: "Nordtor", detail:
                "Kürzer, offene Straße. Ein geöffnetes Servicetor gibt den direkten Weg frei.",
                position: SIMD3(0, 0, -35), radius: 2.5, holdDuration: 3, routeKind: .exposed),
            ExtractionDefinition(id: "service", title: "Wartungsausgang Ost", detail:
                "Länger durch die Ostmulde. Der Nordbunker deckt gegen die Straße, nicht von allen Seiten.",
                position: SIMD3(33, 0, -37), radius: 2.5, holdDuration: 3, routeKind: .sheltered)
        ])
}
