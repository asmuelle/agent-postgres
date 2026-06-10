import AppKit
import SwiftUI

// =============================================================================
// PostgresCellInspectorView — read-only viewer for a single cell's full value,
// opened from the results grid's "Show value…". Pretty-prints JSON/JSONB (with
// a Formatted/Raw toggle); otherwise shows the raw text. Replaces the truncated
// 200-char tooltip for large JSON, text, and bytea values.
// =============================================================================

struct PostgresCellInspectorView: View {
    let inspection: PostgresCellInspection
    @Environment(\.dismiss) private var dismiss
    @State private var formatted: Bool = true

    /// Pretty-printed JSON when the value parses as JSON, else `nil`.
    private var prettyJSON: String? {
        // No `.fragmentsAllowed`: only objects/arrays format as JSON, so a plain
        // `123` / `true` / `null` in a text column isn't mistaken for JSON.
        guard let value = inspection.value, !value.isEmpty,
              let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              )
        else { return nil }
        return String(data: pretty, encoding: .utf8)
    }

    private var canFormat: Bool { prettyJSON != nil }

    private var displayText: String {
        guard let value = inspection.value else { return "NULL" }
        if formatted, let pretty = prettyJSON { return pretty }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(inspection.columnName).font(.headline)
                    if !inspection.typeName.isEmpty {
                        Text(inspection.typeName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if canFormat {
                    Picker("", selection: $formatted) {
                        Text("Formatted").tag(true)
                        Text("Raw").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            .padding(12)

            Divider()

            ScrollView([.vertical, .horizontal]) {
                Text(displayText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(NSColor.textBackgroundColor))

            Divider()

            HStack {
                Text(inspection.value.map { "\($0.count) characters" } ?? "SQL NULL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(displayText, forType: .string)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 460, idealWidth: 620, minHeight: 320, idealHeight: 460)
    }
}
