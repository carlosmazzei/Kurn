//
//  Dereverberation.swift
//  Kurn
//
//  Blind single-channel dereverberation by weighted prediction error (WPE).
//
//  The diarization front end cleans up *noise* — nothing addressed *reverberation*,
//  which is the dominant problem for a phone lying on a meeting-room table and the
//  thing that most degrades speaker embeddings. WPE is the standard front end for
//  far-field diarization in the DIHARD and CHiME evaluations, and the property
//  that makes it safe here is that it is **linear filtering**: it introduces no
//  signal distortion, so it does not conflict with the timbre-preservation
//  argument `DiarizationPreprocessor` is built around, the way a neural denoiser
//  would.
//
//  For each frequency bin, a linear predictor is estimated over the *delayed*
//  past and subtracted:
//
//      d(t,k) = x(t,k) − Σᵢ gᵢ(k)* · x(t−Δ−i, k)
//
//  The delay Δ is what keeps the direct path and early reflections out of the
//  prediction, so only the late tail is removed — without it WPE eats the speech
//  itself. The prediction weights are the inverse of the current power estimate,
//  refined over a few iterations, which is where "weighted" in the name comes
//  from.
//
//  **Blocked, deliberately.** WPE is O(T·L²) per bin per iteration, so running it
//  over a whole meeting would be tens of trillions of operations. Estimating one
//  filter per ~15 s block — a span over which a room's response is stationary —
//  brings an hour-long recording down to tens of GMAC, and bounds working memory
//  at one block of spectra. The filter changing between blocks leaves a seam in
//  principle; in practice it is far below the noise floor of what the diarizer
//  reads.
//

import Accelerate
import Foundation

struct WPEDereverberator: Sendable {

    /// Prediction filter length. With a 32 ms frame this reaches roughly
    /// 32–320 ms into the past, the late-tail range of a meeting room
    /// (RT60 ≈ 0.3–0.6 s).
    var taps = 10

    /// Frames of the recent past excluded from the prediction, protecting the
    /// direct path and early reflections from being whitened away.
    var delay = 2

    /// Weight-refinement passes. The fourth changes little and costs as much as
    /// the third.
    var iterations = 3

    /// Frames per independently-estimated filter. 937 frames is ~15 s at 16 kHz
    /// with a 256-sample hop. See the note on cost in the file header.
    var blockFrames = 937

    /// Diagonal loading, relative to the mean of the diagonal. The correlation
    /// matrix is Hermitian positive-definite by construction but badly
    /// conditioned in near-silent bins.
    var regularization: Float = 1e-6

    /// Dereverberate `samples`, returning a signal of the same length.
    ///
    /// Anything shorter than the delay-plus-taps history is returned untouched:
    /// there is nothing to predict from.
    func process(
        samples: [Float],
        stft: STFT,
        onBlockCompleted: ((Int, Int) -> Void)? = nil
    ) -> [Float] {
        let totalFrames = stft.frameCount(forSampleCount: samples.count)
        let context = delay + taps
        guard totalFrames > context, taps > 0, blockFrames > 0 else { return samples }

        var output = [Float](repeating: 0, count: samples.count)
        var blockStart = 0
        let totalBlocks = (totalFrames + blockFrames - 1) / blockFrames
        var completedBlocks = 0
        while blockStart < totalFrames {
            let blockEnd = min(blockStart + blockFrames, totalFrames)
            processBlock(
                samples: samples,
                stft: stft,
                contextStart: max(0, blockStart - context),
                outputStart: blockStart,
                outputEnd: blockEnd,
                into: &output
            )
            blockStart = blockEnd
            completedBlocks += 1
            onBlockCompleted?(completedBlocks, totalBlocks)
        }
        return output
    }

    // MARK: - Per-block

    /// Frames in `contextStart..<outputStart` are transformed but never written
    /// back — they exist only so the first frames this block *does* emit have the
    /// history their predictor needs. The previous block already emitted them.
    private func processBlock(
        samples: [Float],
        stft: STFT,
        contextStart: Int,
        outputStart: Int,
        outputEnd: Int,
        into output: inout [Float]
    ) {
        let bins = stft.binCount
        let frames = outputEnd - contextStart
        guard frames > 0 else { return }

        var real = [Float](repeating: 0, count: frames * bins)
        var imag = [Float](repeating: 0, count: frames * bins)
        for t in 0..<frames {
            stft.forward(
                samples: samples,
                frameStart: (contextStart + t) * stft.hopSize,
                real: &real,
                imag: &imag,
                offset: t * bins
            )
        }

        let firstOutput = outputStart - contextStart
        for bin in 0..<bins {
            dereverberate(
                bin: bin,
                bins: bins,
                frames: frames,
                firstOutput: firstOutput,
                real: &real,
                imag: &imag
            )
        }

        for t in firstOutput..<frames {
            let frame = stft.inverse(real: real, imag: imag, offset: t * bins)
            let start = (contextStart + t) * stft.hopSize
            frame.withUnsafeBufferPointer { src in
                output.withUnsafeMutableBufferPointer { dst in
                    vDSP_vadd(
                        dst.baseAddress!.advanced(by: start), 1,
                        src.baseAddress!, 1,
                        dst.baseAddress!.advanced(by: start), 1,
                        vDSP_Length(stft.frameSize)
                    )
                }
            }
        }
    }

    // MARK: - Per-bin

    private func dereverberate(
        bin: Int,
        bins: Int,
        frames: Int,
        firstOutput: Int,
        real: inout [Float],
        imag: inout [Float]
    ) {
        // Gather the bin's time series so the inner loops walk contiguous memory
        // rather than striding by `bins` across the whole block.
        var xre = [Float](repeating: 0, count: frames)
        var xim = [Float](repeating: 0, count: frames)
        var power = [Float](repeating: 0, count: frames)
        var totalPower: Double = 0
        for t in 0..<frames {
            let re = real[t * bins + bin]
            let im = imag[t * bins + bin]
            xre[t] = re
            xim[t] = im
            power[t] = re * re + im * im
            totalPower += Double(power[t])
        }

        // A silent bin has nothing to predict and a singular correlation matrix.
        let meanPower = totalPower / Double(frames)
        guard meanPower > 1e-20 else { return }
        // Bounds the 1/λ weight range to ~60 dB. WPE is meant to lean on quiet
        // frames, but without a floor a near-silent frame would dominate the
        // whole estimate.
        let powerFloor = Float(max(meanPower * 1e-6, 1e-20))

        // Frames before this have no complete history; they pass through
        // unfiltered rather than being dropped, which would punch a hole in the
        // start of the recording.
        let start = max(firstOutput, delay + taps - 1)
        guard start < frames else { return }

        var dre = xre
        var dim = xim

        for _ in 0..<iterations {
            guard let filter = estimateFilter(
                xre: xre, xim: xim, power: power,
                start: start, frames: frames, powerFloor: powerFloor
            ) else { break }

            for t in start..<frames {
                var predRe: Float = 0
                var predIm: Float = 0
                for i in 0..<taps {
                    let idx = t - delay - i
                    let vr = xre[idx]
                    let vi = xim[idx]
                    // conj(g) * v
                    predRe += filter.re[i] * vr + filter.im[i] * vi
                    predIm += filter.re[i] * vi - filter.im[i] * vr
                }
                dre[t] = xre[t] - predRe
                dim[t] = xim[t] - predIm
                power[t] = dre[t] * dre[t] + dim[t] * dim[t]
            }
        }

        for t in firstOutput..<frames {
            real[t * bins + bin] = dre[t]
            imag[t * bins + bin] = dim[t]
        }
    }

    /// Build and solve the weighted normal equations `R g = r` for one bin.
    ///
    /// Accumulated in `Double`. The `1/λ` weights span a wide dynamic range by
    /// design — WPE deliberately leans on quiet frames — and summing thousands of
    /// those in `Float` loses the small terms to the large ones. The solve itself
    /// runs in `Float`, where only the (regularized) conditioning matters.
    private func estimateFilter(
        xre: [Float], xim: [Float], power: [Float],
        start: Int, frames: Int, powerFloor: Float
    ) -> (re: [Float], im: [Float])? {
        let size = taps
        var matrixRe = [Double](repeating: 0, count: size * size)
        var matrixIm = [Double](repeating: 0, count: size * size)
        var rhsRe = [Double](repeating: 0, count: size)
        var rhsIm = [Double](repeating: 0, count: size)
        var vre = [Double](repeating: 0, count: size)
        var vim = [Double](repeating: 0, count: size)

        for t in start..<frames {
            let weight = 1 / Double(max(power[t], powerFloor))
            for i in 0..<size {
                let idx = t - delay - i
                vre[i] = Double(xre[idx])
                vim[i] = Double(xim[idx])
            }
            // Only the lower triangle is accumulated — R is Hermitian, and the
            // Cholesky factorization reads nothing above the diagonal. That halves
            // the dominant cost of the whole algorithm.
            for j in 0..<size {
                let ar = vre[j]
                let ai = vim[j]
                for i in j..<size {
                    let br = vre[i]
                    let bi = vim[i]
                    matrixRe[i * size + j] += weight * (br * ar + bi * ai)
                    matrixIm[i * size + j] += weight * (bi * ar - br * ai)
                }
            }
            let cr = Double(xre[t])
            let ci = Double(xim[t])
            for i in 0..<size {
                rhsRe[i] += weight * (vre[i] * cr + vim[i] * ci)
                rhsIm[i] += weight * (vim[i] * cr - vre[i] * ci)
            }
        }

        var trace: Double = 0
        for j in 0..<size { trace += matrixRe[j * size + j] }
        guard trace > 0, trace.isFinite else { return nil }
        let loading = Double(regularization) * trace / Double(size)
        for j in 0..<size { matrixRe[j * size + j] += loading }

        // Normalize by the mean diagonal so the Float solve works on numbers of
        // order 1 regardless of the bin's absolute level. The filter is
        // scale-invariant, so dividing both sides changes nothing.
        let scale = trace / Double(size)
        guard scale > 0, scale.isFinite else { return nil }

        return HermitianSolver.solve(
            matrixRe: matrixRe.map { Float($0 / scale) },
            matrixIm: matrixIm.map { Float($0 / scale) },
            rhsRe: rhsRe.map { Float($0 / scale) },
            rhsIm: rhsIm.map { Float($0 / scale) },
            size: size
        )
    }
}

// MARK: - Solver

/// Cholesky solve for a small dense Hermitian positive-definite complex system.
///
/// Hand-rolled rather than routed through Accelerate's LAPACK: at these sizes
/// (10×10) the Fortran-style `zposv_` call is more code than the factorization,
/// and a local implementation is directly unit-testable — which matters, because
/// a silently wrong solve here would produce plausible-looking audio that is
/// simply not dereverberated.
enum HermitianSolver {

    /// Solve `A g = b` where `A` is Hermitian positive-definite, given in
    /// row-major layout. Only the lower triangle (`i >= j`) is read.
    ///
    /// Returns `nil` when the matrix is not positive-definite, which after the
    /// caller's diagonal loading means the data was degenerate rather than the
    /// arithmetic having failed.
    static func solve(
        matrixRe: [Float], matrixIm: [Float],
        rhsRe: [Float], rhsIm: [Float],
        size: Int
    ) -> (re: [Float], im: [Float])? {
        guard size > 0 else { return nil }
        var lre = [Float](repeating: 0, count: size * size)
        var lim = [Float](repeating: 0, count: size * size)

        // A = L Lᴴ
        for j in 0..<size {
            var diagonal = matrixRe[j * size + j]
            for k in 0..<j {
                let re = lre[j * size + k]
                let im = lim[j * size + k]
                diagonal -= re * re + im * im
            }
            guard diagonal > 0, diagonal.isFinite else { return nil }
            let pivot = diagonal.squareRoot()
            lre[j * size + j] = pivot
            lim[j * size + j] = 0

            for i in (j + 1)..<size {
                var re = matrixRe[i * size + j]
                var im = matrixIm[i * size + j]
                for k in 0..<j {
                    // L[i][k] * conj(L[j][k])
                    let ar = lre[i * size + k]
                    let ai = lim[i * size + k]
                    let br = lre[j * size + k]
                    let bi = lim[j * size + k]
                    re -= ar * br + ai * bi
                    im -= ai * br - ar * bi
                }
                lre[i * size + j] = re / pivot
                lim[i * size + j] = im / pivot
            }
        }

        // Forward substitution: L y = b
        var yre = [Float](repeating: 0, count: size)
        var yim = [Float](repeating: 0, count: size)
        for i in 0..<size {
            var re = rhsRe[i]
            var im = rhsIm[i]
            for k in 0..<i {
                let ar = lre[i * size + k]
                let ai = lim[i * size + k]
                re -= ar * yre[k] - ai * yim[k]
                im -= ar * yim[k] + ai * yre[k]
            }
            let pivot = lre[i * size + i]
            yre[i] = re / pivot
            yim[i] = im / pivot
        }

        // Back substitution: Lᴴ g = y
        var gre = [Float](repeating: 0, count: size)
        var gim = [Float](repeating: 0, count: size)
        for i in stride(from: size - 1, through: 0, by: -1) {
            var re = yre[i]
            var im = yim[i]
            for k in (i + 1)..<size {
                // conj(L[k][i]) * g[k]
                let ar = lre[k * size + i]
                let ai = -lim[k * size + i]
                re -= ar * gre[k] - ai * gim[k]
                im -= ar * gim[k] + ai * gre[k]
            }
            let pivot = lre[i * size + i]
            gre[i] = re / pivot
            gim[i] = im / pivot
        }

        guard gre.allSatisfy({ $0.isFinite }), gim.allSatisfy({ $0.isFinite }) else { return nil }
        return (gre, gim)
    }
}
