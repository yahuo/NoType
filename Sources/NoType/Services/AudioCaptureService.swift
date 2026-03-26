import AVFoundation
import AudioToolbox
import CoreAudio
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

    func startCapture(microphoneID: String?, onChunk: @escaping (Data) -> Void) throws -> URL {
        try stopCapture(flushRemainder: false)

        pendingPCM.removeAll()
        chunkHandler = onChunk

        if let microphoneID {
            try applyInputDevice(uniqueID: microphoneID)
        }

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
        recordingURL = nil
        return StopCaptureResult(recordingURL: activeURL, flushedRemainder: flushedRemainder)
    }

    func clearRecording(at url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func loadRecording(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    static func availableInputDevices() -> [AudioInputDevice] {
        AVCaptureDevice.devices(for: .audio)
            .map { AudioInputDevice(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func consume(buffer: AVAudioPCMBuffer, outputFormat: AVAudioFormat) {
        guard let converter else { return }

        let outputCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate
        ) + 1

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            return
        }

        var didProvideInput = false
        let status = converter.convert(to: outputBuffer, error: nil) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
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

    private func applyInputDevice(uniqueID: String) throws {
        guard let audioUnit = engine.inputNode.audioUnit else { return }
        guard let deviceID = Self.audioDeviceID(forUniqueID: uniqueID) else { return }

        var currentDevice = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &currentDevice,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard status == noErr else {
            throw ASRProviderError.transport("Unable to select microphone (\(status)).")
        }
    }

    private static func audioDeviceID(forUniqueID uniqueID: String) -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &byteCount) == noErr else {
            return nil
        }

        let deviceCount = Int(byteCount) / MemoryLayout<AudioDeviceID>.stride
        var devices = Array(repeating: AudioDeviceID(), count: deviceCount)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &byteCount, &devices) == noErr else {
            return nil
        }

        for device in devices {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidReference: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            let status = AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &uidReference)
            if status == noErr, uidReference as String == uniqueID {
                return device
            }
        }

        return nil
    }
}
