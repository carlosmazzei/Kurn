//
//  STFT.swift
//  Kurn
//
//  Short-time Fourier transform with analysis-only Hann windowing, shared by the
//  diarization front end.
//
//  Sized for Hann at hop = N/2, where the overlap-add of windowed frames sums to
//  ~1.0 so no synthesis window or output normalization is needed. DFT setups are
//  allocated once and reused across every frame, and the scratch buffers are
//  instance state — so an instance is single-threaded by construction, which is
//  how both callers use it.
//
//  Extracted from `DiarizationPreprocessor`, where it started life private, once
//  `Dereverberation` needed the same machinery. The spectral-subtraction helpers
//  (`magnitudes`, `processFrame`) moved across unchanged; `forward` and `inverse`
//  are new, because WPE needs the complex spectrum — `magnitudes` throws the
//  phase away, and the inverse transform used to be welded to the subtraction
//  step inside `processFrame`.
//

import Accelerate
import Foundation

final class STFT {
    let frameSize: Int
    let halfFrame: Int
    let hopSize: Int
    /// Number of bins `forward` writes and `inverse` reads: 0...halfFrame.
    var binCount: Int { halfFrame + 1 }

    private let forwardDFT: vDSP.DiscreteFourierTransform<Float>
    private let inverseDFT: vDSP.DiscreteFourierTransform<Float>
    private var window: [Float]
    private var realIn: [Float]
    private var imagIn: [Float]
    private var realOut: [Float]
    private var imagOut: [Float]
    private var timeReal: [Float]
    private var timeImag: [Float]

    init(frameSize: Int, hopSize: Int) {
        precondition(
            Self.supportsDFTSize(frameSize),
            "frameSize must be f·2ⁿ where f is 1, 3, 5, or 15"
        )
        precondition(hopSize > 0 && hopSize <= frameSize, "hopSize must be in 1...frameSize")
        self.frameSize = frameSize
        self.halfFrame = frameSize / 2
        self.hopSize = hopSize
        guard let forward = try? vDSP.DiscreteFourierTransform(
            previous: nil,
            count: frameSize, direction: .forward, transformType: .complexComplex, ofType: Float.self
        ), let inverse = try? vDSP.DiscreteFourierTransform(
            previous: nil,
            count: frameSize, direction: .inverse, transformType: .complexComplex, ofType: Float.self
        ) else {
            preconditionFailure("vDSP.DiscreteFourierTransform setup failed for frameSize=\(frameSize)")
        }
        self.forwardDFT = forward
        self.inverseDFT = inverse
        self.window = [Float](repeating: 0, count: frameSize)
        vDSP_hann_window(&window, vDSP_Length(frameSize), Int32(vDSP_HANN_DENORM))
        self.realIn = [Float](repeating: 0, count: frameSize)
        self.imagIn = [Float](repeating: 0, count: frameSize)
        self.realOut = [Float](repeating: 0, count: frameSize)
        self.imagOut = [Float](repeating: 0, count: frameSize)
        self.timeReal = [Float](repeating: 0, count: frameSize)
        self.timeImag = [Float](repeating: 0, count: frameSize)
    }

    /// Sizes accepted by vDSP's complex DFT setup: `f·2ⁿ` where
    /// `f ∈ {1, 3, 5, 15}`. DPDFNet's 320-sample frame is `5·2⁶`.
    private static func supportsDFTSize(_ count: Int) -> Bool {
        guard count > 0 else { return false }
        return [1, 3, 5, 15].contains { factor in
            count.isMultiple(of: factor)
                && (count / factor).nonzeroBitCount == 1
        }
    }

    /// Number of whole frames `samples` yields at this frame/hop size.
    func frameCount(forSampleCount count: Int) -> Int {
        count >= frameSize ? (count - frameSize) / hopSize + 1 : 0
    }

    // MARK: - Complex transform

    /// Complex spectrum of bins `0...halfFrame` for the Hann-windowed frame at
    /// `frameStart`, written into `real`/`imag` starting at `offset`.
    ///
    /// Callers hold a whole block of frames as two flat arrays, so this writes in
    /// place rather than returning — a per-frame allocation would dominate the
    /// cost of the transform itself.
    func forward(
        samples: [Float],
        frameStart: Int,
        real: inout [Float],
        imag: inout [Float],
        offset: Int
    ) {
        windowedFrame(samples: samples, frameStart: frameStart, into: &realIn)
        for i in 0..<frameSize { imagIn[i] = 0 }
        forwardDFT.transform(
            inputReal: realIn, inputImaginary: imagIn,
            outputReal: &realOut, outputImaginary: &imagOut
        )
        for bin in 0...halfFrame {
            real[offset + bin] = realOut[bin]
            imag[offset + bin] = imagOut[bin]
        }
    }

    /// Time-domain samples for the spectrum held in `real`/`imag` at `offset`.
    ///
    /// The returned buffer is `frameSize` long and is reused between calls — copy
    /// or overlap-add out of it before the next call. Negative-frequency bins are
    /// mirrored internally, so callers only supply `0...halfFrame`.
    func inverse(real: [Float], imag: [Float], offset: Int) -> [Float] {
        for bin in 0...halfFrame {
            realOut[bin] = real[offset + bin]
            imagOut[bin] = imag[offset + bin]
        }
        mirrorToNegativeFrequencies()
        return inverseTransform()
    }

    // MARK: - Spectral subtraction

    /// Magnitudes of bins `[0...halfFrame]` for the Hann-windowed frame at
    /// `frameStart`. Caller must ensure `frameStart + frameSize <= samples.count`.
    func magnitudes(samples: [Float], frameStart: Int) -> [Float] {
        windowedFrame(samples: samples, frameStart: frameStart, into: &realIn)
        for i in 0..<frameSize { imagIn[i] = 0 }
        forwardDFT.transform(
            inputReal: realIn, inputImaginary: imagIn,
            outputReal: &realOut, outputImaginary: &imagOut
        )
        var mags = [Float](repeating: 0, count: halfFrame + 1)
        for i in 0...halfFrame {
            mags[i] = sqrt(realOut[i] * realOut[i] + imagOut[i] * imagOut[i])
        }
        return mags
    }

    /// Run the frame through STFT → spectral subtraction → iSTFT, returning
    /// the resulting `frameSize` time-domain samples. Caller overlap-adds these
    /// into the output buffer at `frameStart`.
    func processFrame(
        samples: [Float],
        frameStart: Int,
        noiseFloor: [Float],
        alpha: Float,
        beta: Float
    ) -> [Float] {
        windowedFrame(samples: samples, frameStart: frameStart, into: &realIn)
        for i in 0..<frameSize { imagIn[i] = 0 }
        forwardDFT.transform(
            inputReal: realIn, inputImaginary: imagIn,
            outputReal: &realOut, outputImaginary: &imagOut
        )

        for i in 0...halfFrame {
            let mag = sqrt(realOut[i] * realOut[i] + imagOut[i] * imagOut[i])
            let phase = atan2f(imagOut[i], realOut[i])
            let subtracted = mag - alpha * noiseFloor[i]
            let floor = beta * noiseFloor[i]
            let newMag = max(subtracted, floor)
            realOut[i] = newMag * cosf(phase)
            imagOut[i] = newMag * sinf(phase)
        }
        mirrorToNegativeFrequencies()
        return inverseTransform()
    }

    // MARK: - Shared internals

    /// X[N-k] = conj(X[k]) for k = 1..N/2-1, so the inverse DFT yields a
    /// real-valued signal.
    private func mirrorToNegativeFrequencies() {
        for bin in (halfFrame + 1)..<frameSize {
            realOut[bin] = realOut[frameSize - bin]
            imagOut[bin] = -imagOut[frameSize - bin]
        }
    }

    private func inverseTransform() -> [Float] {
        inverseDFT.transform(
            inputReal: realOut, inputImaginary: imagOut,
            outputReal: &timeReal, outputImaginary: &timeImag
        )
        // vDSP DFT inverse is scaled by `count`; divide to undo.
        var scale = 1.0 / Float(frameSize)
        timeReal.withUnsafeMutableBufferPointer { ptr in
            vDSP_vsmul(ptr.baseAddress!, 1, &scale, ptr.baseAddress!, 1, vDSP_Length(frameSize))
        }
        return timeReal
    }

    private func windowedFrame(samples: [Float], frameStart: Int, into output: inout [Float]) {
        samples.withUnsafeBufferPointer { ptr in
            window.withUnsafeBufferPointer { winPtr in
                output.withUnsafeMutableBufferPointer { outPtr in
                    vDSP_vmul(
                        ptr.baseAddress!.advanced(by: frameStart), 1,
                        winPtr.baseAddress!, 1,
                        outPtr.baseAddress!, 1,
                        vDSP_Length(frameSize)
                    )
                }
            }
        }
    }
}
