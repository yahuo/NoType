//! Bridge request handling. Port of `NoTypeAppModel.handleBridgeRequest`.

use std::sync::{Arc, Mutex, PoisonError};

use uuid::Uuid;

use super::ProgressSink;
use crate::PartialCallback;
use crate::agent_editor::{
    AgentEditorTriggers, HOTKEY_TRIGGER, TRIPLE_SPACE_TRIGGER, is_uuid_string,
};
use crate::protocol::{
    Admission, BridgeRequest, BridgeResponse, PING_METHOD, TRANSLATE_CHINESE_BATCH_METHOD,
    TRANSLATE_CHINESE_METHOD, TRANSLATE_EDITOR_METHOD, TRANSLATE_METHOD, VERSION,
    validate_browser_batch,
};
use crate::rewrite::AiRewriteService;

/// Daemon state the bridge consults before admitting a translation.
pub trait BridgeHooks: Send + Sync + 'static {
    /// True while dictation is recording, transcribing or refining.
    fn dictation_busy(&self) -> bool;
}

pub struct BridgeHandler {
    ai: Arc<AiRewriteService>,
    editor: Arc<AgentEditorTriggers>,
    hooks: Arc<dyn BridgeHooks>,
    admission: Mutex<Admission>,
}

/// Releases an admission slot when the request finishes or its future is dropped.
struct AdmissionGuard<'a> {
    admission: &'a Mutex<Admission>,
    token: Uuid,
}

impl Drop for AdmissionGuard<'_> {
    fn drop(&mut self) {
        self.admission
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .release(self.token);
    }
}

impl BridgeHandler {
    pub fn new(
        ai: Arc<AiRewriteService>,
        editor: Arc<AgentEditorTriggers>,
        hooks: Arc<dyn BridgeHooks>,
    ) -> Self {
        Self {
            ai,
            editor,
            hooks,
            admission: Mutex::new(Admission::default()),
        }
    }

    pub async fn handle(&self, request: BridgeRequest, progress: ProgressSink) -> BridgeResponse {
        let id = request.id.as_str();
        if request.version != VERSION {
            return BridgeResponse::failure(
                id,
                "unsupported_version",
                format!(
                    "Unsupported NoType bridge protocol version: {}.",
                    request.version
                ),
            );
        }
        if id.is_empty() || id.len() > 128 {
            return BridgeResponse::failure(
                id,
                "invalid_request_id",
                "The NoType bridge request ID must contain 1 to 128 bytes.",
            );
        }
        if request.method == PING_METHOD {
            return BridgeResponse::success(id, Some("pong".into()));
        }

        match request.method.as_str() {
            TRANSLATE_CHINESE_METHOD | TRANSLATE_CHINESE_BATCH_METHOD | TRANSLATE_METHOD => {}
            TRANSLATE_EDITOR_METHOD => {
                if !self.consume_editor_trigger(&request).await {
                    return BridgeResponse::failure(
                        id,
                        "invalid_editor_trigger",
                        "The NoType agent editor trigger is missing, stale, or belongs to another terminal.",
                    );
                }
            }
            method => {
                return BridgeResponse::failure(
                    id,
                    "unsupported_method",
                    format!("Unsupported NoType bridge method: {method}."),
                );
            }
        }

        let is_batch = request.method == TRANSLATE_CHINESE_BATCH_METHOD;
        let items = request.items.as_deref().unwrap_or_default();
        if is_batch && validate_browser_batch(items).is_err() {
            return BridgeResponse::failure(
                id,
                "invalid_batch",
                "翻译批次无效或超过段数/长度限制。",
            );
        }
        let source_text = request.text.as_deref().unwrap_or_default();
        if !is_batch && source_text.trim().is_empty() {
            return BridgeResponse::failure(
                id,
                "empty_text",
                "The NoType bridge translation text is empty.",
            );
        }

        let browser = is_batch && request.client.as_deref() == Some("browser");
        let admitted = if self.hooks.dictation_busy() {
            None
        } else {
            self.admit(browser)
        };
        let Some(_admission) = admitted else {
            return BridgeResponse::failure(
                id,
                "busy",
                "NoType is already processing another request.",
            );
        };

        if !self.ai.has_credentials() {
            return BridgeResponse::failure(
                id,
                "missing_codex_auth",
                "Translation requires Codex login. Run `codex login` first.",
            );
        }

        if is_batch {
            let request_id = request.id.clone();
            let on_partial: PartialCallback = Arc::new(move |partial: String| {
                let mut update = BridgeResponse::success(&request_id, Some(partial));
                update.partial = Some(true);
                progress.send(update);
            });
            return match self
                .ai
                .translate_browser_batch(items, Some(on_partial))
                .await
            {
                Ok(translated) => {
                    let mut response = BridgeResponse::success(id, None);
                    response.items = Some(translated);
                    response
                }
                Err(error) => BridgeResponse::failure(id, "translation_failed", error.to_string()),
            };
        }
        let translated = if request.method == TRANSLATE_CHINESE_METHOD {
            self.ai.translate_to_chinese(source_text, None).await
        } else {
            self.ai.translate_to_english(source_text, None).await
        };
        match translated {
            Ok(text) => BridgeResponse::success(id, Some(text)),
            Err(error) => BridgeResponse::failure(id, "translation_failed", error.to_string()),
        }
    }

    /// The token is consumed here, before the busy and credential checks, as on macOS.
    async fn consume_editor_trigger(&self, request: &BridgeRequest) -> bool {
        let (Some(token), Some(process_id), Some(parent_process_id), Some(terminal)) = (
            request.token.as_deref(),
            request.process_id,
            request.parent_process_id,
            request.terminal.as_deref(),
        ) else {
            return false;
        };
        request.client.as_deref() == Some("agent-editor")
            && matches!(
                request.trigger.as_deref(),
                Some(TRIPLE_SPACE_TRIGGER | HOTKEY_TRIGGER)
            )
            && is_uuid_string(token)
            && terminal.len() <= 1_024
            && self
                .editor
                .consume(token, process_id, parent_process_id, terminal)
                .await
    }

    fn admit(&self, browser: bool) -> Option<AdmissionGuard<'_>> {
        let token = self
            .admission
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .acquire(browser)?;
        Some(AdmissionGuard {
            admission: &self.admission,
            token,
        })
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicBool, Ordering};

    use super::*;
    use crate::agent_editor::tests::{FakeDesktop, private_terminal, terminal_window};
    use crate::bridge::test_support::TestDir;
    use crate::codex_auth::CodexAuthStore;
    use crate::protocol::TranslationItem;

    struct Hooks(AtomicBool);

    impl BridgeHooks for Hooks {
        fn dictation_busy(&self) -> bool {
            self.0.load(Ordering::SeqCst)
        }
    }

    struct Fixture {
        handler: BridgeHandler,
        editor: Arc<AgentEditorTriggers>,
        desktop: Arc<FakeDesktop>,
        _dir: TestDir,
    }

    // Every case stops before `has_credentials()`, which reads the Codex auth store.
    fn fixture(busy: bool) -> Fixture {
        let dir = TestDir::new();
        let desktop = FakeDesktop::new(Some(terminal_window()));
        let editor = Arc::new(AgentEditorTriggers::with_desktop(
            dir.path("editor-trigger.json"),
            desktop.clone(),
        ));
        let handler = BridgeHandler::new(
            Arc::new(AiRewriteService::new(CodexAuthStore::new(None))),
            editor.clone(),
            Arc::new(Hooks(AtomicBool::new(busy))),
        );
        Fixture {
            handler,
            editor,
            desktop,
            _dir: dir,
        }
    }

    fn request(method: &str) -> BridgeRequest {
        let mut request = BridgeRequest::new(method);
        request.text = Some("你好".into());
        request
    }

    async fn code(handler: &BridgeHandler, request: BridgeRequest) -> String {
        let response = handler.handle(request, ProgressSink::discard()).await;
        assert!(!response.ok);
        response.error.unwrap().code
    }

    #[tokio::test]
    async fn validates_version_id_and_method_in_swift_order() {
        let fixture = fixture(false);
        let mut wrong_version = request("nope");
        wrong_version.version = 2;
        wrong_version.id = String::new();
        assert_eq!(
            code(&fixture.handler, wrong_version).await,
            "unsupported_version"
        );

        let mut long_id = request(PING_METHOD);
        long_id.id = "x".repeat(129);
        assert_eq!(code(&fixture.handler, long_id).await, "invalid_request_id");

        let ping = fixture
            .handler
            .handle(request(PING_METHOD), ProgressSink::discard())
            .await;
        assert!(ping.ok);
        assert_eq!(ping.text.as_deref(), Some("pong"));

        let response = fixture
            .handler
            .handle(request("rewrite"), ProgressSink::discard())
            .await;
        let error = response.error.unwrap();
        assert_eq!(error.code, "unsupported_method");
        assert_eq!(error.message, "Unsupported NoType bridge method: rewrite.");
    }

    #[tokio::test]
    async fn rejects_invalid_batches_and_empty_text() {
        let fixture = fixture(false);
        let mut batch = request(TRANSLATE_CHINESE_BATCH_METHOD);
        batch.items = Some(vec![TranslationItem {
            id: "bad id".into(),
            text: "Hello".into(),
        }]);
        assert_eq!(code(&fixture.handler, batch).await, "invalid_batch");
        assert_eq!(
            code(&fixture.handler, request(TRANSLATE_CHINESE_BATCH_METHOD)).await,
            "invalid_batch"
        );

        let mut empty = request(TRANSLATE_METHOD);
        empty.text = Some(" \n ".into());
        assert_eq!(code(&fixture.handler, empty).await, "empty_text");
    }

    #[tokio::test]
    async fn dictation_and_exclusive_admission_report_busy() {
        let busy = fixture(true);
        assert_eq!(code(&busy.handler, request(TRANSLATE_METHOD)).await, "busy");

        let idle = fixture(false);
        let held = idle.handler.admit(false).unwrap();
        assert_eq!(
            code(&idle.handler, request(TRANSLATE_CHINESE_METHOD)).await,
            "busy"
        );
        drop(held);
        // Dropping the guard (as when a client disconnects) frees the exclusive slot.
        let first = idle.handler.admit(true).unwrap();
        let second = idle.handler.admit(true).unwrap();
        assert!(idle.handler.admit(true).is_none());
        drop((first, second));
        assert!(idle.handler.admit(false).is_some());
    }

    #[tokio::test]
    async fn editor_requests_need_a_valid_single_use_trigger() {
        let fixture = fixture(true);
        let (_master, terminal) = private_terminal();
        let window = terminal_window();
        fixture.editor.trigger(&window).await.unwrap();
        let token = fixture.editor.pending_token().unwrap();

        let editor_request = |client: &str, trigger: &str| {
            let mut request = request(TRANSLATE_EDITOR_METHOD);
            request.client = Some(client.into());
            request.trigger = Some(trigger.into());
            request.token = Some(token.clone());
            request.process_id = Some(std::process::id() as i32);
            request.parent_process_id = Some(unsafe { libc::getppid() });
            request.terminal = Some(terminal.clone());
            request
        };

        assert_eq!(
            code(&fixture.handler, editor_request("pi", HOTKEY_TRIGGER)).await,
            "invalid_editor_trigger"
        );
        assert_eq!(
            code(&fixture.handler, editor_request("agent-editor", "ctrl-g")).await,
            "invalid_editor_trigger"
        );
        // Rejected requests above never reached consume(), so the trigger is still pending.
        assert_eq!(
            fixture.editor.pending_token().as_deref(),
            Some(token.as_str())
        );
        // The trigger is consumed before the busy check.
        assert_eq!(
            code(
                &fixture.handler,
                editor_request("agent-editor", HOTKEY_TRIGGER)
            )
            .await,
            "busy"
        );
        assert_eq!(
            code(
                &fixture.handler,
                editor_request("agent-editor", HOTKEY_TRIGGER)
            )
            .await,
            "invalid_editor_trigger"
        );
        assert_eq!(fixture.desktop.shortcuts(), 1);
    }
}
