//
//  DereverberationTests.swift
//  KurnTests
//
//  Two things are worth proving without real recordings: that the Hermitian
//  solve is arithmetically correct, and that the algorithm built on it actually
//  removes a reverberant tail while leaving dry signal alone.
//
//  What these tests do *not* prove is that WPE improves diarization on real
//  meeting audio — that needs labelled recordings and a DER harness, neither of
//  which exists yet. It is why the feature ships behind an off-by-default flag.
//

import Foundation
import Testing
@testable import Kurn

struct DereverberationTests {

    // MARK: - Solver

    /// Build a known Hermitian positive-definite `A` and a known `g`, form
    /// `b = A g`, and check the solver recovers `g`. A silently wrong solve here
    /// would produce plausible-sounding audio that simply is not dereverberated,
    /// so this is the load-bearing test of the file.
    @Test func solverRecoversAKnownSolution() throws {
        let size = 5
        let (matrixRe, matrixIm) = Self.hermitianPositiveDefinite(size: size)
        let expectedRe: [Float] = [0.5, -1.25, 2.0, 0.125, -0.75]
        let expectedIm: [Float] = [-0.25, 0.75, 1.5, -2.0, 0.375]

        var rhsRe = [Float](repeating: 0, count: size)
        var rhsIm = [Float](repeating: 0, count: size)
        for i in 0..<size {
            for k in 0..<size {
                let ar = matrixRe[i * size + k]
                let ai = matrixIm[i * size + k]
                rhsRe[i] += ar * expectedRe[k] - ai * expectedIm[k]
                rhsIm[i] += ar * expectedIm[k] + ai * expectedRe[k]
            }
        }

        let solution = try #require(
            HermitianSolver.solve(
                matrixRe: matrixRe, matrixIm: matrixIm,
                rhsRe: rhsRe, rhsIm: rhsIm,
                size: size
            )
        )

        for i in 0..<size {
            #expect(abs(solution.re[i] - expectedRe[i]) < 1e-3)
            #expect(abs(solution.im[i] - expectedIm[i]) < 1e-3)
        }
    }

    @Test func solverRejectsANonPositiveDefiniteMatrix() {
        // All zeros: the first pivot is not positive, so there is nothing to
        // factor. Returning nil (rather than NaN) is what lets the caller skip
        // the bin instead of poisoning the output.
        let size = 3
        let result = HermitianSolver.solve(
            matrixRe: [Float](repeating: 0, count: size * size),
            matrixIm: [Float](repeating: 0, count: size * size),
            rhsRe: [Float](repeating: 1, count: size),
            rhsIm: [Float](repeating: 0, count: size),
            size: size
        )
        #expect(result == nil)
    }

    // MARK: - Dereverberation

    /// The test that measures dereverberation: a burst is fed through a room
    /// model, and the energy left ringing *after* the burst ends must drop.
    ///
    /// The room is a recursive echo — `x[n] = s[n] + a·x[n−D]` — rather than a
    /// convolution with a diffuse random tail, and that choice is the whole
    /// point. It is exactly the model WPE claims to invert: in each subband the
    /// observation satisfies `X(t) = S(t) + a'·X(t−2)`, so a correct
    /// implementation should recover `a'` and cancel the tail. Testing against
    /// the algorithm's own model is what makes a *strong* assertion meaningful
    /// here.
    ///
    /// A diffuse white-noise tail, which looks more like a real room, is the
    /// wrong probe for a unit test: for a random impulse response
    /// `E[x(t)·x(t−Δ)*] = Σ h(τ)h(τ−Δ)* ≈ 0`, so there is no linear
    /// predictability for *any* correct WPE to exploit. Real rooms are tractable
    /// because real speech is strongly correlated within each subband, which
    /// synthetic noise is not. So this test proves the implementation solves its
    /// model; it does not predict how much the feature helps on real meetings —
    /// that needs a DER harness and labelled recordings.
    ///
    /// The excitation stays noise so the *source* is unpredictable: a sustained
    /// tone is predictable from its own past and WPE would suppress the signal
    /// itself, testing the opposite of what is intended.
    @Test func removesTheReverberantTailOfABurst() {
        let sampleRate = 16_000
        let burstSamples = sampleRate
        let totalSamples = sampleRate * 5 / 2

        var clean = STFTTests.noise(count: totalSamples, seed: 0x1234_5678_9ABC_DEF0)
        for i in burstSamples..<totalSamples { clean[i] = 0 }

        // One hop-aligned echo path with feedback: an exponential decay whose
        // period matches the prediction delay the dereverberator uses.
        let echoDelay = 512
        let feedback: Float = 0.6
        var reverberant = [Float](repeating: 0, count: totalSamples)
        for n in 0..<totalSamples {
            reverberant[n] = clean[n] + (n >= echoDelay ? feedback * reverberant[n - echoDelay] : 0)
        }

        let dereverberated = WPEDereverberator().process(
            samples: reverberant,
            stft: STFT(frameSize: 512, hopSize: 256)
        )

        // Starts after the burst ends, so only the decaying tail is present.
        let tail = (burstSamples + sampleRate / 20)..<(burstSamples + sampleRate / 3)
        let before = Self.rms(reverberant, tail)
        let after = Self.rms(dereverberated, tail)

        #expect(before > 0)
        #expect(after < before * 0.5, "tail RMS \(before) -> \(after) (ratio \(after / before))")
    }

    /// The counterweight: an anechoic signal must survive essentially untouched.
    /// A WPE that is too aggressive eats speech, and on dry input there is
    /// nothing legitimate for it to remove.
    @Test func leavesDrySignalAlone() {
        let samples = STFTTests.noise(count: 16_000 * 2, seed: 0x0FED_CBA9_8765_4321)
        let processed = WPEDereverberator().process(
            samples: samples,
            stft: STFT(frameSize: 512, hopSize: 256)
        )

        // Skip the leading/trailing half-frames, where overlap-add is partial.
        let interior = 1024..<(samples.count - 1024)
        #expect(Self.correlation(samples, processed, interior) > 0.9)
    }

    @Test func returnsInputUnchangedWhenTooShortToPredict() {
        let samples = STFTTests.noise(count: 600)
        let processed = WPEDereverberator().process(
            samples: samples,
            stft: STFT(frameSize: 512, hopSize: 256)
        )
        #expect(processed == samples)
    }

    @Test func outputIsFiniteAndSameLength() {
        let samples = STFTTests.noise(count: 16_000)
        let processed = WPEDereverberator().process(
            samples: samples,
            stft: STFT(frameSize: 512, hopSize: 256)
        )
        #expect(processed.count == samples.count)
        #expect(processed.allSatisfy { $0.isFinite })
    }

    // MARK: - Helpers

    private static func hermitianPositiveDefinite(size: Int) -> (re: [Float], im: [Float]) {
        // A = M Mᴴ + size·I is Hermitian positive-definite for any M.
        let mre = STFTTests.noise(count: size * size, seed: 0xABCD_1234_5678_9F01, amplitude: 1.0)
        let mim = STFTTests.noise(count: size * size, seed: 0x1111_2222_3333_4444, amplitude: 1.0)
        var re = [Float](repeating: 0, count: size * size)
        var im = [Float](repeating: 0, count: size * size)
        for i in 0..<size {
            for j in 0..<size {
                var sumRe: Float = 0
                var sumIm: Float = 0
                for k in 0..<size {
                    // M[i][k] * conj(M[j][k])
                    let ar = mre[i * size + k], ai = mim[i * size + k]
                    let br = mre[j * size + k], bi = mim[j * size + k]
                    sumRe += ar * br + ai * bi
                    sumIm += ai * br - ar * bi
                }
                re[i * size + j] = sumRe + (i == j ? Float(size) : 0)
                im[i * size + j] = i == j ? 0 : sumIm
            }
        }
        return (re, im)
    }

    private static func rms(_ samples: [Float], _ range: Range<Int>) -> Float {
        let slice = samples[range]
        let sum = slice.reduce(Double(0)) { $0 + Double($1) * Double($1) }
        return Float((sum / Double(slice.count)).squareRoot())
    }

    private static func correlation(_ a: [Float], _ b: [Float], _ range: Range<Int>) -> Float {
        var dot: Double = 0, na: Double = 0, nb: Double = 0
        for i in range {
            dot += Double(a[i]) * Double(b[i])
            na += Double(a[i]) * Double(a[i])
            nb += Double(b[i]) * Double(b[i])
        }
        guard na > 0, nb > 0 else { return 0 }
        return Float(dot / (na.squareRoot() * nb.squareRoot()))
    }
}
