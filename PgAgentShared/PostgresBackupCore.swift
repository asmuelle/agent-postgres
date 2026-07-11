import Foundation

enum PostgresBackupFormat: String, Codable, CaseIterable, Hashable, Sendable {
    case custom, tar, plain

    var pgDumpValue: String {
        switch self {
        case .custom: return "c"
        case .tar: return "t"
        case .plain: return "p"
        }
    }
}

struct PostgresBackupRequest: Codable, Equatable, Sendable {
    let profileId: String
    let profileName: String
    let host: String
    let port: UInt16
    let user: String
    let database: String
    let destinationPath: String
    let format: PostgresBackupFormat
    let dataOnly: Bool
    let schemaOnly: Bool
    let clean: Bool
}

struct PostgresRestoreRequest: Codable, Equatable, Sendable {
    let profileId: String
    let profileName: String
    let host: String
    let port: UInt16
    let user: String
    let database: String
    let sourcePath: String
    let format: PostgresBackupFormat
    let clean: Bool
    let singleTransaction: Bool
}

enum PostgresBackupCommandBuilder {
    static func preflight(for request: PostgresBackupRequest) -> String {
        let directory = URL(fileURLWithPath: request.destinationPath)
            .deletingLastPathComponent().path
        let connection = connectionArguments(
            host: request.host, port: request.port, user: request.user,
            database: request.database)
        return """
        set -eu
        command -v pg_dump >/dev/null
        command -v psql >/dev/null
        test -r "$HOME/.pgpass" || { echo 'A remote ~/.pgpass is required (mode 0600); pgAgent never places passwords in command lines.' >&2; exit 20; }
        pgpass_mode=$(stat -c '%a' "$HOME/.pgpass" 2>/dev/null || stat -f '%Lp' "$HOME/.pgpass")
        test "$pgpass_mode" = '600' || { echo 'Remote ~/.pgpass must have mode 0600.' >&2; exit 20; }
        test -d \(quote(directory)) && test -w \(quote(directory))
        test ! -e \(quote(request.destinationPath)) || { echo 'Backup destination already exists; choose a new path.' >&2; exit 23; }
        tool_major=$(pg_dump --version | sed -E 's/.* ([0-9]+).*/\\1/')
        server_num=$(psql --no-psqlrc --no-password \(connection) -Atqc 'SHOW server_version_num')
        server_major=$((server_num / 10000))
        test "$server_major" -ge 14 || { echo 'PostgreSQL 14 or newer is required.' >&2; exit 21; }
        test "$tool_major" -ge "$server_major" || { echo 'pg_dump is older than the server major version.' >&2; exit 22; }
        database_bytes=$(psql --no-psqlrc --no-password \(connection) -Atqc 'SELECT pg_database_size(current_database())')
        available_kb=$(df -Pk \(quote(directory)) | awk 'NR == 2 { print $4 }')
        required_kb=$(( (database_bytes * 12 / 10 + 1023) / 1024 ))
        test "$available_kb" -ge "$required_kb" || { echo 'Not enough free space for a safe backup (requires database size plus 20%).' >&2; exit 24; }
        printf 'PGAGENT_PREFLIGHT\\t%s\\t%s\\t%s\\t%s\\n' "$server_major" "$tool_major" "$database_bytes" "$available_kb"
        """
    }

    static func backup(for request: PostgresBackupRequest) -> String {
        let destination = quote(request.destinationPath)
        let partialAssignment = "partial=\(quote(request.destinationPath)).partial.$$"
        let connection = connectionArguments(
            host: request.host, port: request.port, user: request.user,
            database: request.database)
        var flags = ["--no-password", "--format=\(request.format.pgDumpValue)"]
        if request.dataOnly { flags.append("--data-only") }
        if request.schemaOnly { flags.append("--schema-only") }
        if request.clean { flags.append("--clean") }
        let verification: String
        switch request.format {
        case .custom, .tar:
            verification = "pg_restore --list \"$partial\" >/dev/null"
        case .plain:
            verification = "test -s \"$partial\""
        }
        return """
        set -eu
        umask 077
        \(partialAssignment)
        trap 'rm -f -- "$partial"' EXIT HUP INT TERM
        pg_dump \(flags.joined(separator: " ")) \(connection) --file="$partial"
        \(verification)
        size=$(wc -c < "$partial" | tr -d ' ')
        if command -v sha256sum >/dev/null 2>&1; then
          checksum=$(sha256sum "$partial" | awk '{print $1}')
        else
          checksum=$(shasum -a 256 "$partial" | awk '{print $1}')
        fi
        tool_major=$(pg_dump --version | sed -E 's/.* ([0-9]+).*/\\1/')
        server_num=$(psql --no-psqlrc --no-password \(connection) -Atqc 'SHOW server_version_num')
        server_major=$((server_num / 10000))
        mv -- "$partial" \(destination)
        trap - EXIT HUP INT TERM
        printf 'PGAGENT_EVIDENCE\\t%s\\t%s\\t%s\\t%s\\n' "$size" "$checksum" "$server_major" "$tool_major"
        """
    }

    static func preflight(for request: PostgresRestoreRequest) -> String {
        let connection = connectionArguments(
            host: request.host, port: request.port, user: request.user,
            database: request.database)
        let verify = request.format == .plain
            ? "test -s \(quote(request.sourcePath))"
            : "pg_restore --list \(quote(request.sourcePath)) >/dev/null"
        return """
        set -eu
        command -v psql >/dev/null
        test -r "$HOME/.pgpass" || { echo 'A remote ~/.pgpass is required (mode 0600).' >&2; exit 20; }
        pgpass_mode=$(stat -c '%a' "$HOME/.pgpass" 2>/dev/null || stat -f '%Lp' "$HOME/.pgpass")
        test "$pgpass_mode" = '600' || { echo 'Remote ~/.pgpass must have mode 0600.' >&2; exit 20; }
        \(verify)
        server_num=$(psql --no-psqlrc --no-password \(connection) -Atqc 'SHOW server_version_num')
        server_major=$((server_num / 10000))
        test "$server_major" -ge 14 || { echo 'PostgreSQL 14 or newer is required.' >&2; exit 21; }
        printf 'PGAGENT_PREFLIGHT\\t%s\\n' "$server_major"
        """
    }

    static func restore(for request: PostgresRestoreRequest) -> String {
        let connection = connectionArguments(
            host: request.host, port: request.port, user: request.user,
            database: request.database)
        if request.format == .plain {
            var flags = ["--no-psqlrc", "--no-password", "--set=ON_ERROR_STOP=1"]
            if request.singleTransaction { flags.append("--single-transaction") }
            return "set -eu\npsql \(flags.joined(separator: " ")) \(connection) --file=\(quote(request.sourcePath))"
        }
        var flags = ["--exit-on-error", "--no-password"]
        if request.clean { flags.append("--clean") }
        if request.singleTransaction { flags.append("--single-transaction") }
        return "set -eu\npg_restore \(flags.joined(separator: " ")) \(connection) \(quote(request.sourcePath))"
    }

    private static func connectionArguments(
        host: String, port: UInt16, user: String, database: String
    ) -> String {
        "--host=\(quote(host)) --port=\(port) --username=\(quote(user)) --dbname=\(quote(database))"
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct PostgresRestoreChallenge: Equatable, Sendable {
    let requiredPhrase: String?
    func accepts(_ input: String) -> Bool {
        guard let requiredPhrase else { return true }
        return input == requiredPhrase
    }
}

enum PostgresRestorePolicy {
    static func challenge(database: String, isProduction: Bool) -> PostgresRestoreChallenge {
        PostgresRestoreChallenge(requiredPhrase: isProduction ? "RESTORE \(database)" : nil)
    }
}

struct PostgresBackupEvidence: Codable, Equatable, Sendable {
    let sizeBytes: Int64
    let sha256: String
    let serverMajorVersion: Int
    let toolMajorVersion: Int
    let verifiedAt: Date
}

enum PostgresBackupEvidenceError: LocalizedError {
    case missingEvidence
    case malformedEvidence

    var errorDescription: String? {
        switch self {
        case .missingEvidence: return "Backup completed without verification evidence."
        case .malformedEvidence: return "Backup verification evidence was malformed."
        }
    }
}

enum PostgresBackupEvidenceParser {
    static func parse(_ output: String, verifiedAt: Date = Date()) throws -> PostgresBackupEvidence {
        guard let line = output.split(separator: "\n").last(where: {
            $0.hasPrefix("PGAGENT_EVIDENCE\t")
        }) else { throw PostgresBackupEvidenceError.missingEvidence }
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 5,
              let size = Int64(fields[1]),
              let server = Int(fields[3]),
              let tool = Int(fields[4])
        else { throw PostgresBackupEvidenceError.malformedEvidence }
        return PostgresBackupEvidence(
            sizeBytes: size,
            sha256: String(fields[2]),
            serverMajorVersion: server,
            toolMajorVersion: tool,
            verifiedAt: verifiedAt
        )
    }
}

enum PostgresRemoteJobProtocol {
    static func launch(token: String, command: String) -> String {
        let root = jobRoot(token)
        let quotedRoot = PostgresBackupCommandBuilder.quote(root)
        let status = PostgresBackupCommandBuilder.quote(root + "/status")
        let log = PostgresBackupCommandBuilder.quote(root + "/log")
        let pid = PostgresBackupCommandBuilder.quote(root + "/pid")
        let inner = PostgresBackupCommandBuilder.quote(command)
        return """
        set -eu
        rm -rf -- \(quotedRoot)
        mkdir -m 700 -- \(quotedRoot)
        ( set +e; sh -c \(inner); rc=$?; printf '%s\\n' "$rc" > \(status); exit 0 ) > \(log) 2>&1 &
        job_pid=$!
        printf '%s\\n' "$job_pid" > \(pid)
        printf 'PGAGENT_JOB\\t%s\\n' "$job_pid"
        """
    }

    static func poll(token: String) -> String {
        let root = jobRoot(token)
        let status = PostgresBackupCommandBuilder.quote(root + "/status")
        let log = PostgresBackupCommandBuilder.quote(root + "/log")
        return """
        if test -f \(status); then printf 'PGAGENT_DONE\\t'; cat \(status); else echo 'PGAGENT_RUNNING'; fi
        tail -c 65536 \(log) 2>/dev/null || true
        """
    }

    static func cancel(token: String) -> String {
        let root = jobRoot(token)
        let pidFile = PostgresBackupCommandBuilder.quote(root + "/pid")
        let status = PostgresBackupCommandBuilder.quote(root + "/status")
        return """
        if test -f \(pidFile); then
          pid=$(cat \(pidFile))
          pkill -TERM -P "$pid" 2>/dev/null || true
          kill -TERM "$pid" 2>/dev/null || true
          printf '130\\n' > \(status)
        fi
        """
    }

    static func cleanup(token: String) -> String {
        "rm -rf -- \(PostgresBackupCommandBuilder.quote(jobRoot(token)))"
    }

    private static func jobRoot(_ token: String) -> String {
        let safe = token.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return "/tmp/pgagent-backup-\(safe.isEmpty ? "invalid" : safe)"
    }
}

enum PostgresBackupJobKind: String, Codable, Equatable, Sendable { case backup, restore }
enum PostgresBackupJobState: String, Codable, Equatable, Sendable { case running, succeeded, failed, cancelled }

struct PostgresBackupJobRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let profileId: String
    let profileName: String
    let database: String
    let kind: PostgresBackupJobKind
    let path: String
    let startedAt: Date
    let finishedAt: Date?
    let state: PostgresBackupJobState
    let evidence: PostgresBackupEvidence?
    let message: String?
}

actor PostgresBackupJobStore {
    private let fileURL: URL

    init(fileURL: URL = PostgresBackupJobStore.defaultFileURL) { self.fileURL = fileURL }

    static var defaultFileURL: URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent("com.mc-ssh", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("postgres-backup-jobs.jsonl")
    }

    func append(_ record: PostgresBackupJobRecord) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(record)
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try data.write(to: fileURL, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func recent(profileId: String? = nil, limit: Int = 100) throws -> [PostgresBackupJobRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = data.split(separator: 0x0A).compactMap {
            try? decoder.decode(PostgresBackupJobRecord.self, from: Data($0))
        }.reversed().filter { profileId == nil || $0.profileId == profileId }
        var seen = Set<String>()
        return records.filter { seen.insert($0.id).inserted }.prefix(limit).map { $0 }
    }
}
