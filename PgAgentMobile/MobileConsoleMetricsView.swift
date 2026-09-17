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
                    Text("Execution History")
                        .font(MidnightMobileDesign.FontToken.label)
                        .foregroundStyle(MidnightColors.accentCyan)
                        .padding(.horizontal)
                        .padding(.top)
                    
                    if logs.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "list.bullet.rectangle")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                            Text("No executed queries logged")
                                .font(MidnightMobileDesign.FontToken.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
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

