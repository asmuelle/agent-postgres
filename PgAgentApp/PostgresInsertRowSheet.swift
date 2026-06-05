import PgAgentMacOS
import SwiftUI

// =============================================================================
// PostgresInsertRowSheet — modal that builds an INSERT row payload.
//
// Each visible column gets one form row with three controls:
//   - Text field for the value
//   - "Use DEFAULT" toggle  (server-side default applies)
//   - "NULL" toggle          (write SQL NULL)
//
// We don't try to read column nullability or default presence from
// the schema (would require a separate `pg_attribute` query); the
// user picks the right combination, and an invalid one (NULL into
// NOT NULL, no default into a required column) surfaces as a
// server error the caller's alert path catches.
// =============================================================================

/// Per-column form state. `useDefault` and `useNull` are mutually
/// exclusive; both off means "send the typed value".
struct PostgresInsertColumnForm: Identifiable {
    let id = UUID()
    let columnName: String
    let typeName: String
    /// `true` when this column should be omitted from the INSERT
    /// (server provides its default).
    var useDefault: Bool
    /// `true` when this column should be sent as SQL NULL.
    var useNull: Bool
    var textValue: String
}

struct PostgresInsertRowSheet: View {
    let target: PostgresEditTarget
    /// Columns the user can set explicitly. Hidden internal columns
    /// (`__pg_*`) are filtered before being passed in.
    let columns: [FfiPgColumn]
    /// All visible columns in the existing result, including the
    /// hidden `__pg_rowid__`. Used to drive RETURNING so the new
    /// row matches the grid shape.
    let returnColumnNames: [String]
    /// Optional column metadata fetched from `pg_attribute`. When
    /// present, the form pre-sets toggles smartly (Use DEFAULT for
    /// columns with defaults, NULL disabled for NOT NULL columns,
    /// generated columns hidden entirely). When absent (caller
    /// hasn't loaded it yet), the sheet falls back to the generic
    /// "everything starts as Use DEFAULT" behavior.
    var columnDetails: [FfiPgColumnDetail]? = nil
    /// Invoked with the user's filled-in form. Closure runs the FFI
    /// INSERT + appends the new row to the store on success;
    /// completion is passed back via `complete` so the sheet can
    /// dismiss or surface an error.
    let onSubmit: ([PostgresInsertColumnForm], [String], @escaping (Result<Void, Error>) -> Void) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var forms: [PostgresInsertColumnForm] = []
    @State private var isSubmitting: Bool = false
    @State private var submitError: String? = nil

    /// Metadata-aware NULL toggle disabling: NOT NULL columns
    /// shouldn't be settable to NULL via the toggle, since the
    /// server would reject it.
    private func columnIsNotNull(_ name: String) -> Bool {
        columnDetails?.first(where: { $0.name == name })?.notNull ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(minWidth: 480, idealWidth: 540, maxWidth: 700,
               minHeight: 320, idealHeight: 480, maxHeight: 720)
        .onAppear { primeForms() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Insert row")
                .font(.headline)
            Text("\(target.schema).\(target.table)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var form: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(forms.indices, id: \.self) { idx in
                    rowEditor(at: idx)
                    if idx < forms.count - 1 {
                        Divider().padding(.leading, 12)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func rowEditor(at idx: Int) -> some View {
        let form = forms[idx]
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(form.columnName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(form.typeName.isEmpty ? " " : form.typeName)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 140, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                TextField("value", text: Binding(
                    get: { forms[idx].textValue },
                    set: { forms[idx].textValue = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .disabled(form.useDefault || form.useNull)

                HStack(spacing: 16) {
                    Toggle("Use DEFAULT", isOn: Binding(
                        get: { forms[idx].useDefault },
                        set: { val in
                            forms[idx].useDefault = val
                            if val { forms[idx].useNull = false }
                        }
                    ))
                    Toggle("NULL", isOn: Binding(
                        get: { forms[idx].useNull },
                        set: { val in
                            forms[idx].useNull = val
                            if val { forms[idx].useDefault = false }
                        }
                    ))
                    .disabled(columnIsNotNull(form.columnName))
                    .help(columnIsNotNull(form.columnName)
                          ? "Column is NOT NULL"
                          : "Write SQL NULL")
                    Spacer()
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let submitError {
                Label(submitError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Button(isSubmitting ? "Inserting…" : "Insert") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting)
            }
        }
        .padding(16)
    }

    // MARK: - Actions

    private func primeForms() {
        guard forms.isEmpty else { return }
        // Build a quick name→detail lookup so we don't iterate the
        // metadata list per column.
        let detailByName: [String: FfiPgColumnDetail] = Dictionary(
            uniqueKeysWithValues: (columnDetails ?? []).map { ($0.name, $0) }
        )

        forms = columns.compactMap { col in
            let detail = detailByName[col.name]
            // Generated columns can't be set on INSERT — Postgres
            // rejects "cannot insert a non-DEFAULT value into
            // column…" — so we hide them from the form entirely.
            if detail?.isGenerated == true { return nil }

            // Default toggle state:
            //   - has default:               Use DEFAULT (skip column)
            //   - NOT NULL & no default:     prompt user (no toggle)
            //   - nullable & no default:     NULL (writes NULL)
            //   - unknown (no metadata):     Use DEFAULT (matches v1)
            let useDefault: Bool
            let useNull: Bool
            switch (detail?.hasDefault ?? false, detail?.notNull ?? false, detail != nil) {
            case (true, _, _):
                useDefault = true
                useNull = false
            case (false, false, true):
                useDefault = false
                useNull = true
            case (false, true, true):
                useDefault = false
                useNull = false
            default:
                // No metadata — fall back to v1 behavior.
                useDefault = true
                useNull = false
            }

            return PostgresInsertColumnForm(
                columnName: col.name,
                typeName: col.typeName,
                useDefault: useDefault,
                useNull: useNull,
                textValue: ""
            )
        }
    }

    private func submit() {
        submitError = nil
        isSubmitting = true
        onSubmit(forms, returnColumnNames) { result in
            isSubmitting = false
            switch result {
            case .success:
                dismiss()
            case .failure(let error):
                submitError = error.localizedDescription
            }
        }
    }
}
