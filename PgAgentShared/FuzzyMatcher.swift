import Foundation

// =============================================================================
// FuzzyMatcher — subsequence scoring for the command palette (and any other
// type-to-filter surface). Platform-neutral, pure.
//
// Contract: `score` returns nil unless every query character appears in the
// candidate in order (case-insensitive). Scores order matches so that
//   full prefix  >  word-boundary starts  >  scattered subsequence
// with consecutive runs rewarded and gaps mildly penalized.
// =============================================================================

enum FuzzyMatcher {
    private static let startBonus = 8
    private static let boundaryBonus = 6
    private static let consecutiveBonus = 4
    private static let prefixBonus = 20
    private static let exactBonus = 10
    private static let gapPenalty = 1

    /// Score `candidate` against `query`. `nil` = not a subsequence match.
    /// Empty query matches everything with score 0.
    static func score(query: String, candidate: String) -> Int? {
        if query.isEmpty { return 0 }
        let q = Array(query.lowercased())
        let c = Array(candidate.lowercased())
        let original = Array(candidate)
        guard q.count <= c.count else { return nil }

        var score = 0
        var qi = 0
        var lastMatch = -1
        var i = 0
        while i < c.count, qi < q.count {
            if c[i] == q[qi] {
                var bonus = 1
                if i == 0 {
                    bonus += startBonus
                } else if isWordBoundary(original, at: i) {
                    bonus += boundaryBonus
                }
                if lastMatch == i - 1 { bonus += consecutiveBonus }
                score += bonus
                lastMatch = i
                qi += 1
            } else if qi > 0 {
                // Gaps only cost once matching has started — a late first
                // match is already handled by losing the start/prefix bonus.
                score -= gapPenalty
            }
            i += 1
        }
        guard qi == q.count else { return nil }

        if String(c).hasPrefix(String(q)) {
            score += prefixBonus
            if q.count == c.count { score += exactBonus }
        }
        return score
    }

    /// Word boundary: after a separator, or a camelCase hump.
    private static func isWordBoundary(_ chars: [Character], at i: Int) -> Bool {
        guard i > 0 else { return true }
        let prev = chars[i - 1]
        if prev == " " || prev == "_" || prev == "-" || prev == "." || prev == "/" || prev == ":" {
            return true
        }
        return chars[i].isUppercase && prev.isLowercase
    }
}
