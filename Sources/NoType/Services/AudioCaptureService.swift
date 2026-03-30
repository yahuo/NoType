@preconcurrency import AVFoundation
import Foundation

final class AudioCaptureService {
    struct StopCaptureResult {
        let recordingURL: URL?
        let flushedRemainder: Data?
    }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var pendingPCM = Data()
    private var fileHandle: FileHandle?
    private(set) var recordingURL: URL?
    private var chunkHandler: ((Data) -> Void)?
    private var levelHandler: ((Double) -> Void)?

    private final class ConversionState: @unchecked Sendable {
        var didProvideInput = false
    }

    private final class PCMBufferBox: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer

        init(buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }

    func startCapture(
        onChunk: @escaping (Data) -> Void,
        onLevel: @escaping (Double) -> Void
    ) throws -> URL {
        try stopCapture(flushRemainder: false)

        pendingPCM.removeAll()
        chunkHandler = onChunk
        levelHandler = onLevel

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notype-\(UUID().uuidString).pcm")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: url)
        recordingURL = url

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(PCMUtilities.sampleRate),
            channels: AVAudioChannelCount(PCMUtilities.channelCount),
            interleaved: true
        ) else {
            throw ASRProviderError.transport("Unable to create target audio format.")
        }

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer: buffer, outputFormat: targetFormat)
        }

        engine.prepare()
        try engine.start()
        return url
    }

    @discardableResult
    func stopCapture(flushRemainder: Bool = true) throws -> URL? {
        try stopCapture(flushRemainder: flushRemainder, emitRemainder: true).recordingURL
    }

    func stopCaptureForFinalization() throws -> StopCaptureResult {
        try stopCapture(flushRemainder: true, emitRemainder: false)
    }

    func clearRecording(at url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func stopCapture(flushRemainder: Bool, emitRemainder: Bool) throws -> StopCaptureResult {
        let activeURL = recordingURL
        var flushedRemainder: Data?

        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }

        if flushRemainder, !pendingPCM.isEmpty {
            let remainder = pendingPCM
            try fileHandle?.write(contentsOf: remainder)
            if emitRemainder {
                chunkHandler?(remainder)
            } else {
                flushedRemainder = remainder
            }
            pendingPCM.removeAll()
        } else {
            pendingPCM.removeAll()
        }

        try fileHandle?.close()
        fileHandle = nil
        converter = nil
        chunkHandler = nil
        levelHandler = nil
        recordingURL = nil
        return StopCaptureResult(recordingURL: activeURL, flushedRemainder: flushedRemainder)
    }

    private func consume(buffer: AVAudioPCMBuffer, outputFormat: AVAudioFormat) {
        levelHandler?(Self.rmsLevel(for: buffer))

        guard let converter else { return }

        let outputCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate
        ) + 1

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            return
        }

        let state = ConversionState()
        let bufferBox = PCMBufferBox(buffer: buffer)
        let status = converter.convert(to: outputBuffer, error: nil) { _, outStatus in
            if state.didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            state.didProvideInput = true
            outStatus.pointee = .haveData
            return bufferBox.buffer
        }

        guard status != .error else { return }
        guard let source = outputBuffer.audioBufferList.pointee.mBuffers.mData else { return }

        let byteCount = Int(outputBuffer.audioBufferList.pointee.mBuffers.mDataByteSize)
        guard byteCount > 0 else { return }

        pendingPCM.append(source.assumingMemoryBound(to: UInt8.self), count: byteCount)

        while pendingPCM.count >= PCMUtilities.chunkByteCount {
            let frame = pendingPCM.prefix(PCMUtilities.chunkByteCount)
            pendingPCM.removeFirst(PCMUtilities.chunkByteCount)
            try? writeAndEmit(frame: Data(frame))
        }
    }

    private func writeAndEmit(frame: Data) throws {
        try fileHandle?.write(contentsOf: frame)
        chunkHandler?(frame)
    }

    private static func rmsLevel(for buffer: AVAudioPCMBuffer) -> Double {
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0, channelCount > 0 else { return 0 }

        if let channelData = buffer.floatChannelData {
            var sum: Float = 0
            for channel in 0..<channelCount {
                let samples = channelData[channel]
                for index in 0..<frameLength {
                    let sample = samples[index]
                    sum += sample * sample
                }
            }
            let meanSquare = sum / Float(frameLength * channelCount)
            return min(1, max(0, Double(sqrt(meanSquare)) * 3.2))
        }

        if let channelData = buffer.int16ChannelData {
            var sum = 0.0
            for channel in 0..<channelCount {
                let samples = channelData[channel]
                for index in 0..<frameLength {
                    let sample = Double(samples[index]) / Double(Int16.max)
                    sum += sample * sample
                }
            }
            let meanSquare = sum / Double(frameLength * channelCount)
            return min(1, max(0, sqrt(meanSquare) * 3.2))
        }

        return 0
    }
}
