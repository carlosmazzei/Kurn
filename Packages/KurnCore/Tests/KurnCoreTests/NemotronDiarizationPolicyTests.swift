import Testing
@testable import KurnCore

struct NemotronDiarizationPolicyTests {
    @Test func budgetScalesToTheClipWithAFloorAndCeiling() {
        #expect(NemotronDiarizationPolicy.processTimeout(forAudioDuration: 0) == 180)
        #expect(NemotronDiarizationPolicy.processTimeout(forAudioDuration: 30) == 180)
        #expect(NemotronDiarizationPolicy.processTimeout(forAudioDuration: 1200) == 600)
        #expect(NemotronDiarizationPolicy.processTimeout(forAudioDuration: 3600) == 1800)
        #expect(NemotronDiarizationPolicy.processTimeout(forAudioDuration: 7200) == 1800)
        #expect(NemotronDiarizationPolicy.processTimeout(forAudioDuration: -20) == 180)
        #expect(NemotronDiarizationPolicy.processTimeout(forAudioDuration: .nan) == 180)
        #expect(NemotronDiarizationPolicy.processTimeout(forAudioDuration: -.infinity) == 180)
        #expect(NemotronDiarizationPolicy.processTimeout(forAudioDuration: .infinity) == 1800)
    }

    @Test func checksTheDeadlineBetweenChunks() throws {
        try NemotronDiarizationPolicy.checkBudget(elapsed: 0, audioDuration: 60)
        try NemotronDiarizationPolicy.checkBudget(elapsed: 180, audioDuration: 60)
        try NemotronDiarizationPolicy.checkBudget(elapsed: 600, audioDuration: 1200)
        for elapsed: Double in [180.01, .infinity, .nan] {
            #expect(throws: NemotronDiarizationPolicy.Failure.timeBudgetExceeded) {
                try NemotronDiarizationPolicy.checkBudget(elapsed: elapsed, audioDuration: 60)
            }
        }
    }

    @Test func installedRequiresCurrentWeightsManifestAndCorrectSilenceAsset() {
        #expect(installed(version: "current"))
        #expect(installed(version: "current\n"))
        #expect(installed(version: " current \n"))
        #expect(!installed(version: nil))
        #expect(!installed(version: "preview"))
        #expect(!installed(version: "current", manifest: false))
        #expect(!installed(version: "current", silenceBytes: nil))
        #expect(!installed(version: "current", silenceBytes: 2047))
        #expect(!installed(version: "current", silenceBytes: 2049))
    }

    private func installed(version: String?, manifest: Bool = true, silenceBytes: Int? = 2048) -> Bool {
        NemotronDiarizationPolicy.isInstalled(
            cachedVersion: version,
            expectedVersion: "current",
            hasCompiledManifest: manifest,
            silenceEmbeddingByteCount: silenceBytes
        )
    }
}
