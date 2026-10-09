//! Microphone capture through PipeWire's `pw-record`, converted to the macOS app's PCM format:
//! 16 kHz, mono, signed 16-bit little-endian, delivered in 200 ms chunks.

use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use anyhow::{Context, Result, anyhow};
use tokio::io::AsyncReadExt;
use tokio::process::{Child, Command};
use tokio::sync::mpsc::UnboundedSender;
use tokio::task::JoinHandle;

pub const SAMPLE_RATE: u32 = 16_000;
pub const CHUNK_BYTES: usize = 6_400;
/// Level updates every 50 ms keep the HUD waveform responsive between 200 ms chunks.
const LEVEL_BYTES: usize = 1_600;

#[derive(Debug)]
pub enum CaptureEvent {
    Chunk(Vec<u8>),
    Level(f64),
    /// `pw-record` exited while the session was still recording.
    Failed(String),
}

pub struct Recording {
    /// Every captured sample, including the trailing partial chunk.
    pub pcm: Vec<u8>,
    /// Bytes after the last emitted chunk; streaming providers send them before finishing.
    pub remainder: Vec<u8>,
}

pub struct Recorder {
    child: Child,
    reader: Option<JoinHandle<std::io::Result<Recording>>>,
    stopping: Arc<AtomicBool>,
}

impl Recorder {
    /// Starts capture. The event sender is dropped once the stream ends, so a consumer loop
    /// over the receiver finishes after the last chunk.
    pub fn start(events: UnboundedSender<CaptureEvent>) -> Result<Self> {
        let mut child = Command::new("pw-record")
            .args([
                "--raw",
                "--rate",
                "16000",
                "--channels",
                "1",
                "--format",
                "s16",
                "-",
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .context("failed to start pw-record; install pipewire")?;
        let mut stdout = child.stdout.take().context("pw-record has no stdout")?;
        let mut stderr = child.stderr.take().context("pw-record has no stderr")?;
        let stopping = Arc::new(AtomicBool::new(false));
        let reader_stopping = stopping.clone();

        let reader = tokio::spawn(async move {
            let mut stream = PcmStream::default();
            let mut buffer = vec![0u8; 3_200];
            loop {
                let read = stdout.read(&mut buffer).await?;
                if read == 0 {
                    break;
                }
                for event in stream.push(&buffer[..read]) {
                    let _ = events.send(event);
                }
            }
            if !reader_stopping.load(Ordering::SeqCst) {
                let mut message = String::new();
                let _ = tokio::time::timeout(
                    Duration::from_millis(200),
                    stderr.read_to_string(&mut message),
                )
                .await;
                let message = message.trim();
                let _ = events.send(CaptureEvent::Failed(if message.is_empty() {
                    "Microphone capture stopped unexpectedly.".into()
                } else {
                    format!("Microphone capture failed: {message}")
                }));
            }
            Ok(stream.finish())
        });

        Ok(Self {
            child,
            reader: Some(reader),
            stopping,
        })
    }

    /// Stops `pw-record` and drains the pipe so audio captured before the stop is kept.
    pub async fn stop(mut self) -> Result<Recording> {
        self.stopping.store(true, Ordering::SeqCst);
        if let Some(pid) = self.child.id() {
            unsafe { libc::kill(pid as libc::pid_t, libc::SIGINT) };
        }
        let mut reader = self.reader.take().context("recorder already stopped")?;
        let recording = match tokio::time::timeout(Duration::from_secs(2), &mut reader).await {
            Ok(joined) => joined.map_err(|error| anyhow!(error))??,
            Err(_) => {
                let _ = self.child.start_kill();
                reader.await.map_err(|error| anyhow!(error))??
            }
        };
        let _ = tokio::time::timeout(Duration::from_secs(1), self.child.wait()).await;
        Ok(recording)
    }
}

impl Drop for Recorder {
    fn drop(&mut self) {
        // Cancelling a session drops the recorder; the child is killed by kill_on_drop.
        self.stopping.store(true, Ordering::SeqCst);
    }
}

#[derive(Default)]
struct PcmStream {
    all: Vec<u8>,
    pending: Vec<u8>,
    level_pending: Vec<u8>,
    odd_byte: Option<u8>,
}

impl PcmStream {
    fn push(&mut self, bytes: &[u8]) -> Vec<CaptureEvent> {
        let mut events = Vec::new();
        self.all.extend_from_slice(bytes);
        self.pending.extend_from_slice(bytes);

        // Keep level windows sample-aligned even if a read splits a sample.
        let mut level_bytes = Vec::with_capacity(bytes.len() + 1);
        level_bytes.extend(self.odd_byte.take());
        level_bytes.extend_from_slice(bytes);
        if level_bytes.len() % 2 == 1 {
            self.odd_byte = level_bytes.pop();
        }
        self.level_pending.extend_from_slice(&level_bytes);
        while self.level_pending.len() >= LEVEL_BYTES {
            let window: Vec<u8> = self.level_pending.drain(..LEVEL_BYTES).collect();
            events.push(CaptureEvent::Level(rms_level(&window)));
        }

        while self.pending.len() >= CHUNK_BYTES {
            events.push(CaptureEvent::Chunk(
                self.pending.drain(..CHUNK_BYTES).collect(),
            ));
        }
        events
    }

    fn finish(self) -> Recording {
        let mut pcm = self.all;
        let mut remainder = self.pending;
        // A trailing half sample is not valid PCM.
        if pcm.len() % 2 == 1 {
            pcm.pop();
            remainder.pop();
        }
        Recording { pcm, remainder }
    }
}

/// Same scale as `AudioCaptureService.rmsLevel` on macOS.
pub fn rms_level(pcm: &[u8]) -> f64 {
    let samples = pcm.len() / 2;
    if samples == 0 {
        return 0.0;
    }
    let sum: f64 = pcm
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| {
            let sample = f64::from(i16::from_le_bytes([pair[0], pair[1]])) / f64::from(i16::MAX);
            sample * sample
        })
        .sum();
    ((sum / samples as f64).sqrt() * 3.2).clamp(0.0, 1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(samples: usize, amplitude: i16) -> Vec<u8> {
        (0..samples)
            .flat_map(|index| {
                if index % 2 == 0 {
                    amplitude
                } else {
                    -amplitude
                }
                .to_le_bytes()
            })
            .collect()
    }

    #[test]
    fn level_matches_macos_scale() {
        assert_eq!(rms_level(&[]), 0.0);
        assert_eq!(rms_level(&tone(160, 0)), 0.0);
        let quarter = rms_level(&tone(160, i16::MAX / 16));
        assert!((quarter - 0.2).abs() < 0.001, "{quarter}");
        assert_eq!(rms_level(&tone(160, i16::MAX)), 1.0);
    }

    #[test]
    fn stream_emits_200ms_chunks_and_keeps_remainder() {
        let mut stream = PcmStream::default();
        let audio = tone(8_000, 1_000); // 500 ms
        let mut chunks = 0;
        let mut levels = 0;
        // Odd-sized writes split samples across reads.
        for piece in audio.chunks(999) {
            for event in stream.push(piece) {
                match event {
                    CaptureEvent::Chunk(chunk) => {
                        assert_eq!(chunk.len(), CHUNK_BYTES);
                        chunks += 1;
                    }
                    CaptureEvent::Level(level) => {
                        assert!(level > 0.0);
                        levels += 1;
                    }
                    CaptureEvent::Failed(_) => unreachable!(),
                }
            }
        }
        assert_eq!(chunks, 2);
        assert_eq!(levels, 10);
        let recording = stream.finish();
        assert_eq!(recording.pcm, audio);
        assert_eq!(recording.remainder.len(), audio.len() - 2 * CHUNK_BYTES);
    }
}
