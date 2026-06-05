import Foundation

// MARK: - Feature flags

/// Central registry of feature flags that gate incomplete v1 features.
///
/// Before the beta, set any feature that isn't stable to `false`.
/// This hides UI elements (menu items, toolbar buttons, sidebar entries)
/// without removing the code paths.
public enum FeatureFlags: String, CaseIterable, Sendable {
    /// RDP/VNC remote desktop — stubs only, not v1-ready
    case remoteDesktop = "Remote Desktop"
    /// SFTP standalone connection (separate from SSH file browser)
    case standaloneSFTP = "Standalone SFTP"
    /// FTP/FTPS connections
    case ftp = "FTP/FTPS"
    /// Drag-and-drop file transfers between local and remote panes
    case dragDrop = "Drag & Drop Transfer"
    /// Image/sixel protocol in terminal
    case terminalImages = "Terminal Image Support"
    /// GPU monitoring tab
    case gpuMonitor = "GPU Monitor"
    /// Files app / Finder extension backed by SFTP
    case fileProviderIntegration = "Files App Integration"
    /// Uploads from other apps through the platform share sheet
    case shareSheetUploads = "Share Sheet Uploads"
    /// App Intents exposed to Shortcuts
    case shortcutsAutomation = "Shortcuts Automation"
    /// Pinned remote folders cached for offline use
    case offlineSFTPCache = "Offline SFTP Cache"
    /// iCloud sync for profile metadata, snippets, and settings
    case cloudSync = "iCloud Sync"
    /// Terminal output path detection with file actions
    case filenameAwareTerminal = "Filename-Aware Terminal"
    /// Built-in tmux session picker and reconnect flow
    case tmuxSessionManager = "tmux Session Manager"
    /// General local/remote/dynamic SSH port forwarding
    case portForwarding = "Port Forwarding"
    /// Secure Enclave, security keys, and SSH certificate identities
    case advancedAuthentication = "Advanced Authentication"
    /// iOS widgets, Live Activities, Dynamic Island, and watch status
    case liveActivitySurfaces = "Live Activity Surfaces"
    /// DigitalOcean / Hetzner inventory and server lifecycle
    case cloudServerManagement = "Cloud Server Management"
    /// Tailscale-aware resolution and Multipath TCP support
    case networkPolish = "Network Polish"
    /// Read-only, evidence-linked server diagnostics.
    case serverDoctor = "Server Doctor"
    /// Read-only update, reboot, and SSH hardening checks for connected hosts.
    case securityPatchMonitor = "Security Patch Monitor"

    /// Whether this feature is enabled for the current build.
    ///
    /// In Debug builds, all features are visible. In Release (beta) builds,
    /// only the stable subset is enabled.
    public var isEnabled: Bool {
        #if DEBUG
        return true
        #else
        switch self {
        case .remoteDesktop: return false
        case .standaloneSFTP: return false
        case .ftp: return false
        case .dragDrop: return false
        case .terminalImages: return false
        case .gpuMonitor: return false
        case .fileProviderIntegration: return false
        case .shareSheetUploads: return false
        case .shortcutsAutomation: return false
        case .offlineSFTPCache: return false
        case .cloudSync: return false
        case .filenameAwareTerminal: return false
        case .tmuxSessionManager: return false
        case .portForwarding: return false
        case .advancedAuthentication: return false
        case .liveActivitySurfaces: return false
        case .cloudServerManagement: return false
        case .networkPolish: return false
        case .serverDoctor: return false
        case .securityPatchMonitor: return false
        }
        #endif
    }
}
