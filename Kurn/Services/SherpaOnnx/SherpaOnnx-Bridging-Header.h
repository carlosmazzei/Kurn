//
//  SherpaOnnx-Bridging-Header.h
//  Kurn
//
//  sherpa-onnx's public surface is a C API with no Clang module of its own
//  (its SPM product is literally named "sherpa-onnx", which is not a valid
//  Swift/Clang module identifier), so — unlike FluidAudio and whisper.cpp,
//  both `import`able directly — it is exposed to Swift via this bridging
//  header, mirroring the upstream project's own
//  `swift-api-examples/SherpaOnnx-Bridging-Header.h`.
//
//  Set as the `Kurn` target's `SWIFT_OBJC_BRIDGING_HEADER`, alongside the
//  `SHERPA_ONNX_ENABLED` compilation condition that guards the real
//  implementation — see `SherpaOnnxDiarizer.swift`. `KurnTests` gets neither,
//  so it always takes that file's `#else` stub.
//

#ifndef SherpaOnnx_Bridging_Header_h
#define SherpaOnnx_Bridging_Header_h

#import <SherpaOnnxC/sherpa-onnx/c-api/c-api.h>

#endif /* SherpaOnnx_Bridging_Header_h */
