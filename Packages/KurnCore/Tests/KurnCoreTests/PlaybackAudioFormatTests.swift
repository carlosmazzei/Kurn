//
//  PlaybackAudioFormatTests.swift
//  KurnCoreTests
//
//  Gemini returns bare 16-bit PCM with its rate in the MIME type;
//  `PCMWaveFile` adds the 44-byte RIFF header `AVAudioPlayer` needs. The
//  header fields are checked byte by byte, because a wrong size or rate
//  plays as noise or not at all rather than failing loudly.
//

import Foundation
import Testing
@testable import KurnCore

struct PlaybackAudioFormatTests {

    private func uint32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<offset + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
    }

    private func uint16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    @Test func wrapWritesACanonicalHeader() {
        let pcm = Data(repeating: 0x7F, count: 100)
        let wave = PCMWaveFile.wrap(pcm: pcm, sampleRate: 24_000)

        #expect(wave.count == 44 + 100)
        #expect(String(decoding: wave[0..<4], as: UTF8.self) == "RIFF")
        #expect(uint32(wave, at: 4) == 36 + 100)
        #expect(String(decoding: wave[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: wave[12..<16], as: UTF8.self) == "fmt ")
        #expect(uint32(wave, at: 16) == 16)
        #expect(uint16(wave, at: 20) == 1, "PCM format")
        #expect(uint16(wave, at: 22) == 1, "mono")
        #expect(uint32(wave, at: 24) == 24_000)
        #expect(uint32(wave, at: 28) == 48_000, "byte rate")
        #expect(uint16(wave, at: 32) == 2, "block align")
        #expect(uint16(wave, at: 34) == 16, "bits per sample")
        #expect(String(decoding: wave[36..<40], as: UTF8.self) == "data")
        #expect(uint32(wave, at: 40) == 100)
        #expect(wave.suffix(100) == pcm)
    }

    @Test func stereoDoublesTheBlockAlignAndByteRate() {
        let wave = PCMWaveFile.wrap(pcm: Data(count: 8), sampleRate: 16_000, channels: 2)
        #expect(uint16(wave, at: 22) == 2)
        #expect(uint16(wave, at: 32) == 4)
        #expect(uint32(wave, at: 28) == 64_000)
    }

    @Test func sampleRateIsReadFromTheMimeType() {
        #expect(PCMWaveFile.sampleRate(fromMimeType: "audio/L16;codec=pcm;rate=24000") == 24_000)
        #expect(PCMWaveFile.sampleRate(fromMimeType: "audio/L16; Rate = 16000") == 16_000)
    }

    @Test func missingOrMalformedRateIsNil() {
        #expect(PCMWaveFile.sampleRate(fromMimeType: "audio/L16;codec=pcm") == nil)
        #expect(PCMWaveFile.sampleRate(fromMimeType: "audio/L16;rate") == nil)
        #expect(PCMWaveFile.sampleRate(fromMimeType: "audio/L16;rate=fast") == nil)
    }

    @Test func listeningTuningStaysGentle() {
        let tuning = PlaybackTuning.listening
        #expect(tuning.targetLUFS == -16)
        #expect(tuning.wetMix > 0 && tuning.wetMix < 1, "dry/wet mix keeps the band a 16 kHz model drops")
        #expect(tuning.limiterPreGainDB == 0)
        #expect(tuning.presence == PlaybackTuning.Band(frequency: 4000, bandwidth: 1.2, gain: 3))
    }
}
