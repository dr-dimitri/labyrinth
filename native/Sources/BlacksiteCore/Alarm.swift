import Foundation
import simd

/// Authored radio service: the referenced world device supplies/enables this
/// network. The first map uses its generator; no particular device ID is assumed.
public struct MapAlarmDefinition: Sendable {
    public let radioDeviceID: Int
    public let radioPosition: SIMD3<Float>
    public let radioRange: Float
    public let returnGuardPosts: [SIMD3<Float>]
    public let reinforcementCount: Int
    public init(radioDeviceID: Int, radioPosition: SIMD3<Float>, radioRange: Float = 60,
                returnGuardPosts: [SIMD3<Float>], reinforcementCount: Int = 2) {
        self.radioDeviceID = radioDeviceID; self.radioPosition = radioPosition; self.radioRange = radioRange
        self.returnGuardPosts = returnGuardPosts; self.reinforcementCount = reinforcementCount
    }
}
public enum ContactReportChannel: String, Sendable { case localShout, radio }
public struct ContactReport: Sendable {
    public let id: Int, enemyID: Int
    public let contactPosition: SIMD3<Float>
    public let contactTime: Double, transmittedAt: Double, expiresAt: Double
    public let channel: ContactReportChannel
    public init(id: Int, enemyID: Int, contactPosition: SIMD3<Float>, contactTime: Double,
                transmittedAt: Double, expiresAt: Double, channel: ContactReportChannel) {
        self.id = id; self.enemyID = enemyID; self.contactPosition = contactPosition; self.contactTime = contactTime
        self.transmittedAt = transmittedAt; self.expiresAt = expiresAt; self.channel = channel
    }
}
public struct PendingContactReport: Sendable {
    public let id: Int, enemyID: Int
    public let contactPosition: SIMD3<Float>
    public let contactTime: Double
    public let radioAtStart: Bool
    public internal(set) var radioCancelled = false
    public var progress: Float { Float(ticks) / 144 }
    var ticks: Int = 0
}
public struct AlarmStatus: Sendable {
    public let radioPowered: Bool, escalated: Bool
    public let assignedGuardIDs: [Int]
    public let reinforcementsCommitted: Int
    /// True only if the player could hear the actual radio cue at transmission.
    /// This does not depend on audio volume or captions preferences.
    public let playerHeardEscalation: Bool
}
