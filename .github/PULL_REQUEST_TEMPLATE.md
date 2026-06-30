<!--
Thanks for sending a pull request! Please fill in the sections below so reviewers
can understand and verify the change quickly. Delete any sections that do not
apply.
-->

## Summary

<!-- One or two sentences describing what this PR does. -->

## Motivation

<!--
Why is this change needed? Link any related issues with "Fixes #123" or
"Refs #456". For UI/UX changes, briefly describe the user-facing problem.
-->

## Changes

<!-- High-level list of the main changes in this PR. -->

-
-
-

## Screenshots / recordings

<!--
Required for UI changes (iOS app, Apple Watch, or Live Activity). Include
before/after where it helps. Drag & drop images or `.mov` files here.
-->

## Test plan

<!--
How did you verify this? Be specific about devices/simulators, the steps you
ran, and what you observed. Reviewers should be able to reproduce.
-->

- [ ] `swiftlint lint --config .swiftlint.yml` passes locally
- [ ] `xcodebuild ... build` succeeds for the `Kurn` scheme
- [ ] `xcodebuild ... test` passes (new behavior covered by tests where it can be)
- [ ] Verified on iOS simulator / device: <!-- model, iOS version -->
- [ ] Verified on watchOS (if relevant): <!-- model, watchOS version -->
- [ ] Localization strings updated for all supported languages (if any strings changed)

## Checklist

- [ ] PR title and description are in English
- [ ] Change is focused; unrelated refactors split into separate PRs
- [ ] New error cases added to `AppError` have matching localization keys
- [ ] New third-party dependencies/models documented in `THIRD_PARTY_NOTICES.md`
- [ ] No secrets, API keys, personal recordings, or transcripts included in the diff
