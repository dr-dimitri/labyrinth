import BlacksiteCore

/// Both the cached sound and optional hearing text use the same actual source.
/// No emitter lookup, global wind timer or mixer setting can invent a warning.
struct NativeSmokeWarningCue {
    let label: String
    let expiresAt: Double
    let spatial: NativeSpatialSample

    static func make(event: GameEvent, simulation: CombatSimulation) -> NativeSmokeWarningCue? {
        guard event.kind == .smokeWarning, let warning = event.warning,
              let hearing = event.hearing, hearing.kind == .gust,
              warning.startsAt.isFinite, hearing.time.isFinite,
              hearing.time <= simulation.elapsed + 0.0001,
              warning.startsAt > simulation.elapsed else { return nil }
        let sample = simulation.acousticSample(for: hearing, listener: simulation.eyePosition)
        guard sample.audible else { return nil }
        let label: String
        switch warning.kind {
        case .spray: label = "GISCHT NAHT"
        case .steam: label = "DAMPF NAHT"
        case .smoke: label = "RAUCH NAHT"
        }
        return NativeSmokeWarningCue(label: label, expiresAt: warning.startsAt,
            spatial: NativeSpatialAudio.positioned(gain: sample.gain, source: hearing.position,
                listener: simulation.eyePosition, yaw: simulation.player.yaw))
    }
}
