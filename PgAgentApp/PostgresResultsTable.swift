import AppKit
import PgAgentMacOS
import SwiftUI

// =============================================================================
// PostgresResultsTable — `NSViewRepresentable` wrapping `NSScrollView +
// NSTableView` for the query result grid.
//
// Why drop SwiftUI's `LazyVGrid`: column resize, multi-row selection,
// and ⌘C-to-clipboard need either NSViewRepresentable plumbing or
// macOS 14+ APIs. NSTableView is the right primitive; SwiftUI's
// `Table` (macOS 12+) doesn't support fully dynamic columns.
//
// Update strategy:
// - Column set changed → rebuild columns + reload data.
// - Same columns, more rows → `insertRows(at:)` so existing user
//   scroll position is preserved during pagination.
// - Same columns, fewer/different rows (rare) → reload.
//
// This file holds the representable + supporting value types + the
// NSTableView/row-view subclasses. The coordinator lives in:
//   - PostgresResultsTableCoordinator.swift    — data source/delegate core
//   - PostgresResultsTable+CopyExport.swift    — copy / CSV export actions
//   - PostgresResultsTable+Editing.swift       — inline + bulk cell editing
//   - PostgresResultsTable+Menu.swift          — menu validation + FK items
// =============================================================================

/// Compact column identity for the rebuild-vs-append decision.
/// Two columns that share name + OID are treated as the same column
/// across `updateNSView` calls, which lets pagination append rows
/// without rebuilding (and without losing user-resized widths).
private struct ColumnSignature: Equatable {
    let name: String
    let typeOid: UInt32
}

/// Edit request bubbled from the table's commit handler up to the
/// host (the query tab view), which runs the actual UPDATE and
/// reports an outcome back via the completion closure.
struct PostgresCellEdit {
    let rowIndex: Int
    /// Index in the underlying `result.columns`, *not* the visible
    /// table-column index. Hidden `__pg_*` columns sit between
    /// visible ones, so the indices diverge.
    let columnIndex: Int
    let columnName: String
    /// The column's `pg_type.typname`. Used by the UPDATE to cast
    /// `$1::<type>` server-side. Empty for multi-statement results
    /// where types aren't surfaced; the UI gates editing on this
    /// being non-empty.
    let columnType: String
    /// `nil` = SET NULL. Empty string = the literal empty string
    /// (for text-like columns) — the UI distinguishes via the
    /// "Set to NULL" menu item rather than typing a magic word.
    let newValue: String?
    /// Row identifier extracted from the hidden `__pg_rowid__`
    /// column (the relation's ctid). Empty would mean the result
    /// has no rowid; the UI gates editing on this being non-empty
    /// before invoking the closure.
    let rowId: String
}

enum PostgresCellEditOutcome {
    /// The UPDATE applied; display the new value.
    case applied
    /// The UPDATE matched zero rows. ctid moved or the row was
    /// deleted by another session.
    case conflict
    /// Server-side or driver error; revert.
    case failed(message: String)
}

/// Tuple describing the (profile, table) the table view should
/// persist column widths against. Composite key built from these
/// is shared across query reruns of the same table.
struct PostgresColumnWidthKey: Equatable {
    let profileId: String
    let schema: String
    let table: String
}

/// Active server-side sort, mirrored into the header indicators.
/// Set by browse-mode hosts; the grid renders the arrows but never
/// reorders rows itself — the host re-runs the SELECT with ORDER BY.
struct PostgresServerSort: Equatable {
    let columnName: String
    let ascending: Bool
}

/// A cell the user asked to inspect (right-click → "Show value…"). The host
/// presents a viewer; `typeName` lets it pretty-print JSON/JSONB. The
/// addressing fields (`typeOid`, row/column indices, `rowId`) let the host
/// offer in-place editing for json/jsonb cells through the same cell-update
/// pipeline the grid uses; they default to "not addressable".
struct PostgresCellInspection: Identifiable {
    let id = UUID()
    let columnName: String
    let typeName: String
    let value: String?
    /// Postgres type OID — drives the affinity check for JSON editing.
    var typeOid: UInt32 = 0
    /// Index into `result.rows` (the data row, not the display row).
    var rowIndex: Int = -1
    /// Index into `result.columns` (hidden `__pg_*` columns included).
    var columnIndex: Int = -1
    /// The row's ctid from the hidden `__pg_rowid__` column, when present.
    var rowId: String? = nil
}

/// Navigation request bubbled from the grid's FK menu items to the
/// host, which opens the target relation in a new tab filtered to
/// the given column/value pairs (ANDed; multi-column FKs produce
/// multiple pairs). Values are raw cell text — the host quotes them.
struct PostgresFKNavigation {
    let schema: String
    let table: String
    let filters: [(column: String, value: String)]
}

/// Cheap identity token for "did the rows change?". The host's store
/// bumps `value` on every mutation that changes the displayed rows
/// (new result, page append, cell write-back, insert, delete); the
/// tab id disambiguates hosts that reuse one view across tabs. When
/// present, `updateNSView` compares this instead of deep-equating
/// up-to-50k-row arrays on every unrelated store mutation.
struct PostgresResultsRevision: Equatable {
    let tabId: UUID
    let value: UInt64
}

struct PostgresResultsTable: NSViewRepresentable {
    let result: FfiPgExecutionResult
    /// Rows-change token from the host's store. `nil` (hosts that
    /// don't track revisions) falls back to the deep rows compare.
    var revision: PostgresResultsRevision? = nil
    /// Case-insensitive substring filter across visible columns. Empty = no
    /// filter. Driven by the host's filter field.
    var filterText: String = ""
    /// Offset for the "#" gutter column — the first display row
    /// renders as `rowNumberBase + 1`. Browse-mode hosts pass
    /// `page * pageSize` so numbering is continuous across pages.
    var rowNumberBase: Int = 0
    /// Server-side sort to reflect in the header indicators. Only
    /// meaningful alongside `onHeaderSort`.
    var serverSort: PostgresServerSort? = nil
    /// When set, a header click delegates sorting to the host (which
    /// re-runs the SELECT with ORDER BY) instead of sorting the
    /// fetched rows locally. Receives the clicked column's name.
    var onHeaderSort: ((String) -> Void)? = nil
    /// Invoked when the user picks "Show value…" — the host presents a viewer.
    var onInspectCell: ((PostgresCellInspection) -> Void)? = nil
    /// `true` when the host knows how to UPDATE rows (tab opened
    /// from the schema browser AND the result carries a `__pg_rowid__`
    /// column). When `false`, the grid is fully read-only — no
    /// double-click-to-edit, no "Set to NULL" menu item.
    var editable: Bool = false
    var pendingEdits: [PostgresPendingEditKey: PostgresPendingEdit] = [:]
    /// Invoked when the user commits a cell edit. Receives the edit
    /// description plus a completion callback to be invoked on the
    /// main queue with the UPDATE outcome.
    var onCellEdit: ((PostgresCellEdit, @escaping (PostgresCellEditOutcome) -> Void) -> Void)? = nil
    /// Invoked when the user picks "Export full result as CSV…".
    /// The host runs the file dialog + cursor-drain pipeline; the
    /// table just exposes the menu item. `nil` hides the item.
    var onExportFull: (() -> Void)? = nil
    /// Invoked when the user picks "Export full result as JSONL…".
    /// Same pattern as `onExportFull`.
    var onExportFullJsonl: (() -> Void)? = nil
    /// Invoked when the user picks "Export full result as Parquet…".
    /// Same pattern as `onExportFull`.
    var onExportFullParquet: (() -> Void)? = nil
    /// Invoked when the user picks "Delete selected row(s)". Receives
    /// the *result* row indices (translated from selection) — the
    /// host runs the confirm + DELETE pipeline.
    var onDeleteRows: (([Int]) -> Void)? = nil
    /// Invoked when the user picks "Insert row…". Host presents the
    /// modal sheet + runs the INSERT pipeline. `nil` hides the
    /// menu item.
    var onInsertRow: (() -> Void)? = nil
    /// Persistence key for column widths. When all three are
    /// non-nil, the coordinator restores user-saved widths on
    /// rebuild and persists changes after each manual resize.
    /// Generic SQL tabs leave these `nil` and use defaults.
    var widthPersistKey: PostgresColumnWidthKey? = nil
    /// FK constraints for the tab's source table. Drives the
    /// "Go to …" / "Show referencing rows …" context-menu items.
    /// `nil` (generic SQL tabs, or metadata still loading) hides
    /// FK navigation entirely.
    var foreignKeys: PgTableForeignKeys? = nil
    /// Invoked when the user picks an FK navigation item. The host
    /// opens the filtered relation tab. `nil` hides the items.
    var onNavigateFK: ((PostgresFKNavigation) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        let coord = Coordinator(
            result: result,
            editable: editable,
            onCellEdit: onCellEdit,
            onExportFull: onExportFull,
            onExportFullJsonl: onExportFullJsonl,
            onExportFullParquet: onExportFullParquet,
            onDeleteRows: onDeleteRows,
            onInsertRow: onInsertRow,
            widthPersistKey: widthPersistKey
        )
        coord.pendingEdits = pendingEdits
        coord.onInspectCell = onInspectCell
        coord.filterText = filterText
        coord.rowNumberBase = rowNumberBase
        coord.serverSort = serverSort
        coord.onHeaderSort = onHeaderSort
        coord.foreignKeys = foreignKeys
        coord.onNavigateFK = onNavigateFK
        coord.lastRevision = revision
        coord.recomputeDisplayOrder()
        return coord
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        // Overlay scrollbars avoid reserving an empty strip below
        // the final visible table row.
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder

        let table = CopyableTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnSelection = false
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.rowHeight = 22
        table.headerView = NSTableHeaderView()
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.copySource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.handleDoubleClick(_:))

        // Initial column set.
        context.coordinator.rebuildColumns(in: table, from: result.columns)

        // Right-click menu — gives discoverability that ⌘C alone
        // doesn't. Items look up the table's selection at runtime.
        let menu = NSMenu()
        menu.delegate = context.coordinator
        var items: [NSMenuItem] = [
            NSMenuItem(
                title: "Copy",
                action: #selector(Coordinator.copySelectedRows(_:)),
                keyEquivalent: "c"
            ),
            NSMenuItem(
                title: "Copy with header",
                action: #selector(Coordinator.copySelectedRowsWithHeader(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem.separator(),
            NSMenuItem(
                title: "Copy cell",
                action: #selector(Coordinator.copyClickedCell(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem(
                title: "Show value…",
                action: #selector(Coordinator.showClickedValue(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem(
                title: "Copy NULL as empty (toggle)",
                action: #selector(Coordinator.toggleNullAsEmpty(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem.separator(),
            NSMenuItem(
                title: "Export visible rows as CSV…",
                action: #selector(Coordinator.exportCsv(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem(
                title: "Export selected rows as CSV…",
                action: #selector(Coordinator.exportSelectedCsv(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem(
                title: "Export full result as CSV…",
                action: #selector(Coordinator.exportFullCsv(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem(
                title: "Export full result as JSONL…",
                action: #selector(Coordinator.exportFullJsonl(_:)),
                keyEquivalent: ""
            ),
            NSMenuItem(
                title: "Export full result as Parquet…",
                action: #selector(Coordinator.exportFullParquet(_:)),
                keyEquivalent: ""
            ),
        ]
        if editable {
            // Edit affordances live in the same menu so users
            // discover them next to copy. `Set to NULL` is the only
            // way to write NULL — typing a "NULL" string would be
            // taken as the literal text, ambiguous in a database
            // tool.
            items.append(.separator())
            items.append(NSMenuItem(
                title: "Set to NULL",
                action: #selector(Coordinator.setClickedCellToNull(_:)),
                keyEquivalent: ""
            ))
            items.append(NSMenuItem(
                title: "Set selected rows in this column to NULL",
                action: #selector(Coordinator.setSelectionInColumnToNull(_:)),
                keyEquivalent: ""
            ))
            items.append(NSMenuItem(
                title: "Paste into selected rows in this column",
                action: #selector(Coordinator.pasteIntoSelectionInColumn(_:)),
                keyEquivalent: ""
            ))
            items.append(.separator())
            items.append(NSMenuItem(
                title: "Insert row…",
                action: #selector(Coordinator.insertRow(_:)),
                keyEquivalent: ""
            ))
            items.append(NSMenuItem(
                title: "Delete selected row(s)",
                action: #selector(Coordinator.deleteSelectedRows(_:)),
                keyEquivalent: ""
            ))
        }
        menu.items = items
        for item in menu.items {
            item.target = context.coordinator
        }
        table.menu = menu

        // One coordinator per representable; record the backing
        // table here so the menu actions can resolve it without
        // walking responders or hit-testing the mouse location.
        context.coordinator.lastTable = table

        // Persist column widths when the user drags a divider.
        // `NSTableViewColumnDidResize` fires synchronously per
        // resize step; the store's per-key dedupe guard keeps
        // disk writes infrequent.
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.columnDidResize(_:)),
            name: NSTableView.columnDidResizeNotification,
            object: table
        )

        scrollView.documentView = table
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let table = nsView.documentView as? CopyableTableView else { return }
        let coord = context.coordinator
        // Identity = (name, typeOid). Two queries that happen to use
        // the same column names but different types should still
        // rebuild — the affinity-driven alignment / formatting
        // depends on the OID.
        let prevColumnIdentities = coord.result.columns.map { ColumnSignature(name: $0.name, typeOid: $0.typeOid) }
        let prevDisplayOrder = coord.displayOrder
        let prevRows = coord.result.rows
        let prevRowNumberBase = coord.rowNumberBase
        let prevServerSort = coord.serverSort
        let prevRevision = coord.lastRevision

        coord.rowNumberBase = rowNumberBase
        coord.serverSort = serverSort
        coord.onHeaderSort = onHeaderSort
        coord.editable = editable
        coord.pendingEdits = pendingEdits
        coord.onCellEdit = onCellEdit
        coord.onExportFull = onExportFull
        coord.onExportFullJsonl = onExportFullJsonl
        coord.onExportFullParquet = onExportFullParquet
        coord.onDeleteRows = onDeleteRows
        coord.onInsertRow = onInsertRow
        coord.onInspectCell = onInspectCell
        coord.widthPersistKey = widthPersistKey
        coord.foreignKeys = foreignKeys
        coord.onNavigateFK = onNavigateFK
        coord.lastRevision = revision
        // Set the filter before `update` so the recompute reflects it.
        coord.filterText = filterText
        coord.update(result: result)

        let newIdentities = result.columns.map { ColumnSignature(name: $0.name, typeOid: $0.typeOid) }
        let columnsChanged = newIdentities != prevColumnIdentities
        if columnsChanged {
            coord.rebuildColumns(in: table, from: result.columns)
            table.reloadData()
            return
        }

        if serverSort != prevServerSort {
            coord.updateSortIndicators(in: table)
        }
        // A page move replaces all rows with a same-shaped result —
        // `displayOrder` (pure indices) can't see that, so reload on
        // the page-offset change instead.
        if rowNumberBase != prevRowNumberBase {
            table.reloadData()
            return
        }

        // Reconcile against the recomputed display order. A pure suffix-append
        // (pagination, no sort/filter) keeps scroll position via insertRows;
        // any other change (sort, filter, re-run) reloads.
        let newDisplayOrder = coord.displayOrder
        if newDisplayOrder == prevDisplayOrder {
            // Same shape and order, but a re-run (server-side sort,
            // refresh) can swap row *content* without moving any
            // indices — `displayOrder` is blind to that. When the
            // host supplies a revision token, comparing it replaces
            // the deep row-array compare (which could walk 50k rows
            // on every unrelated store mutation); hosts without a
            // token keep the exhaustive compare.
            let rowsChanged: Bool
            if let revision {
                rowsChanged = revision != prevRevision
            } else {
                rowsChanged = result.rows != prevRows
            }
            if rowsChanged {
                table.reloadData()
            }
            return
        }
        if newDisplayOrder.count > prevDisplayOrder.count,
           Array(newDisplayOrder.prefix(prevDisplayOrder.count)) == prevDisplayOrder {
            let appended = IndexSet(integersIn: prevDisplayOrder.count..<newDisplayOrder.count)
            table.insertRows(at: appended, withAnimation: [])
        } else {
            table.reloadData()
        }
    }
}

// =============================================================================
// CopyableTableView — NSTableView subclass that accepts ⌘C and routes it
// to a designated copy source. Without this, ⌘C lands on the responder
// chain's default no-op for read-only NSTableViews.
// =============================================================================

final class CopyableTableView: NSTableView {
    weak var copySource: PostgresResultsTable.Coordinator?

    /// Action target for the standard `copy:` selector. NSTableView
    /// inherits this from NSResponder; without the override, ⌘C
    /// silently no-ops on a read-only table.
    @objc func copy(_ sender: Any?) {
        copySource?.lastTable = self
        copySource?.copySelectedRows(sender)
    }

    /// AppKit menu item validation lives on `NSMenuItemValidation`,
    /// not `NSResponder`. Conforming explicitly is the right shape.
    override func becomeFirstResponder() -> Bool {
        copySource?.lastTable = self
        return super.becomeFirstResponder()
    }
}

/// Row view that draws a thin accent-colored stripe on the leading
/// edge for rows the user has edited in the current session. Stripe
/// is purely cosmetic — the underlying data is already committed
/// server-side; the indicator is "you touched this row, in case you
/// forget".
final class PostgresEditedRowView: NSTableRowView {
    var isEdited: Bool = false {
        didSet {
            if isEdited != oldValue { needsDisplay = true }
        }
    }
    var isStaged: Bool = false {
        didSet {
            if isStaged != oldValue { needsDisplay = true }
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isStaged {
            let stripeRect = NSRect(x: 0, y: 0, width: 3, height: bounds.height)
            NSColor.systemBlue.withAlphaComponent(0.85).setFill()
            stripeRect.fill()
        } else if isEdited {
            let stripeRect = NSRect(x: 0, y: 0, width: 3, height: bounds.height)
            NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
            stripeRect.fill()
        }
    }
}

extension CopyableTableView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)) {
            return !selectedRowIndexes.isEmpty || numberOfRows > 0
        }
        return true
    }
}
