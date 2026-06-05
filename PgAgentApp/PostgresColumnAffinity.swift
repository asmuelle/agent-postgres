#if canImport(AppKit)
import AppKit
typealias PlatformColor = NSColor
#elseif canImport(UIKit)
import UIKit
typealias PlatformColor = UIColor
#endif

#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// =============================================================================
// PostgresColumnAffinity — UI-side classification of Postgres column types.
//
// We don't try to enumerate every type Postgres supports — that's a long
// tail with diminishing returns. Instead we group OIDs into a handful of
// presentation buckets:
//   - `numeric`   → right-align (eyes scan a column of numbers fast)
//   - `boolean`   → transform "t"/"f" to "true"/"false" with color
//   - `timestamp` → mono font, ISO format kept verbatim, tooltip with
//                   relative time (deferred to v2 to avoid per-row
//                   formatter overhead in the grid hot path)
//   - `json`      → muted background hint
//   - `default`   → left-aligned mono (catch-all)
//
// OID values are stable across Postgres versions. They live in
// `pg_type.oid` and the canonical list is in the server's
// `src/include/catalog/pg_type.dat` (or the `pg_type` view).
// =============================================================================

enum PostgresColumnAffinity: Sendable {
    case numeric
    case boolean
    case timestamp
    case json
    case `default`

    /// Map a Postgres OID to a presentation bucket. Defaults to
    /// `.default` for anything we don't classify — strings, bytea,
    /// arrays, geometric, network, custom enums, user-defined types.
    static func from(typeOid: UInt32) -> PostgresColumnAffinity {
        switch typeOid {
        // Numeric scalars.
        case 21,    // int2
             23,    // int4
             20,    // int8
             700,   // float4
             701,   // float8
             1700,  // numeric
             790,   // money
             26,    // oid
             27:    // tid (block,offset) — not strictly numeric but
                    //                       displays as numbers
            return .numeric

        case 16:    // bool
            return .boolean

        // Date / time family. We don't separate date vs timestamp
        // here — they all share alignment + monospaced rendering.
        case 1082,  // date
             1083,  // time
             1114,  // timestamp
             1184,  // timestamptz
             1266:  // timetz
            return .timestamp

        case 114,   // json
             3802:  // jsonb
            return .json

        default:
            return .default
        }
    }

    /// Convenience constructor straight from the FFI record.
    static func from(column: FfiPgColumn) -> PostgresColumnAffinity {
        from(typeOid: column.typeOid)
    }

    /// Cell text alignment derived from the affinity. Numeric values
    /// right-align so columns of digits read as a column.
    var textAlignment: NSTextAlignment {
        switch self {
        case .numeric: return .right
        default:       return .left
        }
    }

    /// Header alignment matches cell alignment for the same reason.
    var headerAlignment: NSTextAlignment {
        textAlignment
    }

    /// Suggested initial column width. Numeric and boolean columns
    /// tend to be narrower than free-form text; this keeps a wide
    /// schema browseable without manual resize on every reload.
    var defaultWidth: CGFloat {
        switch self {
        case .numeric:   return 110
        case .boolean:   return 70
        case .timestamp: return 200
        case .json:      return 220
        case .default:   return 160
        }
    }

    /// Transform a server-side text value for display. Most types
    /// pass through; the boolean "t"/"f" → "true"/"false" swap is
    /// the only meaningful change in v1.
    func displayValue(_ raw: String) -> String {
        switch self {
        case .boolean:
            switch raw {
            case "t": return "true"
            case "f": return "false"
            default:  return raw
            }
        default:
            return raw
        }
    }

    /// Optional foreground color hint (for now: only booleans get
    /// one). Returning `nil` means "use the default label color".
    var foregroundTint: PlatformColor? {
        switch self {
        case .boolean: return .systemBlue
        default:       return nil
        }
    }
}
