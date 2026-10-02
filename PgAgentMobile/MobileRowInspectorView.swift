import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// MobileRowInspectorView — one result row, every column, full values. Wide
// tables don't fit a grid on a tablet; tapping a row opens this beside the
// grid (an `.inspector` column on iPad, a sheet on iPhone). JSON values are
// pretty-printed; every value is selectable and copyable.
//
// Deliberately no NavigationStack/title/toolbar: the inspector lives inside
// the Query tab's NavigationStack, so those would take over the main bar
// (and its database switcher). The header is part of the panel instead.
// =============================================================================
struct MobileRowInspectorView: View {
    let columns: [FfiPgColumn]
    let row: FfiPgRow
    let rowNumber: Int
    let rowCount: Int
    let onStep: (_ offset: Int) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                ForEach(visibleColumnIndices, id: \.self) { index in
                    Section {
                        value(at: index)
                    } header: {
                        HStack {
                            Text(columns[index].name)
                            Spacer()
                            Text(columns[index].typeName)
                                .font(.caption.monospaced())
                                .textCase(nil)
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 18) {
            Text(verbatim: "Row \(rowNumber) of \(rowCount)")
                .font(.headline)
                .monospacedDigit()
            Spacer()
            Button {
                onStep(-1)
            } label: {
                Label("Previous Row", systemImage: "chevron.up")
            }
            .disabled(rowNumber <= 1)
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button {
                onStep(1)
            } label: {
                Label("Next Row", systemImage: "chevron.down")
            }
            .disabled(rowNumber >= rowCount)
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button(action: onClose) {
                Label("Close", systemImage: "xmark")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Hidden `__pg_*` helpers (row identity) stay out of sight, as in the grid.
    private var visibleColumnIndices: [Int] {
        columns.indices.filter { !columns[$0].name.hasPrefix("__pg_") }
    }

    @ViewBuilder
    private func value(at index: Int) -> some View {
        if let cell = index < row.cells.count ? row.cells[index] : nil {
            Text(verbatim: PostgresCellFormatting.prettyJSON(cell) ?? cell)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = cell
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
        } else {
            Text("NULL")
                .font(.callout.monospaced())
                .foregroundStyle(.tertiary)
        }
    }
}

/// Loaded result rows as a CSV file — for the share sheet (Files, Mail…)
/// and for dragging out of the app. Holds the result's own arrays (no copy);
/// the CSV text is built only when actually shared.
struct MobileResultCSV: Transferable {
    let fileName: String
    let columns: [FfiPgColumn]
    let rows: [FfiPgRow]

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { csv in
            Data(PostgresExportEncoding.csvDocument(
                columnNames: csv.columns.map(\.name),
                rows: csv.rows.map(\.cells)
            ).utf8)
        }
        .suggestedFileName { $0.fileName }
    }
}
