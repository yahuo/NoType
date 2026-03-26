import Foundation
import SwiftData

enum DictationSessionStatus: String, Codable, CaseIterable {
    case success
    case failed
    case cancelled
}

@Model
final class DictationSessionRecord {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date
    var targetAppBundleID: String
    var targetAppName: String
    var microphoneName: String
    var finalText: String
    var statusRawValue: String
    var latencyMs: Int

    init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date,
        targetAppBundleID: String,
        targetAppName: String,
        microphoneName: String,
        finalText: String,
        status: DictationSessionStatus,
        latencyMs: Int
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.targetAppBundleID = targetAppBundleID
        self.targetAppName = targetAppName
        self.microphoneName = microphoneName
        self.finalText = finalText
        self.statusRawValue = status.rawValue
        self.latencyMs = latencyMs
    }

    var status: DictationSessionStatus {
        get { DictationSessionStatus(rawValue: statusRawValue) ?? .failed }
        set { statusRawValue = newValue.rawValue }
    }
}
