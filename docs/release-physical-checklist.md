# Release physical checklist

H10 PR 25, item 7: the manual real-device checklist for failures the
Simulator cannot reproduce (no Data Protection semantics, no real thermal
state, no physical Bluetooth/Watch hardware). `AccessibilityAuditUITests`
and the rest of `iOS CI` cover everything a simulator *can* reproduce; this
file is what's left, and it is the actual release gate for those items —
`beta`/`submit` in `.github/workflows/swift.yml` reach every item below at
least once before an App Review submission proceeds. Neither Simulator nor
CI can automate any of it.

Run this on a physical device against a release-configuration (or
TestFlight) build before tagging. Check every box; a failure here blocks
the release the same as a failed CI job would.

## Capture and storage

- [ ] Data Protection: start a recording, lock the device before first
      unlock (reboot, then lock without unlocking), confirm the app fails
      closed rather than crashing or silently losing the recording.
- [ ] Screen lock during capture: lock the screen mid-recording and
      mid-finalization; confirm the recording survives and finalizes
      correctly on unlock.
- [ ] Force quit during capture: record for a minute in the foreground,
      swipe the app away from the app switcher, relaunch; confirm the
      recording was stopped and saved (`willTerminate`) or, if not, that it
      shows as needing recovery and "recover" rebuilds it from its capture
      journal with the audio up to the moment of the kill. Repeat with the
      app backgrounded (screen locked) before swiping it away.
- [ ] Nearly-full storage: fill the device to near capacity, start a
      recording, confirm `ResourceGuard`'s low-storage path engages instead
      of a silent truncated/corrupt file.
- [ ] Capacity-query failure (airplane mode toggled during a storage check,
      or a device state where `URLResourceValues` capacity queries can
      transiently fail): confirm this degrades safely rather than crashing.

## Interruptions

- [ ] Phone call: receive a call mid-recording, confirm pause/resume
      behaves correctly and no audio is lost or corrupted.
- [ ] Siri interruption: invoke Siri mid-recording, confirm the same.
- [ ] Bluetooth input disconnect/reconnect mid-recording (unpair or walk out
      of range, then reconnect): confirm the recorder recovers per
      `AudioRecorderService`'s `AVAudioEngineConfigurationChange` handling
      rather than silently dropping audio.
- [ ] Bluetooth route format change (e.g. a route that changes sample rate
      mid-session): confirm `recoverEngineIfNeeded` keeps writing to the
      same file rather than invalidating the recording.

## Background and resources

- [ ] Long background capture: background the app during a long recording,
      confirm it survives past the point a foreground-only assumption would
      fail, and that `BackgroundActivity`'s window expiration is handled
      cleanly (pause, not corruption) if the recording outlasts it.
- [ ] Memory pressure: induce real memory pressure (e.g. several other
      camera/heavy apps open) during transcription; confirm
      `MemoryPressureState`'s cooldown actually defers new heavy work
      instead of getting jetsam-killed.
- [ ] Thermal pressure: let the device get genuinely warm (extended
      recording + charging + a bright display) and confirm the live
      thermal-state check in `ResourceScheduler` engages.
- [ ] Chat in the background (A68): ask a long question in a saved
      conversation, type a follow-up without sending it, lock the device
      until the background window ends, then force quit and relaunch;
      confirm the reply settled as interrupted (no invented answer), the
      question is retryable or resumed once, and the unsent follow-up is
      back in the composer.

## Watch and models

- [ ] Watch disconnect/reconnect during an active recording: confirm
      `PhoneSessionController`'s reconnect reconciliation restores the
      correct state on the Watch rather than a stale "recording" context.
- [ ] Duplicate or lost Watch commands (e.g. tap a Watch control rapidly,
      or move out of Bluetooth range mid-command): confirm commands stay
      idempotent per `commandID` dedup rather than double-executing or
      hanging.
- [ ] Model compilation/load on physical hardware (first-time FluidAudio or
      whisper.cpp model use, real Neural Engine — not the Simulator's CPU
      fallback): confirm compilation succeeds and the progress UI reflects
      it accurately.
- [ ] Model-load cancellation mid-compilation on physical hardware: confirm
      cancelling doesn't leave the app in a stuck "downloading forever" or
      falsely-installed state.

## Common-task accessibility certification (U0.4 / U5)

Nutrition Labels (`fastlane/accessibility.json`) may only be declared for
features where every task below is completed end to end on a physical device
with VoiceOver + Screen Curtain, and then with Voice Control alone. Record
the completed certification in the release PR or `vX.Y.Z` tag notes (see
"Recording this checklist's own result" below); the release approver must
verify that record in the tag/PR notes before approving the `release`
environment deployment in `.github/workflows/accessibility-labels.yml`:

- [ ] Record and stop: start a recording from the meetings list, pause/resume,
      and stop and save.
- [ ] Find a meeting: filter or search for a meeting and open its detail screen.
- [ ] Read a summary: navigate to the Summary tab and read its sections.
- [ ] Ask a question: open Ask, submit a question against authorized sources,
      and read the cited answer.
- [ ] Export a meeting: export/share a meeting transcript or summary.
- [ ] Export Knowledge: enable Knowledge export in Settings → Knowledge (with
      re-authentication) and export a `kurn.knowledge-export` JSON file from
      the Knowledge browser via `fileExporter`.
- [ ] Read a generated note and open its claims: open a Knowledge entity page,
      read the generated narrative ("Notes"), expand its "Based on N claims"
      disclosure, and inspect the underlying claims/evidence.
- [ ] Change provider: open Settings → AI Providers and switch or configure
      the active provider.
- [ ] Delete: delete a meeting or clear Knowledge data and confirm the
      confirmation dialog and deletion outcome.

## Recording this checklist's own result

This file has no CI job of its own — a maintainer runs it by hand and
records the outcome in the release PR or tag notes (which boxes were
checked, on which device/iOS version, and any failure found). That record
is what makes a regression here traceable to a specific release rather than
"broken at some point since the checklist was last run."
