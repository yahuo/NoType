import Foundation

enum PCMUtilities {
    static let sampleRate = 16_000
    static let channelCount = 1
    static let bitsPerSample = 16
    static let chunkDurationMilliseconds = 200

    static let chunkByteCount =
        sampleRate * channelCount * (bitsPerSample / 8) * chunkDurationMilliseconds / 1_000

    static func chunk(_ data: Data, chunkSize: Int = chunkByteCount) -> [Data] {
        guard !data.isEmpty else { return [] }
        var chunks: [Data] = []
        var cursor = data.startIndex
        while cursor < data.endIndex {
            let next = data.index(cursor, offsetBy: chunkSize, limitedBy: data.endIndex) ?? data.endIndex
            chunks.append(data[cursor..<next])
            cursor = next
        }
        return chunks
    }

    static func bigEndianData(for value: UInt32) -> Data {
        var bigEndianValue = value.bigEndian
        return Data(bytes: &bigEndianValue, count: MemoryLayout<UInt32>.size)
    }

    static func uint32(from data: Data) -> UInt32 {
        data.withUnsafeBytes { rawBuffer in
            rawBuffer.load(as: UInt32.self).bigEndian
        }
    }
}
