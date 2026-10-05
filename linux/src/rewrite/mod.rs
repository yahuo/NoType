//! Codex Responses (SSE) rewrite and translation. Port of AIRewriteService.swift.

mod prompts;
mod stream;
#[cfg(test)]
pub(crate) mod test_support;

use std::future::Future;
use std::sync::{Mutex, PoisonError};
use std::time::Duration;

use reqwest::header::{CONTENT_TYPE, USER_AGENT};
use tokio::time::Instant;

pub use prompts::{
    BROWSER_TRANSLATION_PROMPT, CHINESE_TRANSLATION_PROMPT, REWRITE_PROMPT, TRANSLATION_PROMPT, rewrite_user_message,
    translation_user_message,
};
pub use stream::CodexResponseStreamAccumulator;

use crate::PartialCallback;
use crate::codex_auth::{CodexAuthStore, CodexCredentials, CodexModelResolver};
use crate::protocol::{TranslationItem, decode_browser_batch, validate_browser_batch};
use stream::{CodexResponseRequest, LineBuffer};

pub const REWRITE_MODEL: &str = "gpt-5.6-terra";
pub const REWRITE_REASONING_EFFORT: &str = "high";
pub const TRANSLATION_MODEL: &str = "gpt-5.6-luna";
pub const TRANSLATION_REASONING_EFFORT: &str = "none";
pub const CODEX_RESPONSES_URL: &str = "https://chatgpt.com/backend-api/codex/responses";
// An HTTP/2 connection used within this window is assumed to still be pooled.
const CONNECTION_WARM_WINDOW: Duration = Duration::from_secs(20);

#[derive(Debug, thiserror::Error)]
pub enum AiError {
    #[error("Codex OAuth is not configured. Run `codex login` in Terminal first.")]
    MissingCodexAuth,
    #[error("Codex OAuth credentials are invalid. Run `codex login` again.")]
    InvalidCodexAuth,
    #[error("Codex OAuth access token is expired. Run `codex login status` or reopen Codex to refresh it.")]
    CodexAuthExpired,
    #[error("The Codex rewrite service returned an invalid response.")]
    InvalidResponse,
    #[error("The Codex rewrite stream ended before completion.")]
    IncompleteStream,
    #[error("AI Rewrite timed out.")]
    TimedOut,
    #[error("翻译超时，请稍后重试或缩短选中文字。")]
    TranslationTimedOut,
    #[error("{}", request_failed_message(*.0, .1))]
    RequestFailed(u16, String),
    /// The network went idle for longer than the request timeout (`URLError.timedOut`).
    #[error("The request timed out.")]
    RequestTimedOut,
    #[error(transparent)]
    Network(#[from] reqwest::Error),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

fn request_failed_message(status: u16, body: &str) -> String {
    if body.is_empty() {
        format!("The Codex rewrite service returned HTTP {status}.")
    } else {
        format!("The Codex rewrite service returned HTTP {status}: {body}")
    }
}

impl AiError {
    fn is_timeout(&self) -> bool {
        match self {
            Self::TimedOut | Self::RequestTimedOut => true,
            Self::Network(error) => error.is_timeout(),
            _ => false,
        }
    }
}

/// Dictation rewrite budgets: until the first text, between text updates, and overall.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RewriteTimeouts {
    pub first_text: Duration,
    pub idle: Duration,
    pub total: Duration,
}

impl Default for RewriteTimeouts {
    fn default() -> Self {
        Self { first_text: Duration::from_secs(30), idle: Duration::from_secs(15), total: Duration::from_secs(120) }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AiTimeouts {
    pub rewrite: RewriteTimeouts,
    pub english_translation: Duration,
    /// Reading a long selection can take much longer than refining a short dictation.
    pub selection_translation: Duration,
    /// Network idle timeouts, like `URLRequest.timeoutInterval`.
    pub request: Duration,
    pub selection_request: Duration,
}

impl Default for AiTimeouts {
    fn default() -> Self {
        Self {
            rewrite: RewriteTimeouts::default(),
            english_translation: Duration::from_secs(10),
            selection_translation: Duration::from_secs(180),
            request: Duration::from_secs(30),
            selection_request: Duration::from_secs(60),
        }
    }
}

struct RewriteDeadline {
    total_deadline: Instant,
    idle_timeout: Duration,
    // (progress deadline, received byte count)
    progress: Mutex<(Instant, usize)>,
}

impl RewriteDeadline {
    fn new(timeouts: RewriteTimeouts) -> Self {
        let start = Instant::now();
        Self {
            total_deadline: start + timeouts.total,
            idle_timeout: timeouts.idle,
            progress: Mutex::new((start + timeouts.first_text, 0)),
        }
    }

    fn record_text(&self, text: &str) {
        let mut progress = self.progress.lock().unwrap_or_else(PoisonError::into_inner);
        if text.len() <= progress.1 {
            return;
        }
        *progress = (Instant::now() + self.idle_timeout, text.len());
    }

    async fn wait_until_expired(&self) {
        loop {
            let now = Instant::now();
            let progress = self.progress.lock().unwrap_or_else(PoisonError::into_inner).0;
            let deadline = self.total_deadline.min(progress);
            if now >= deadline {
                return;
            }
            // First text can shorten the deadline; recheck instead of sleeping until
            // the original first-text deadline. Detection lag is at most 100 ms.
            tokio::time::sleep_until(deadline.min(now + Duration::from_millis(100))).await;
        }
    }
}

async fn within<F: Future>(timeout: Duration, future: F) -> Result<F::Output, AiError> {
    tokio::time::timeout(timeout, future).await.map_err(|_| AiError::RequestTimedOut)
}

fn forward(on_partial: &Option<PartialCallback>, partial: &str) {
    if let Some(on_partial) = on_partial {
        on_partial(partial.to_owned());
    }
}

/// Dropping any returned future cancels its request.
pub struct AiRewriteService {
    pub auth: CodexAuthStore,
    model_resolver: CodexModelResolver,
    client: reqwest::Client,
    endpoint: String,
    timeouts: AiTimeouts,
    last_connection_activity: Mutex<Option<Instant>>,
}

impl AiRewriteService {
    pub fn new(auth: CodexAuthStore) -> Self {
        Self {
            model_resolver: CodexModelResolver::new(auth.codex_home.clone()),
            auth,
            client: reqwest::Client::new(),
            endpoint: CODEX_RESPONSES_URL.to_owned(),
            timeouts: AiTimeouts::default(),
            last_connection_activity: Mutex::new(None),
        }
    }

    pub fn with_timeouts(mut self, timeouts: AiTimeouts) -> Self {
        self.timeouts = timeouts;
        self
    }

    #[cfg(test)]
    fn with_endpoint(mut self, endpoint: &str) -> Self {
        self.endpoint = endpoint.to_owned();
        self.client = reqwest::Client::builder().no_proxy().build().unwrap();
        self
    }

    pub fn has_credentials(&self) -> bool {
        self.auth.has_credentials()
    }

    /// Opens the TLS connection ahead of a likely request so the request can reuse it.
    /// The response status is irrelevant; only the pooled connection matters.
    pub async fn prewarm(&self) {
        {
            let mut last_activity = self.last_connection_activity.lock().unwrap_or_else(PoisonError::into_inner);
            let now = Instant::now();
            if last_activity.is_some_and(|last| now.duration_since(last) < CONNECTION_WARM_WINDOW) {
                return;
            }
            if self.auth.load().is_err() {
                return;
            }
            *last_activity = Some(now);
        }
        let _ = self.client.head(&self.endpoint).timeout(Duration::from_secs(5)).send().await;
    }

    pub async fn rewrite(&self, text: &str, on_partial: Option<PartialCallback>) -> Result<String, AiError> {
        let deadline = RewriteDeadline::new(self.timeouts.rewrite);
        let on_text = |partial: &str| {
            deadline.record_text(partial);
            forward(&on_partial, partial);
        };
        let user_message = rewrite_user_message(text);
        let rewritten = tokio::select! {
            biased;
            result = self.stream_response(
                REWRITE_PROMPT,
                &user_message,
                Some(REWRITE_MODEL),
                Some(REWRITE_REASONING_EFFORT),
                self.timeouts.request,
                &on_text,
            ) => result?,
            () = deadline.wait_until_expired() => return Err(AiError::TimedOut),
        };

        let rewritten = rewritten.trim();
        Ok(if rewritten.is_empty() { text.to_owned() } else { rewritten.to_owned() })
    }

    pub async fn translate_to_english(&self, text: &str, on_partial: Option<PartialCallback>) -> Result<String, AiError> {
        self.translate(text, false, on_partial).await
    }

    pub async fn translate_to_chinese(&self, text: &str, on_partial: Option<PartialCallback>) -> Result<String, AiError> {
        self.translate(text, true, on_partial).await.map_err(|error| {
            if error.is_timeout() { AiError::TranslationTimedOut } else { error }
        })
    }

    pub async fn translate_browser_batch(
        &self,
        items: &[TranslationItem],
        on_partial: Option<PartialCallback>,
    ) -> Result<Vec<TranslationItem>, AiError> {
        validate_browser_batch(items).map_err(|_| AiError::InvalidResponse)?;
        let input = serde_json::to_string(items).map_err(|_| AiError::InvalidResponse)?;
        let on_text = |partial: &str| forward(&on_partial, partial);
        let output = tokio::select! {
            biased;
            result = self.stream_response(
                BROWSER_TRANSLATION_PROMPT,
                &input,
                Some(TRANSLATION_MODEL),
                Some(TRANSLATION_REASONING_EFFORT),
                self.timeouts.selection_request,
                &on_text,
            ) => result?,
            () = tokio::time::sleep(self.timeouts.selection_translation) => return Err(AiError::TranslationTimedOut),
        };
        decode_browser_batch(&output, items).map_err(|_| AiError::InvalidResponse)
    }

    /// Settings check: asks the configured Codex model for `OK`.
    pub async fn test_connection(&self) -> Result<(), AiError> {
        let content = self
            .stream_response("Reply with exactly OK.", "ping", None, None, self.timeouts.request, &|_: &str| {})
            .await?;
        if !content.trim().to_uppercase().contains("OK") {
            return Err(AiError::InvalidResponse);
        }
        Ok(())
    }

    async fn translate(&self, text: &str, to_chinese: bool, on_partial: Option<PartialCallback>) -> Result<String, AiError> {
        let (instructions, timeout, request_timeout) = if to_chinese {
            (CHINESE_TRANSLATION_PROMPT, self.timeouts.selection_translation, self.timeouts.selection_request)
        } else {
            (TRANSLATION_PROMPT, self.timeouts.english_translation, self.timeouts.request)
        };
        let user_message = translation_user_message(text, to_chinese);
        let on_text = |partial: &str| forward(&on_partial, partial);
        let translated = tokio::select! {
            biased;
            result = self.stream_response(
                instructions,
                &user_message,
                Some(TRANSLATION_MODEL),
                Some(TRANSLATION_REASONING_EFFORT),
                request_timeout,
                &on_text,
            ) => result?,
            () = tokio::time::sleep(timeout) => return Err(AiError::TimedOut),
        };

        let translated = translated.trim();
        if translated.is_empty() {
            return Err(AiError::InvalidResponse);
        }
        Ok(translated.to_owned())
    }

    /// Streams one Codex response; `on_partial` receives the accumulated text.
    async fn stream_response(
        &self,
        instructions: &str,
        user_message: &str,
        model: Option<&str>,
        reasoning_effort: Option<&str>,
        request_timeout: Duration,
        on_partial: &(dyn Fn(&str) + Sync),
    ) -> Result<String, AiError> {
        let credentials = self.auth.load()?;
        if credentials.is_expired() {
            return Err(AiError::CodexAuthExpired);
        }
        let resolved_model;
        let model = match model {
            Some(model) => model,
            None => {
                resolved_model = self.model_resolver.resolve_model();
                &resolved_model
            }
        };

        let request = self.codex_request(&credentials, model, reasoning_effort, instructions, user_message);
        let mut response = within(request_timeout, request.send()).await??;
        let status = response.status();
        let mut lines = LineBuffer::default();

        if !status.is_success() {
            let mut body = String::new();
            while let Some(chunk) = within(request_timeout, response.chunk()).await?? {
                lines.push(&chunk).iter().for_each(|line| body.push_str(line));
            }
            body.extend(lines.finish());
            return Err(AiError::RequestFailed(status.as_u16(), body.trim().to_owned()));
        }

        let mut accumulator = CodexResponseStreamAccumulator::default();
        'read: loop {
            let chunk = within(request_timeout, response.chunk()).await??;
            let received = match &chunk {
                Some(chunk) => lines.push(chunk),
                None => lines.finish().into_iter().collect(),
            };
            for line in received {
                if let Some(partial) = accumulator.consume(&line)? {
                    on_partial(&partial);
                }
                // The server can hold the stream open for seconds after the final text.
                if accumulator.is_complete() {
                    break 'read;
                }
            }
            if chunk.is_none() {
                break;
            }
        }
        *self.last_connection_activity.lock().unwrap_or_else(PoisonError::into_inner) = Some(Instant::now());

        if !accumulator.is_complete() {
            return Err(AiError::IncompleteStream);
        }
        Ok(accumulator.into_text())
    }

    fn codex_request(
        &self,
        credentials: &CodexCredentials,
        model: &str,
        reasoning_effort: Option<&str>,
        instructions: &str,
        user_message: &str,
    ) -> reqwest::RequestBuilder {
        let mut request = self
            .client
            .post(&self.endpoint)
            .bearer_auth(&credentials.access_token)
            .header(CONTENT_TYPE, "application/json")
            .header("originator", "codex_cli_rs")
            .header(USER_AGENT, "codex_cli_rs/0.0.0 (NoType)");
        if let Some(account_id) = credentials.account_id.as_deref().filter(|id| !id.is_empty()) {
            request = request.header("ChatGPT-Account-ID", account_id);
        }
        request.json(&CodexResponseRequest::new(model, reasoning_effort, instructions, user_message))
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::time::SystemTime;

    use super::test_support::{MockResponse, MockServer, TempCodexHome};
    use super::*;

    fn delta(text: &str) -> String {
        format!("data: {}", serde_json::json!({"type": "response.output_text.delta", "delta": text}))
    }

    fn event(kind: &str) -> String {
        format!("data: {}", serde_json::json!({"type": kind}))
    }

    /// One delta now, a second one plus `response.completed` 200 ms later.
    fn delayed_translation() -> MockResponse {
        MockResponse::sse([(0, delta("第一段")), (200, delta("第二段")), (200, event("response.completed"))])
    }

    fn service(home: &TempCodexHome, server: &MockServer, timeouts: AiTimeouts) -> AiRewriteService {
        AiRewriteService::new(home.store()).with_endpoint(&server.url).with_timeouts(timeouts)
    }

    fn rewrite_timeouts(first_text: u64, idle: u64, total: u64) -> AiTimeouts {
        AiTimeouts {
            rewrite: RewriteTimeouts {
                first_text: Duration::from_millis(first_text),
                idle: Duration::from_millis(idle),
                total: Duration::from_millis(total),
            },
            ..AiTimeouts::default()
        }
    }

    #[test]
    fn errors_match_swift_descriptions() {
        assert_eq!(
            AiError::MissingCodexAuth.to_string(),
            "Codex OAuth is not configured. Run `codex login` in Terminal first."
        );
        assert_eq!(AiError::RequestFailed(500, String::new()).to_string(), "The Codex rewrite service returned HTTP 500.");
        assert_eq!(
            AiError::RequestFailed(400, "bad".into()).to_string(),
            "The Codex rewrite service returned HTTP 400: bad"
        );
        assert!(AiError::TranslationTimedOut.to_string().contains("翻译超时"));
        assert!(!AiError::TranslationTimedOut.to_string().contains("AI Rewrite"));
        assert_eq!(AiTimeouts::default().selection_request, Duration::from_secs(60));
    }

    #[test]
    fn service_and_futures_can_cross_tasks() {
        fn assert_send<T: Send>(_: &T) {}
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<AiRewriteService>();
        let service = AiRewriteService::new(CodexAuthStore::default());
        assert_send(&service.rewrite("x", None));
        assert_send(&service.translate_to_chinese("x", None));
        assert_send(&service.translate_browser_batch(&[], None));
        assert_send(&service.prewarm());
        assert_send(&service.test_connection());
    }

    #[test]
    fn codex_request_uses_codex_headers_and_streaming_body() {
        let service = AiRewriteService::new(CodexAuthStore::default());
        let credentials = CodexCredentials {
            access_token: "access-token".into(),
            account_id: Some("account-id".into()),
            expires_at: Some(SystemTime::now() + Duration::from_secs(3600)),
        };
        let request = service.codex_request(&credentials, "gpt-test", None, "system", "user").build().unwrap();
        assert_eq!(request.url().as_str(), "https://chatgpt.com/backend-api/codex/responses");
        assert_eq!(request.method(), reqwest::Method::POST);
        let headers = request.headers();
        assert_eq!(headers["authorization"], "Bearer access-token");
        assert!(headers["authorization"].is_sensitive());
        assert_eq!(headers["content-type"], "application/json");
        assert_eq!(headers["originator"], "codex_cli_rs");
        assert_eq!(headers["user-agent"], "codex_cli_rs/0.0.0 (NoType)");
        assert_eq!(headers["chatgpt-account-id"], "account-id");
        let body: serde_json::Value = serde_json::from_slice(request.body().unwrap().as_bytes().unwrap()).unwrap();
        assert_eq!(body["model"], "gpt-test");
        assert_eq!(body["stream"], true);
        assert_eq!(body["store"], false);
        assert!(body.get("reasoning").is_none());

        let no_account = CodexCredentials { account_id: Some(String::new()), ..credentials.clone() };
        let request = service
            .codex_request(&no_account, REWRITE_MODEL, Some(REWRITE_REASONING_EFFORT), "rewrite", "source")
            .build()
            .unwrap();
        assert!(request.headers().get("chatgpt-account-id").is_none());
        let body: serde_json::Value = serde_json::from_slice(request.body().unwrap().as_bytes().unwrap()).unwrap();
        assert_eq!(body["model"], "gpt-5.6-terra");
        assert_eq!(body["reasoning"]["effort"], "high");
        assert_eq!((TRANSLATION_MODEL, TRANSLATION_REASONING_EFFORT), ("gpt-5.6-luna", "none"));
    }

    #[tokio::test]
    async fn rewrite_keeps_waiting_while_text_is_being_produced_and_streams_accumulated_text() {
        let home = TempCodexHome::with_token();
        let server = MockServer::start(|_| delayed_translation()).await;
        let service = service(&home, &server, rewrite_timeouts(100, 1000, 2000));
        let partials = Arc::new(Mutex::new(Vec::new()));
        let sink = partials.clone();
        let callback: PartialCallback = Arc::new(move |partial| sink.lock().unwrap().push(partial));

        let result = service.rewrite("第一段第二段", Some(callback)).await.unwrap();

        assert_eq!(result, "第一段第二段");
        assert_eq!(*partials.lock().unwrap(), vec!["第一段".to_owned(), "第一段第二段".to_owned()]);
        let request = &server.requests()[0];
        assert_eq!(request.header("authorization"), Some("Bearer test-only-token"));
        let body: serde_json::Value = serde_json::from_slice(&request.body).unwrap();
        assert_eq!(body["instructions"], REWRITE_PROMPT);
        assert_eq!(body["input"][0]["content"][0]["text"], rewrite_user_message("第一段第二段"));
    }

    fn scripted_rewrite(scenario: &str) -> MockResponse {
        let delta = delta("段");
        let done = event("response.completed");
        let events: Vec<(u64, String)> = match scenario {
            "waiting" => vec![
                (0, event("response.created")),
                (40, ": keepalive".into()),
                (120, ": keepalive".into()),
                (350, delta),
                (380, done),
            ],
            "stalled" => std::iter::once((0, delta))
                .chain((1..=10).map(|index| (index * 40, event("response.in_progress"))))
                .chain([(450, done)])
                .collect(),
            "slow-first" => vec![(900, delta.clone()), (1200, delta), (1400, done)],
            "progress" => (0..=5).map(|index| (index * 300, delta.clone())).chain([(1600, done)]).collect(),
            _ => (0..=5).map(|index| (index * 60, delta.clone())).chain([(320, done)]).collect(),
        };
        MockResponse::sse(events)
    }

    #[tokio::test]
    async fn rewrite_enforces_first_text_idle_and_total_deadlines() {
        for (scenario, timeouts) in [
            ("waiting", rewrite_timeouts(80, 1000, 2000)),
            ("stalled", rewrite_timeouts(1000, 80, 2000)),
            ("total", rewrite_timeouts(150, 150, 220)),
        ] {
            let home = TempCodexHome::with_token();
            let server = MockServer::start(move |_| scripted_rewrite(scenario)).await;
            let result = service(&home, &server, timeouts).rewrite("原始转写", None).await;
            assert!(matches!(result, Err(AiError::TimedOut)), "{scenario}: {result:?}");
        }
    }

    #[tokio::test]
    async fn rewrite_uses_separate_first_text_and_renewable_idle_budgets() {
        for (scenario, first_text, expected) in [("progress", 750, 6), ("slow-first", 1500, 2)] {
            let home = TempCodexHome::with_token();
            let server = MockServer::start(move |_| scripted_rewrite(scenario)).await;
            let result = service(&home, &server, rewrite_timeouts(first_text, 750, 5000)).rewrite("原始转写", None).await;
            assert_eq!(result.unwrap(), "段".repeat(expected), "{scenario}");
        }
    }

    #[tokio::test]
    async fn rewrite_falls_back_to_the_transcript_when_output_is_blank() {
        let home = TempCodexHome::with_token();
        let server = MockServer::start(|_| MockResponse::sse([(0, delta("  ")), (0, event("response.completed"))])).await;
        let result = service(&home, &server, AiTimeouts::default()).rewrite(" 原始 ", None).await;
        assert_eq!(result.unwrap(), " 原始 ");
    }

    #[tokio::test]
    async fn rewrite_can_be_cancelled_while_waiting_for_more_text() {
        let home = TempCodexHome::with_token();
        let server = MockServer::start(|_| {
            let mut response = MockResponse::sse([(0, delta("第一段"))]);
            response.hold_open = true;
            response
        })
        .await;
        let service = Arc::new(service(&home, &server, AiTimeouts::default()));
        let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
        let callback: PartialCallback = Arc::new(move |partial| {
            let _ = sender.send(partial);
        });
        let task = tokio::spawn({
            let service = service.clone();
            async move { service.rewrite("原始转写", Some(callback)).await }
        });
        assert_eq!(receiver.recv().await.as_deref(), Some("第一段"));
        task.abort();
        assert!(task.await.unwrap_err().is_cancelled());
    }

    #[tokio::test]
    async fn selection_translation_can_outlast_the_english_translation_deadline() {
        let home = TempCodexHome::with_token();
        let server = MockServer::start(|_| delayed_translation()).await;
        let timeouts = AiTimeouts { english_translation: Duration::from_millis(40), ..AiTimeouts::default() };
        let result = service(&home, &server, timeouts)
            .translate_to_chinese(&"Long source text. ".repeat(200), None)
            .await;
        assert_eq!(result.unwrap(), "第一段第二段");
        let body: serde_json::Value = serde_json::from_slice(&server.requests()[0].body).unwrap();
        assert_eq!(body["instructions"], CHINESE_TRANSLATION_PROMPT);
        assert_eq!(body["model"], TRANSLATION_MODEL);
        assert_eq!(body["reasoning"]["effort"], "none");
    }

    #[tokio::test]
    async fn selection_translation_still_enforces_its_own_deadline() {
        let home = TempCodexHome::with_token();
        let server = MockServer::start(|_| delayed_translation()).await;
        let timeouts = AiTimeouts {
            english_translation: Duration::from_secs(1),
            selection_translation: Duration::from_millis(40),
            ..AiTimeouts::default()
        };
        let result = service(&home, &server, timeouts).translate_to_chinese("slow source", None).await;
        assert!(matches!(result, Err(AiError::TranslationTimedOut)), "{result:?}");
    }

    #[tokio::test]
    async fn english_translation_keeps_its_existing_deadline() {
        let home = TempCodexHome::with_token();
        let server = MockServer::start(|_| delayed_translation()).await;
        let timeouts = AiTimeouts { english_translation: Duration::from_millis(40), ..AiTimeouts::default() };
        let result = service(&home, &server, timeouts).translate_to_english("slow source", None).await;
        assert!(matches!(result, Err(AiError::TimedOut)), "{result:?}");
    }

    #[tokio::test]
    async fn selection_translation_network_timeout_uses_chinese_feedback() {
        let home = TempCodexHome::with_token();
        let server = MockServer::start(|_| {
            let mut response = MockResponse::new(200, "text/event-stream");
            response.silent = true;
            response
        })
        .await;
        let timeouts = AiTimeouts { selection_request: Duration::from_millis(50), ..AiTimeouts::default() };
        let result = service(&home, &server, timeouts).translate_to_chinese("source", None).await;
        assert!(matches!(result, Err(AiError::TranslationTimedOut)), "{result:?}");
    }

    #[tokio::test]
    async fn translation_returns_on_final_text_without_waiting_for_stream_close() {
        let home = TempCodexHome::with_token();
        let server = MockServer::start(|_| {
            let mut response = MockResponse::sse([
                (0, delta("Hello")),
                (0, format!("data: {}", serde_json::json!({"type": "response.output_text.done", "text": "Hello"}))),
            ]);
            response.hold_open = true;
            response
        })
        .await;
        let timeouts = AiTimeouts { english_translation: Duration::from_secs(2), ..AiTimeouts::default() };
        let result = service(&home, &server, timeouts).translate_to_english("你好", None).await;
        assert_eq!(result.unwrap(), "Hello");
    }

    #[tokio::test]
    async fn failed_requests_and_truncated_streams_are_reported() {
        let home = TempCodexHome::with_token();
        let server = MockServer::start(|request| {
            if request.body.windows(4).any(|window| window == b"fail") {
                MockResponse::new(429, "application/json").body("{\"error\":\n\"slow down\"}\n")
            } else {
                MockResponse::sse([(0, delta("partial"))])
            }
        })
        .await;
        let service = service(&home, &server, AiTimeouts::default());
        let failed = service.translate_to_english("fail", None).await;
        assert!(
            matches!(&failed, Err(AiError::RequestFailed(429, body)) if body == "{\"error\":\"slow down\"}"),
            "{failed:?}"
        );
        let truncated = service.translate_to_english("ok", None).await;
        assert!(matches!(truncated, Err(AiError::IncompleteStream)), "{truncated:?}");
    }

    #[tokio::test]
    async fn missing_and_expired_login_fail_before_any_request() {
        let server = MockServer::start(|_| delayed_translation()).await;
        let missing = TempCodexHome::new(None);
        let result = service(&missing, &server, AiTimeouts::default()).rewrite("text", None).await;
        assert!(matches!(result, Err(AiError::MissingCodexAuth)));

        let payload = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, r#"{"exp":1}"#);
        let expired = TempCodexHome::new(Some(&format!(r#"{{"tokens":{{"access_token":"header.{payload}.signature"}}}}"#)));
        let result = service(&expired, &server, AiTimeouts::default()).translate_to_english("text", None).await;
        assert!(matches!(result, Err(AiError::CodexAuthExpired)));
        assert!(server.requests().is_empty());
    }

    #[tokio::test]
    async fn connection_prewarm_sends_one_head_request_per_warm_window() {
        let home = TempCodexHome::with_token();
        let server = MockServer::start(|_| MockResponse::new(405, "text/plain")).await;
        let service = service(&home, &server, AiTimeouts::default());
        service.prewarm().await;
        service.prewarm().await;
        let requests = server.requests();
        assert_eq!(requests.iter().filter(|request| request.method == "HEAD").count(), 1);
        assert_eq!(requests[0].header("authorization"), None);

        // No credentials, no prewarm.
        let missing = TempCodexHome::new(None);
        let unauthenticated = AiRewriteService::new(missing.store()).with_endpoint(&server.url);
        unauthenticated.prewarm().await;
        assert_eq!(server.requests().len(), 1);
    }

    #[tokio::test]
    async fn browser_batch_reuses_streaming_channel_and_enforces_deadline() {
        let home = TempCodexHome::with_token();
        let server = MockServer::start(|_| {
            MockResponse::sse([
                (0, delta("{\"id\":\"a\",\"text\":\"第一")),
                (100, delta("段\"}\n{\"id\":\"b\",\"text\":\"第二段\"}")),
                (100, event("response.completed")),
            ])
        })
        .await;
        let items = vec![
            TranslationItem { id: "a".into(), text: "First".into() },
            TranslationItem { id: "b".into(), text: "Second".into() },
        ];
        let result = service(&home, &server, AiTimeouts::default()).translate_browser_batch(&items, None).await;
        let texts: Vec<String> = result.unwrap().into_iter().map(|item| item.text).collect();
        assert_eq!(texts, ["第一段", "第二段"]);
        let body: serde_json::Value = serde_json::from_slice(&server.requests()[0].body).unwrap();
        assert_eq!(body["instructions"], BROWSER_TRANSLATION_PROMPT);
        assert_eq!(body["input"][0]["content"][0]["text"], r#"[{"id":"a","text":"First"},{"id":"b","text":"Second"}]"#);

        let timeouts = AiTimeouts { selection_translation: Duration::from_millis(20), ..AiTimeouts::default() };
        let timed = service(&home, &server, timeouts).translate_browser_batch(&items, None).await;
        assert!(matches!(timed, Err(AiError::TranslationTimedOut)), "{timed:?}");

        let invalid = service(&home, &server, AiTimeouts::default()).translate_browser_batch(&[], None).await;
        assert!(matches!(invalid, Err(AiError::InvalidResponse)));
        assert_eq!(server.requests().len(), 2);
    }

    // Live: uses ~/.codex/auth.json. `cargo test --lib rewrite::tests::live -- --ignored --nocapture`
    #[tokio::test]
    #[ignore]
    async fn live_translate_to_english() {
        let service = AiRewriteService::new(CodexAuthStore::default());
        let started = std::time::Instant::now();
        let translated = service.translate_to_english("你好，世界", None).await.unwrap();
        println!("live translation ({:?}): {translated}", started.elapsed());
        assert!(translated.to_lowercase().contains("hello"));
    }
}
