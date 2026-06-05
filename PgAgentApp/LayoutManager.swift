import Cocoa
import OSLog
import PgAgentMacOS

/// Observable object that owns the workspace layout state, persists it
/// to `Application Support/com.mc-ssh/layout.json`, and responds to
/// keyboard shortcuts.
///
/// Lifecycle: created in `PgAgentApp` and injected as `@StateObject`.
///
/// Writes are debounced to avoid a blocking disk write on every mutation
/// (menu toggle, preset switch, drag resize). Each mutation resets a 250ms
/// timer; the final state lands on disk once activity settles.
@MainActor
class LayoutManager: ObservableObject {
    private let logger = Logger(subsystem: "com.mc-ssh", category: "layout")

    // MARK: - Published panel state

    @Published var layout: WorkspaceLayout {
        didSet { scheduleSave() }
    }

    // MARK: - Persistence URL

    private static var layoutFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.mc-ssh")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("layout.json")
    }

    // MARK: - Init

    init() {
        self.layout = Self.load()
    }

    // MARK: - Debounced persistence

    private var saveTask: Task<Void, Never>?

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            do {
                let data = try JSONEncoder().encode(layout)
                try data.write(to: Self.layoutFileURL)
            } catch {
                logger.error("Failed to save layout: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Panel toggles

    func toggleSidebar() {
        layout.sidebarVisible.toggle()
    }

    func toggleBottom() {
        layout.bottomVisible.toggle()
    }

    func toggleInspector() {
        layout.inspectorVisible.toggle()
    }

    /// Apply a named preset.
    func applyPreset(_ preset: LayoutPreset) {
        switch preset {
        case .default:
            layout = WorkspaceLayout.default
        case .minimal:
            layout = WorkspaceLayout(
                sidebarVisible: false, bottomVisible: false, inspectorVisible: false,
                sidebarWidth: LayoutConstants.defaultSidebarWidth,
                bottomHeight: LayoutConstants.defaultBottomHeight,
                inspectorWidth: LayoutConstants.defaultInspectorWidth
            )
        case .focus:
            layout = WorkspaceLayout(
                sidebarVisible: true, bottomVisible: true, inspectorVisible: false,
                sidebarWidth: LayoutConstants.defaultSidebarWidth,
                bottomHeight: LayoutConstants.defaultBottomHeight,
                inspectorWidth: LayoutConstants.defaultInspectorWidth
            )
        case .fullStack:
            layout = WorkspaceLayout(
                sidebarVisible: true, bottomVisible: true, inspectorVisible: true,
                sidebarWidth: LayoutConstants.defaultSidebarWidth,
                bottomHeight: LayoutConstants.defaultBottomHeight,
                inspectorWidth: LayoutConstants.defaultInspectorWidth
            )
        case .zen:
            layout = WorkspaceLayout(
                sidebarVisible: false, bottomVisible: false, inspectorVisible: false,
                sidebarWidth: 0, bottomHeight: 0, inspectorWidth: 0
            )
        }
    }

    private static func load() -> WorkspaceLayout {
        do {
            let data = try Data(contentsOf: layoutFileURL)
            return try JSONDecoder().decode(WorkspaceLayout.self, from: data)
        } catch {
            return .default
        }
    }
}

// MARK: - Layout presets

enum LayoutPreset: String, CaseIterable {
    case `default`
    case minimal
    case focus
    case fullStack
    case zen
}
