import SwiftUI
import OSLog
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// Postgres Visualizer Views
// Dedicated high-fidelity segmented visualizers & editors for:
// 1. Sequences (Properties card deck + DDL)
// 2. Routines (Metadata header + DDL editor)
// 3. Object Types (UDT Structure tables/grids + DDL)
//
// These views pull metadata dynamically via pgExecute catalog queries,
// keeping UI state modern and extremely premium.
// =============================================================================

enum VisualizerState<T: Sendable>: Sendable {
    case loading
    case loaded(T)
    case error(String)
}

enum VisualizerError: Error, LocalizedError {
    case notConnected
    case notFound
    case invalidResponse
    
    var errorDescription: String? {
        switch self {
        case .notConnected: return "Database connection is not available."
        case .notFound: return "The database object could not be found."
        case .invalidResponse: return "The catalog query returned an invalid response."
        }
    }
}

// MARK: - Reusable Components

struct PropertyCard: View {
    let label: String
    let value: String
    var statusPill: String? = nil
    var pillColor: Color = .green
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            
            HStack(spacing: 8) {
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
                
                if let pill = statusPill {
                    Text(pill)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(pillColor.opacity(0.15))
                        .foregroundStyle(pillColor)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .midnightMacCard()
    }
}

struct MonospacedCodeView: View {
    let code: String
    @State private var copied = false
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .background(MidnightMacDesign.ColorToken.textBackground)
            
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(code, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    Text(copied ? "Copied" : "Copy DDL")
                }
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(copied ? 0.2 : 0.1))
                .foregroundStyle(copied ? .green : Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .padding(10)
        }
        .border(MidnightMacDesign.ColorToken.separator, width: 1)
    }
}

// MARK: - Safe SQL Literal Helper
private func escapeLiteral(_ s: String) -> String {
    s.replacingOccurrences(of: "'", with: "''")
}

private func normalizeSignature(_ sig: String) -> String {
    sig.replacingOccurrences(of: " ", with: "")
       .replacingOccurrences(of: "\n", with: "")
       .lowercased()
}

// =============================================================================
// 1. ROUTINES / FUNCTIONS VISUALIZER
// =============================================================================

struct RoutineProperties: Sendable {
    let oid: String
    let language: String
    let signature: String
    let returns: String
    let description: String?
    let ddl: String
}

struct PostgresRoutineVisualizerView: View {
    let connectionId: String?
    let schema: String
    let name: String
    let signature: String
    
    @State private var state: VisualizerState<RoutineProperties> = .loading
    @State private var selectedTab: String = "DDL"
    
    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            
            switch state {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Introspecting function metadata…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
            case .error(let msg):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text("Failed to load routine details")
                        .font(.headline)
                    Text(msg)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                    Button("Retry") {
                        Task { await loadRoutine() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
            case .loaded(let props):
                if selectedTab == "Properties" {
                    propertiesGrid(props)
                } else {
                    MonospacedCodeView(code: props.ddl)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(MidnightMacDesign.ColorToken.windowBackground)
        .task(id: connectionId) {
            await loadRoutine()
        }
    }
    
    @ViewBuilder
    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "f.sign")
                .font(.title2)
                .foregroundStyle(.purple)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .bottom, spacing: 6) {
                    Text(name)
                        .font(.headline)
                    Text(signature)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text("Routine in \(schema)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Picker("", selection: $selectedTab) {
                Text("DDL").tag("DDL")
                Text("Properties").tag("Properties")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
            
            Button {
                Task { await loadRoutine() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh metadata")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
    
    @ViewBuilder
    private func propertiesGrid(_ props: RoutineProperties) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let desc = props.description {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("DESCRIPTION")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text(desc)
                            .font(.body)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .midnightMacCard()
                    }
                }
                
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 12)], spacing: 12) {
                    PropertyCard(label: "OID", value: props.oid)
                    PropertyCard(label: "Language", value: props.language.uppercased(), statusPill: "ACTIVE", pillColor: .purple)
                    PropertyCard(label: "Returns", value: props.returns)
                }
            }
            .padding(16)
        }
    }
    
    private func loadRoutine() async {
        guard let connectionId else {
            state = .error(VisualizerError.notConnected.localizedDescription)
            return
        }
        state = .loading
        let sessionId = UUID().uuidString
        defer {
            Task {
                await BridgeManager.shared.pgReleaseSession(connectionId: connectionId, sessionId: sessionId)
            }
        }
        do {
            let sql = """
            SELECT p.oid, l.lanname as language,
                   pg_get_function_arguments(p.oid) as signature,
                   pg_get_function_result(p.oid) as returns,
                   p.prosrc,
                   d.description,
                   CASE WHEN l.lanname <> 'internal' AND l.lanname <> 'c' THEN pg_get_functiondef(p.oid) ELSE NULL END AS ddl
            FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            LEFT JOIN pg_language l ON l.oid = p.prolang
            LEFT JOIN pg_description d ON d.objoid = p.oid
            WHERE n.nspname = '\(escapeLiteral(schema))' AND p.proname = '\(escapeLiteral(name))'
            """
            
            let result = try await BridgeManager.shared.pgExecute(
                connectionId: connectionId,
                sessionId: sessionId,
                sql: sql,
                pageSize: 100
            )
            
            let normalizedTarget = normalizeSignature(signature)
            var matchedRow: FfiPgRow? = nil
            for row in result.rows {
                guard row.cells.count >= 6 else { continue }
                let rowSig = row.cells[2] ?? ""
                if normalizeSignature(rowSig) == normalizedTarget {
                    matchedRow = row
                    break
                }
            }
            
            let row = matchedRow ?? result.rows.first
            guard let row = row, row.cells.count >= 6 else {
                state = .error("Function signature not found in schema '\(schema)'.")
                return
            }
            
            let oid = row.cells[0] ?? ""
            let language = row.cells[1] ?? "sql"
            let sigStr = row.cells[2] ?? ""
            let returns = row.cells[3] ?? "void"
            let prosrc = row.cells[4] ?? ""
            let description = row.cells[5] ?? ""
            
            var ddlText = ""
            if row.cells.count > 6, let ddl = row.cells[6], !ddl.isEmpty {
                ddlText = ddl
            } else {
                ddlText = """
                -- Routine: \(schema).\(name)
                -- Reconstructed DDL (Internal / C source)

                CREATE OR REPLACE FUNCTION \(schema).\(name)(\(sigStr))
                RETURNS \(returns)
                LANGUAGE \(language)
                AS \(prosrc.contains("\n") ? "$$\n" + prosrc + "\n$$" : "'\(prosrc)'");
                """
            }
            
            if !description.isEmpty {
                ddlText += "\n\nCOMMENT ON FUNCTION \(schema).\(name)(\(sigStr)) IS '\(description.replacingOccurrences(of: "'", with: "''"))';"
            }
            
            let props = RoutineProperties(
                oid: oid,
                language: language,
                signature: sigStr,
                returns: returns,
                description: description.isEmpty ? nil : description,
                ddl: ddlText
            )
            state = .loaded(props)
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}

// =============================================================================
// 2. SEQUENCES VISUALIZER
// =============================================================================

struct SequenceProperties: Sendable {
    let lastValue: String
    let incrementBy: String
    let startValue: String
    let minValue: String
    let maxValue: String
    let cacheSize: String
    let isCycled: Bool
    let description: String?
    let ddl: String
}

struct PostgresSequenceVisualizerView: View {
    let connectionId: String?
    let schema: String
    let name: String
    
    @State private var state: VisualizerState<SequenceProperties> = .loading
    @State private var selectedTab: String = "Properties"
    
    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            
            switch state {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Introspecting sequence parameters…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
            case .error(let msg):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text("Failed to load sequence details")
                        .font(.headline)
                    Text(msg)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                    Button("Retry") {
                        Task { await loadSequence() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
            case .loaded(let props):
                if selectedTab == "Properties" {
                    propertiesGrid(props)
                } else {
                    MonospacedCodeView(code: props.ddl)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(MidnightMacDesign.ColorToken.windowBackground)
        .task(id: connectionId) {
            await loadSequence()
        }
    }
    
    @ViewBuilder
    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "number")
                .font(.title2)
                .foregroundStyle(.orange)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.headline)
                Text("Sequence in \(schema)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Picker("", selection: $selectedTab) {
                Text("Properties").tag("Properties")
                Text("DDL").tag("DDL")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            
            Button {
                Task { await loadSequence() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh sequence metadata")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
    
    @ViewBuilder
    private func propertiesGrid(_ props: SequenceProperties) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let desc = props.description {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("DESCRIPTION")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text(desc)
                            .font(.body)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .midnightMacCard()
                    }
                }
                
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 300), spacing: 12)], spacing: 12) {
                    PropertyCard(label: "Current Value", value: props.lastValue, statusPill: "LIVE", pillColor: .green)
                    PropertyCard(label: "Increment By", value: props.incrementBy)
                    PropertyCard(label: "Start Value", value: props.startValue)
                    PropertyCard(label: "Min Value", value: props.minValue)
                    PropertyCard(label: "Max Value", value: props.maxValue)
                    PropertyCard(label: "Cache Size", value: props.cacheSize)
                    PropertyCard(label: "Cycles?", value: props.isCycled ? "YES" : "NO", statusPill: props.isCycled ? "CYCLE" : "NO CYCLE", pillColor: props.isCycled ? .green : .secondary)
                }
            }
            .padding(16)
        }
    }
    
    private func loadSequence() async {
        guard let connectionId else {
            state = .error(VisualizerError.notConnected.localizedDescription)
            return
        }
        state = .loading
        let sessionId = UUID().uuidString
        defer {
            Task {
                await BridgeManager.shared.pgReleaseSession(connectionId: connectionId, sessionId: sessionId)
            }
        }
        do {
            let sql = """
            SELECT s.last_value, s.increment_by, s.start_value, s.min_value, s.max_value, s.cache_size, s.is_cycled,
                   d.description
            FROM pg_sequences s
            LEFT JOIN pg_class c ON c.relname = s.sequencename
            LEFT JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = s.schemaname
            LEFT JOIN pg_description d ON d.objoid = c.oid AND d.objsubid = 0
            WHERE s.schemaname = '\(escapeLiteral(schema))' AND s.sequencename = '\(escapeLiteral(name))'
            """
            
            let result = try await BridgeManager.shared.pgExecute(
                connectionId: connectionId,
                sessionId: sessionId,
                sql: sql,
                pageSize: 10
            )
            
            guard let row = result.rows.first, row.cells.count >= 7 else {
                state = .error("Sequence '\(schema).\(name)' not found in pg_sequences.")
                return
            }
            
            let lastValue = row.cells[0] ?? "1"
            let incrementBy = row.cells[1] ?? "1"
            let startValue = row.cells[2] ?? "1"
            let minValue = row.cells[3] ?? "1"
            let maxValue = row.cells[4] ?? "9223372036854775807"
            let cacheSize = row.cells[5] ?? "1"
            let cycledRaw = row.cells[6] ?? "f"
            let isCycled = cycledRaw == "t" || cycledRaw == "true"
            let description = row.cells.count > 7 ? row.cells[7] : nil
            
            var ddlText = """
            -- Sequence: \(schema).\(name)
            -- Reconstructed DDL

            CREATE SEQUENCE IF NOT EXISTS \(schema).\(name)
                INCREMENT BY \(incrementBy)
                START WITH \(startValue)
                MINVALUE \(minValue)
                MAXVALUE \(maxValue)
                CACHE \(cacheSize)
                \(isCycled ? "CYCLE" : "NO CYCLE");
            """
            
            if let desc = description, !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ddlText += "\n\nCOMMENT ON SEQUENCE \(schema).\(name) IS '\(desc.replacingOccurrences(of: "'", with: "''"))';"
            }
            
            let props = SequenceProperties(
                lastValue: lastValue,
                incrementBy: incrementBy,
                startValue: startValue,
                minValue: minValue,
                maxValue: maxValue,
                cacheSize: cacheSize,
                isCycled: isCycled,
                description: description,
                ddl: ddlText
            )
            state = .loaded(props)
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}

// =============================================================================
// 3. OBJECT TYPES (UDT) VISUALIZER
// =============================================================================

struct CompositeAttr: Hashable, Sendable {
    let name: String
    let type: String
    let attnum: Int
}

struct DomainConstraint: Hashable, Sendable {
    let name: String
    let definition: String
}

enum UdtStructure: Sendable {
    case enumType(variants: [String])
    case compositeType(attributes: [CompositeAttr])
    case domainType(baseType: String, defaultVal: String?, notNull: Bool, constraints: [DomainConstraint])
    case rangeType(subtype: String, opclass: String?, collation: String?)
    case otherType(details: String)
}

struct ObjectTypeProperties: Sendable {
    let oid: String
    let typname: String
    let typtype: String
    let description: String?
    let structure: UdtStructure
    let ddl: String
}

struct PostgresObjectTypeVisualizerView: View {
    let connectionId: String?
    let schema: String
    let name: String
    let typeKind: String
    
    @State private var state: VisualizerState<ObjectTypeProperties> = .loading
    @State private var selectedTab: String = "Structure"
    
    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            
            switch state {
            case .loading:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Introspecting custom object type…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
            case .error(let msg):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text("Failed to load type details")
                        .font(.headline)
                    Text(msg)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                    Button("Retry") {
                        Task { await loadObjectType() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
            case .loaded(let props):
                if selectedTab == "Structure" {
                    structureView(props)
                } else {
                    MonospacedCodeView(code: props.ddl)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(MidnightMacDesign.ColorToken.windowBackground)
        .task(id: connectionId) {
            await loadObjectType()
        }
    }
    
    @ViewBuilder
    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "cube")
                .font(.title2)
                .foregroundStyle(.teal)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.headline)
                    Text(typeKind.uppercased())
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Text("User-defined type in \(schema)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Picker("", selection: $selectedTab) {
                Text("Structure").tag("Structure")
                Text("DDL").tag("DDL")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            
            Button {
                Task { await loadObjectType() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh type metadata")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
    
    @ViewBuilder
    private func structureView(_ props: ObjectTypeProperties) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let desc = props.description {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("DESCRIPTION")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text(desc)
                            .font(.body)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .midnightMacCard()
                    }
                }
                
                switch props.structure {
                case .enumType(let variants):
                    enumStructureView(variants: variants)
                    
                case .compositeType(let attributes):
                    compositeStructureView(attributes: attributes)
                    
                case .domainType(let baseType, let defaultVal, let notNull, let constraints):
                    domainStructureView(baseType: baseType, defaultVal: defaultVal, notNull: notNull, constraints: constraints)
                    
                case .rangeType(let subtype, let opclass, let collation):
                    rangeStructureView(subtype: subtype, opclass: opclass, collation: collation)
                    
                case .otherType(let details):
                    VStack(alignment: .leading, spacing: 6) {
                        Text("DETAILS")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text(details)
                            .font(.system(.body, design: .monospaced))
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .midnightMacCard()
                    }
                }
            }
            .padding(16)
        }
    }
    
    @ViewBuilder
    private func enumStructureView(variants: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ENUM LABELS (ORDERED)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            
            VStack(spacing: 0) {
                HStack {
                    Text("Index").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                    Text("Label").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(MidnightMacDesign.ColorToken.controlBackground)
                
                Divider()
                
                ForEach(Array(variants.enumerated()), id: \.offset) { index, variant in
                    HStack {
                        Text("#\(index + 1)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .leading)
                        Text(variant)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    if index < variants.count - 1 {
                        Divider()
                    }
                }
            }
            .midnightMacCard()
            .border(MidnightMacDesign.ColorToken.separator, width: 1)
        }
    }
    
    @ViewBuilder
    private func compositeStructureView(attributes: [CompositeAttr]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ATTRIBUTES")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            
            VStack(spacing: 0) {
                HStack {
                    Text("Position").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                    Text("Attribute Name").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).frame(width: 180, alignment: .leading)
                    Text("Data Type").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(MidnightMacDesign.ColorToken.controlBackground)
                
                Divider()
                
                ForEach(attributes, id: \.attnum) { attr in
                    HStack {
                        Text("#\(attr.attnum)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .leading)
                        Text(attr.name)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 180, alignment: .leading)
                        Text(attr.type)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    if attr.attnum < attributes.count {
                        Divider()
                    }
                }
            }
            .midnightMacCard()
            .border(MidnightMacDesign.ColorToken.separator, width: 1)
        }
    }
    
    @ViewBuilder
    private func domainStructureView(
        baseType: String,
        defaultVal: String?,
        notNull: Bool,
        constraints: [DomainConstraint]
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("PROPERTIES")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 300), spacing: 12)], spacing: 12) {
                PropertyCard(label: "Base Type", value: baseType)
                PropertyCard(label: "Default Value", value: defaultVal ?? "NULL")
                PropertyCard(label: "Nullability", value: notNull ? "NOT NULL" : "NULLABLE", statusPill: notNull ? "NOT NULL" : "NULL", pillColor: notNull ? .orange : .secondary)
            }
            
            if !constraints.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ACTIVE CONSTRAINTS")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    
                    VStack(spacing: 0) {
                        ForEach(Array(constraints.enumerated()), id: \.offset) { index, con in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(con.name)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text(con.definition)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.primary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if index < constraints.count - 1 {
                                Divider()
                            }
                        }
                    }
                    .midnightMacCard()
                    .border(MidnightMacDesign.ColorToken.separator, width: 1)
                }
            }
        }
    }
    
    @ViewBuilder
    private func rangeStructureView(subtype: String, opclass: String?, collation: String?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("RANGE DETAILS")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 300), spacing: 12)], spacing: 12) {
                PropertyCard(label: "Subtype", value: subtype)
                PropertyCard(label: "Operator Class", value: opclass ?? "DEFAULT")
                PropertyCard(label: "Collation", value: collation ?? "DEFAULT")
            }
        }
    }
    
    private func loadObjectType() async {
        guard let connectionId else {
            state = .error(VisualizerError.notConnected.localizedDescription)
            return
        }
        state = .loading
        let sessionId = UUID().uuidString
        defer {
            Task {
                await BridgeManager.shared.pgReleaseSession(connectionId: connectionId, sessionId: sessionId)
            }
        }
        do {
            let sql = """
            SELECT t.oid, t.typtype, t.typname, d.description,
                   bt.typname as base_type_name,
                   t.typdefault,
                   t.typnotnull,
                   rng.rngsubtype
            FROM pg_type t
            JOIN pg_namespace n ON n.oid = t.typnamespace
            LEFT JOIN pg_description d ON d.objoid = t.oid
            LEFT JOIN pg_type bt ON bt.oid = t.typbasetype
            LEFT JOIN pg_range rng ON rng.rngtypid = t.oid
            WHERE n.nspname = '\(escapeLiteral(schema))' AND t.typname = '\(escapeLiteral(name))'
            """
            
            let result = try await BridgeManager.shared.pgExecute(
                connectionId: connectionId,
                sessionId: sessionId,
                sql: sql,
                pageSize: 10
            )
            
            guard let firstRow = result.rows.first, firstRow.cells.count >= 3 else {
                state = .error("Type '\(schema).\(name)' not found in pg_type.")
                return
            }
            
            let oid = firstRow.cells[0] ?? ""
            let typtype = firstRow.cells[1] ?? ""
            let typname = firstRow.cells[2] ?? ""
            let description = firstRow.cells.count > 3 ? firstRow.cells[3] : nil
            let baseTypeName = firstRow.cells.count > 4 ? firstRow.cells[4] : nil
            let typDefault = firstRow.cells.count > 5 ? firstRow.cells[5] : nil
            let typNotNullRaw = firstRow.cells.count > 6 ? firstRow.cells[6] : "f"
            let typNotNull = typNotNullRaw == "t" || typNotNullRaw == "true"
            
            var structure: UdtStructure = .otherType(details: "Type: \(typname), OID: \(oid)")
            var ddlText = ""
            
            if typtype == "e" {
                // Enum
                let enumSql = "SELECT enumlabel FROM pg_enum WHERE enumtypid = \(oid) ORDER BY enumsortorder;"
                let enumRes = try await BridgeManager.shared.pgExecute(
                    connectionId: connectionId,
                    sessionId: sessionId,
                    sql: enumSql,
                    pageSize: 1000
                )
                let variants = enumRes.rows.compactMap { row -> String? in
                    guard let cell = row.cells.first else { return nil }
                    return cell
                }
                structure = .enumType(variants: variants)
                
                ddlText = """
                -- Object Type: \(schema).\(name)
                -- Reconstructed UDT (Enum)

                CREATE TYPE \(schema).\(name) AS ENUM (
                    \(variants.map { "'\($0)'" }.joined(separator: ",\n    "))
                );
                """
            } else if typtype == "c" {
                // Composite
                let compSql = """
                SELECT a.attname, format_type(a.atttypid, a.atttypmod) as attribute_type, a.attnum
                FROM pg_attribute a
                WHERE a.attrelid = (SELECT typrelid FROM pg_type WHERE oid = \(oid))
                  AND a.attnum > 0
                  AND NOT a.attisdropped
                ORDER BY a.attnum;
                """
                let compRes = try await BridgeManager.shared.pgExecute(
                    connectionId: connectionId,
                    sessionId: sessionId,
                    sql: compSql,
                    pageSize: 1000
                )
                var attributes: [CompositeAttr] = []
                for row in compRes.rows {
                    guard row.cells.count >= 2 else { continue }
                    let attrName = row.cells[0] ?? ""
                    let attrType = row.cells[1] ?? ""
                    let attnumStr = row.cells.count > 2 ? (row.cells[2] ?? "0") : "0"
                    let attnum = Int(attnumStr) ?? 0
                    attributes.append(CompositeAttr(name: attrName, type: attrType, attnum: attnum))
                }
                structure = .compositeType(attributes: attributes)
                
                ddlText = """
                -- Object Type: \(schema).\(name)
                -- Reconstructed UDT (Composite)

                CREATE TYPE \(schema).\(name) AS (
                    \(attributes.map { "\($0.name) \($0.type)" }.joined(separator: ",\n    "))
                );
                """
            } else if typtype == "d" {
                // Domain
                let domSql = """
                SELECT conname, pg_get_constraintdef(oid) as constraint_definition
                FROM pg_constraint
                WHERE contypid = \(oid);
                """
                let domRes = try await BridgeManager.shared.pgExecute(
                    connectionId: connectionId,
                    sessionId: sessionId,
                    sql: domSql,
                    pageSize: 100
                )
                var constraints: [DomainConstraint] = []
                for row in domRes.rows {
                    guard row.cells.count >= 2 else { continue }
                    let conName = row.cells[0] ?? ""
                    let conDef = row.cells[1] ?? ""
                    constraints.append(DomainConstraint(name: conName, definition: conDef))
                }
                let base = baseTypeName ?? "unknown"
                structure = .domainType(baseType: base, defaultVal: typDefault, notNull: typNotNull, constraints: constraints)
                
                var constrLines = ""
                if !constraints.isEmpty {
                    constrLines = "\n    " + constraints.map { "CONSTRAINT \($0.name) \($0.definition)" }.joined(separator: ",\n    ")
                }
                
                ddlText = """
                -- Object Type: \(schema).\(name)
                -- Reconstructed UDT (Domain)

                CREATE DOMAIN \(schema).\(name) AS \(base)
                    \(typDefault != nil ? "DEFAULT \(typDefault!)" : "")
                    \(typNotNull ? "NOT NULL" : "NULL")\(constrLines);
                """
            } else if typtype == "r" {
                // Range
                let rngSql = """
                SELECT format_type(r.rngsubtype, NULL) as subtype_name,
                       opc.opcname as operator_class,
                       coll.collname as collation
                FROM pg_range r
                LEFT JOIN pg_opclass opc ON opc.oid = r.rngsubopc
                LEFT JOIN pg_collation coll ON coll.oid = r.rngcollation
                WHERE r.rngtypid = \(oid);
                """
                let rngRes = try await BridgeManager.shared.pgExecute(
                    connectionId: connectionId,
                    sessionId: sessionId,
                    sql: rngSql,
                    pageSize: 10
                )
                
                if let rRow = rngRes.rows.first, rRow.cells.count >= 1 {
                    let subTypeName = rRow.cells[0] ?? "unknown"
                    let opc = rRow.cells.count > 1 ? rRow.cells[1] : nil
                    let coll = rRow.cells.count > 2 ? rRow.cells[2] : nil
                    structure = .rangeType(subtype: subTypeName, opclass: opc, collation: coll)
                    
                    ddlText = """
                    -- Object Type: \(schema).\(name)
                    -- Reconstructed UDT (Range)

                    CREATE TYPE \(schema).\(name) AS RANGE (
                        SUBTYPE = \(subTypeName)
                        \(opc != nil ? ", SUBTYPE_OPCLASS = \(opc!)" : "")
                        \(coll != nil ? ", COLLATION = \(coll!)" : "")
                    );
                    """
                } else {
                    structure = .otherType(details: "Range details missing for \(name)")
                }
            } else {
                structure = .otherType(details: "Type: \(typname) (typtype: \(typtype)), OID: \(oid)")
                ddlText = "-- Dynamic DDL not supported for type kind '\(typtype)'."
            }
            
            if let desc = description, !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ddlText += "\n\nCOMMENT ON TYPE \(schema).\(name) IS '\(desc.replacingOccurrences(of: "'", with: "''"))';"
            }
            
            let props = ObjectTypeProperties(
                oid: oid,
                typname: typname,
                typtype: typtype,
                description: description,
                structure: structure,
                ddl: ddlText
            )
            state = .loaded(props)
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}
