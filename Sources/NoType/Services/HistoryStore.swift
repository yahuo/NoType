import Foundation
import SwiftData

@MainActor
final class HistoryStore {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func addRecord(
        startedAt: Date,
        endedAt: Date,
        context: DictationTargetContext,
        microphoneName: String,
        finalText: String,
        status: DictationSessionStatus,
        latencyMs: Int
    ) throws {
        let record = DictationSessionRecord(
            startedAt: startedAt,
            endedAt: endedAt,
            targetAppBundleID: context.bundleIdentifier,
            targetAppName: context.localizedName,
            microphoneName: microphoneName,
            finalText: finalText,
            status: status,
            latencyMs: latencyMs
        )
        modelContext.insert(record)
        try modelContext.save()
    }

    func prune(retentionDays: Int) throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: .now) ?? .distantPast
        let descriptor = FetchDescriptor<DictationSessionRecord>(
            predicate: #Predicate { $0.startedAt < cutoff }
        )
        let staleRecords = try modelContext.fetch(descriptor)
        for record in staleRecords {
            modelContext.delete(record)
        }
        if !staleRecords.isEmpty {
            try modelContext.save()
        }
    }
}
