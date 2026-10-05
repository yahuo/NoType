//! Unix socket bridge server for Pi, the editor proxy and the browser host.
//! Port of NoTypeBridgeService.swift (server side) plus the request handling from
//! NoTypeAppModel.handleBridgeRequest.

mod handler;
mod server;

pub use handler::{BridgeHandler, BridgeHooks};
pub use server::{BridgeServer, BridgeServiceError, MAX_CONNECTIONS, ProgressSink, RequestHandler};

#[cfg(test)]
pub(crate) mod test_support {
    use std::fs::{self, DirBuilder};
    use std::os::unix::fs::DirBuilderExt;
    use std::path::{Path, PathBuf};

    /// A private scratch directory removed on drop. Prefers the crate's `target/` so tests stay
    /// inside the checkout, falling back to the system temp dir when a socket path would exceed
    /// the `sockaddr_un` limit.
    pub struct TestDir(pub PathBuf);

    impl TestDir {
        pub fn new() -> Self {
            let name = format!("nt-{}", &uuid::Uuid::new_v4().simple().to_string()[..8]);
            let local = Path::new(env!("CARGO_MANIFEST_DIR")).join("target").join(&name);
            let path = if local.as_os_str().len() + "/bridge.sock".len() < 100 {
                local
            } else {
                std::env::temp_dir().join(name)
            };
            DirBuilder::new().recursive(true).mode(0o700).create(&path).unwrap();
            Self(path)
        }

        pub fn path(&self, name: &str) -> PathBuf {
            self.0.join(name)
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
}
