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
    pub fn global() -> &'static Self {
        BRIDGE
            .get()
            .expect("MacOsBridge not initialized — call rshell_init() first")
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
