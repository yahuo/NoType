//! Port of NoTypeEditor/NoTypeEditor.swift: a transparent `$VISUAL` that translates the draft
//! only when NoType has just written a matching trigger, and otherwise execs the real editor.

use std::ffi::{CStr, OsString};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

use super::buffer::{EditorBuffer, is_claude_buffer, is_supported_buffer};
use super::client::{EditorBridgeClient, EditorTranslation};
use crate::agent_editor::{HOTKEY_TRIGGER, PendingTrigger, TRIGGER_VERSION, TRIPLE_SPACE_TRIGGER, is_uuid_string, now_milliseconds};
use crate::paths;

const MAX_BUFFER_BYTES: u64 = 1_048_576;
const MAX_TRIGGER_BYTES: u64 = 4_096;

/// The environment the proxy reads, captured once so tests can supply their own.
#[derive(Clone, Debug, Default)]
pub struct EditorEnvironment {
    pub real_visual: Option<String>,
    pub real_editor: Option<String>,
    pub fallback: Option<String>,
    pub trigger_file: PathBuf,
    pub bridge_socket: PathBuf,
}

impl EditorEnvironment {
    pub fn from_process() -> Self {
        let variable = |name| std::env::var(name).ok();
        Self {
            real_visual: variable("NOTYPE_REAL_VISUAL"),
            real_editor: variable("NOTYPE_REAL_EDITOR"),
            fallback: variable("NOTYPE_EDITOR_FALLBACK"),
            trigger_file: std::env::var_os("NOTYPE_EDITOR_TRIGGER_FILE")
                .filter(|value| !value.is_empty())
                .map_or_else(paths::editor_trigger_file, PathBuf::from),
            bridge_socket: paths::bridge_socket(),
        }
    }
}

/// Entry point of `notype-editor`.
pub fn run() -> ExitCode {
    let arguments: Vec<OsString> = std::env::args_os().skip(1).collect();
    let environment = EditorEnvironment::from_process();

    let Some(file) = editable_file(&arguments) else {
        return exec_fallback_editor(&arguments, &environment);
    };
    let Some(trigger) = load_pending_trigger(&environment.trigger_file, now_milliseconds()) else {
        return exec_fallback_editor(&arguments, &environment);
    };

    let buffer = terminal_path().zip(read_editor_buffer(&file)).and_then(|(terminal, content)| {
        EditorBuffer::parse(&content, &trigger.trigger).map(|buffer| (terminal, buffer))
    });
    let Some((terminal, buffer)) = buffer else {
        write_error("NoType: automatic translation validation failed; the draft was left unchanged.\n");
        return ExitCode::SUCCESS;
    };

    if is_claude_buffer(&file) {
        write_error("NoType: translating…\n");
    }
    let client = EditorBridgeClient::new(environment.bridge_socket.clone());
    let translated = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(anyhow::Error::from)
        .and_then(|runtime| runtime.block_on(translate_file(&client, &file, &buffer, &trigger, &terminal)));
    if let Err(error) = translated {
        // A failed automatic translation must leave the agent's temporary file untouched.
        write_error(&format!("NoType: {error}\n"));
    }
    ExitCode::SUCCESS
}

pub async fn translate_file(
    client: &EditorBridgeClient,
    file: &Path,
    buffer: &EditorBuffer,
    trigger: &PendingTrigger,
    terminal: &str,
) -> anyhow::Result<()> {
    let translated = client
        .translate(&EditorTranslation {
            source_text: &buffer.source_text,
            token: &trigger.token,
            process_id: std::process::id() as i32,
            parent_process_id: unsafe { libc::getppid() },
            terminal,
            trigger: &trigger.trigger,
        })
        .await?;
    replace_editor_buffer(file, &buffer.replacing_source(&translated))?;
    Ok(())
}

/// The agent passes its temporary file last; only user-owned Claude/Codex drafts qualify.
pub fn editable_file(arguments: &[OsString]) -> Option<PathBuf> {
    let path = arguments.last().filter(|path| !path.is_empty())?;
    let path = std::path::absolute(path).ok()?;
    if !is_supported_buffer(&path) {
        return None;
    }
    let metadata = fs::symlink_metadata(&path).ok()?;
    (metadata.file_type().is_file() && metadata.uid() == euid() && metadata.len() <= MAX_BUFFER_BYTES).then_some(path)
}

pub fn read_editor_buffer(path: &Path) -> Option<String> {
    let (_, data) = read_private_file(path, MAX_BUFFER_BYTES, false)?;
    String::from_utf8(data).ok()
}

/// Reads NoType's single-use trigger; it must be private, fresh and well-formed.
pub fn load_pending_trigger(path: &Path, now: i64) -> Option<PendingTrigger> {
    let (_, data) = read_private_file(path, MAX_TRIGGER_BYTES, true)?;
    let trigger: PendingTrigger = serde_json::from_slice(&data).ok()?;
    let valid = trigger.version == TRIGGER_VERSION
        && is_uuid_string(&trigger.token)
        && trigger.target_process_id > 0
        && !trigger.target_window_address.is_empty()
        && matches!(trigger.trigger.as_str(), HOTKEY_TRIGGER | TRIPLE_SPACE_TRIGGER)
        && trigger.is_fresh(now);
    valid.then_some(trigger)
}

/// Opens without following symlinks and validates the opened file, not the path.
fn read_private_file(path: &Path, max_bytes: u64, owner_only: bool) -> Option<(File, Vec<u8>)> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.file_type().is_file()
        || metadata.uid() != euid()
        || metadata.len() > max_bytes
        || (owner_only && metadata.mode() & 0o077 != 0)
    {
        return None;
    }
    let mut data = Vec::new();
    (&file).take(max_bytes + 1).read_to_end(&mut data).ok()?;
    (data.len() as u64 <= max_bytes).then_some((file, data))
}

/// Atomically replaces the draft, keeping its permission bits.
fn replace_editor_buffer(path: &Path, content: &str) -> io::Result<()> {
    let permissions = fs::symlink_metadata(path)?.permissions().mode() & 0o7777;
    let directory = path.parent().ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput))?;
    let name = path.file_name().map(|name| name.to_string_lossy()).unwrap_or_default();
    let temporary = directory.join(format!(".{name}.notype-{}", uuid::Uuid::new_v4().simple()));
    let written = (|| {
        let mut file = OpenOptions::new().write(true).create_new(true).mode(0o600).open(&temporary)?;
        file.write_all(content.as_bytes())?;
        file.sync_all()?;
        file.set_permissions(fs::Permissions::from_mode(permissions))?;
        fs::rename(&temporary, path)
    })();
    if written.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    written
}

/// The controlling terminal of stdin, stdout or stderr, owned by this user.
pub fn terminal_path() -> Option<String> {
    [libc::STDIN_FILENO, libc::STDOUT_FILENO, libc::STDERR_FILENO]
        .into_iter()
        .find_map(|descriptor| {
            let mut name = [0 as libc::c_char; 1024];
            if unsafe { libc::ttyname_r(descriptor, name.as_mut_ptr(), name.len()) } != 0 {
                return None;
            }
            let path = unsafe { CStr::from_ptr(name.as_ptr()) }.to_str().ok()?.to_owned();
            let owned = fs::metadata(&path).is_ok_and(|metadata| metadata.uid() == euid());
            (path.starts_with("/dev/") && owned).then_some(path)
        })
}

/// The editor to delegate to: the user's original `$VISUAL`/`$EDITOR`, never the proxy itself.
pub fn fallback_command(environment: &EditorEnvironment) -> String {
    let command = [&environment.real_visual, &environment.real_editor, &environment.fallback]
        .into_iter()
        .flatten()
        .map(|command| command.trim())
        .find(|command| !command.is_empty() && !is_editor_proxy_command(command))
        .map(str::to_owned)
        .unwrap_or_else(default_editor);
    if command.contains(['\n', '\r']) { default_editor() } else { command }
}

/// Matches `(?:^|[/\s'"])notype-?editor(?:$|[\s'"])`, case-insensitively.
pub fn is_editor_proxy_command(command: &str) -> bool {
    let command = command.to_ascii_lowercase();
    let quote = |character: char| matches!(character, '\'' | '"') || character.is_whitespace();
    command.match_indices("notype").any(|(index, word)| {
        let starts_word = command[..index].chars().next_back().is_none_or(|before| before == '/' || quote(before));
        let rest = &command[index + word.len()..];
        let rest = rest.strip_prefix('-').unwrap_or(rest);
        starts_word && rest.strip_prefix("editor").is_some_and(|after| after.chars().next().is_none_or(quote))
    })
}

#[cfg(target_os = "linux")]
fn default_editor() -> String {
    // Omarchy ships Neovim; plain `vi` may not be installed.
    let path = std::env::var_os("PATH").unwrap_or_default();
    let installed = |name: &str| {
        std::env::split_paths(&path).any(|directory| {
            fs::metadata(directory.join(name)).is_ok_and(|metadata| metadata.is_file() && metadata.mode() & 0o111 != 0)
        })
    };
    ["vi", "nvim", "vim"].into_iter().find(|name| installed(name)).unwrap_or("vi").to_owned()
}

#[cfg(not(target_os = "linux"))]
fn default_editor() -> String {
    "/usr/bin/vi".to_owned()
}

fn exec_fallback_editor(arguments: &[OsString], environment: &EditorEnvironment) -> ExitCode {
    let command = fallback_command(environment);
    let error = Command::new("/bin/sh")
        .arg("-c")
        .arg(format!("exec {command} \"$@\""))
        .arg("notype-editor")
        .args(arguments)
        .exec();
    write_error(&format!("NoType: unable to launch the fallback editor: {error}\n"));
    ExitCode::from(127)
}

fn write_error(message: &str) {
    let _ = io::stderr().write_all(message.as_bytes());
}

fn euid() -> u32 {
    unsafe { libc::geteuid() }
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::{DirBuilderExt, symlink};

    use tokio::io::AsyncWriteExt;
    use tokio::net::UnixListener;

    use super::*;
    use crate::agent_editor::tests::terminal_window;
    use crate::bridge::test_support::TestDir;
    use crate::protocol::{BridgeRequest, BridgeResponse, encode_json_frame, read_frame};

    fn environment(visual: Option<&str>, editor: Option<&str>) -> EditorEnvironment {
        EditorEnvironment {
            real_visual: visual.map(Into::into),
            real_editor: editor.map(Into::into),
            ..EditorEnvironment::default()
        }
    }

    #[test]
    fn recognizes_the_proxy_command() {
        for command in [
            "notype-editor",
            "/home/me/.local/bin/notype-editor",
            "'/opt/NoType Editor/NoTypeEditor' --wait",
            "env FOO=1 notypeeditor",
        ] {
            assert!(is_editor_proxy_command(command), "{command}");
        }
        for command in ["nvim", "code --wait", "notype-editor-old", "mynotype-editor", "notype"] {
            assert!(!is_editor_proxy_command(command), "{command}");
        }
    }

    #[test]
    fn delegates_to_the_original_editor_but_never_to_itself() {
        assert_eq!(fallback_command(&environment(Some(" nvim "), Some("vim"))), "nvim");
        assert_eq!(fallback_command(&environment(Some("notype-editor"), Some("helix"))), "helix");
        assert_eq!(fallback_command(&environment(Some(""), Some("  "))), default_editor());
        assert_eq!(fallback_command(&environment(Some("vim\nrm -rf ~"), None)), default_editor());
        let mut fallback = environment(None, None);
        fallback.fallback = Some("nano".into());
        assert_eq!(fallback_command(&fallback), "nano");
    }

    struct Draft {
        dir: TestDir,
        file: PathBuf,
        trigger_file: PathBuf,
    }

    fn draft(content: &str) -> Draft {
        let dir = TestDir::new();
        let claude = dir.path("claude-test");
        fs::DirBuilder::new().mode(0o700).create(&claude).unwrap();
        let file = claude.join(format!("claude-prompt-{}.md", uuid::Uuid::new_v4()));
        fs::write(&file, content).unwrap();
        fs::set_permissions(&file, fs::Permissions::from_mode(0o640)).unwrap();
        let trigger_file = dir.path("editor-trigger.json");
        Draft { dir, file, trigger_file }
    }

    fn write_trigger(path: &Path, trigger: &PendingTrigger, mode: u32) {
        let _ = fs::remove_file(path);
        fs::write(path, serde_json::to_vec(trigger).unwrap()).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
    }

    #[test]
    fn only_private_fresh_triggers_and_owned_drafts_are_accepted() {
        let draft = draft("draft");
        assert_eq!(editable_file(&["--wait".into(), draft.file.clone().into()]), Some(draft.file.clone()));
        assert_eq!(editable_file(&[draft.dir.path("notes.md").into()]), None);
        assert_eq!(editable_file(&[]), None);
        let link = draft.file.with_file_name(format!("claude-prompt-{}.md", uuid::Uuid::new_v4()));
        symlink(&draft.file, &link).unwrap();
        assert_eq!(editable_file(&[link.into()]), None);

        let mut trigger = PendingTrigger::new(&terminal_window(), HOTKEY_TRIGGER, 10_000);
        write_trigger(&draft.trigger_file, &trigger, 0o600);
        assert_eq!(load_pending_trigger(&draft.trigger_file, 14_999), Some(trigger.clone()));
        assert_eq!(load_pending_trigger(&draft.trigger_file, 15_001), None);
        write_trigger(&draft.trigger_file, &trigger, 0o644);
        assert_eq!(load_pending_trigger(&draft.trigger_file, 10_001), None);

        let link = draft.dir.path("trigger-link.json");
        write_trigger(&draft.trigger_file, &trigger, 0o600);
        symlink(&draft.trigger_file, &link).unwrap();
        assert_eq!(load_pending_trigger(&link, 10_001), None);

        trigger.trigger = "ctrl-g".into();
        write_trigger(&draft.trigger_file, &trigger, 0o600);
        assert_eq!(load_pending_trigger(&draft.trigger_file, 10_001), None);
        trigger.trigger = TRIPLE_SPACE_TRIGGER.into();
        trigger.target_window_address.clear();
        write_trigger(&draft.trigger_file, &trigger, 0o600);
        assert_eq!(load_pending_trigger(&draft.trigger_file, 10_001), None);
    }

    /// Answers one editor request with `reply(request)` and returns the request it saw.
    async fn fake_bridge(
        socket: PathBuf,
        reply: impl FnOnce(&BridgeRequest) -> BridgeResponse + Send + 'static,
    ) -> tokio::task::JoinHandle<BridgeRequest> {
        let listener = UnixListener::bind(&socket).unwrap();
        tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let request: BridgeRequest =
                serde_json::from_slice(&read_frame(&mut stream).await.unwrap().unwrap()).unwrap();
            let mut progress = BridgeResponse::success(&request.id, Some("partial".into()));
            progress.partial = Some(true);
            stream.write_all(&encode_json_frame(&progress).unwrap()).await.unwrap();
            stream.write_all(&encode_json_frame(&reply(&request)).unwrap()).await.unwrap();
            request
        })
    }

    #[tokio::test]
    async fn translates_the_reply_and_keeps_claude_context_and_permissions() {
        let prefix = format!("{}\n\n", EditorBuffer::CLAUDE_REPLY_MARKER_PREFIX);
        let draft = draft(&format!("{prefix}请继续\n"));
        let trigger = PendingTrigger::new(&terminal_window(), HOTKEY_TRIGGER, now_milliseconds());
        let buffer = EditorBuffer::parse(&read_editor_buffer(&draft.file).unwrap(), &trigger.trigger).unwrap();
        let socket = draft.dir.path("bridge.sock");
        let server = fake_bridge(socket.clone(), |request| {
            BridgeResponse::success(&request.id, Some("Please continue.".into()))
        })
        .await;

        let client = EditorBridgeClient::new(socket);
        translate_file(&client, &draft.file, &buffer, &trigger, "/dev/pts/9").await.unwrap();

        let request = server.await.unwrap();
        assert_eq!(request.method, "translate_editor");
        assert_eq!(request.client.as_deref(), Some("agent-editor"));
        assert_eq!(request.text.as_deref(), Some("请继续"));
        assert_eq!(request.token, Some(trigger.token));
        assert_eq!(request.process_id, Some(std::process::id() as i32));
        assert_eq!(request.terminal.as_deref(), Some("/dev/pts/9"));
        assert_eq!(request.trigger.as_deref(), Some(HOTKEY_TRIGGER));
        assert_eq!(fs::read_to_string(&draft.file).unwrap(), format!("{prefix}Please continue.\n"));
        assert_eq!(fs::metadata(&draft.file).unwrap().mode() & 0o777, 0o640);
    }

    #[tokio::test]
    async fn failures_leave_the_draft_untouched() {
        let draft = draft("请继续   ");
        let trigger = PendingTrigger::new(&terminal_window(), TRIPLE_SPACE_TRIGGER, now_milliseconds());
        let buffer = EditorBuffer::parse("请继续   ", &trigger.trigger).unwrap();
        let socket = draft.dir.path("bridge.sock");
        let client = EditorBridgeClient::new(socket.clone());

        let error = translate_file(&client, &draft.file, &buffer, &trigger, "/dev/pts/9").await.unwrap_err();
        assert!(error.to_string().starts_with("Unable to connect to NoType: "), "{error}");

        let server = fake_bridge(socket.clone(), |request| {
            BridgeResponse::failure(&request.id, "busy", "NoType is already processing another request.")
        })
        .await;
        let error = translate_file(&client, &draft.file, &buffer, &trigger, "/dev/pts/9").await.unwrap_err();
        assert_eq!(error.to_string(), "NoType is already processing another request.");
        server.await.unwrap();
        fs::remove_file(&socket).unwrap();

        let server = fake_bridge(socket.clone(), |_| BridgeResponse::success("other", Some("text".into()))).await;
        let error = translate_file(&client, &draft.file, &buffer, &trigger, "/dev/pts/9").await.unwrap_err();
        assert_eq!(
            error.to_string(),
            "NoType returned an invalid editor response: response ID or version mismatch"
        );
        server.await.unwrap();
        fs::remove_file(&socket).unwrap();

        let server = fake_bridge(socket.clone(), |request| BridgeResponse::success(&request.id, Some(" \n".into()))).await;
        let error = translate_file(&client, &draft.file, &buffer, &trigger, "/dev/pts/9").await.unwrap_err();
        assert_eq!(error.to_string(), "NoType returned an invalid editor response: translation is empty");
        server.await.unwrap();

        assert_eq!(fs::read_to_string(&draft.file).unwrap(), "请继续   ");
    }
}
