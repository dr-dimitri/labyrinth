import Foundation
import BlacksiteCore

/// Only an audible radio report exposes the operation's escalation. The
/// presentation never inspects remote enemies or their current target positions.
final class NativeAlarmPresentation {
    struct Notice {
        let label: String
        let title: String
        let detail: String
    }
    private var announced = false
    private var arrivalAnnounced = false
    private var lastTime: Double = 0
    private var expires: Double = 0
    private(set) var accessibilityText = ""

    func clear() {
        announced = false; arrivalAnnounced = false
        lastTime = 0; expires = 0; accessibilityText = ""
    }

    func consume(_ events: [GameEvent], simulation: CombatSimulation) -> Notice? {
        if simulation.elapsed < lastTime { clear() }
        lastTime = simulation.elapsed
        if simulation.elapsed >= expires { accessibilityText = "" }
        guard !announced else { return nil }
        for event in events where event.kind == .alarmEscalated {
            guard let report = event.contactReport, report.channel == .radio,
                  report.transmittedAt <= simulation.elapsed, report.expiresAt > simulation.elapsed,
                  let sound = event.hearing,
                  sound.kind == .radio,
                  simulation.acousticSample(for: sound, listener: simulation.eyePosition).audible else { continue }
            announced = true; expires = simulation.elapsed + 8
            let notice = Notice(label: "FEINDLICHE FUNKMELDUNG", title: "RÜCKWEG WIRD GESICHERT",
                detail: "Zugangswachen und eine begrenzte Verstärkung angekündigt")
            accessibilityText = "\(notice.label). \(notice.title). \(notice.detail)."
            return notice
        }
        return nil
    }

    /// A single arrival notice for the one announced group, even when safe
    /// entry retries split it over several frames. No unseen headcount is shown.
    func arrivalNotice(_ events: [GameEvent], simulation: CombatSimulation) -> String? {
        guard announced, !arrivalAnnounced else { return nil }
        let arrivals = events.filter { $0.kind == .reinforcementsArrived && $0.alarmReportID != nil }
        guard !arrivals.isEmpty else { return nil }
        arrivalAnnounced = true
        let directions = Set(arrivals.map {
            NativeNoisePresentation.direction(source: $0.position, listener: simulation.eyePosition, yaw: simulation.player.yaw)
        }).sorted().joined(separator: " / ")
        let result = "ANGEKÜNDIGTE VERSTÄRKUNG · \(directions)"
        accessibilityText = result; expires = simulation.elapsed + 6
        return result
    }
}
