import Foundation

// MARK: - Panel identifiers

/// The four panels in the workspace layout.
public enum Panel: String, Codable, CaseIterable, Sendable {
    case sidebar
    case main
    case bottom
    case inspector
}

// MARK: - Persisted layout state

/// Full workspace layout that survives relaunch.
/// Stored as JSON in `Application Support/com.mc-ssh/layout.json`.
public struct WorkspaceLayout: Codable, Sendable {
    public var sidebarVisible: Bool
    public var bottomVisible: Bool
    public var inspectorVisible: Bool
    public var sidebarWidth: CGFloat
    public var bottomHeight: CGFloat
    public var inspectorWidth: CGFloat

    public init(
        sidebarVisible: Bool,
        bottomVisible: Bool,
        inspectorVisible: Bool,
        sidebarWidth: CGFloat,
        bottomHeight: CGFloat,
        inspectorWidth: CGFloat
    ) {
        self.sidebarVisible = sidebarVisible
        self.bottomVisible = bottomVisible
        self.inspectorVisible = inspectorVisible
        self.sidebarWidth = sidebarWidth
        self.bottomHeight = bottomHeight
        self.inspectorWidth = inspectorWidth
    }

    /// First-launch defaults: mirror the Tauri layout — sidebar +
    /// inspector both visible (System Monitor is the right column),
    /// bottom panel collapsed by default since most users won't have
    /// transfers in flight on launch. Widths are slightly wider than
    /// before to fit the connection-details panel and the monitor's
    /// per-mount disk rows without clipping.
    public static let `default` = WorkspaceLayout(
        sidebarVisible: true,
        bottomVisible: false,
        inspectorVisible: true,
        sidebarWidth: 240,
        bottomHeight: 200,
        inspectorWidth: 320
    )
}

// MARK: - Tab and tab-group models

/// Renamed from `Tab` to dodge the macOS 26 SDK's `SwiftUI.Tab` (new top-level
/// type in `TabView` API) — both modules are imported in app sources, which
/// makes a bare `Tab` ambiguous.
public struct WorkspaceTab: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var connectionId: String?
    public var order: Int

    public init(id: UUID = UUID(), title: String, connectionId: String? = nil, order: Int) {
        self.id = id
        self.title = title
        self.connectionId = connectionId
        self.order = order
    }
}

public enum SplitDirection: String, Codable, Sendable {
    case horizontal
    case vertical
}

public struct TabGroup: Codable, Identifiable, Sendable {
    public var id: UUID
    public var tabs: [WorkspaceTab]
    public var activeTabId: UUID?
    public var splitDirection: SplitDirection?
    public var children: [TabGroup]?

    public init(
        id: UUID = UUID(),
        tabs: [WorkspaceTab] = [],
        activeTabId: UUID? = nil,
        splitDirection: SplitDirection? = nil,
        children: [TabGroup]? = nil
    ) {
        self.id = id
        self.tabs = tabs
        self.activeTabId = activeTabId
        self.splitDirection = splitDirection
        self.children = children
    }

    public var activeTab: WorkspaceTab? {
        activeTabId.flatMap { id in tabs.first { $0.id == id } }
    }
}

// MARK: - Layout constants

public enum LayoutConstants {
    public static let minSidebarWidth: CGFloat = 140
    public static let maxSidebarWidth: CGFloat = 400
    public static let defaultSidebarWidth: CGFloat = 220

    public static let minInspectorWidth: CGFloat = 180
    public static let maxInspectorWidth: CGFloat = 500
    public static let defaultInspectorWidth: CGFloat = 260

    public static let minBottomHeight: CGFloat = 80
    public static let maxBottomHeight: CGFloat = 500
    public static let defaultBottomHeight: CGFloat = 200

    public static let workspaceTabStripHeight: CGFloat = 32
}
