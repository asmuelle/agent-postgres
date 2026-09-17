import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// MARK: - CSV Text Paste/Import Sheet
struct ConnectionCSVImportView: View {
    @Environment(\.dismiss) private var dismiss
    var onImport: ([PostgresProfile]) -> Void
    
    @State private var csvText = ""
    @State private var parsedProfiles: [PostgresProfile] = []
    @State private var validationMessage: String?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Paste connection details below in CSV format:")
                    .font(MidnightMobileDesign.FontToken.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                
                Text("Format: `name,host,port,database,username,password`")
                    .font(MidnightMobileDesign.FontToken.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                
                TextEditor(text: $csvText)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(8)
                    .background(Color.black.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(MidnightColors.borderGray, lineWidth: 1))
                    .padding(.horizontal)
                    .onChange(of: csvText) { _ in
                        validateCSV()
                    }
                
                if let msg = validationMessage {
                    Text(msg)
                        .font(MidnightMobileDesign.FontToken.captionStrong)
                        .foregroundStyle(.orange)
                        .padding(.horizontal)
                }
                
                if !parsedProfiles.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ready to import \(parsedProfiles.count) profiles:")
                            .font(MidnightMobileDesign.FontToken.captionStrong)
                            .foregroundStyle(.green)
                        
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(parsedProfiles, id: \.name) { p in
                                    Text("• \(p.name) (\(p.host))")
                                        .font(MidnightMobileDesign.FontToken.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxHeight: 100)
                    }
                    .padding()
                    .background(MidnightColors.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)
                }
                
                Spacer()
            }
            .padding(.top)
            .background(MidnightColors.primaryBackground)
            .navigationTitle("Import CSV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        onImport(parsedProfiles)
                    }
                    .disabled(parsedProfiles.isEmpty)
                }
            }
        }
    }
    
    private func validateCSV() {
        parsedProfiles = []
        validationMessage = nil
        let lines = csvText.components(separatedBy: .newlines)
        
        var temp: [PostgresProfile] = []
        for line in lines {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 5 else { continue }
            
            let name = parts[0]
            let host = parts[1]
            let portStr = parts[2]
            let database = parts[3]
            let user = parts[4]
            let port = UInt16(portStr) ?? 5432
            
            guard !name.isEmpty && !host.isEmpty && !database.isEmpty && !user.isEmpty else { continue }
            
            let profile = PostgresProfile(
                name: name,
                host: host,
                port: port,
                database: database,
                user: user,
                auth: .keychain
            )
            temp.append(profile)
        }
        
        if !temp.isEmpty {
            parsedProfiles = temp
            validationMessage = "Successfully parsed \(temp.count) entries."
        } else if !csvText.isEmpty {
            validationMessage = "No valid lines parsed. Make sure to specify name, host, port, database, username."
        }
    }
}
