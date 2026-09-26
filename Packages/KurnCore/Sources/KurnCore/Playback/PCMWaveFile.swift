//
//  PCMWaveFile.swift
//  KurnCore
//
//  Gemini's speech generation returns bare signed 16-bit little-endian PCM —
//  no container, so nothing says what rate or channel count it is, and
//  `AVAudioPlayer(data:)` refuses it. Prefixing the canonical 44-byte RIFF/WAVE
//  header is the whole fix; the samples are not touched.
//

import Foundation

public enum PCMWaveFile {
    /// `pcm` wrapped in a WAVE container describing it as 16-bit integer PCM.
    public static func wrap(pcm: Data, sampleRate: Int, channels: Int = 1) -> Data {
        let bitsPerSample = 16
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * blockAlign
        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        header.append(littleEndian: UInt32(36 + pcm.count))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        header.append(littleEndian: UInt32(16))
        header.append(littleEndian: UInt16(1))
        header.append(littleEndian: UInt16(channels))
        header.append(littleEndian: UInt32(sampleRate))
        header.append(littleEndian: UInt32(byteRate))
        header.append(littleEndian: UInt16(blockAlign))
        header.append(littleEndian: UInt16(bitsPerSample))
        header.append(contentsOf: Array("data".utf8))
        header.append(littleEndian: UInt32(pcm.count))
        return header + pcm
    }

    /// Sample rate named in an audio MIME type such as
    /// `audio/L16;codec=pcm;rate=24000`, which is how Gemini labels its output.
    public static func sampleRate(fromMimeType mimeType: String) -> Int? {
        for parameter in mimeType.split(separator: ";") {
            let pair = parameter.split(separator: "=", maxSplits: 1)
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "rate" else { continue }
            return Int(pair[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
