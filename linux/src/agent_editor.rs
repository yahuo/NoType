//! Claude Code / Codex CLI draft translation trigger (`Ctrl+G` external editor flow).
//! Port of AgentEditorIntegrationService.swift. Linux has no global key monitoring, so the
//! trigger is a Hyprland binding (`notype agent-translate`) instead of triple Space.

use std::fs::{self, DirBuilder, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use futures_util::future::BoxFuture;
use serde::{Deserialize, Serialize};
use tokio::task::AbortHandle;

use crate::hyprland::{self, ActiveWindow};
use crate::paths;

pub const TRIGGER_VERSION: i64 = 1;
pub const TRIGGER_LIFETIME_MILLISECONDS: i64 = 5_000;
/// Linux: the user pressed the NoType Hyprland binding.
pub const HOTKEY_TRIGGER: &str = "hotkey";
/// macOS: the user typed three trailing spaces.
pub const TRIPLE_SPACE_TRIGGER: &str = "triple-space";

/// Single-use token shared with `notype-editor` through `paths::editor_trigger_file()`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingTrigger {
    pub version: i64,
    pub token: String,
    pub created_at_milliseconds: i64,
    #[serde(rename = "targetProcessID")]
    pub target_process_id: i32,
    #[serde(default)]
    pub target_window_address: String,
    #[serde(default)]
    pub target_window_class: String,
    #[serde(default = "default_trigger_kind")]
    pub trigger: String,
}

fn default_trigger_kind() -> String {
    TRIPLE_SPACE_TRIGGER.to_owned()
}

impl PendingTrigger {
    pub fn new(window: &ActiveWindow, trigger: &str, created_at_milliseconds: i64) -> Self {
        Self {
            version: TRIGGER_VERSION,
            token: uuid::Uuid::new_v4().to_string().to_uppercase(),
            created_at_milliseconds,
            target_process_id: window.pid,
            target_window_address: window.address.clone(),
            target_window_class: window.class.clone(),
            trigger: trigger.to_owned(),
        }
    }

    pub fn is_fresh(&self, now_milliseconds: i64) -> bool {
        let age = now_milliseconds - self.created_at_milliseconds;
        (-1_000..=TRIGGER_LIFETIME_MILLISECONDS).contains(&age)
    }

    pub fn accepts(&self, candidate: &str, now_milliseconds: i64) -> bool {
        self.version == TRIGGER_VERSION
            && candidate == self.token
            && is_uuid_string(candidate)
            && self.is_fresh(now_milliseconds)
    }
}

/// Matches Foundation's `UUID(uuidString:)`: only the hyphenated 8-4-4-4-12 form, any hex case.
pub fn is_uuid_string(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => byte == b'-',
            _ => byte.is_ascii_hexdigit(),
        })
}

pub fn now_milliseconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_millis() as i64)
}

#[derive(Debug, thiserror::Error)]
pub enum AgentEditorError {
    #[error("NoType agent editor integration does not support {0}.")]
    UnsupportedTerminal(String),
    #[error("The focused terminal changed before NoType could open the agent editor.")]
    TargetChanged,
    #[error("Unable to create a private NoType agent editor trigger.")]
    UnableToSecureTrigger,
    #[error("Unable to synthesize the agent external-editor shortcut.")]
    ShortcutSynthesisFailed,
}

/// Focus query and shortcut injection; Hyprland in production, faked in tests.
pub(crate) trait Desktop: Send + Sync + 'static {
    fn active_window(&self) -> BoxFuture<'_, anyhow::Result<Option<ActiveWindow>>>;
    fn open_external_editor(&self) -> BoxFuture<'_, anyhow::Result<()>>;
}

struct Hyprland;

impl Desktop for Hyprland {
    fn active_window(&self) -> BoxFuture<'_, anyhow::Result<Option<ActiveWindow>>> {
        Box::pin(hyprland::active_window())
    }

    fn open_external_editor(&self) -> BoxFuture<'_, anyhow::Result<()>> {
        Box::pin(hyprland::send_shortcut("CTRL", "G"))
    }
}

struct Pending {
    trigger: PendingTrigger,
    window: ActiveWindow,
    expiration: Option<AbortHandle>,
}

struct Shared {
    trigger_file: PathBuf,
    pending: Mutex<Option<Pending>>,
}

impl Shared {
    fn lock(&self) -> MutexGuard<'_, Option<Pending>> {
        self.pending.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Clears the pending trigger and its file; the caller holds the lock.
    fn clear_locked(&self, pending: &mut Option<Pending>) {
        if let Some(expiration) = pending.take().and_then(|pending| pending.expiration) {
            expiration.abort();
        }
        let _ = fs::remove_file(&self.trigger_file);
    }
}

pub struct AgentEditorTriggers {
    shared: Arc<Shared>,
    desktop: Arc<dyn Desktop>,
    expiry: Duration,
}

impl Default for AgentEditorTriggers {
    fn default() -> Self {
        Self::new()
    }
}

impl AgentEditorTriggers {
    pub fn new() -> Self {
        Self::with_desktop(paths::editor_trigger_file(), Arc::new(Hyprland))
    }

    pub(crate) fn with_desktop(trigger_file: PathBuf, desktop: Arc<dyn Desktop>) -> Self {
        Self {
            shared: Arc::new(Shared {
                trigger_file,
                pending: Mutex::new(None),
            }),
            desktop,
            expiry: Duration::from_millis(TRIGGER_LIFETIME_MILLISECONDS as u64),
        }
    }

    /// Writes a private single-use token for `window`, then sends `Ctrl+G` so the focused
    /// Claude Code or Codex CLI opens `$VISUAL` (the `notype-editor` proxy).
    pub async fn trigger(&self, window: &ActiveWindow) -> anyhow::Result<()> {
        if !window.is_terminal() {
            let name = if window.class.is_empty() {
                &window.title
            } else {
                &window.class
            };
            return Err(AgentEditorError::UnsupportedTerminal(name.clone()).into());
        }
        let focused = self.desktop.active_window().await.ok().flatten();
        if window.pid <= 0 || !focused.is_some_and(|focused| focused.same_window(window)) {
            return Err(AgentEditorError::TargetChanged.into());
        }

        let trigger = PendingTrigger::new(window, HOTKEY_TRIGGER, now_milliseconds());
        {
            let mut pending = self.shared.lock();
            self.shared.clear_locked(&mut pending);
            if persist(&self.shared.trigger_file, &trigger).is_err() {
                let _ = fs::remove_file(&self.shared.trigger_file);
                return Err(AgentEditorError::UnableToSecureTrigger.into());
            }
            *pending = Some(Pending {
                trigger: trigger.clone(),
                window: window.clone(),
                expiration: Some(self.schedule_expiration(trigger.token.clone())),
            });
        }

        if let Err(error) = self.desktop.open_external_editor().await {
            self.clear_if_current(&trigger.token);
            return Err(error.context(AgentEditorError::ShortcutSynthesisFailed));
        }
        Ok(())
    }

    /// Accepts a pending token once. A wrong or stale token leaves the pending trigger intact;
    /// any later failure still consumes it.
    pub async fn consume(&self, token: &str, pid: i32, ppid: i32, terminal: &str) -> bool {
        self.consume_at(token, pid, ppid, terminal, now_milliseconds())
            .await
    }

    async fn consume_at(&self, token: &str, pid: i32, ppid: i32, terminal: &str, now: i64) -> bool {
        let window = {
            let mut pending = self.shared.lock();
            let Some(window) = pending
                .as_ref()
                .filter(|pending| pending.trigger.accepts(token, now))
                .map(|pending| pending.window.clone())
            else {
                return false;
            };
            self.shared.clear_locked(&mut pending);
            window
        };

        if pid <= 1
            || ppid <= 1
            || !process_exists(pid)
            || !process_exists(ppid)
            || !is_private_terminal(terminal)
        {
            return false;
        }
        matches!(self.desktop.active_window().await, Ok(Some(focused)) if focused.same_window(&window))
    }

    pub fn shutdown(&self) {
        let mut pending = self.shared.lock();
        self.shared.clear_locked(&mut pending);
    }

    fn clear_if_current(&self, token: &str) {
        let mut pending = self.shared.lock();
        if pending
            .as_ref()
            .is_some_and(|pending| pending.trigger.token == token)
        {
            self.shared.clear_locked(&mut pending);
        }
    }

    fn schedule_expiration(&self, token: String) -> AbortHandle {
        let shared = Arc::downgrade(&self.shared);
        let expiry = self.expiry;
        tokio::spawn(async move {
            tokio::time::sleep(expiry).await;
            let Some(shared) = shared.upgrade() else {
                return;
            };
            let mut pending = shared.lock();
            if pending
                .as_ref()
                .is_some_and(|pending| pending.trigger.token == token)
            {
                // Taking the value drops our own abort handle without aborting this task early.
                pending.take();
                let _ = fs::remove_file(&shared.trigger_file);
            }
        })
        .abort_handle()
    }

    #[cfg(test)]
    pub(crate) fn pending_token(&self) -> Option<String> {
        self.shared
            .lock()
            .as_ref()
            .map(|pending| pending.trigger.token.clone())
    }
}

/// Writes the trigger atomically with mode `0600` inside a private `0700` directory.
fn persist(trigger_file: &Path, trigger: &PendingTrigger) -> io::Result<()> {
    let directory = trigger_file.parent().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "trigger file has no directory")
    })?;
    DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(directory)?;
    let metadata = fs::symlink_metadata(directory)?;
    if !metadata.is_dir() || metadata.uid() != unsafe { libc::geteuid() } {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "trigger directory is not private",
        ));
    }
    fs::set_permissions(directory, fs::Permissions::from_mode(0o700))?;

    let data = serde_json::to_vec(trigger)?;
    let temporary = directory.join(format!(
        ".editor-trigger-{}.tmp",
        uuid::Uuid::new_v4().simple()
    ));
    let written = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)?;
        file.write_all(&data)?;
        fs::rename(&temporary, trigger_file)?;
        fs::set_permissions(trigger_file, fs::Permissions::from_mode(0o600))
    })();
    if written.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    written
}

#[cfg(target_os = "linux")]
fn process_exists(pid: i32) -> bool {
    Path::new(&format!("/proc/{pid}")).exists()
}

#[cfg(not(target_os = "linux"))]
fn process_exists(pid: i32) -> bool {
    let alive = unsafe { libc::kill(pid, 0) } == 0;
    alive || io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

/// A terminal character device (not a symlink) owned by this user: `/dev/pts/3` on Linux,
/// `/dev/ttys003` on macOS. The path prefix also keeps root-owned devices such as `/dev/null`
/// out when the daemon itself runs as root.
fn is_private_terminal(path: &str) -> bool {
    (path.starts_with("/dev/pts/") || path.starts_with("/dev/tty"))
        && fs::symlink_metadata(path).is_ok_and(|metadata| {
            metadata.file_type().is_char_device() && metadata.uid() == unsafe { libc::geteuid() }
        })
}

#[cfg(test)]
pub(crate) mod tests {
    use std::os::fd::{FromRawFd, OwnedFd};
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

    use super::*;
    use crate::bridge::test_support::TestDir;

    pub(crate) struct FakeDesktop {
        focused: Mutex<Option<ActiveWindow>>,
        shortcuts: AtomicUsize,
        fail_shortcut: AtomicBool,
    }

    impl FakeDesktop {
        pub(crate) fn new(focused: Option<ActiveWindow>) -> Arc<Self> {
            Arc::new(Self {
                focused: Mutex::new(focused),
                shortcuts: AtomicUsize::new(0),
                fail_shortcut: AtomicBool::new(false),
            })
        }

        pub(crate) fn focus(&self, window: Option<ActiveWindow>) {
            *self.focused.lock().unwrap() = window;
        }

        pub(crate) fn shortcuts(&self) -> usize {
            self.shortcuts.load(Ordering::SeqCst)
        }
    }

    impl Desktop for FakeDesktop {
        fn active_window(&self) -> BoxFuture<'_, anyhow::Result<Option<ActiveWindow>>> {
            let focused = self.focused.lock().unwrap().clone();
            Box::pin(async move { Ok(focused) })
        }

        fn open_external_editor(&self) -> BoxFuture<'_, anyhow::Result<()>> {
            self.shortcuts.fetch_add(1, Ordering::SeqCst);
            let fail = self.fail_shortcut.load(Ordering::SeqCst);
            Box::pin(async move {
                if fail {
                    anyhow::bail!("hyprctl eval failed");
                }
                Ok(())
            })
        }
    }

    pub(crate) fn terminal_window() -> ActiveWindow {
        ActiveWindow {
            address: "0x61".into(),
            pid: 42,
            class: "com.mitchellh.ghostty".into(),
            title: "claude".into(),
            tags: vec!["terminal*".into()],
        }
    }

    /// Opens a pseudo-terminal and returns its master plus the user-owned slave path.
    pub(crate) fn private_terminal() -> (OwnedFd, String) {
        static PTSNAME: Mutex<()> = Mutex::new(());
        let _serialized = PTSNAME.lock().unwrap_or_else(PoisonError::into_inner);
        unsafe {
            let master = libc::posix_openpt(libc::O_RDWR | libc::O_NOCTTY);
            assert!(master >= 0, "posix_openpt failed");
            let master = OwnedFd::from_raw_fd(master);
            use std::os::fd::AsRawFd;
            assert_eq!(libc::grantpt(master.as_raw_fd()), 0);
            assert_eq!(libc::unlockpt(master.as_raw_fd()), 0);
            let name = libc::ptsname(master.as_raw_fd());
            assert!(!name.is_null());
            let path = std::ffi::CStr::from_ptr(name)
                .to_string_lossy()
                .into_owned();
            (master, path)
        }
    }

    struct Fixture {
        triggers: AgentEditorTriggers,
        desktop: Arc<FakeDesktop>,
        dir: TestDir,
    }

    fn fixture() -> Fixture {
        let dir = TestDir::new();
        let desktop = FakeDesktop::new(Some(terminal_window()));
        let triggers = AgentEditorTriggers::with_desktop(
            dir.path("runtime").join("editor-trigger.json"),
            desktop.clone(),
        );
        Fixture {
            triggers,
            desktop,
            dir,
        }
    }

    fn read_trigger(fixture: &Fixture) -> PendingTrigger {
        serde_json::from_slice(
            &fs::read(fixture.dir.path("runtime").join("editor-trigger.json")).unwrap(),
        )
        .unwrap()
    }

    fn ids() -> (i32, i32) {
        (std::process::id() as i32, unsafe { libc::getppid() })
    }

    #[test]
    fn pending_token_must_match_and_remain_fresh() {
        let mut trigger = PendingTrigger::new(&terminal_window(), HOTKEY_TRIGGER, 10_000);
        let token = trigger.token.clone();
        assert!(trigger.accepts(&token, 14_999));
        assert!(trigger.accepts(&token, 9_000));
        assert!(!trigger.accepts(&token, 8_999));
        assert!(!trigger.accepts(&uuid::Uuid::new_v4().to_string(), 10_001));
        assert!(!trigger.accepts(&token, 15_001));
        trigger.token = trigger.token.replace('-', "");
        assert!(!trigger.accepts(&trigger.token.clone(), 10_001));
    }

    #[test]
    fn uuid_strings_follow_foundation() {
        assert!(is_uuid_string("2c259eaf-686d-4be3-8b30-f4728fed6ca0"));
        assert!(is_uuid_string("2C259EAF-686D-4BE3-8B30-F4728FED6CA0"));
        assert!(!is_uuid_string("2c259eaf686d4be38b30f4728fed6ca0"));
        assert!(!is_uuid_string("{2c259eaf-686d-4be3-8b30-f4728fed6ca0}"));
        assert!(!is_uuid_string("2c259eaf-686d-4be3-8b30-f4728fed6cag"));
    }

    #[test]
    fn trigger_file_keeps_macos_field_names() {
        let trigger = PendingTrigger::new(&terminal_window(), HOTKEY_TRIGGER, 1);
        let json = serde_json::to_value(&trigger).unwrap();
        assert_eq!(json["targetProcessID"], 42);
        assert_eq!(json["createdAtMilliseconds"], 1);
        assert_eq!(json["targetWindowAddress"], "0x61");
        assert_eq!(json["trigger"], "hotkey");
        let legacy: PendingTrigger = serde_json::from_str(
            r#"{"version":1,"token":"x","createdAtMilliseconds":1,"targetProcessID":2,"targetBundleIdentifier":"b"}"#,
        )
        .unwrap();
        assert_eq!(legacy.trigger, TRIPLE_SPACE_TRIGGER);
    }

    #[tokio::test]
    async fn trigger_writes_a_private_token_and_sends_ctrl_g() {
        let fixture = fixture();
        fixture.triggers.trigger(&terminal_window()).await.unwrap();
        let file = fixture.dir.path("runtime").join("editor-trigger.json");
        assert_eq!(fs::metadata(&file).unwrap().mode() & 0o777, 0o600);
        assert_eq!(
            fs::metadata(fixture.dir.path("runtime")).unwrap().mode() & 0o777,
            0o700
        );
        let trigger = read_trigger(&fixture);
        assert_eq!(trigger.trigger, HOTKEY_TRIGGER);
        assert_eq!(Some(trigger.token), fixture.triggers.pending_token());
        assert_eq!(fixture.desktop.shortcuts(), 1);
        fixture.triggers.shutdown();
        assert!(!file.exists());
    }

    #[tokio::test]
    async fn trigger_rejects_non_terminals_and_focus_changes() {
        let fixture = fixture();
        let mut browser = terminal_window();
        browser.tags.clear();
        assert!(fixture.triggers.trigger(&browser).await.is_err());

        let mut other = terminal_window();
        other.address = "0x62".into();
        fixture.desktop.focus(Some(other));
        let error = fixture
            .triggers
            .trigger(&terminal_window())
            .await
            .unwrap_err();
        assert!(matches!(
            error.downcast_ref(),
            Some(AgentEditorError::TargetChanged)
        ));
        assert_eq!(fixture.desktop.shortcuts(), 0);
        assert!(fixture.triggers.pending_token().is_none());
    }

    #[tokio::test]
    async fn failed_shortcut_clears_the_trigger() {
        let fixture = fixture();
        fixture.desktop.fail_shortcut.store(true, Ordering::SeqCst);
        let error = fixture
            .triggers
            .trigger(&terminal_window())
            .await
            .unwrap_err();
        assert_eq!(
            error.to_string(),
            AgentEditorError::ShortcutSynthesisFailed.to_string()
        );
        assert!(fixture.triggers.pending_token().is_none());
        assert!(
            !fixture
                .dir
                .path("runtime")
                .join("editor-trigger.json")
                .exists()
        );
    }

    #[tokio::test]
    async fn consume_is_single_use_and_checks_terminal_and_focus() {
        let fixture = fixture();
        let (_master, terminal) = private_terminal();
        let (pid, ppid) = ids();

        fixture.triggers.trigger(&terminal_window()).await.unwrap();
        let token = fixture.triggers.pending_token().unwrap();
        // A wrong token does not burn the pending trigger.
        assert!(
            !fixture
                .triggers
                .consume(&uuid::Uuid::new_v4().to_string(), pid, ppid, &terminal)
                .await
        );
        assert!(fixture.triggers.consume(&token, pid, ppid, &terminal).await);
        assert!(!fixture.triggers.consume(&token, pid, ppid, &terminal).await);
        assert!(
            !fixture
                .dir
                .path("runtime")
                .join("editor-trigger.json")
                .exists()
        );

        for (pid, ppid, terminal) in [
            (1, ppid, terminal.as_str()),
            (pid, 0, terminal.as_str()),
            (i32::MAX, ppid, terminal.as_str()),
            (pid, ppid, "/dev/null"),
            (pid, ppid, "/etc/hosts"),
        ] {
            fixture.triggers.trigger(&terminal_window()).await.unwrap();
            let token = fixture.triggers.pending_token().unwrap();
            assert!(
                !fixture.triggers.consume(&token, pid, ppid, terminal).await,
                "{pid} {ppid} {terminal}"
            );
            // Validation failures after the token matched still consume it.
            assert!(fixture.triggers.pending_token().is_none());
        }

        fixture.triggers.trigger(&terminal_window()).await.unwrap();
        let token = fixture.triggers.pending_token().unwrap();
        let mut other = terminal_window();
        other.pid = 43;
        fixture.desktop.focus(Some(other));
        assert!(!fixture.triggers.consume(&token, pid, ppid, &terminal).await);
    }

    #[tokio::test]
    async fn consume_rejects_stale_tokens() {
        let fixture = fixture();
        let (_master, terminal) = private_terminal();
        let (pid, ppid) = ids();
        fixture.triggers.trigger(&terminal_window()).await.unwrap();
        let trigger = read_trigger(&fixture);
        let stale = trigger.created_at_milliseconds + TRIGGER_LIFETIME_MILLISECONDS + 1;
        assert!(
            !fixture
                .triggers
                .consume_at(&trigger.token, pid, ppid, &terminal, stale)
                .await
        );
        assert!(fixture.triggers.pending_token().is_some());
    }

    #[tokio::test]
    async fn pending_trigger_expires() {
        let mut fixture = fixture();
        assert_eq!(fixture.triggers.expiry, Duration::from_secs(5));
        fixture.triggers.expiry = Duration::from_millis(100);
        fixture.triggers.trigger(&terminal_window()).await.unwrap();
        assert!(fixture.triggers.pending_token().is_some());
        tokio::time::sleep(Duration::from_millis(400)).await;
        assert!(fixture.triggers.pending_token().is_none());
        assert!(
            !fixture
                .dir
                .path("runtime")
                .join("editor-trigger.json")
                .exists()
        );
    }
}
