import Foundation
import Testing
import simd
import BlacksiteCore
@testable import BlacksiteMac

struct CombatFeedbackTests {
    @Test func directionsFollowEveryCameraHeading() {
        let listener = SIMD3<Float>(3, 2, 7)
        for yaw: Float in [0, .pi / 2, .pi, -.pi / 2, 0.43] {
            let right = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
            let front = SIMD3<Float>(-sin(yaw), 0, -cos(yaw))
            for (offset, expected, label) in [(right, SIMD2<Float>(1, 0), "RECHTS"),
                                            (-right, SIMD2<Float>(-1, 0), "LINKS"),
                                            (front, SIMD2<Float>(0, -1), "VORN"),
                                            (-front, SIMD2<Float>(0, 1), "HINTEN")] {
                let bearing = ThreatBearing(source: listener + offset * 10, listener: listener, yaw: yaw)
                #expect(simd_distance(bearing.direction, expected) < 0.0001)
                #expect(bearing.label == label)
                #expect(abs(bearing.distance - 10) < 0.0001)
            }
        }
        #expect(ThreatBearing(source: listener, listener: listener, yaw: 0).label == "GANZ NAH")
        let above = ThreatBearing(source: listener + SIMD3(0, 4, 0), listener: listener, yaw: 1)
        let below = ThreatBearing(source: listener - SIMD3(0, 3, 0), listener: listener, yaw: 2)
        #expect(above.label == "OBEN" && below.label == "UNTEN")
        #expect(above.direction == .zero && below.direction == .zero)
    }

    @Test func multipleHitsStayBoundedAndExpireInSimulationTime() {
        var feedback = CombatFeedback()
        for i in 0..<8 {
            feedback.record(GameEvent(kind: .damage, position: SIMD3(Float(i) * 3, 1, 0), amount: 12), time: 4)
        }
        #expect(feedback.activeDamage(at: 4).count == 4)
        // A paused clock preserves the warnings; a repeated burst refreshes one source.
        feedback.record(GameEvent(kind: .damage, position: SIMD3(21, 1, 0), amount: 12), time: 4.6)
        #expect(feedback.activeDamage(at: 4.6).count == 4)
        #expect(feedback.activeDamage(at: 5).count == 1)
        #expect(feedback.activeDamage(at: 5.61).isEmpty)
        feedback.reset()
        #expect(feedback.damage.isEmpty)
    }

    @Test func onlyDamageCreatesAnIndicatorAndItsSourceRemainsFixed() {
        var feedback = CombatFeedback()
        feedback.record(GameEvent(kind: .enemyShot, position: SIMD3(8, 0, 0), amount: 30), time: 0)
        feedback.record(GameEvent(kind: .damage, amount: 0), time: 0)
        #expect(feedback.damage.isEmpty)
        var event = GameEvent(kind: .damage, position: SIMD3(8, 0, 0), amount: 30)
        feedback.record(event, time: 0)
        event.position = SIMD3(-8, 0, 0)
        #expect(feedback.damage.first?.position == SIMD3(8, 0, 0))
    }

    @Test func legacyVolumeMigratesThenSeparateVolumesSurviveReload() throws {
        let suite = "BlacksiteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0.27, forKey: "native.volume")
        var settings = NativeSettings(defaults: defaults)
        #expect(abs(settings.musicVolume - 0.27) < 0.001)
        #expect(abs(settings.effectsVolume - 0.27) < 0.001)
        settings.musicVolume = 0
        settings.effectsVolume = 0.81
        settings.save(defaults: defaults)
        let reloaded = NativeSettings(defaults: defaults)
        #expect(reloaded.musicVolume == 0)
        #expect(abs(reloaded.effectsVolume - 0.81) < 0.001)
    }
}
