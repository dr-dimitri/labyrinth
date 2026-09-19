import Foundation
import BlacksiteCore

/// A heard local warning, not a global weather countdown. A later camera move
/// changes its bearing but never its recorded origin or scheduled start time.
final class NativeWeatherPresentation {
    private struct HeardWarning { let warning: SmokeWarning; let label: String; let origin: SIMD3<Float> }
    private var warnings: [HeardWarning] = []
    private var heardIDs: [Int] = []
    private var lastTime: Double = 0

    func clear() { warnings.removeAll(); heardIDs.removeAll(); lastTime = 0 }

    func consume(_ events: [GameEvent], simulation: CombatSimulation) {
        if simulation.elapsed < lastTime { clear() }
        lastTime = simulation.elapsed
        warnings.removeAll { $0.warning.startsAt <= simulation.elapsed + 0.0000001 || !isActive($0.warning,simulation:simulation) }
        for event in events where event.kind == .smokeWarning {
            guard let warning = event.warning, let hearing = event.hearing,
                  warning.beginsAt <= simulation.elapsed + 0.0000001, warning.startsAt > simulation.elapsed + 0.0000001,
                  isActive(warning,simulation:simulation),
                  !heardIDs.contains(hearing.id),
                  let cue = NativeSmokeWarningCue.make(event: event, simulation: simulation) else { continue }
            heardIDs.append(hearing.id)
            if heardIDs.count > 64 { heardIDs.removeFirst(heardIDs.count - 64) }
            warnings.removeAll { $0.warning.emitterID == warning.emitterID }
            warnings.append(HeardWarning(warning: warning, label: cue.label, origin: hearing.position))
            warnings.sort { $0.warning.startsAt < $1.warning.startsAt }
            if warnings.count > 2 { warnings.removeLast(warnings.count - 2) }
        }
    }

    func line(simulation: CombatSimulation) -> String? {
        guard let warning = warnings.first(where: { $0.warning.startsAt > simulation.elapsed + 0.0000001 && isActive($0.warning,simulation:simulation) }) else { return nil }
        let bearing = NativeNoisePresentation.direction(source: warning.origin,
            listener: simulation.eyePosition, yaw: simulation.player.yaw)
        return "\(warning.label) · \(bearing) · \(String(format: "%.1f", warning.warning.startsAt - simulation.elapsed)) s"
    }

    private func isActive(_ warning:SmokeWarning,simulation:CombatSimulation)->Bool {
        // Authored sources can lose power after their audible advance cue.
        // A remembered sound must not promise an emission Core has cancelled.
        // Synthetic event-only diagnostics remain possible without inventing a
        // source definition solely for presentation unit tests.
        guard simulation.map.environment.smokeEmitters.contains(where:{ $0.id==warning.emitterID }) else { return true }
        return simulation.smokeWarnings.contains {
            $0.emitterID==warning.emitterID && $0.cycle==warning.cycle && $0.startsAt==warning.startsAt
        }
    }
}
