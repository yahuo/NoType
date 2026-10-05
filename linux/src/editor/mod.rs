//! Editor proxy core shared by `notype-editor`.
//! Port of Sources/NoTypeEditorCore and Sources/NoTypeEditor.

mod buffer;
mod client;
mod proxy;

pub use buffer::{EditorBuffer, is_claude_buffer, is_supported_buffer};
pub use client::{DEFAULT_TIMEOUT, EDITOR_CLIENT, EditorBridgeClient, EditorBridgeError, EditorTranslation};
pub use proxy::{
    EditorEnvironment, editable_file, fallback_command, is_editor_proxy_command, load_pending_trigger,
    read_editor_buffer, run, terminal_path, translate_file,
};
