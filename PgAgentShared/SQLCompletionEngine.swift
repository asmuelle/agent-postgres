import Foundation

// =============================================================================
// SQLCompletionEngine — pure, platform-neutral schema-aware SQL completion.
//
// Input: the full editor text, a UTF-16 cursor offset (NSTextView's native
// coordinate space), and an immutable `SQLCompletionCatalog` snapshot.
// Output: a ranked list of insertion-ready completions. No I/O, no AppKit —
// the engine never loads schema metadata; it only reports which referenced
// relations *lack* column data so the editor can ask the store to prefetch.
//
// Context model (heuristic, not a SQL parser — limits documented inline):
//   - after FROM / JOIN / INTO / UPDATE / TABLE  → tables + views (+ schemas)
//   - after `alias.` / `table.` / `schema.table.` → that relation's columns
//   - after `schema.`                             → that schema's relations
//   - after SELECT / WHERE / ON / GROUP BY / …    → in-scope columns
//                                                   (+ functions + keywords)
//   - after `::`                                  → common type names
//   - anywhere else                               → keywords + schemas + tables
//   - inside string literals / comments / quoted identifiers → nothing
//
// Alias resolution is a lightweight token scan of the current statement
// (semicolon-delimited), both sides of the cursor. It understands
// `FROM t`, `FROM t a`, `FROM t AS a`, comma lists, JOIN chains, and
// `schema.t`. Known limits: subqueries are skipped wholesale (their aliases
// contribute no columns), CTE names are not resolved, LATERAL/function
// aliases are ignored, and scoping is flat — an outer query sees inner
// aliases. Good enough for interactive completion; wrong answers are merely
// unranked noise, never inserted without the user picking them.
// =============================================================================

struct SQLCompletionItem: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case keyword, function, type, schema, relation, column, alias
    }

    /// Exactly what gets inserted at the caret — identifiers pre-quoted iff
    /// needed, keywords uppercased.
    let insertText: String
    let kind: Kind
}

struct SQLCompletionResult: Sendable {
    var items: [SQLCompletionItem]
    /// Relations referenced by the current statement whose columns aren't in
    /// the catalog snapshot. The editor may ask the schema store to load
    /// them so the next trigger completes columns.
    var relationsNeedingColumns: [SQLCompletionCatalog.Relation]

    static let empty = SQLCompletionResult(items: [], relationsNeedingColumns: [])
}

enum SQLCompletionEngine {
    /// Hard cap on returned completions — past this the popup is noise.
    private static let maxItems = 80

    // MARK: - Public entry

    static func complete(
        sql: String,
        cursorUTF16: Int,
        catalog: SQLCompletionCatalog
    ) -> SQLCompletionResult {
        let clamped = max(0, min(cursorUTF16, sql.utf16.count))
        let cursor = String.Index(utf16Offset: clamped, in: sql)

        let lexed = tokenize(sql, cursor: cursor)
        if lexed.cursorSuppressed { return .empty }

        // Identifier run immediately behind the cursor = the partial word.
        var partialStart = cursor
        while partialStart > sql.startIndex {
            let prev = sql.index(before: partialStart)
            if isIdentChar(sql[prev]) { partialStart = prev } else { break }
        }
        let partial = String(sql[partialStart..<cursor])

        // Current statement = tokens between the surrounding semicolons.
        // Alias scanning uses the whole statement (a SELECT-list completion
        // needs the FROM clause that comes *after* the cursor); context
        // classification only looks backwards.
        let statement = statementTokens(lexed.tokens, around: cursor)
        let before = statement.filter { $0.end <= partialStart }
        let scope = scopeRelations(in: statement)

        var needingColumns: [SQLCompletionCatalog.Relation] = []
        func noteNeedsColumns(_ rel: SQLCompletionCatalog.Relation) {
            if rel.columns.isEmpty, !needingColumns.contains(rel) {
                needingColumns.append(rel)
            }
        }
        for s in scope {
            if let rel = resolve(s, in: catalog) { noteNeedsColumns(rel) }
        }

        let candidates: [Candidate]
        switch classify(before: before, partialStart: partialStart) {
        case .qualified(let schema, let name):
            candidates = qualifiedCandidates(
                schema: schema, name: name,
                scope: scope, catalog: catalog,
                noteNeedsColumns: noteNeedsColumns
            )

        case .relations:
            candidates = relationCandidates(catalog: catalog, schemaFilter: nil, rankBase: 0)
                + schemaCandidates(catalog: catalog, rank: 2)

        case .columns:
            candidates = columnCandidates(scope: scope, catalog: catalog)
                + functionCandidates(rank: 2)
                + keywordCandidates(rank: 3)

        case .insertColumns(let target):
            candidates = qualifiedCandidates(
                schema: target.schema, name: target.name,
                scope: scope, catalog: catalog,
                noteNeedsColumns: noteNeedsColumns
            )

        case .types:
            candidates = SQLCompletionVocabulary.types.map {
                Candidate(insertText: $0, kind: .type, filterText: $0, rank: 0)
            }

        case .bare:
            candidates = keywordCandidates(rank: 0)
                + schemaCandidates(catalog: catalog, rank: 1)
                + relationCandidates(catalog: catalog, schemaFilter: nil, rankBase: 2)
        }

        return SQLCompletionResult(
            items: finalize(candidates, partial: partial),
            relationsNeedingColumns: needingColumns
        )
    }

    // MARK: - Tokenizer

    struct Token {
        enum Kind: Equatable {
            case identifier
            case quotedIdentifier
            case number
            case symbol(Character)
        }

        let kind: Kind
        /// Normalized text — the inner (unescaped) name for quoted
        /// identifiers, raw text otherwise.
        let text: String
        let start: String.Index
        let end: String.Index

        var upper: String { text.uppercased() }
        var isIdent: Bool { kind == .identifier || kind == .quotedIdentifier }
        var isKeyword: Bool {
            kind == .identifier && SQLCompletionVocabulary.keywordSet.contains(upper)
        }
        func isSymbol(_ c: Character) -> Bool { kind == .symbol(c) }
    }

    static func isIdentChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "$"
    }

    private static func isIdentStart(_ c: Character) -> Bool {
        c.isLetter || c == "_"
    }

    /// Lex `sql` into tokens, dropping comments and string literals but
    /// remembering whether `cursor` sits inside one (→ suppress completion).
    static func tokenize(
        _ sql: String, cursor: String.Index
    ) -> (tokens: [Token], cursorSuppressed: Bool) {
        var tokens: [Token] = []
        var suppressed = false
        var i = sql.startIndex
        let end = sql.endIndex

        func char(after idx: String.Index) -> Character? {
            let next = sql.index(after: idx)
            return next < end ? sql[next] : nil
        }

        while i < end {
            let c = sql[i]

            if c.isWhitespace {
                i = sql.index(after: i)
                continue
            }

            // Line comment: -- … to end of line. The cursor counts as inside
            // through the end of the line (typing there appends to the comment).
            if c == "-", char(after: i) == "-" {
                let start = i
                while i < end, sql[i] != "\n" { i = sql.index(after: i) }
                if cursor > start, cursor <= i { suppressed = true }
                continue
            }

            // Block comment, nested per Postgres rules.
            if c == "/", char(after: i) == "*" {
                let start = i
                var depth = 0
                while i < end {
                    if sql[i] == "/", char(after: i) == "*" {
                        depth += 1
                        i = sql.index(i, offsetBy: 2)
                    } else if sql[i] == "*", char(after: i) == "/" {
                        depth -= 1
                        i = sql.index(i, offsetBy: 2)
                        if depth == 0 { break }
                    } else {
                        i = sql.index(after: i)
                    }
                }
                let terminated = depth == 0
                if cursor > start, !terminated || cursor < i { suppressed = true }
                continue
            }

            // String literal with '' escapes.
            if c == "'" {
                let start = i
                i = sql.index(after: i)
                var terminated = false
                while i < end {
                    if sql[i] == "'" {
                        if char(after: i) == "'" {
                            i = sql.index(i, offsetBy: 2)
                        } else {
                            i = sql.index(after: i)
                            terminated = true
                            break
                        }
                    } else {
                        i = sql.index(after: i)
                    }
                }
                if cursor > start, !terminated || cursor < i { suppressed = true }
                continue
            }

            // Dollar-quoted string: $$ … $$ or $tag$ … $tag$.
            if c == "$" {
                var j = sql.index(after: i)
                while j < end, isIdentChar(sql[j]), sql[j] != "$" { j = sql.index(after: j) }
                if j < end, sql[j] == "$" {
                    let tag = String(sql[i...j])
                    let bodyStart = sql.index(after: j)
                    if let close = sql.range(of: tag, range: bodyStart..<end) {
                        if cursor > i, cursor < close.upperBound { suppressed = true }
                        i = close.upperBound
                    } else {
                        if cursor > i { suppressed = true }
                        i = end
                    }
                    continue
                }
                // Bare `$1` positional parameter or stray `$` — symbol.
                tokens.append(Token(kind: .symbol("$"), text: "$", start: i, end: sql.index(after: i)))
                i = sql.index(after: i)
                continue
            }

            // Quoted identifier with "" escapes. Completion inside one is
            // suppressed — the engine can't know if the name is finished.
            if c == "\"" {
                let start = i
                i = sql.index(after: i)
                var inner = ""
                var terminated = false
                while i < end {
                    if sql[i] == "\"" {
                        if char(after: i) == "\"" {
                            inner.append("\"")
                            i = sql.index(i, offsetBy: 2)
                        } else {
                            i = sql.index(after: i)
                            terminated = true
                            break
                        }
                    } else {
                        inner.append(sql[i])
                        i = sql.index(after: i)
                    }
                }
                if cursor > start, !terminated || cursor < i { suppressed = true }
                tokens.append(Token(kind: .quotedIdentifier, text: inner, start: start, end: i))
                continue
            }

            if isIdentStart(c) {
                let start = i
                while i < end, isIdentChar(sql[i]) { i = sql.index(after: i) }
                tokens.append(Token(kind: .identifier, text: String(sql[start..<i]), start: start, end: i))
                continue
            }

            if c.isNumber {
                let start = i
                while i < end, sql[i].isNumber || sql[i] == "." { i = sql.index(after: i) }
                tokens.append(Token(kind: .number, text: String(sql[start..<i]), start: start, end: i))
                continue
            }

            tokens.append(Token(kind: .symbol(c), text: String(c), start: i, end: sql.index(after: i)))
            i = sql.index(after: i)
        }

        return (tokens, suppressed)
    }

    /// Slice of `tokens` between the semicolon before and after `cursor`.
    private static func statementTokens(_ tokens: [Token], around cursor: String.Index) -> [Token] {
        var start = 0
        var end = tokens.count
        for (idx, t) in tokens.enumerated() {
            guard t.isSymbol(";") else { continue }
            if t.end <= cursor {
                start = idx + 1
            } else if t.start >= cursor {
                end = idx
                break
            }
        }
        return start <= end ? Array(tokens[start..<end]) : []
    }

    // MARK: - Alias / scope scan

    struct ScopeRelation: Equatable {
        let schema: String?
        let name: String
        let alias: String?
    }

    /// Relations (with optional aliases) referenced by FROM / JOIN / UPDATE /
    /// INSERT INTO / TABLE clauses of one statement. See header for limits.
    static func scopeRelations(in tokens: [Token]) -> [ScopeRelation] {
        let starters: Set<String> = ["FROM", "JOIN", "UPDATE", "INTO", "TABLE"]
        var result: [ScopeRelation] = []
        var i = 0

        while i < tokens.count {
            guard tokens[i].kind == .identifier, starters.contains(tokens[i].upper) else {
                i += 1
                continue
            }
            let allowsCommaList = tokens[i].upper == "FROM"
            i += 1

            refLoop: while i < tokens.count {
                if tokens[i].isSymbol("(") {
                    // Subquery / VALUES list: skip the balanced group and any
                    // trailing alias. Its columns are unknown to the engine.
                    var depth = 1
                    i += 1
                    while i < tokens.count, depth > 0 {
                        if tokens[i].isSymbol("(") { depth += 1 }
                        if tokens[i].isSymbol(")") { depth -= 1 }
                        i += 1
                    }
                    if i < tokens.count, tokens[i].kind == .identifier, tokens[i].upper == "AS" { i += 1 }
                    if i < tokens.count, tokens[i].isIdent, !tokens[i].isKeyword { i += 1 }
                } else {
                    guard i < tokens.count, tokens[i].isIdent, !tokens[i].isKeyword else { break refLoop }
                    var schema: String? = nil
                    var name = tokens[i].text
                    i += 1
                    if i + 1 < tokens.count, tokens[i].isSymbol("."), tokens[i + 1].isIdent {
                        schema = name
                        name = tokens[i + 1].text
                        i += 2
                    }
                    var alias: String? = nil
                    if i < tokens.count, tokens[i].kind == .identifier, tokens[i].upper == "AS" {
                        i += 1
                        if i < tokens.count, tokens[i].isIdent {
                            alias = tokens[i].text
                            i += 1
                        }
                    } else if i < tokens.count, tokens[i].isIdent, !tokens[i].isKeyword {
                        alias = tokens[i].text
                        i += 1
                    }
                    result.append(ScopeRelation(schema: schema, name: name, alias: alias))
                }

                if allowsCommaList, i < tokens.count, tokens[i].isSymbol(",") {
                    i += 1
                    continue refLoop
                }
                break refLoop
            }
        }
        return result
    }

    private static func resolve(
        _ scoped: ScopeRelation, in catalog: SQLCompletionCatalog
    ) -> SQLCompletionCatalog.Relation? {
        if let schema = scoped.schema {
            return catalog.relation(schema: schema, name: scoped.name)
        }
        return catalog.relations(named: scoped.name).first
    }

    // MARK: - Context classification

    private enum Context {
        case qualified(schema: String?, name: String)
        case relations
        case columns
        case insertColumns(ScopeRelation)
        case types
        case bare
    }

    /// Classify the completion site from the tokens strictly before the
    /// partial word. Heuristic: nearest preceding clause keyword wins.
    private static func classify(
        before: [Token], partialStart: String.Index
    ) -> Context {
        let n = before.count

        // `alias.` / `table.` / `schema.table.` — dot and name must be
        // adjacent to the caret (no whitespace), so `1.` and `x .  y` don't
        // misfire.
        if n >= 2 {
            let dot = before[n - 1]
            let name = before[n - 2]
            if dot.isSymbol("."), dot.end == partialStart,
               name.isIdent, !name.isKeyword, name.end == dot.start {
                var schema: String? = nil
                if n >= 4, before[n - 3].isSymbol("."), before[n - 3].end == name.start,
                   before[n - 4].isIdent, before[n - 4].end == before[n - 3].start {
                    schema = before[n - 4].text
                }
                return .qualified(schema: schema, name: name.text)
            }
        }

        // `expr::` — cast target.
        if n >= 2, before[n - 1].isSymbol(":"), before[n - 2].isSymbol(":"),
           before[n - 1].end == partialStart, before[n - 2].end == before[n - 1].start {
            return .types
        }

        // INSERT INTO t ( … — the parenthesized column list.
        if let target = insertColumnListTarget(before: before) {
            return .insertColumns(target)
        }

        let relationStarters: Set<String> = ["FROM", "JOIN", "UPDATE", "INTO", "TABLE"]
        let columnStarters: Set<String> = [
            "SELECT", "WHERE", "ON", "USING", "HAVING", "BY", "SET", "RETURNING",
            "WHEN", "THEN", "ELSE", "AND", "OR", "NOT", "DISTINCT", "CASE",
            "BETWEEN", "LIKE", "ILIKE", "IN",
        ]
        for t in before.reversed() {
            guard t.kind == .identifier else { continue }
            let upper = t.upper
            if relationStarters.contains(upper) { return .relations }
            if columnStarters.contains(upper) { return .columns }
        }
        return .bare
    }

    /// Detect `INSERT INTO <rel> ( …caret` — an open paren at depth 0 whose
    /// relation reference is preceded by INTO. Returns the target relation.
    private static func insertColumnListTarget(before: [Token]) -> ScopeRelation? {
        var depth = 0
        var openIdx: Int? = nil
        for idx in stride(from: before.count - 1, through: 0, by: -1) {
            let t = before[idx]
            if t.isSymbol(")") { depth += 1 }
            if t.isSymbol("(") {
                if depth == 0 {
                    openIdx = idx
                    break
                }
                depth -= 1
            }
        }
        guard let open = openIdx, open >= 2 else { return nil }

        var i = open - 1
        guard before[i].isIdent, !before[i].isKeyword else { return nil }
        let name = before[i].text
        var schema: String? = nil
        i -= 1
        if i >= 1, before[i].isSymbol("."), before[i - 1].isIdent, !before[i - 1].isKeyword {
            schema = before[i - 1].text
            i -= 2
        }
        guard i >= 0, before[i].kind == .identifier, before[i].upper == "INTO" else { return nil }
        return ScopeRelation(schema: schema, name: name, alias: nil)
    }

    // MARK: - Candidate builders

    private struct Candidate {
        let insertText: String
        let kind: SQLCompletionItem.Kind
        /// Lowercased text the typed prefix matches against — always the bare
        /// object name, so `us` still finds `app.users` and `"User Stats"`.
        let filterText: String
        let rank: Int

        init(insertText: String, kind: SQLCompletionItem.Kind, filterText: String, rank: Int) {
            self.insertText = insertText
            self.kind = kind
            self.filterText = filterText.lowercased()
            self.rank = rank
        }
    }

    private static func keywordCandidates(rank: Int) -> [Candidate] {
        SQLCompletionVocabulary.keywords.map {
            Candidate(insertText: $0, kind: .keyword, filterText: $0, rank: rank)
        }
    }

    private static func functionCandidates(rank: Int) -> [Candidate] {
        SQLCompletionVocabulary.functions.map {
            Candidate(insertText: $0, kind: .function, filterText: $0, rank: rank)
        }
    }

    private static func schemaCandidates(catalog: SQLCompletionCatalog, rank: Int) -> [Candidate] {
        catalog.schemas.map {
            Candidate(
                insertText: SQLCompletionVocabulary.quoteIfNeeded($0),
                kind: .schema, filterText: $0, rank: rank
            )
        }
    }

    /// Tables + views. Search-path relations insert unqualified and rank
    /// first; foreign-schema relations insert `schema.name`-qualified.
    private static func relationCandidates(
        catalog: SQLCompletionCatalog, schemaFilter: String?, rankBase: Int
    ) -> [Candidate] {
        catalog.relations.compactMap { rel in
            if let filter = schemaFilter {
                guard rel.schema.caseInsensitiveCompare(filter) == .orderedSame else { return nil }
                return Candidate(
                    insertText: SQLCompletionVocabulary.quoteIfNeeded(rel.name),
                    kind: .relation, filterText: rel.name, rank: rankBase
                )
            }
            let inPath = catalog.isInSearchPath(rel.schema)
            let insert = inPath
                ? SQLCompletionVocabulary.quoteIfNeeded(rel.name)
                : SQLCompletionVocabulary.quoteIfNeeded(rel.schema)
                    + "." + SQLCompletionVocabulary.quoteIfNeeded(rel.name)
            return Candidate(
                insertText: insert,
                kind: .relation, filterText: rel.name, rank: rankBase + (inPath ? 0 : 1)
            )
        }
    }

    /// Columns of everything in scope. When the same column name appears in
    /// more than one in-scope relation, every occurrence inserts
    /// alias-qualified so the picked completion is unambiguous SQL.
    private static func columnCandidates(
        scope: [ScopeRelation], catalog: SQLCompletionCatalog
    ) -> [Candidate] {
        var resolved: [(display: String, rel: SQLCompletionCatalog.Relation)] = []
        for s in scope {
            guard let rel = resolve(s, in: catalog) else { continue }
            resolved.append((s.alias ?? rel.name, rel))
        }

        var occurrences: [String: Int] = [:]
        for (_, rel) in resolved {
            for col in rel.columns { occurrences[col.lowercased(), default: 0] += 1 }
        }

        var out: [Candidate] = []
        for (display, rel) in resolved {
            for col in rel.columns {
                let quotedCol = SQLCompletionVocabulary.quoteIfNeeded(col)
                let ambiguous = (occurrences[col.lowercased()] ?? 0) > 1
                let insert = ambiguous
                    ? SQLCompletionVocabulary.quoteIfNeeded(display) + "." + quotedCol
                    : quotedCol
                out.append(Candidate(insertText: insert, kind: .column, filterText: col, rank: 0))
            }
            // The alias / table name itself — typing it then `.` narrows.
            out.append(Candidate(
                insertText: SQLCompletionVocabulary.quoteIfNeeded(display),
                kind: .alias, filterText: display, rank: 1
            ))
        }
        return out
    }

    /// `<qualifier>.` resolution, most-specific first: explicit schema.table,
    /// then alias, then in-scope table name, then any catalog table, then a
    /// schema name (→ its relations).
    private static func qualifiedCandidates(
        schema: String?,
        name: String,
        scope: [ScopeRelation],
        catalog: SQLCompletionCatalog,
        noteNeedsColumns: (SQLCompletionCatalog.Relation) -> Void
    ) -> [Candidate] {
        func columns(of rel: SQLCompletionCatalog.Relation) -> [Candidate] {
            noteNeedsColumns(rel)
            return rel.columns.map {
                Candidate(
                    insertText: SQLCompletionVocabulary.quoteIfNeeded($0),
                    kind: .column, filterText: $0, rank: 0
                )
            }
        }

        if let schema {
            guard let rel = catalog.relation(schema: schema, name: name) else { return [] }
            return columns(of: rel)
        }

        if let aliased = scope.first(where: {
            $0.alias?.caseInsensitiveCompare(name) == .orderedSame
        }), let rel = resolve(aliased, in: catalog) {
            return columns(of: rel)
        }

        if let scoped = scope.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }), let rel = resolve(scoped, in: catalog) {
            return columns(of: rel)
        }

        if let rel = catalog.relations(named: name).first {
            return columns(of: rel)
        }

        if catalog.schemas.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return relationCandidates(catalog: catalog, schemaFilter: name, rankBase: 0)
        }

        return []
    }

    // MARK: - Filtering & ranking

    private static func finalize(_ candidates: [Candidate], partial: String) -> [SQLCompletionItem] {
        let prefix = partial.lowercased()
        var seen = Set<String>()
        let filtered = candidates.filter { c in
            (prefix.isEmpty || c.filterText.hasPrefix(prefix))
                && c.insertText.lowercased() != prefix
                && seen.insert(c.insertText).inserted
        }
        let sorted = filtered.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if a.filterText != b.filterText { return a.filterText < b.filterText }
            return a.insertText < b.insertText
        }
        return sorted.prefix(maxItems).map {
            SQLCompletionItem(insertText: $0.insertText, kind: $0.kind)
        }
    }
}
