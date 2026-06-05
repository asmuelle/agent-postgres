import Foundation

public struct TerminalPathCandidate: Codable, Equatable, Hashable, Sendable {
    public var originalText: String
    public var remotePath: String

    public init(originalText: String, remotePath: String) {
        self.originalText = originalText
        self.remotePath = remotePath
    }
}

public enum TerminalPathDetector {
    public static func candidates(
        in text: String,
        currentDirectory: String? = nil,
        username: String? = nil,
        limit: Int = 16
    ) -> [TerminalPathCandidate] {
        let cleaned = stripANSIEscapes(from: text)
        let nsText = cleaned as NSString
        let pattern = #"(?<![:A-Za-z0-9_./-])(?:~?/|\.{1,2}/)[^\s"'`<>|;]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var seen = Set<String>()
        var output: [TerminalPathCandidate] = []
        let matches = regex.matches(
            in: cleaned,
            range: NSRange(location: 0, length: nsText.length)
        )

        for match in matches {
            guard match.range.location != NSNotFound else { continue }
            let raw = trimTerminalPathToken(nsText.substring(with: match.range))
            guard let resolved = resolve(raw, currentDirectory: currentDirectory, username: username),
                  resolved.count > 1,
                  seen.insert(resolved).inserted else {
                continue
            }
            output.append(TerminalPathCandidate(originalText: raw, remotePath: resolved))
            if output.count >= limit { break }
        }

        return output
    }

    private static func resolve(
        _ raw: String,
        currentDirectory: String?,
        username: String?
    ) -> String? {
        if raw.hasPrefix("/") {
            return normalizeAbsolute(raw)
        }

        if raw.hasPrefix("~/") {
            let home = username == "root" ? "/root" : "/home/\(username ?? "")"
            guard !home.hasSuffix("/") else { return nil }
            return normalizeAbsolute(home + String(raw.dropFirst()))
        }

        if raw.hasPrefix("./") || raw.hasPrefix("../") {
            guard let currentDirectory, currentDirectory.hasPrefix("/") else { return nil }
            return normalizeAbsolute(currentDirectory + "/" + raw)
        }

        return nil
    }

    private static func normalizeAbsolute(_ path: String) -> String {
        var parts: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !parts.isEmpty { parts.removeLast() }
            default:
                parts.append(String(component))
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func trimTerminalPathToken(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailing = CharacterSet(charactersIn: ".,:;)]}")
        while let scalar = value.unicodeScalars.last, trailing.contains(scalar) {
            value.removeLast()
        }
        return value
    }

    private static func stripANSIEscapes(from text: String) -> String {
        let pattern = #"\u{001B}\[[0-?]*[ -/]*[@-~]|\u{001B}\][^\u{0007}]*(?:\u{0007}|\u{001B}\\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}

public struct TerminalSnippetContext: Equatable, Sendable {
    public var profileName: String
    public var host: String
    public var username: String
    public var currentDirectory: String?
    public var variables: [String: String]
    public var now: Date

    public init(
        profileName: String,
        host: String,
        username: String,
        currentDirectory: String? = nil,
        variables: [String: String] = [:],
        now: Date = Date()
    ) {
        self.profileName = profileName
        self.host = host
        self.username = username
        self.currentDirectory = currentDirectory
        self.variables = variables
        self.now = now
    }
}

public enum TerminalSnippetStep: Equatable, Sendable {
    case send(String)
    case delay(milliseconds: Int)
}

public enum TerminalSnippetRenderer {
    public static func terminalSteps(
        body: String,
        context: TerminalSnippetContext
    ) -> [TerminalSnippetStep] {
        body
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .flatMap { rawLine -> [TerminalSnippetStep] in
                let line = String(rawLine)
                if let delay = delayMilliseconds(from: line) {
                    return [.delay(milliseconds: delay)]
                }
                let rendered = replaceVariables(in: line, context: context)
                return [.send(replaceControlTokens(in: rendered) + "\r")]
            }
    }

    public static func shellCommand(
        body: String,
        context: TerminalSnippetContext
    ) -> String {
        body
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .compactMap { rawLine -> String? in
                let line = String(rawLine)
                guard delayMilliseconds(from: line) == nil else { return nil }
                return removeControlTokens(from: replaceVariables(in: line, context: context))
            }
            .joined(separator: "\n")
    }

    private static func delayMilliseconds(from line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefixes = ["#delay ", "@delay ", ":delay "]
        guard let prefix = prefixes.first(where: { trimmed.hasPrefix($0) }) else { return nil }
        let raw = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasSuffix("ms") {
            return Int(raw.dropLast(2).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if raw.hasSuffix("s"), let seconds = Double(raw.dropLast().trimmingCharacters(in: .whitespacesAndNewlines)) {
            return Int(seconds * 1_000)
        }
        return Int(raw)
    }

    private static func replaceVariables(
        in line: String,
        context: TerminalSnippetContext
    ) -> String {
        var values = context.variables
        values["profile.name"] = context.profileName
        values["host"] = context.host
        values["username"] = context.username
        values["cwd"] = context.currentDirectory ?? ""
        values["date"] = Self.dateFormatter.string(from: context.now)

        var output = line
        for (key, value) in values {
            output = output.replacingOccurrences(of: "{{\(key)}}", with: value)
        }
        return output
    }

    private static func replaceControlTokens(in line: String) -> String {
        var output = line
        for (token, value) in simpleControlTokens {
            output = output.replacingOccurrences(of: "{{\(token)}}", with: value)
        }

        guard let regex = try? NSRegularExpression(pattern: #"\{\{ctrl:([A-Za-z\[\]\\\]^_?])\}\}"#) else {
            return output
        }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        let matches = regex.matches(in: output, range: range).reversed()
        for match in matches {
            guard let tokenRange = Range(match.range(at: 1), in: output),
                  let wholeRange = Range(match.range, in: output),
                  let scalar = controlScalar(for: String(output[tokenRange])) else {
                continue
            }
            output.replaceSubrange(wholeRange, with: String(UnicodeScalar(scalar)))
        }
        return output
    }

    private static func removeControlTokens(from line: String) -> String {
        var output = line
        for token in simpleControlTokens.keys {
            output = output.replacingOccurrences(of: "{{\(token)}}", with: "")
        }
        guard let regex = try? NSRegularExpression(pattern: #"\{\{ctrl:[^}]+\}\}"#) else { return output }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        return regex.stringByReplacingMatches(in: output, range: range, withTemplate: "")
    }

    private static func controlScalar(for token: String) -> UInt8? {
        guard let scalar = token.lowercased().unicodeScalars.first else { return nil }
        switch scalar {
        case "a"..."z":
            return UInt8(scalar.value - UnicodeScalar("a").value + 1)
        case "[":
            return 0x1B
        case "\\":
            return 0x1C
        case "]":
            return 0x1D
        case "^":
            return 0x1E
        case "_", "?":
            return 0x7F
        default:
            return nil
        }
    }

    private static let simpleControlTokens: [String: String] = [
        "esc": "\u{1B}",
        "tab": "\t",
        "enter": "\r",
        "return": "\r",
        "backspace": "\u{08}",
    ]

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()
}

public enum MidnightSSHDeepLinkKind: String, Codable, Equatable, Sendable {
    case monitoring
    case terminal
    case folder
    case automation
    case server
}

public struct MidnightSSHDeepLink: Codable, Equatable, Sendable {
    public var kind: MidnightSSHDeepLinkKind
    public var profileId: String?
    public var remotePath: String?
    public var operationId: String?

    public init?(_ url: URL) {
        guard url.scheme == "pgAgent", let host = url.host else { return nil }
        let parts = url.pathComponents.dropFirst()
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .reduce(into: [String: String]()) { values, item in
                values[item.name] = item.value
            } ?? [:]

        switch host {
        case "monitoring":
            kind = .monitoring
            profileId = parts.first
            remotePath = nil
            operationId = nil
        case "terminal":
            kind = .terminal
            profileId = parts.first
            remotePath = nil
            operationId = nil
        case "folder", "files":
            kind = .folder
            profileId = parts.first
            remotePath = query["path"] ?? parts.dropFirst().first
            operationId = nil
        case "automation":
            kind = .automation
            profileId = query["profile"]
            remotePath = nil
            operationId = parts.first
        case "server", "profile":
            kind = .server
            profileId = parts.first
            remotePath = nil
            operationId = nil
        default:
            return nil
        }
    }
}
