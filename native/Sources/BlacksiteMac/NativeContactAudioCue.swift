import BlacksiteCore

/// Presentation never infers a contact point or ranges of its own. Only an
/// actual audible source snapshot can select one of the cached contact cues.
struct NativeContactAudioCue {
    enum Kind:String,CaseIterable { case call,radioBegin,radioSent,radioInterrupted }
    let kind:Kind
    let spatial:NativeSpatialSample

    static func make(event:GameEvent,simulation:CombatSimulation)->NativeContactAudioCue? {
        guard event.kind == .contactReportStarted || event.kind == .contactReportTransmitted || event.kind == .contactReportInterrupted,
              let hearing=event.hearing else { return nil }
        let kind:Kind
        switch hearing.kind {
        case .shout:
            guard event.kind != .contactReportInterrupted else { return nil }
            kind = .call
        case .radio:
            kind = event.kind == .contactReportInterrupted ? .radioInterrupted:event.kind == .contactReportTransmitted ? .radioSent:.radioBegin
        default:return nil
        }
        let sample=simulation.acousticSample(for:hearing,listener:simulation.eyePosition)
        guard sample.audible else { return nil }
        return NativeContactAudioCue(kind:kind,spatial:NativeSpatialAudio.positioned(gain:sample.gain,
            source:hearing.position,listener:simulation.eyePosition,yaw:simulation.player.yaw))
    }
}
