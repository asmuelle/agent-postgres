import Foundation

// =============================================================================
// PostgresCellSort — the comparator behind the results grid's client-side
// column sort (generic SQL tabs; browse tabs sort server-side).
//
// Cells arrive as text. `localizedStandardCompare` orders digit runs
// naturally ("img9" < "img10") but ignores signs and decimal fractions, so
// on a numeric column it put -5 before -10 and 1.5 before 1.25. Numeric
// columns therefore compare by value, following Postgres' own ordering:
// -Infinity < finite values < Infinity < NaN. NULLs sort as larger than
// every value (Postgres' default NULLS LAST ascending / FIRST descending).
// Everything else keeps the locale-aware natural comparison.
// =============================================================================

enum PostgresCellSort {
    /// Built-in numeric types whose text output is a plain decimal or
    /// float literal. `money` is deliberately absent: its output is
    /// locale-formatted ("$1,234.56", "1.234,56 €"), so it keeps the text
    /// comparison rather than risk a wrong parse.
    private static let numericTypeOids: Set<UInt32> = [
        20,   // int8
        21,   // int2
        23,   // int4
        26,   // oid
        700,  // float4
        701,  // float8
        1700, // numeric
    ]

    private static let numericTypeNames: Set<String> = [
        "int2", "int4", "int8", "smallint", "integer", "bigint",
        "oid", "float4", "float8", "real", "double precision", "numeric", "decimal",
    ]

    /// Whether a column's cells should sort by numeric value. Uses the type
    /// OID, falling back to the type name for results that carry no OID.
    static func isNumeric(typeOid: UInt32, typeName: String) -> Bool {
        if numericTypeOids.contains(typeOid) { return true }
        return typeOid == 0 && numericTypeNames.contains(typeName.lowercased())
    }

    /// Order two cells ascending. NULL (`nil`) sorts after every value. On
    /// numeric columns values compare numerically; a cell that doesn't parse
    /// as a number falls back to the text comparison for that pair.
    static func compare(_ a: String?, _ b: String?, numeric: Bool) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (.some(x), .some(y)):
            if numeric, let nx = NumericValue(x), let ny = NumericValue(y) {
                return nx.compare(ny)
            }
            return x.localizedStandardCompare(y)
        }
    }

    // MARK: - Numeric parsing

    /// A parsed numeric cell. Finite values keep `Decimal` precision
    /// (int8 and numeric exceed a Double's 53-bit mantissa) unless written
    /// in exponent form, which is how float4/float8 print extreme
    /// magnitudes that `Decimal` can't represent.
    private enum NumericValue {
        case negativeInfinity
        case decimal(Decimal)
        case double(Double)
        case positiveInfinity
        case nan

        private static let posix = Locale(identifier: "en_US_POSIX")

        init?(_ text: String) {
            let s = text.trimmingCharacters(in: .whitespaces)
            switch s.lowercased() {
            case "nan": self = .nan; return
            case "infinity", "+infinity", "inf": self = .positiveInfinity; return
            case "-infinity", "-inf": self = .negativeInfinity; return
            default: break
            }
            guard let hasExponent = Self.validate(s) else { return nil }
            if !hasExponent, let d = Decimal(string: s, locale: Self.posix) {
                self = .decimal(d)
            } else if let d = Double(s), d.isFinite {
                self = .double(d)
            } else {
                return nil
            }
        }

        /// Accepts `[+-]digits[.digits][e[+-]digits]` (at least one mantissa
        /// digit). Returns whether an exponent is present, or `nil` when the
        /// text isn't a plain numeric literal.
        private static func validate(_ s: String) -> Bool? {
            var chars = Substring(s)
            if chars.first == "+" || chars.first == "-" { chars = chars.dropFirst() }
            var mantissaDigits = 0
            var seenDot = false
            while let c = chars.first, c.isASCII, c.isNumber || c == "." {
                if c == "." {
                    if seenDot { return nil }
                    seenDot = true
                } else {
                    mantissaDigits += 1
                }
                chars = chars.dropFirst()
            }
            guard mantissaDigits > 0 else { return nil }
            guard let e = chars.first else { return false }
            guard e == "e" || e == "E" else { return nil }
            chars = chars.dropFirst()
            if chars.first == "+" || chars.first == "-" { chars = chars.dropFirst() }
            guard !chars.isEmpty, chars.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return true
        }

        private var rank: Int {
            switch self {
            case .negativeInfinity: return 0
            case .decimal, .double: return 1
            case .positiveInfinity: return 2
            case .nan: return 3
            }
        }

        func compare(_ other: NumericValue) -> ComparisonResult {
            if rank != other.rank {
                return rank < other.rank ? .orderedAscending : .orderedDescending
            }
            switch (self, other) {
            case let (.decimal(x), .decimal(y)):
                return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
            case (.decimal, .double), (.double, .decimal), (.double, .double):
                let x = asDouble, y = other.asDouble
                return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
            default:
                return .orderedSame // same non-finite rank
            }
        }

        private var asDouble: Double {
            switch self {
            case .decimal(let d): return NSDecimalNumber(decimal: d).doubleValue
            case .double(let d): return d
            case .negativeInfinity: return -.infinity
            case .positiveInfinity: return .infinity
            case .nan: return .nan
            }
        }
    }
}
