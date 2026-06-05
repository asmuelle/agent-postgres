import SwiftUI

// =============================================================================
// PostgresSavedQueryEditSheet — modal for renaming + editing a saved
// query in place. Distinct from the popover's inline "save current
// SQL" form because that form is for *new* entries built from the
// editor's contents; this one is for editing an existing entry's
// stored SQL without round-tripping through the editor.
// =============================================================================

struct PostgresSavedQueryEditSheet: View {
    let original: PostgresSavedQuery
    let onSubmit: (PostgresSavedQuery) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var sql: String = ""

    var body: some View {
        VStack(spacing: 0) {
            Text("Edit saved query")
                .font(.headline)
                .padding(.top, 16)

            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                Section("SQL") {
                    // Multi-line editor for the SQL body. Same
                    // monospaced font as the main editor for
                    // visual continuity.
                    TextEditor(text: $sql)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 160, idealHeight: 240)
                }
            }
            .formStyle(.grouped)
            .padding()

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: 360, idealHeight: 440)
        .onAppear {
            name = original.name
            sql = original.sql
        }
    }

    private func submit() {
        var updated = original
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.sql = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        onSubmit(updated)
        dismiss()
    }
}
