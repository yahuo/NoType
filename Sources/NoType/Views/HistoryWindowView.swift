import SwiftData
import SwiftUI

struct HistoryWindowView: View {
    @Query(sort: [SortDescriptor(\DictationSessionRecord.startedAt, order: .reverse)])
    private var records: [DictationSessionRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Dictation History")
                .font(.largeTitle.bold())

            if records.isEmpty {
                ContentUnavailableView(
                    "No History Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Completed and failed dictation sessions will appear here.")
                )
            } else {
                Table(records) {
                    TableColumn("Started") { record in
                        Text(record.startedAt, style: .date) + Text(" ") + Text(record.startedAt, style: .time)
                    }
                    .width(min: 160)

                    TableColumn("App") { record in
                        Text(record.targetAppName)
                    }
                    .width(min: 120)

                    TableColumn("Mic") { record in
                        Text(record.microphoneName)
                    }
                    .width(min: 120)

                    TableColumn("Status") { record in
                        Text(record.status.rawValue.capitalized)
                            .foregroundStyle(color(for: record.status))
                    }
                    .width(min: 90)

                    TableColumn("Latency") { record in
                        Text("\(record.latencyMs) ms")
                    }
                    .width(min: 90)

                    TableColumn("Transcript") { record in
                        Text(record.finalText)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(20)
    }

    private func color(for status: DictationSessionStatus) -> Color {
        switch status {
        case .success:
            .green
        case .failed:
            .red
        case .cancelled:
            .secondary
        }
    }
}
