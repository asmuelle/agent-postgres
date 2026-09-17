import SwiftUI
#if canImport(PgAgentMacOS)
import PgAgentMacOS
#endif

// MARK: - Results Grid Cell View
struct MobileResultsGridCellView: View {
    let cell: String?
    let rIdx: Int
    let cIdx: Int
    let pendingEdits: [PostgresPendingEditKey: PostgresPendingEdit]

    private var isStaged: Bool {
        let key = PostgresPendingEditKey(rowIndex: rIdx, columnIndex: cIdx)
        return pendingEdits[key] != nil
    }
    
    var body: some View {
        Text(cell ?? "NULL")
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(cell == nil ? Color.secondary.opacity(0.5) : Color.primary)
            .lineLimit(1)
            .frame(width: 140, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isStaged
                    ? MidnightColors.accentCyan.opacity(0.18)
                    : (rIdx % 2 == 0 ? Color.black.opacity(0.1) : Color.white.opacity(0.02))
            )
            .border(MidnightColors.borderGray, width: 0.5)
    }
}

// MARK: - Results Grid Row View
struct MobileResultsGridRowView: View {
    let rIdx: Int
    let row: FfiPgRow
    /// Column indices to render, in order — excludes hidden `__pg_`
    /// columns so the cell index still maps to the real result column
    /// (pending-edit keys stay stable).
    let visibleColumns: [Int]
    let pendingEdits: [PostgresPendingEditKey: PostgresPendingEdit]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(visibleColumns, id: \.self) { cIdx in
                MobileResultsGridCellView(cell: cIdx < row.cells.count ? row.cells[cIdx] : nil, rIdx: rIdx, cIdx: cIdx, pendingEdits: pendingEdits)
            }
        }
    }
}

// MARK: - Results Grid View
struct MobileResultsGridView: View {
    let columns: [FfiPgColumn]
    let rows: [FfiPgRow]
    let hasMore: Bool
    var isLoadingMore: Bool = false
    let pendingEdits: [PostgresPendingEditKey: PostgresPendingEdit]
    var onLoadMore: () -> Void
    /// Server-side sort + pagination state for relation-browse tabs.
    /// `nil` for generic SQL tabs, which keep local sort + cursor
    /// "Load more". When set, the footer becomes a first/prev/next
    /// pager and header clicks re-run the SELECT with a new ORDER BY.
    var browse: PostgresBrowseState? = nil
    /// Jump to a 0-based page (browse tabs only).
    var onGoToPage: ((Int) -> Void)? = nil
    /// Cycle the sort on a column by name (browse tabs only).
    var onCycleSort: ((String) -> Void)? = nil

    /// Result-column index the grid is sorted by, or `nil` for none.
    /// Used only for generic SQL tabs; browse tabs sort server-side.
    @State private var sortColumn: Int?
    @State private var sortAscending: Bool = true

    /// Column indices to display — hides internal `__pg_` columns
    /// (e.g. the `ctid AS __pg_rowid__` row identity on browse tabs),
    /// matching the macOS grid.
    private var visibleColumns: [Int] {
        columns.indices.filter { !columns[$0].name.hasPrefix("__pg_") }
    }

    /// Original row indices in display order (after applying the local sort).
    /// Falls back to natural order when no sort is active or when the tab
    /// sorts server-side (browse). The original index is preserved so
    /// pending-edit keys and row striping stay stable.
    private var displayOrder: [Int] {
        let base = Array(0..<rows.count)
        guard browse == nil, let col = sortColumn, col < columns.count else { return base }
        return base.sorted { a, b in
            let va = col < rows[a].cells.count ? rows[a].cells[col] : nil
            let vb = col < rows[b].cells.count ? rows[b].cells[col] : nil
            let order = Self.compareCells(va, vb)
            return sortAscending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    /// NULLs sort as largest (Postgres default); non-nulls use a locale- and
    /// numeric-aware comparison so `img9` precedes `img10`. Mirrors the macOS
    /// results grid (`PostgresResultsTableCoordinator.compareCells`).
    static func compareCells(_ a: String?, _ b: String?) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (.some(x), .some(y)): return x.localizedStandardCompare(y)
        }
    }

    /// Cycle a column through ascending → descending → unsorted, matching the
    /// macOS header-click behavior.
    private func toggleSort(_ col: Int) {
        if sortColumn == col {
            if sortAscending { sortAscending = false } else { sortColumn = nil }
        } else {
            sortColumn = col
            sortAscending = true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Grid Canvas
            if rows.isEmpty {
                VStack {
                    Spacer()
                    Text("No results to display")
                        .foregroundStyle(.secondary)
                        .font(MidnightMobileDesign.FontToken.caption)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Outer horizontal scroll carries both header and body so they
                // stay column-aligned; the inner vertical scroll only moves the
                // rows, keeping the header pinned to the top.
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        headerRow
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(displayOrder, id: \.self) { rIdx in
                                    MobileResultsGridRowView(rIdx: rIdx, row: rows[rIdx], visibleColumns: visibleColumns, pendingEdits: pendingEdits)
                                }

                                // Cursor "Load more" lives in-scroll for
                                // generic SQL tabs; browse tabs page via
                                // the footer pager below instead.
                                if browse == nil, hasMore {
                                    Button(action: onLoadMore) {
                                        HStack {
                                            Spacer()
                                            Label("Load More Pages", systemImage: "arrow.down.circle")
                                                .font(MidnightMobileDesign.FontToken.captionStrong)
                                                .foregroundStyle(MidnightColors.accentCyan)
                                                .padding()
                                            Spacer()
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .frame(height: 50)
                                }
                            }
                        }
                    }
                }
            }

            // Paging footer (browse tabs) — first / prev / next with the
            // current row range, mirroring the macOS browse pager.
            if let browse, let onGoToPage {
                Divider().background(MidnightColors.borderGray)
                browsePagerFooter(browse: browse, onGoToPage: onGoToPage)
            }
        }
        .background(MidnightColors.primaryBackground)
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(visibleColumns, id: \.self) { idx in
                let col = columns[idx]
                let sortedAscending: Bool? = {
                    if let browse {
                        return browse.sortColumn == col.name ? browse.sortAscending : nil
                    }
                    return sortColumn == idx ? sortAscending : nil
                }()
                Button {
                    if let onCycleSort {
                        onCycleSort(col.name)
                    } else {
                        toggleSort(idx)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(col.name)
                            .font(MidnightMobileDesign.FontToken.captionStrong)
                            .foregroundStyle(MidnightColors.accentCyan)
                            .lineLimit(1)
                        if let ascending = sortedAscending {
                            Image(systemName: ascending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(MidnightColors.accentCyan)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: 140, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(MidnightColors.cardBackground)
                    .border(MidnightColors.borderGray, width: 0.5)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// First / previous / next page controls plus the current row range.
    /// Each tap re-runs the browse SELECT at a new OFFSET (the query
    /// workspace owns the re-run), so the grid never accumulates rows.
    @ViewBuilder
    private func browsePagerFooter(browse: PostgresBrowseState, onGoToPage: @escaping (Int) -> Void) -> some View {
        let first = browse.firstRowNumber
        let atStart = browse.page == 0
        HStack(spacing: 14) {
            Button {
                onGoToPage(0)
            } label: {
                Image(systemName: "chevron.left.2")
                    .foregroundStyle(atStart ? Color.secondary : MidnightColors.accentCyan)
            }
            .disabled(atStart)

            Button {
                onGoToPage(browse.page - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .foregroundStyle(atStart ? Color.secondary : MidnightColors.accentCyan)
            }
            .disabled(atStart)

            Text(rows.isEmpty
                 ? "Page \(browse.page + 1) · no rows"
                 : "Page \(browse.page + 1) · rows \(first)–\(first + rows.count - 1)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                onGoToPage(browse.page + 1)
            } label: {
                Image(systemName: "chevron.right")
                    .foregroundStyle(browse.hasNextPage ? MidnightColors.accentCyan : Color.secondary)
            }
            .disabled(!browse.hasNextPage)

            if let sort = browse.sortColumn {
                Divider().frame(height: 12)
                Label("\(sort) \(browse.sortAscending ? "asc" : "desc")",
                      systemImage: "arrow.up.arrow.down")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
        .foregroundStyle(MidnightColors.accentCyan)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.3))
    }
}

