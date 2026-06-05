import Foundation

public enum ShellIntegrationCommandKind: String, Codable, CaseIterable, Hashable, Sendable {
    case notify
    case widget
    case liveActivity
}

public struct ShellIntegrationCommand: Codable, Identifiable, Equatable, Sendable {
    public var id: String?
    public var kind: ShellIntegrationCommandKind
    public var title: String?
    public var body: String?
    public var state: String?
    public var progress: Double?
    public var openURL: String?
    public var metadata: [String: String]

    public init(
        id: String? = nil,
        kind: ShellIntegrationCommandKind,
        title: String? = nil,
        body: String? = nil,
        state: String? = nil,
        progress: Double? = nil,
        openURL: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id?.trimmingCharacters(in: .whitespacesAndNewlines).shellNilIfBlank
        self.kind = kind
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).shellNilIfBlank
        self.body = body?.trimmingCharacters(in: .whitespacesAndNewlines).shellNilIfBlank
        self.state = state?.trimmingCharacters(in: .whitespacesAndNewlines).shellNilIfBlank
        self.progress = progress.map { min(1, max(0, $0)) }
        self.openURL = openURL?.trimmingCharacters(in: .whitespacesAndNewlines).shellNilIfBlank
        self.metadata = metadata.filter { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public var stableIdentifier: String {
        id ?? "\(kind.rawValue):\(title ?? body ?? UUID().uuidString)"
    }

    public static func parse(_ text: String) -> ShellIntegrationCommand? {
        parseAll(in: text).first
    }

    public static func parseAll(in text: String) -> [ShellIntegrationCommand] {
        var commands: [ShellIntegrationCommand] = []
        var searchStart = text.startIndex

        while let range = text.range(of: "pgAgent://", range: searchStart..<text.endIndex) {
            let rawURL = commandURLString(in: text, from: range.lowerBound)
            if let command = parseURLString(rawURL) {
                commands.append(command)
            }
            searchStart = rawURL.isEmpty
                ? text.index(after: range.lowerBound)
                : text.index(range.lowerBound, offsetBy: rawURL.count, limitedBy: text.endIndex) ?? text.endIndex
        }

        return commands
    }

    private static func parseURLString(_ rawURL: String) -> ShellIntegrationCommand? {
        guard let components = URLComponents(string: rawURL) else { return nil }
        let commandName = components.host?.shellNilIfBlank
            ?? components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).shellNilIfBlank
        guard let commandName else { return nil }

        let normalizedCommand = commandName
            .replacingOccurrences(of: "-", with: "")
            .lowercased()

        let kind: ShellIntegrationCommandKind
        switch normalizedCommand {
        case ShellIntegrationCommandKind.notify.rawValue.lowercased():
            kind = .notify
        case ShellIntegrationCommandKind.widget.rawValue.lowercased():
            kind = .widget
        case "liveactivity":
            kind = .liveActivity
        default:
            return nil
        }

        let queryItems = components.queryItems ?? []
        let values = Dictionary(
            queryItems.compactMap { item -> (String, String)? in
                guard let value = item.value else { return nil }
                return (item.name, value)
            },
            uniquingKeysWith: { _, newest in newest }
        )
        let reserved: Set<String> = ["id", "title", "body", "state", "progress", "url", "openURL"]
        let metadata = values.filter { !reserved.contains($0.key) }

        return ShellIntegrationCommand(
            id: values["id"],
            kind: kind,
            title: values["title"],
            body: values["body"],
            state: values["state"],
            progress: values["progress"].flatMap(Double.init),
            openURL: values["openURL"] ?? values["url"],
            metadata: metadata
        )
    }

    private static func commandURLString(in text: String, from start: String.Index) -> String {
        var end = start
        while end < text.endIndex {
            let scalar = text[end].unicodeScalars.first
            if let scalar,
               scalar.value == 7 || scalar.value == 27 || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                break
            }
            end = text.index(after: end)
        }
        return String(text[start..<end])
    }
}

public struct ShellIntegrationCommandStreamParser: Sendable {
    private var buffer: String = ""
    private let maximumBufferLength: Int

    public init(maximumBufferLength: Int = 4_096) {
        self.maximumBufferLength = max(256, maximumBufferLength)
    }

    public mutating func append(_ text: String) -> [ShellIntegrationCommand] {
        guard !text.isEmpty else { return [] }
        buffer.append(text)

        var commands: [ShellIntegrationCommand] = []
        while let terminator = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" || $0 == "\u{7}" }) {
            let segment = String(buffer[..<terminator])
            commands.append(contentsOf: ShellIntegrationCommand.parseAll(in: segment))
            buffer.removeSubrange(...terminator)
        }

        if buffer.count > maximumBufferLength {
            buffer = String(buffer.suffix(maximumBufferLength))
        }

        return commands
    }

    public mutating func flush() -> [ShellIntegrationCommand] {
        defer { buffer.removeAll() }
        return ShellIntegrationCommand.parseAll(in: buffer)
    }
}

private extension String {
    var shellNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
