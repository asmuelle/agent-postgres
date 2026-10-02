import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// MARK: - Console Metrics View
struct MobileConsoleMetricsView: View {
    let profileId: String
    let queryStore: PostgresQueryTabsStore
    
    @State private var logs: [PostgresHistoryEntry] = []
    
    var body: some View {
        ZStack {
            MidnightColors.primaryBackground.ignoresSafeArea()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // The segmented control above already says "History".
                    if logs.isEmpty {
                        ContentUnavailableView(
                            "No Queries Yet",
                            systemImage: "clock.arrow.circlepath",
                            description: Text("Queries you run on this connection appear here.")
                        )
                        .padding(.vertical, 40)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(logs) { record in
                                logRecordView(record)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
        }
        .onAppear {
            loadLogs()
        }
    }
    
    @ViewBuilder
    private func logRecordView(_ record: PostgresHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(record.executedAt, style: .time)
                    .font(MidnightMobileDesign.FontToken.captionStrong)
                    .foregroundStyle(.secondary)
                Spacer()
                if let duration = record.durationMs {
                    Text("\(duration) ms")
                        .font(MidnightMobileDesign.FontToken.captionStrong)
                        .foregroundStyle(MidnightColors.accentCyan)
                }
            }
            Text(record.sql)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(2)
            
            if let rows = record.rowsReturned {
                Text("\(rows) rows returned")
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(MidnightColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(MidnightColors.borderGray, lineWidth: 1))
    }
    
    private func loadLogs() {
        logs = PostgresHistoryStore.shared.entries(forProfile: profileId)
    }
}

