//! Codex dictation upload (`/backend-api/transcribe`). Port of CodexTranscriptionService.swift.

use std::time::Duration;

use flacenc::component::BitRepr as _;
use flacenc::error::Verify as _;
use reqwest::header::{ACCEPT, CONTENT_TYPE, HeaderMap, USER_AGENT};
use serde::Deserialize;
use tokio::time::Instant;

use crate::codex_auth::{CodexAuthStore, CodexCredentials};
use crate::rewrite::AiError;

pub const TRANSCRIBE_URL: &str = "https://chatgpt.com/backend-api/transcribe";
const SAMPLE_RATE: u32 = 16_000;
const CHANNEL_COUNT: u16 = 1;
const BITS_PER_SAMPLE: u16 = 16;
/// Idle limit like `URLRequest.timeoutInterval`: time to the response headers and between body reads.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(60);
const RESOURCE_TIMEOUT: Duration = Duration::from_secs(120);
const MAX_PCM_BYTES: usize = u32::MAX as usize - 36;

#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
pub enum TranscriptionError {
    #[error("没有检测到有效语音。")]
    NoSpeech,
    #[error("录音数据不完整，无法转写。")]
    InvalidAudio,
    #[error("Codex 语音转写返回了无效结果。")]
    InvalidResponse,
    #[error("{}", request_failed_message(*.0))]
    RequestFailed(u16),
}

fn request_failed_message(status: u16) -> String {
    match status {
        401 => "Codex 登录已失效。请打开 Codex 刷新登录后重试。".to_owned(),
        403 => "Codex 语音转写请求被拒绝（HTTP 403）。请稍后重试；若持续出现，请检查 Codex 登录和网络。".to_owned(),
        429 => "Codex 语音转写已限流，请稍后重试。".to_owned(),
        status => format!("Codex 语音转写失败（HTTP {status}）。"),
    }
}

#[derive(Deserialize)]
struct TranscriptionResponse {
    text: String,
}

/// Dropping the `transcribe` future cancels the upload.
pub struct CodexTranscriptionService {
    pub auth: CodexAuthStore,
    client: reqwest::Client,
    endpoint: String,
}

fn client_builder() -> reqwest::ClientBuilder {
    // Never follow a redirect with the bearer token attached.
    reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .read_timeout(REQUEST_TIMEOUT)
        .timeout(RESOURCE_TIMEOUT)
}

impl CodexTranscriptionService {
    pub fn new(auth: CodexAuthStore) -> Self {
        Self {
            auth,
            client: client_builder().build().expect("HTTP client configuration is valid"),
            endpoint: TRANSCRIBE_URL.to_owned(),
        }
    }

    #[cfg(test)]
    fn with_endpoint(mut self, endpoint: &str) -> Self {
        self.endpoint = endpoint.to_owned();
        self.client = client_builder().no_proxy().build().unwrap();
        self
    }

    pub fn check_credentials(&self) -> Result<(), AiError> {
        self.current_credentials().map(|_| ())
    }

    pub fn current_credentials(&self) -> Result<CodexCredentials, AiError> {
        let credentials = self.auth.load()?;
        if credentials.is_expired() {
            return Err(AiError::CodexAuthExpired);
        }
        Ok(credentials)
    }

    /// `pcm` is 16 kHz mono signed 16-bit little-endian audio.
    pub async fn transcribe(&self, pcm: Vec<u8>) -> anyhow::Result<String> {
        let mut operation = Operation::start(pcm.len());
        let result = self.upload(pcm, &operation).await;
        match &result {
            Ok(text) => operation.finish("success", &format!(" characters={}", text.chars().count())),
            Err(error) => operation.finish(&failure_category(error), ""),
        }
        result
    }

    async fn upload(&self, pcm: Vec<u8>, operation: &Operation) -> anyhow::Result<String> {
        let credentials = self.current_credentials()?;
        let boundary = format!("----notype-{}", uuid::Uuid::new_v4().to_string().to_uppercase());
        let multipart_boundary = boundary.clone();
        let body = tokio::task::spawn_blocking(move || multipart_body(&pcm, &multipart_boundary, true)).await??;
        operation.record(
            "audio_prepared",
            &format!("body_bytes={} elapsed_ms={}", body.len(), operation.elapsed_ms()),
        );

        let response = self.request(&credentials, &boundary, body).send().await?;
        let status = response.status();
        let headers = response.headers().clone();
        let data = response.bytes().await?;
        operation.record("http_response", &response_summary(status.as_u16(), &headers, data.len()));
        if !status.is_success() {
            return Err(TranscriptionError::RequestFailed(status.as_u16()).into());
        }
        let result: TranscriptionResponse =
            serde_json::from_slice(&data).map_err(|_| TranscriptionError::InvalidResponse)?;
        let text = result.text.trim();
        if text.is_empty() {
            return Err(TranscriptionError::NoSpeech.into());
        }
        Ok(text.to_owned())
    }

    fn request(&self, credentials: &CodexCredentials, boundary: &str, body: Vec<u8>) -> reqwest::RequestBuilder {
        let mut request = self.client.post(&self.endpoint).bearer_auth(&credentials.access_token);
        if let Some(account_id) = &credentials.account_id {
            request = request.header("ChatGPT-Account-Id", account_id);
        }
        request
            .header("originator", "Codex Desktop")
            .header(USER_AGENT, "NoType/0.1")
            .header(CONTENT_TYPE, format!("multipart/form-data; boundary={boundary}"))
            .header(ACCEPT, "application/json")
            .body(body)
    }
}

fn validate_pcm(pcm: &[u8]) -> Result<(), TranscriptionError> {
    if pcm.is_empty() {
        return Err(TranscriptionError::NoSpeech);
    }
    if !pcm.len().is_multiple_of(2) || pcm.len() > MAX_PCM_BYTES {
        return Err(TranscriptionError::InvalidAudio);
    }
    Ok(())
}

/// The upload body: one `file` part holding WAV, or FLAC when that is smaller.
pub fn multipart_body(pcm: &[u8], boundary: &str, compress: bool) -> Result<Vec<u8>, TranscriptionError> {
    validate_pcm(pcm)?;
    let wav = wav_bytes(pcm);
    let (audio, format) = match compress.then(|| compress_pcm(pcm).ok()).flatten() {
        Some(flac) if flac.len() < wav.len() => (flac, "flac"),
        _ => (wav, "wav"),
    };

    let mut body = format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.{format}\"\r\nContent-Type: audio/{format}\r\n\r\n"
    )
    .into_bytes();
    body.extend_from_slice(&audio);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    Ok(body)
}

fn wav_bytes(pcm: &[u8]) -> Vec<u8> {
    let block_alignment = CHANNEL_COUNT * BITS_PER_SAMPLE / 8;
    let mut wav = Vec::with_capacity(44 + pcm.len());
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + pcm.len() as u32).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes()); // Linear PCM
    wav.extend_from_slice(&CHANNEL_COUNT.to_le_bytes());
    wav.extend_from_slice(&SAMPLE_RATE.to_le_bytes());
    wav.extend_from_slice(&(SAMPLE_RATE * u32::from(block_alignment)).to_le_bytes());
    wav.extend_from_slice(&block_alignment.to_le_bytes());
    wav.extend_from_slice(&BITS_PER_SAMPLE.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&(pcm.len() as u32).to_le_bytes());
    wav.extend_from_slice(pcm);
    wav
}

/// Lossless FLAC encoding of the PCM (pure Rust, `flacenc`).
pub fn compress_pcm(pcm: &[u8]) -> Result<Vec<u8>, TranscriptionError> {
    validate_pcm(pcm).map_err(|_| TranscriptionError::InvalidAudio)?;
    let samples: Vec<i32> =
        pcm.as_chunks::<2>().0.iter().map(|&sample| i32::from(i16::from_le_bytes(sample))).collect();
    let config = flacenc::config::Encoder::default().into_verified().map_err(|_| TranscriptionError::InvalidAudio)?;
    let source = flacenc::source::MemSource::from_samples(
        &samples,
        usize::from(CHANNEL_COUNT),
        usize::from(BITS_PER_SAMPLE),
        SAMPLE_RATE as usize,
    );
    let stream = flacenc::encode_with_fixed_block_size(&config, source, config.block_size)
        .map_err(|_| TranscriptionError::InvalidAudio)?;
    let mut sink = flacenc::bitsink::ByteSink::new();
    stream.write(&mut sink).map_err(|_| TranscriptionError::InvalidAudio)?;
    Ok(sink.into_inner())
}

/// One upload's diagnostics. Logs `outcome=cancelled` if dropped before finishing.
struct Operation {
    id: String,
    started: Instant,
    finished: bool,
}

impl Operation {
    fn start(pcm_bytes: usize) -> Self {
        let operation = Self { id: uuid::Uuid::new_v4().to_string().to_uppercase(), started: Instant::now(), finished: false };
        operation.record("request_start", &format!("pcm_bytes={pcm_bytes} audio_ms={}", pcm_bytes * 1000 / 32000));
        operation
    }

    fn record(&self, event: &str, fields: &str) {
        tracing::info!(target: "notype::codex_dictation", "{event} operation={} {fields}", self.id);
    }

    fn elapsed_ms(&self) -> u128 {
        self.started.elapsed().as_millis()
    }

    fn finish(&mut self, outcome: &str, extra: &str) {
        self.finished = true;
        self.record("request_end", &format!("outcome={outcome} elapsed_ms={}{extra}", self.elapsed_ms()));
    }
}

impl Drop for Operation {
    fn drop(&mut self) {
        if !self.finished {
            self.finish("cancelled", "");
        }
    }
}

/// A header value safe to log, or `none` / `invalid`.
pub fn safe_identifier(value: Option<&str>) -> String {
    let Some(value) = value else { return "none".to_owned() };
    let allowed = |c: char| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | ':');
    if value.is_empty() || value.len() > 128 || !value.chars().all(allowed) {
        return "invalid".to_owned();
    }
    value.to_owned()
}

/// Response metadata that is safe to log: no cookies, tokens or body.
pub fn response_summary(status: u16, headers: &HeaderMap, byte_count: usize) -> String {
    let header = |name: &str| headers.get(name).map(|value| String::from_utf8_lossy(value.as_bytes()).into_owned());
    let mime_type = header("content-type").map(|value| value.split(';').next().unwrap_or_default().trim().to_lowercase());
    let format = match mime_type.as_deref() {
        Some("application/json") => "json",
        Some("text/html") => "html",
        _ => "other",
    };
    let request_id = safe_identifier(header("x-request-id").as_deref());
    let ray = safe_identifier(header("cf-ray").as_deref());
    let challenge = header("cf-mitigated").as_deref() == Some("challenge");
    format!(
        "status={status} response_bytes={byte_count} format={format} request_id={request_id} cf_ray={ray} challenge={challenge}"
    )
}

fn failure_category(error: &anyhow::Error) -> String {
    if let Some(error) = error.downcast_ref::<TranscriptionError>() {
        return match error {
            TranscriptionError::RequestFailed(status) => format!("http_{status}"),
            TranscriptionError::NoSpeech => "no_speech".to_owned(),
            TranscriptionError::InvalidAudio => "invalid_audio".to_owned(),
            TranscriptionError::InvalidResponse => "invalid_response".to_owned(),
        };
    }
    if let Some(error) = error.downcast_ref::<reqwest::Error>() {
        let kind = if error.is_timeout() {
            "timeout"
        } else if error.is_connect() {
            "connect"
        } else if error.is_body() || error.is_decode() {
            "body"
        } else {
            "request"
        };
        return format!("network_{kind}");
    }
    match error.downcast_ref::<AiError>() {
        Some(AiError::Io(_)) | None => "local_error".to_owned(),
        Some(_) => "authentication".to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use reqwest::header::HeaderValue;

    use super::*;
    use crate::rewrite::test_support::{MockResponse, MockServer, TempCodexHome};

    fn credentials(account_id: Option<&str>) -> CodexCredentials {
        CodexCredentials { access_token: "test-token".into(), account_id: account_id.map(str::to_owned), expires_at: None }
    }

    fn sine_pcm() -> Vec<u8> {
        (0..16000).flat_map(|index| ((((index as f64) * 0.04).sin() * 12000.0) as i16).to_le_bytes()).collect()
    }

    fn file_part(body: &[u8]) -> &[u8] {
        let start = body.windows(4).position(|window| window == b"\r\n\r\n").unwrap() + 4;
        &body[start..]
    }

    #[test]
    fn uploads_complete_pcm_as_wav_using_only_codex_auth() {
        let pcm = [0x01, 0x02, 0xFF, 0x7F];
        let service = CodexTranscriptionService::new(CodexAuthStore::default());
        let body = multipart_body(&pcm, "test-boundary", false).unwrap();
        let request = service.request(&credentials(Some("test-account")), "test-boundary", body).build().unwrap();
        assert_eq!(request.url().as_str(), "https://chatgpt.com/backend-api/transcribe");
        assert_eq!(request.method(), reqwest::Method::POST);
        let headers = request.headers();
        assert_eq!(headers["authorization"], "Bearer test-token");
        assert!(headers["authorization"].is_sensitive());
        assert_eq!(headers["chatgpt-account-id"], "test-account");
        assert_eq!(headers["originator"], "Codex Desktop");
        assert_eq!(headers["user-agent"], "NoType/0.1");
        assert_eq!(headers["content-type"], "multipart/form-data; boundary=test-boundary");
        assert_eq!(headers["accept"], "application/json");

        let body = request.body().unwrap().as_bytes().unwrap();
        assert!(body.starts_with(b"--test-boundary\r\n"));
        let wav = &file_part(body)[..44 + pcm.len()];
        assert_eq!(&wav[..4], b"RIFF");
        assert_eq!(wav[4..8], [40, 0, 0, 0]);
        assert_eq!(&wav[8..16], b"WAVEfmt ");
        assert_eq!(wav[20..24], [1, 0, 1, 0]); // PCM, mono
        assert_eq!(wav[24..28], [0x80, 0x3E, 0, 0]); // 16 kHz
        assert_eq!(wav[32..36], [2, 0, 16, 0]); // block alignment, bit depth
        assert_eq!(wav[40..44], [4, 0, 0, 0]);
        assert_eq!(wav[44..], pcm);
        assert!(body.ends_with(b"\r\n--test-boundary--\r\n"));
        assert!(!String::from_utf8_lossy(body).contains("name=\"model\""));

        let request = service.request(&credentials(None), "b", Vec::new()).build().unwrap();
        assert!(request.headers().get("chatgpt-account-id").is_none());
    }

    #[test]
    fn rejects_empty_or_truncated_audio() {
        assert_eq!(multipart_body(&[], "b", true), Err(TranscriptionError::NoSpeech));
        assert_eq!(multipart_body(&[1], "b", true), Err(TranscriptionError::InvalidAudio));
        assert_eq!(compress_pcm(&[]), Err(TranscriptionError::InvalidAudio));
    }

    #[test]
    fn flac_compression_preserves_every_sample_and_uses_the_right_multipart_type() {
        let pcm = sine_pcm();
        let compressed = compress_pcm(&pcm).unwrap();
        assert!(compressed.len() < pcm.len());
        assert_eq!(&compressed[..4], b"fLaC");
        let body = multipart_body(&pcm, "b", true).unwrap();
        let head = String::from_utf8_lossy(&body[..200]);
        assert!(head.contains("filename=\"dictation.flac\""));
        assert!(head.contains("Content-Type: audio/flac"));
        assert_eq!(&file_part(&body)[..compressed.len()], compressed);

        // Decoding needs an external tool; skipped where neither is installed.
        let directory = std::env::temp_dir().join(format!("notype-flac-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&directory).unwrap();
        let (flac, decoded) = (directory.join("in.flac"), directory.join("out.raw"));
        std::fs::write(&flac, &compressed).unwrap();
        let decoders: [(&str, Vec<&std::ffi::OsStr>); 2] = [
            ("flac", vec!["-d".as_ref(), "-s".as_ref(), "-f".as_ref(), "--force-raw-format".as_ref(),
                "--endian=little".as_ref(), "--sign=signed".as_ref(), "-o".as_ref(), decoded.as_os_str(), flac.as_os_str()]),
            ("ffmpeg", vec!["-v".as_ref(), "error".as_ref(), "-y".as_ref(), "-i".as_ref(), flac.as_os_str(),
                "-f".as_ref(), "s16le".as_ref(), decoded.as_os_str()]),
        ];
        let decoded_pcm = decoders.iter().find_map(|(tool, args)| {
            let status = std::process::Command::new(tool).args(args).output().ok()?.status;
            status.success().then(|| std::fs::read(&decoded).unwrap())
        });
        std::fs::remove_dir_all(&directory).ok();
        match decoded_pcm {
            Some(decoded_pcm) => assert!(decoded_pcm == pcm, "FLAC round trip changed the audio"),
            None => eprintln!("no FLAC decoder installed; round trip not checked"),
        }
    }

    #[test]
    fn diagnostics_keep_only_safe_response_metadata() {
        let mut headers = HeaderMap::new();
        for (name, value) in [
            ("content-type", "text/html; charset=utf-8"),
            ("x-request-id", "req-123"),
            ("cf-ray", "123abc-SJC"),
            ("cf-mitigated", "challenge"),
            ("set-cookie", "secret-cookie"),
            ("authorization", "secret-token"),
        ] {
            headers.insert(name, HeaderValue::from_static(value));
        }
        let summary = response_summary(403, &headers, 66021);
        assert_eq!(
            summary,
            "status=403 response_bytes=66021 format=html request_id=req-123 cf_ray=123abc-SJC challenge=true"
        );
        assert_eq!(safe_identifier(Some("id\ninjected=true")), "invalid");
        assert_eq!(safe_identifier(Some(&"x".repeat(200))), "invalid");
        assert_eq!(safe_identifier(Some("")), "invalid");
        assert_eq!(safe_identifier(None), "none");
        assert!(!TranscriptionError::RequestFailed(403).to_string().contains("账号无法"));
        assert_eq!(TranscriptionError::RequestFailed(502).to_string(), "Codex 语音转写失败（HTTP 502）。");
        assert_eq!(response_summary(200, &HeaderMap::new(), 0).split(' ').nth(2), Some("format=other"));
    }

    async fn transcribe(scenario: &'static str) -> (anyhow::Result<String>, MockServer) {
        let home = TempCodexHome::with_token();
        let server = MockServer::start(move |_| {
            let status = scenario.parse().unwrap_or(200);
            let body = match scenario {
                "empty" => r#"{"text":"  "}"#,
                "invalid" => r#"{"other":"value"}"#,
                _ => "{\"text\":\"  嗯，五秒，不对，十秒。\\n不要修改翻译。  \"}",
            };
            MockResponse::new(status, "application/json").body(body)
        })
        .await;
        let service = CodexTranscriptionService::new(home.store()).with_endpoint(&server.url);
        let result = service.transcribe(vec![0, 0]).await;
        // Tiny audio is smaller as WAV than as FLAC.
        assert!(String::from_utf8_lossy(&server.requests()[0].body).contains("filename=\"dictation.wav\""));
        (result, server)
    }

    #[tokio::test]
    async fn preserves_text_without_rewriting_it() {
        let (result, server) = transcribe("success").await;
        assert_eq!(result.unwrap(), "嗯，五秒，不对，十秒。\n不要修改翻译。");
        let request = &server.requests()[0];
        assert_eq!((request.method.as_str(), request.path.as_str()), ("POST", "/"));
        assert_eq!(request.header("authorization"), Some("Bearer test-only-token"));
        assert_eq!(request.header("chatgpt-account-id"), None);
        let boundary = request.header("content-type").unwrap().strip_prefix("multipart/form-data; boundary=").unwrap();
        assert!(boundary.starts_with("----notype-"));
        assert!(request.body.starts_with(format!("--{boundary}\r\n").as_bytes()));
    }

    #[tokio::test]
    async fn rejects_failed_or_empty_responses() {
        for scenario in ["401", "403", "429", "500", "302", "empty", "invalid"] {
            let (result, server) = transcribe(scenario).await;
            let error = result.unwrap_err();
            let expected = match scenario {
                "empty" => TranscriptionError::NoSpeech,
                "invalid" => TranscriptionError::InvalidResponse,
                status => TranscriptionError::RequestFailed(status.parse().unwrap()),
            };
            assert_eq!(error.downcast_ref::<TranscriptionError>(), Some(&expected), "{scenario}: {error:?}");
            // A redirect is never followed.
            assert_eq!(server.requests().len(), 1, "{scenario}");
        }
    }

    #[tokio::test]
    async fn can_cancel_an_in_flight_request() {
        let home = TempCodexHome::with_token();
        let server = MockServer::start(|_| {
            let mut response = MockResponse::new(200, "application/json");
            response.silent = true;
            response
        })
        .await;
        let service = std::sync::Arc::new(CodexTranscriptionService::new(home.store()).with_endpoint(&server.url));
        let task = tokio::spawn({
            let service = service.clone();
            async move { service.transcribe(vec![0, 0]).await }
        });
        tokio::time::sleep(Duration::from_millis(100)).await;
        task.abort();
        assert!(task.await.unwrap_err().is_cancelled());
        assert_eq!(server.requests().len(), 1);
    }

    #[tokio::test]
    async fn rejects_missing_and_expired_login_before_uploading() {
        let server = MockServer::start(|_| MockResponse::new(200, "application/json").body(r#"{"text":"x"}"#)).await;
        let home = TempCodexHome::new(None);
        let service = CodexTranscriptionService::new(home.store()).with_endpoint(&server.url);
        assert!(matches!(service.check_credentials(), Err(AiError::MissingCodexAuth)));

        let payload = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, r#"{"exp":1}"#);
        std::fs::write(
            home.path.join("auth.json"),
            format!(r#"{{"tokens":{{"access_token":"header.{payload}.signature"}}}}"#),
        )
        .unwrap();
        // Credentials are checked before the audio.
        let error = service.transcribe(Vec::new()).await.unwrap_err();
        assert!(matches!(error.downcast_ref::<AiError>(), Some(AiError::CodexAuthExpired)), "{error:?}");
        assert_eq!(failure_category(&error), "authentication");
        assert!(server.requests().is_empty());
    }

    // Live: `NOTYPE_CODEX_SMOKE_PCM=<16 kHz mono s16le file> cargo test --lib codex_transcription -- --ignored`
    #[tokio::test]
    #[ignore]
    async fn live_smoke() {
        let path = std::env::var("NOTYPE_CODEX_SMOKE_PCM").expect("NOTYPE_CODEX_SMOKE_PCM");
        let pcm = std::fs::read(path).unwrap();
        // Shows the diagnostics (sizes and response metadata only, never the token).
        let _ = tracing_subscriber::fmt().with_test_writer().try_init();
        println!("wav_bytes={} flac_bytes={}", wav_bytes(&pcm).len(), compress_pcm(&pcm).map_or(0, |flac| flac.len()));
        let started = std::time::Instant::now();
        let text = CodexTranscriptionService::new(CodexAuthStore::default()).transcribe(pcm).await.unwrap();
        assert!(!text.is_empty());
        println!("Codex live transcription ({:?}): {text}", started.elapsed());
    }
}
