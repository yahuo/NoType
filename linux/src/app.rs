//! Session state machine, ported from `NoTypeAppModel` on macOS.
//!
//! Every session owns an ID. Work runs in spawned tasks that re-check the ID after each await,
//! so a newer session, a cancel or a failure makes stale work stop without touching the status.
//! The state mutex is never held across an await; lock order is always state, then status.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError, Weak};
use std::time::Duration;

use tokio::sync::{mpsc, watch};
use tokio::task::{AbortHandle, JoinHandle};

use crate::PartialCallback;
use crate::agent_editor::AgentEditorTriggers;
use crate::audio::{CaptureEvent, Recorder};
use crate::bridge::BridgeHooks;
use crate::codex_transcription::CodexTranscriptionService;
use crate::config::{self, Config};
use crate::control::{ControlHandler, ControlRequest};
use crate::doubao::{AsrEvent, DoubaoConfig, DoubaoSession};
use crate::hyprland::{self, ActiveWindow};
use crate::insertion::{self, InsertOutcome};
use crate::rewrite::{AiError, AiRewriteService};
use crate::status::{
    OutputMode, Phase, SelectionSnapshot, SelectionState, SpeechProvider, StatusSnapshot,
};
use crate::transcript;

const COPIED_RESET: Duration = Duration::from_millis(1_800);
const FAILED_RESET: Duration = Duration::from_millis(2_000);
const SELECTION_EMPTY: &str = "未读取到选中文字。请先选中一段文本，再按 Alt + Ctrl + Space。";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum HotkeyAction {
    Start,
    Stop,
    Cancel,
}

/// The dictation and translation hotkeys toggle: start, stop recording, or cancel processing.
/// A second press while a start is still connecting cancels it.
fn hotkey_action(phase: Phase, starting: bool) -> HotkeyAction {
    match phase {
        Phase::Recording => HotkeyAction::Stop,
        Phase::Transcribing | Phase::Refining => HotkeyAction::Cancel,
        _ if starting => HotkeyAction::Cancel,
        _ => HotkeyAction::Start,
    }
}

fn smoothed_level(current: f64, incoming: f64) -> f64 {
    let smoothing = if incoming > current { 0.40 } else { 0.15 };
    current + (incoming - current) * smoothing
}

fn translation_login_message(config: &Config) -> String {
    config.text(
        "翻译需要 Codex 登录态。请先运行 codex login。",
        "Translation requires Codex login. Run codex login first.",
    )
}

fn error_message(error: &anyhow::Error) -> String {
    format!("{error:#}")
}

/// Everything a session decided when it started.
#[derive(Clone)]
struct Plan {
    session: u64,
    mode: OutputMode,
    provider: SpeechProvider,
    rewrite: bool,
    config: Config,
    /// Focused window when the hotkey was pressed; text is pasted only if it still has focus.
    target: Option<ActiveWindow>,
}

struct Capture {
    recorder: Recorder,
    /// Forwards chunks to Doubao in order and feeds the level meter.
    consumer: JoinHandle<()>,
    plan: Plan,
}

#[derive(Default)]
struct State {
    session: u64,
    /// A start is resolving the target, configuration and provider; the phase is not busy yet.
    starting: bool,
    tasks: Vec<AbortHandle>,
    feedback: Option<AbortHandle>,
    capture: Option<Capture>,
    asr: Option<Arc<DoubaoSession>>,
    selection_request: u64,
    selection_task: Option<AbortHandle>,
}

pub struct App {
    me: Weak<App>,
    state: Mutex<State>,
    status: watch::Sender<StatusSnapshot>,
    selection: watch::Sender<SelectionSnapshot>,
    ai: Arc<AiRewriteService>,
    transcription: Arc<CodexTranscriptionService>,
    editor: Arc<AgentEditorTriggers>,
}

impl App {
    pub fn new(
        ai: Arc<AiRewriteService>,
        transcription: Arc<CodexTranscriptionService>,
        editor: Arc<AgentEditorTriggers>,
    ) -> Arc<Self> {
        let provider = Config::load()
            .map(|config| config.speech_provider)
            .unwrap_or_default();
        Arc::new_cyclic(|me| Self {
            me: me.clone(),
            state: Mutex::new(State::default()),
            status: watch::channel(StatusSnapshot {
                provider,
                ..Default::default()
            })
            .0,
            selection: watch::channel(SelectionSnapshot::default()).0,
            ai,
            transcription,
            editor,
        })
    }

    fn arc(&self) -> Arc<Self> {
        self.me
            .upgrade()
            .expect("App is alive while handling commands")
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// A persistent notice shown with every status, such as a bridge that failed to start.
    pub fn set_warning(&self, warning: Option<String>) {
        self.status.send_modify(|status| status.warning = warning);
    }

    pub fn shutdown(&self) {
        self.hide_selection();
        self.cancel();
    }

    // MARK: Commands

    fn hotkey(&self, mode: OutputMode) {
        let action = {
            let state = self.lock();
            hotkey_action(self.status.borrow().phase, state.starting)
        };
        match action {
            HotkeyAction::Start => self.start(mode),
            HotkeyAction::Stop => self.stop(),
            HotkeyAction::Cancel => {
                self.hide_selection();
                self.cancel();
            }
        }
    }

    fn record_start(&self) {
        let idle = {
            let state = self.lock();
            !state.starting && !self.status.borrow().phase.is_busy()
        };
        if idle {
            self.start(OutputMode::Dictation);
        }
    }

    fn start(&self, mode: OutputMode) {
        self.hide_selection();
        let app = self.arc();
        let mut state = self.lock();
        let session = self.begin_session(&mut state);
        state.starting = true;
        let task = tokio::spawn(async move { app.run_start(session, mode).await });
        state.tasks.push(task.abort_handle());
    }

    fn cancel(&self) {
        let mut state = self.lock();
        Self::end_session(&mut state);
        self.status.send_modify(|status| {
            status.phase = Phase::Idle;
            status.mode = OutputMode::Dictation;
            status.transcript.clear();
            status.level = 0.0;
            status.error = None;
        });
    }

    fn stop(&self) {
        let app = self.arc();
        let mut state = self.lock();
        if self.status.borrow().phase != Phase::Recording {
            return;
        }
        let Some(capture) = state.capture.take() else {
            return;
        };
        self.status.send_modify(|status| {
            status.phase = Phase::Transcribing;
            status.level = 0.0;
        });
        let task = tokio::spawn(async move { app.finish_capture(capture).await });
        state.tasks.push(task.abort_handle());
    }

    /// A running session keeps the provider it started with; the next one reads the file again.
    fn reload_config(&self) {
        let Ok(config) = Config::load() else { return };
        let state = self.lock();
        if state.starting || self.status.borrow().phase.is_busy() {
            return;
        }
        self.status.send_if_modified(|status| {
            let changed = status.provider != config.speech_provider;
            status.provider = config.speech_provider;
            changed
        });
    }

    fn agent_translate(&self) {
        let app = self.arc();
        let mut state = self.lock();
        if state.starting || self.status.borrow().phase.is_busy() {
            return;
        }
        let session = self.begin_session(&mut state);
        let task = tokio::spawn(async move { app.run_agent_translate(session).await });
        state.tasks.push(task.abort_handle());
    }

    fn selection_chinese(&self) {
        let app = self.arc();
        let mut state = self.lock();
        if state.starting || self.status.borrow().phase.is_busy() {
            return;
        }
        state.selection_request += 1;
        if let Some(task) = state.selection_task.take() {
            task.abort();
        }
        // Keep the panel hidden during capture so it cannot become the copy target.
        self.selection.send_replace(SelectionSnapshot::default());
        let request = state.selection_request;
        let task = tokio::spawn(async move { app.run_selection_chinese(request).await });
        state.selection_task = Some(task.abort_handle());
    }

    fn hide_selection(&self) {
        let mut state = self.lock();
        state.selection_request += 1;
        if let Some(task) = state.selection_task.take() {
            task.abort();
        }
        self.selection.send_if_modified(|selection| {
            let visible = selection.state != SelectionState::Hidden;
            *selection = SelectionSnapshot::default();
            visible
        });
    }

    fn copy_selection(&self) {
        let selection = self.selection.borrow().clone();
        if selection.state == SelectionState::Done && !selection.translation.is_empty() {
            tokio::spawn(async move {
                if let Err(error) = insertion::copy_text(&selection.translation).await {
                    tracing::warn!("failed to copy the translation: {error:#}");
                }
            });
        }
    }

    // MARK: Session bookkeeping

    /// Invalidates the previous session and clears its preview, like `resetSessionStateForStart`.
    fn begin_session(&self, state: &mut State) -> u64 {
        Self::end_session(state);
        self.status.send_modify(|status| {
            if matches!(
                status.phase,
                Phase::Failed | Phase::Inserted | Phase::CopiedToClipboard
            ) {
                status.phase = Phase::Idle;
            }
            status.transcript.clear();
            status.level = 0.0;
            status.error = None;
        });
        state.session
    }

    fn end_session(state: &mut State) {
        state.session += 1;
        state.starting = false;
        for task in state.tasks.drain(..) {
            task.abort();
        }
        if let Some(task) = state.feedback.take() {
            task.abort();
        }
        if let Some(capture) = state.capture.take() {
            capture.consumer.abort();
            // Dropping the recorder kills pw-record.
            drop(capture.recorder);
        }
        if let Some(asr) = state.asr.take() {
            asr.cancel();
        }
    }

    fn is_current(&self, session: u64) -> bool {
        self.lock().session == session
    }

    /// Applies `update` only while `session` is current.
    fn update(&self, session: u64, update: impl FnOnce(&mut StatusSnapshot)) -> bool {
        let state = self.lock();
        if state.session != session {
            return false;
        }
        self.status.send_modify(update);
        true
    }

    fn fail(&self, session: u64, message: String) {
        let mut state = self.lock();
        if state.session != session {
            return;
        }
        Self::end_session(&mut state);
        self.status.send_modify(|status| {
            status.phase = Phase::Failed;
            status.level = 0.0;
            status.error = Some(message);
        });
        self.schedule_reset(&mut state, FAILED_RESET);
    }

    fn schedule_reset(&self, state: &mut State, delay: Duration) {
        if let Some(task) = state.feedback.take() {
            task.abort();
        }
        let app = self.arc();
        let session = state.session;
        let task = tokio::spawn(async move {
            tokio::time::sleep(delay).await;
            app.update(session, |status| {
                status.phase = Phase::Idle;
                status.transcript.clear();
                status.level = 0.0;
                status.error = None;
            });
        });
        state.feedback = Some(task.abort_handle());
    }

    fn partial_sink(&self, session: u64) -> PartialCallback {
        let app = self.me.clone();
        Arc::new(move |partial: String| {
            if let Some(app) = app.upgrade() {
                app.update(session, |status| status.transcript = partial);
            }
        })
    }

    // MARK: Dictation

    async fn run_start(self: Arc<Self>, session: u64, mode: OutputMode) {
        let target = match hyprland::active_window().await {
            Ok(window) => window,
            Err(error) => {
                tracing::warn!("cannot read the focused window: {error:#}");
                None
            }
        };
        let config = match Config::load() {
            Ok(config) => config,
            Err(error) => return self.fail(session, error_message(&error)),
        };
        if !self.is_current(session) {
            return;
        }

        if mode == OutputMode::Translation
            && let Some(window) = target.as_ref().filter(|window| !window.is_terminal())
        {
            let selected = insertion::selected_text(window)
                .await
                .filter(|text| !text.trim().is_empty());
            if !self.is_current(session) {
                return;
            }
            if let Some(source) = selected {
                if !self.ai.has_credentials() {
                    return self.fail(session, translation_login_message(&config));
                }
                let plan = Plan {
                    session,
                    mode,
                    provider: config.speech_provider,
                    rewrite: false,
                    config,
                    target,
                };
                return self.translate_selection(plan, source).await;
            }
        }

        let doubao = match config.speech_provider {
            SpeechProvider::Codex => {
                if let Err(error) = self.transcription.check_credentials() {
                    return self.fail(session, error.to_string());
                }
                None
            }
            SpeechProvider::Doubao => {
                let token = config::doubao_access_token(&config).await;
                if !config.has_valid_doubao_configuration() || token.is_empty() {
                    return self.fail(
                        session,
                        config.text(
                            "豆包配置不完整。请先填写 App ID、Resource ID 和 Access Token。",
                            "Doubao configuration is incomplete. Fill the App ID, Resource ID, and Access Token first.",
                        ),
                    );
                }
                Some(DoubaoConfig::new(
                    config.doubao.app_id.clone(),
                    token,
                    config.doubao.resource_id.clone(),
                    config.language.clone(),
                ))
            }
        };

        let plan = Plan {
            session,
            mode,
            provider: config.speech_provider,
            rewrite: config.should_rewrite_dictation(),
            config,
            target,
        };
        if plan.mode == OutputMode::Translation || (plan.rewrite && self.ai.has_credentials()) {
            let ai = self.ai.clone();
            tokio::spawn(async move { ai.prewarm().await });
        }

        let asr = match doubao {
            Some(doubao) => {
                let (events, receiver) = mpsc::unbounded_channel();
                let asr = match DoubaoSession::start(doubao, events).await {
                    Ok(asr) => Arc::new(asr),
                    Err(error) => return self.fail(session, error_message(&error)),
                };
                let app = self.clone();
                let pump_plan = plan.clone();
                let pump =
                    tokio::spawn(async move { app.pump_asr_events(receiver, pump_plan).await });
                let mut state = self.lock();
                if state.session != session {
                    asr.cancel();
                    pump.abort();
                    return;
                }
                state.tasks.push(pump.abort_handle());
                state.asr = Some(asr.clone());
                Some(asr)
            }
            None => None,
        };

        let (events, receiver) = mpsc::unbounded_channel();
        let recorder = match Recorder::start(events) {
            Ok(recorder) => recorder,
            Err(error) => return self.fail(session, error_message(&error)),
        };
        let app = self.clone();
        let consumer =
            tokio::spawn(async move { app.consume_capture(receiver, asr, session).await });

        let mut state = self.lock();
        if state.session != session {
            consumer.abort();
            return;
        }
        state.starting = false;
        let (mode, provider) = (plan.mode, plan.provider);
        state.capture = Some(Capture {
            recorder,
            consumer,
            plan,
        });
        self.status.send_modify(|status| {
            status.phase = Phase::Recording;
            status.mode = mode;
            status.provider = provider;
            status.transcript.clear();
            status.level = 0.0;
            status.error = None;
        });
    }

    async fn consume_capture(
        self: Arc<Self>,
        mut events: mpsc::UnboundedReceiver<CaptureEvent>,
        asr: Option<Arc<DoubaoSession>>,
        session: u64,
    ) {
        while let Some(event) = events.recv().await {
            match event {
                CaptureEvent::Chunk(chunk) => {
                    if let Some(asr) = &asr
                        && let Err(error) = asr.send_audio(chunk, false).await
                    {
                        return self.fail(session, error_message(&error));
                    }
                }
                CaptureEvent::Level(level) => {
                    self.update(session, |status| {
                        if status.phase == Phase::Recording {
                            status.level = smoothed_level(status.level, level);
                        }
                    });
                }
                CaptureEvent::Failed(message) => return self.fail(session, message),
            }
        }
    }

    async fn pump_asr_events(
        self: Arc<Self>,
        mut events: mpsc::UnboundedReceiver<AsrEvent>,
        plan: Plan,
    ) {
        while let Some(event) = events.recv().await {
            match event {
                AsrEvent::Partial(text) => {
                    let current = self.update(plan.session, |status| {
                        status.transcript = text;
                        if status.phase != Phase::Recording {
                            status.phase = Phase::Transcribing;
                        }
                    });
                    if !current {
                        return;
                    }
                }
                AsrEvent::Final(text) => return self.complete(&plan, text).await,
                AsrEvent::Error(message) => return self.fail(plan.session, message),
            }
        }
    }

    async fn finish_capture(self: Arc<Self>, capture: Capture) {
        let Capture {
            recorder,
            consumer,
            plan,
        } = capture;
        let session = plan.session;
        let recording = recorder.stop().await;
        // Every chunk captured before the stop reaches Doubao before the remainder.
        let _ = consumer.await;
        if !self.is_current(session) {
            return;
        }
        let recording = match recording {
            Ok(recording) => recording,
            Err(error) => return self.fail(session, error_message(&error)),
        };

        match plan.provider {
            SpeechProvider::Codex => {
                if recording.pcm.is_empty() {
                    return self.fail(
                        session,
                        plan.config
                            .text("没有检测到有效语音。", "No speech was detected."),
                    );
                }
                let transcript = self.transcription.transcribe(recording.pcm).await;
                if !self.is_current(session) {
                    return;
                }
                match transcript {
                    Ok(transcript) => self.complete(&plan, transcript).await,
                    Err(error) => self.fail(session, error_message(&error)),
                }
            }
            SpeechProvider::Doubao => {
                let Some(asr) = self.lock().asr.clone() else {
                    return;
                };
                let mut result = Ok(());
                if !recording.remainder.is_empty() {
                    result = asr.send_audio(recording.remainder, false).await;
                }
                if result.is_ok() {
                    result = asr.finish().await;
                }
                // The final transcript arrives through `pump_asr_events`.
                if let Err(error) = result {
                    self.fail(session, error_message(&error));
                }
            }
        }
    }

    /// `completeSession`: normalize, then translate or rewrite, then paste.
    async fn complete(&self, plan: &Plan, transcript: String) {
        let session = plan.session;
        let normalized = match plan.provider {
            SpeechProvider::Codex => transcript.trim().to_owned(),
            SpeechProvider::Doubao => transcript::normalize(&transcript),
        };
        {
            let mut state = self.lock();
            if state.session != session {
                return;
            }
            if let Some(asr) = state.asr.take() {
                asr.cancel();
            }
            self.status.send_modify(|status| {
                status.level = 0.0;
                status.transcript = normalized.clone();
            });
        }
        if normalized.trim().is_empty() {
            return self.fail(
                session,
                plan.config
                    .text("没有检测到有效语音。", "No speech was detected."),
            );
        }

        let mut final_text = normalized.clone();
        if plan.mode == OutputMode::Translation {
            if !self.ai.has_credentials() {
                return self.fail(session, translation_login_message(&plan.config));
            }
            self.update(session, |status| status.phase = Phase::Refining);
            let translated = self
                .ai
                .translate_to_english(&normalized, Some(self.partial_sink(session)))
                .await;
            if !self.is_current(session) {
                return;
            }
            match translated {
                Ok(translated) => final_text = translated,
                Err(error) => return self.fail(session, error.to_string()),
            }
        } else if plan.rewrite && self.ai.has_credentials() {
            self.update(session, |status| status.phase = Phase::Refining);
            let rewritten = self
                .ai
                .rewrite(&normalized, Some(self.partial_sink(session)))
                .await;
            if !self.is_current(session) {
                return;
            }
            match rewritten {
                Ok(rewritten) => final_text = rewritten,
                Err(error) => {
                    tracing::warn!("AI rewrite failed: {error}");
                    self.update(session, |status| {
                        status.transcript = normalized.clone();
                        status.error = Some(plan.config.text(
                            "AI 改写失败，已继续使用原始转写结果。",
                            "AI Rewrite failed. Using the raw transcript instead.",
                        ));
                    });
                }
            }
        }

        let empty = plan.config.text(
            "最终转写为空，未执行文本注入。",
            "The final transcript was empty, so nothing was pasted.",
        );
        self.insert_final(plan, final_text, empty).await;
    }

    /// Translation hotkey with a selection: replace it with English.
    async fn translate_selection(&self, plan: Plan, source: String) {
        let session = plan.session;
        {
            let mut state = self.lock();
            if state.session != session {
                return;
            }
            state.starting = false;
            self.status.send_modify(|status| {
                status.phase = Phase::Refining;
                status.mode = OutputMode::Translation;
                status.transcript = source.clone();
                status.level = 0.0;
                status.error = None;
            });
        }
        let translated = self
            .ai
            .translate_to_english(&source, Some(self.partial_sink(session)))
            .await;
        if !self.is_current(session) {
            return;
        }
        match translated {
            Ok(translated) => {
                let empty = plan.config.text(
                    "翻译结果为空，未执行文本注入。",
                    "The translation was empty, so nothing was pasted.",
                );
                self.insert_final(&plan, translated, empty).await;
            }
            Err(error) => self.fail(session, error.to_string()),
        }
    }

    async fn insert_final(&self, plan: &Plan, text: String, empty_message: String) {
        let session = plan.session;
        if !self.is_current(session) {
            return;
        }
        let outcome = insertion::insert(&text, plan.target.as_ref()).await;
        let mut state = self.lock();
        if state.session != session {
            return;
        }
        match outcome {
            Ok(InsertOutcome::Pasted) => {
                if let Some(task) = state.feedback.take() {
                    task.abort();
                }
                self.status.send_modify(|status| {
                    status.phase = Phase::Idle;
                    status.transcript = text;
                    status.level = 0.0;
                    status.error = None;
                });
            }
            Ok(InsertOutcome::CopiedToClipboard) => {
                self.status.send_modify(|status| {
                    status.phase = Phase::CopiedToClipboard;
                    status.transcript = text;
                    status.error = None;
                });
                self.schedule_reset(&mut state, COPIED_RESET);
            }
            Ok(InsertOutcome::Skipped) => {
                drop(state);
                self.fail(session, empty_message);
            }
            Err(error) => {
                drop(state);
                self.fail(session, error_message(&error));
            }
        }
    }

    // MARK: Agent editor and selection panel

    async fn run_agent_translate(self: Arc<Self>, session: u64) {
        let config = match Config::load() {
            Ok(config) => config,
            Err(error) => return self.fail(session, error_message(&error)),
        };
        if !self.ai.has_credentials() {
            return self.fail(session, translation_login_message(&config));
        }
        let window = match hyprland::active_window().await {
            Ok(Some(window)) if window.is_terminal() => window,
            Ok(_) => {
                return self.fail(
                    session,
                    config.text(
                        "请先聚焦运行 Pi、Claude Code 或 Codex 的终端窗口。",
                        "Focus a terminal running Pi, Claude Code, or Codex first.",
                    ),
                );
            }
            Err(error) => return self.fail(session, error_message(&error)),
        };
        if !self.is_current(session) {
            return;
        }
        if let Err(error) = self.editor.trigger(&window).await {
            self.fail(session, error_message(&error));
        }
    }

    async fn run_selection_chinese(self: Arc<Self>, request: u64) {
        let window = hyprland::active_window().await.ok().flatten();
        let source = match &window {
            Some(window) => insertion::selected_text(window).await.unwrap_or_default(),
            None => String::new(),
        };
        let current = |app: &Self| app.lock().selection_request == request;
        if !current(&self) {
            return;
        }
        if source.trim().is_empty() {
            self.selection.send_replace(SelectionSnapshot {
                state: SelectionState::Failed,
                source,
                translation: String::new(),
                error: Some(SELECTION_EMPTY.into()),
            });
            return;
        }
        self.selection.send_replace(SelectionSnapshot {
            state: SelectionState::Translating,
            source: source.clone(),
            translation: String::new(),
            error: None,
        });

        let app = self.me.clone();
        let on_partial: PartialCallback = Arc::new(move |partial: String| {
            let Some(app) = app.upgrade() else { return };
            let state = app.lock();
            if state.selection_request == request {
                app.selection.send_modify(|selection| {
                    if selection.state == SelectionState::Translating {
                        selection.translation = partial;
                    }
                });
            }
        });
        let result = self
            .ai
            .translate_to_chinese(&source, Some(on_partial))
            .await;

        let state = self.lock();
        if state.selection_request != request {
            return;
        }
        let snapshot = match result {
            Ok(translation) if !translation.trim().is_empty() => SelectionSnapshot {
                state: SelectionState::Done,
                source,
                translation: translation.trim().to_owned(),
                error: None,
            },
            Ok(_) => SelectionSnapshot {
                state: SelectionState::Failed,
                source,
                translation: String::new(),
                error: Some(AiError::InvalidResponse.to_string()),
            },
            Err(error) => SelectionSnapshot {
                state: SelectionState::Failed,
                source,
                translation: String::new(),
                error: Some(error.to_string()),
            },
        };
        self.selection.send_replace(snapshot);
    }
}

impl BridgeHooks for App {
    fn dictation_busy(&self) -> bool {
        let state = self.lock();
        state.starting || self.status.borrow().phase.is_busy()
    }
}

impl ControlHandler for App {
    fn handle(&self, request: ControlRequest) -> Result<(), String> {
        match request {
            ControlRequest::Ping | ControlRequest::Status { .. } => {}
            ControlRequest::RecordToggle => self.hotkey(OutputMode::Dictation),
            ControlRequest::RecordStart => self.record_start(),
            ControlRequest::RecordStop => self.stop(),
            ControlRequest::Translate => self.hotkey(OutputMode::Translation),
            ControlRequest::Cancel => {
                self.hide_selection();
                self.cancel();
            }
            ControlRequest::AgentTranslate => self.agent_translate(),
            ControlRequest::SelectionChinese => self.selection_chinese(),
            ControlRequest::SelectionHide => self.hide_selection(),
            ControlRequest::SelectionCopy => self.copy_selection(),
            ControlRequest::ReloadConfig => self.reload_config(),
        }
        Ok(())
    }

    fn status(&self) -> watch::Receiver<StatusSnapshot> {
        self.status.subscribe()
    }

    fn selection(&self) -> watch::Receiver<SelectionSnapshot> {
        self.selection.subscribe()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hotkey_toggles_like_macos() {
        assert_eq!(hotkey_action(Phase::Idle, false), HotkeyAction::Start);
        assert_eq!(hotkey_action(Phase::Failed, false), HotkeyAction::Start);
        assert_eq!(
            hotkey_action(Phase::CopiedToClipboard, false),
            HotkeyAction::Start
        );
        assert_eq!(hotkey_action(Phase::Recording, false), HotkeyAction::Stop);
        assert_eq!(
            hotkey_action(Phase::Transcribing, false),
            HotkeyAction::Cancel
        );
        assert_eq!(hotkey_action(Phase::Refining, false), HotkeyAction::Cancel);
        assert_eq!(hotkey_action(Phase::Idle, true), HotkeyAction::Cancel);
    }

    #[test]
    fn level_rises_faster_than_it_falls() {
        assert!((smoothed_level(0.0, 1.0) - 0.40).abs() < 1e-9);
        assert!((smoothed_level(1.0, 0.0) - 0.85).abs() < 1e-9);
    }
}
