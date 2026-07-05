import Foundation

// =============================================================================
// PostgresBrowseState — server-side sort + pagination state for tabs
// opened from the schema browser, plus the hidden rowid column name.
//
// Extracted from PostgresQueryTab.swift; behavior-preserving. This
// file is also compiled into the PgAgentMobile target (like its
// source file) — keep it platform-neutral.
// =============================================================================

/// Server-side browse state for tabs opened from the schema browser.
/// Sorting and pagination re-run the generated SELECT with ORDER BY /
/// LIMIT / OFFSET instead of reordering the fetched rows locally, so
/// the grid always reflects server-truthful order across the whole
/// relation — not just the page that happens to be in memory.
struct PostgresBrowseState: Hashable, Sendable {
    var schema: String
    var table: String
    /// Pre-quoted filter from FK navigation, or `nil` for a plain browse.
    var whereClause: String?
    /// Column the browse is ordered by, or `nil` for storage order.
    var sortColumn: String?
    var sortAscending: Bool = true
    /// 0-based page index into the relation at `pageSize` rows per page.
    var page: Int = 0
    var pageSize: Int = 500
    /// `true` when the last fetch filled the page, so a next page
    /// (almost certainly) exists. A relation whose row count is an
    /// exact multiple of `pageSize` yields one trailing empty page —
    /// acceptable, and far cheaper than a count(*) per browse.
    var hasNextPage: Bool = false
    /// `false` for relations without a `ctid` (plain views, foreign
    /// tables) — selecting it there fails with "column ctid does not
    /// exist". Tables, partitioned tables, and materialized views all
    /// have one. Without a row identity the grid is read-only, which
    /// is correct for those relation kinds anyway.
    var hasRowIdentity: Bool = true

    /// First row number (1-based) shown on the current page.
    var firstRowNumber: Int { page * pageSize + 1 }

    /// The SELECT this state describes. Identifiers are quoted
    /// defensively (mixed case, reserved words); `ctid AS
    /// __pg_rowid__` gives the grid row identity for cell-level
    /// UPDATEs (hidden from display). OFFSET is omitted on the first
    /// page so the common case reads clean in the editor.
    func sql() -> String {
        let projection = hasRowIdentity ? "*, ctid AS \(POSTGRES_ROWID_COLUMN)" : "*"
        var s = "SELECT \(projection) FROM \(Self.quoteIdent(schema)).\(Self.quoteIdent(table))"
        if let whereClause {
            s += " WHERE \(whereClause)"
        }
        if let sortColumn {
            s += " ORDER BY \(Self.quoteIdent(sortColumn)) \(sortAscending ? "ASC" : "DESC")"
        }
        s += " LIMIT \(pageSize)"
        if page > 0 {
            s += " OFFSET \(page * pageSize)"
        }
        return s + ";"
    }

    /// Header-click cycle: unsorted → ascending → descending →
    /// unsorted. Any sort change rewinds to the first page — the old
    /// offset is meaningless under a new order.
    func cyclingSort(by column: String) -> PostgresBrowseState {
        var next = self
        next.page = 0
        if sortColumn == column {
            if sortAscending {
                next.sortAscending = false
            } else {
                next.sortColumn = nil
                next.sortAscending = true
            }
        } else {
            next.sortColumn = column
            next.sortAscending = true
        }
        return next
    }

    func movingToPage(_ newPage: Int) -> PostgresBrowseState {
        var next = self
        next.page = max(0, newPage)
        return next
    }

    /// Postgres double-quote escaping — embedded double quotes become
    /// two double quotes, and the whole identifier is wrapped.
    static func quoteIdent(_ s: String) -> String {
        "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

/// Magic column name the auto-generated SELECT aliases `ctid` to.
/// The grid hides any column whose name starts with `__pg_`, so this
/// stays out of the user's sight while still being available for
/// row identification on UPDATEs.
let POSTGRES_ROWID_COLUMN: String = "__pg_rowid__"
