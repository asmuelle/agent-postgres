use std::sync::Arc;
use std::sync::OnceLock;

use ssh_commander_core::connection_manager::ConnectionManager;
use tokio::runtime::Runtime;

static BRIDGE: OnceLock<MacOsBridge> = OnceLock::new();

pub struct MacOsBridge {
    pub runtime: Runtime,
    pub connection_manager: Arc<ConnectionManager>,
}

impl MacOsBridge {
    /// Return the process-wide bridge instance, lazily creating it if
    /// `rshell_init()` hasn't run yet.
    ///
    /// Every `rshell_*` FFI entry point (~56 call sites) reaches this
    /// through `global()`, so a bad ordering on the Swift side used to
    /// `.expect()`-panic here — which aborts the whole host process
    /// across the FFI boundary rather than surfacing a recoverable
    /// error. `init()` only builds a fresh `Runtime` + `ConnectionManager`
    /// (no per-call state, nothing that depends on caller-supplied
    /// arguments), and `rshell_init()` is otherwise a fire-and-forget
    /// `bool`, so self-initializing here is behaviorally equivalent to
    /// requiring `rshell_init()` first while removing the panic entirely.
    pub fn global() -> &'static Self {
        Self::init()
    }

    pub fn init() -> &'static Self {
        BRIDGE.get_or_init(|| {
            let runtime = Runtime::new().expect("failed to create Tokio runtime");
            let connection_manager = Arc::new(ConnectionManager::new());
            MacOsBridge {
                runtime,
                connection_manager,
            }
        })
    }
}
