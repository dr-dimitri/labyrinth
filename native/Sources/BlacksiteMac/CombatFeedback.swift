import Foundation
import simd
import BlacksiteCore

/// Camera-relative direction in HUD coordinates: right is +x, down is +y.
struct ThreatBearing {
    let direction: SIMD2<Float>
    let distance: Float
    private let verticalLabel: String?

    init(source: SIMD3<Float>, listener: SIMD3<Float>, yaw: Float) {
        let offset = source - listener
        distance = simd_length(offset)
        let horizontal = SIMD2(offset.x, offset.z)
        let length = simd_length(horizontal)
        verticalLabel = length < 0.1 ? (offset.y > 0 ? "OBEN" : "UNTEN") : nil
        if length < 0.1 { direction = .zero }
        else {
            direction = SIMD2(offset.x * cos(yaw) - offset.z * sin(yaw),
                              offset.x * sin(yaw) + offset.z * cos(yaw)) / length
        }
    }

    var label: String {
        if distance < 1 { return "GANZ NAH" }
        if let verticalLabel { return verticalLabel }
        if abs(direction.x) > abs(direction.y) { return direction.x > 0 ? "RECHTS" : "LINKS" }
        return direction.y < 0 ? "VORN" : "HINTEN"
    }
}

struct CombatFeedback {
    struct DamageCue {
        let position: SIMD3<Float>
        let expires: Double
    }
    private(set) var damage: [DamageCue] = []

    mutating func record(_ event: GameEvent, time: Double) {
        guard event.kind == .damage, event.amount > 0 else { return }
        // A burst from the same source refreshes one arrow rather than stacking it.
        damage.removeAll { $0.expires <= time || simd_distance_squared($0.position, event.position) < 4 }
        if damage.count >= 4 { damage.removeFirst() }
        damage.append(DamageCue(position: event.position, expires: time + 1))
    }

    func activeDamage(at time: Double) -> [DamageCue] { damage.filter { $0.expires > time } }
    mutating func reset() { damage.removeAll(keepingCapacity: true) }

    static func nearbyGrenades(_ simulation: CombatSimulation) -> [GrenadeState] {
        simulation.grenades.filter {
            simd_distance($0.position + SIMD3(0, 0.18, 0), simulation.eyePosition) < 8
        }.sorted { $0.fuse == $1.fuse ? $0.id < $1.id : $0.fuse < $1.fuse }.prefix(3).map { $0 }
    }
}
