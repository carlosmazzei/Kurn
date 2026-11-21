# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Kurn is a local-first iOS + watchOS app (Swift 6, SwiftUI, SwiftData) for recording
meetings, transcribing audio, diarizing speakers, and generating structured AI
summaries. Everything is stored on device; optional models require explicit
user-approved downloads, and cloud (Whisper-compatible) transcription and cloud
AI features send data only to the selected provider. ASR, diarization, and live
preview load cached models locally, never downloading as runtime recovery.

Beyond the summary, a transcript also feeds three further derived artifacts, each
opt-in and each described in its own section below: a per-meeting **wiki**
(`WikiArticle`), free-form **documents** synthesized across meetings
(`GeneratedDocument`), and an optional **LLM correction pass** over the fused
segments. All three are cloud-LLM-backed and therefore off by default — the rule
throughout is that a fresh install transcribes offline and asks before it ever
reaches the network.

The iOS app targets **iOS 26.0** and uses the system's Liquid Glass chrome
directly (see "Navigation chrome" below); the watchOS companion still targets
watchOS 10.0. There is no `#available` fallback for pre-26 iOS — the floor is the
deployment target.

The project is an Xcode project (`Kurn.xcodeproj`) with three app targets: `Kurn`
(app), `KurnWatch` (watchOS companion), and `KurnLiveActivityExtension`
(widget/Live Activity). Tests live in `KurnTests` (Swift Testing, not XCTest),
`KurnSwiftDataTests` (SwiftData store boot/salvage and concurrency-sensitive
suites, split into their own target for process isolation), `KurnUITests`
(accessibility audit and fastlane screenshots) and `KurnWatchUITests`.
There is no root `Package.swift`; three local packages live under `Packages/`:
`Packages/KurnCore` (pure-Foundation logic — `AppError`, `ReliabilityEvent`,
the filesystem/clock seams, the transcript pipeline value types — compiled and
tested with `swift test` on Linux, no Xcode needed; see
`Packages/KurnCore/Package.swift`), `Packages/AgentHarness` (standalone Foundation-only
agent loop, context compaction and vendor wire formats, with no dependencies),
and `Packages/WhisperCpp`, whose only target
is a `.binaryTarget` pointing at whisper.cpp's official prebuilt XCFramework
release asset (see "On-device Whisper (whisper.cpp)" below). The only remote
package is FluidAudio.

### Agent harness (`Packages/AgentHarness/`)

`Packages/AgentHarness/README.md` is the module guide (seams, loop, sessions, entry types,
invariants); keep it current when the harness's public shape changes.
`AgentHarness` and `KurnCore` are independent Foundation-only packages: neither
imports or depends on the other. `AgentHarness` owns the generic runtime, tool
execution, compaction, script-aware `TokenEstimate`, model capacity catalog/resolver,
overflow classification/contracts and `AgentRunTrace`/`AgentRunStep` reduction.
`KurnCore/Chat/` contains meeting/source/artifact domain types only. The app's
`Application/Agent/` composes the runtime, registers Kurn-specific source/document
tool bindings and translates generic steps into localized presentation. HTTP,
SwiftData and trace-file persistence remain host adapters. `Tools/check_static_policy.py`
rejects imports that cross these boundaries. Do not add runtime convenience
extensions or tool schemas back to KurnCore. Generation's bounded map/reduce
`ContextBudget` lives in `Application/Generation/`; it uses the harness estimator
without imposing its 100k practical cap on agent conversations.
Compaction prompts are injectable through `AgentContextPolicy.summaryPrompts`: the
runtime defaults are domain-neutral; `ChatCompactionPrompts.profile` in the app
preserves the meeting/source/citation instructions used by Kurn.

The NH01 baseline and target are in `docs/contracts/native-harness-v1.md` and its
machine-checked catalog. Frozen synthetic fixtures live in each package's test
resources and in `KurnTests/Fixtures`; they pin legacy message/wire/step codecs,
source selections and artifact/session restoration before canonical migration.
`Tools/check_native_harness_contracts.py` validates all 27 components/70 acceptance
cases, evidence links, profile exclusions and fixture hashes in CI. Legacy evidence
is separate from target conformance. NH02 activates native user/assistant/tool-result messages at the provider/runtime
boundary, with ordered blocks, final reconciliation, replay copies and canonical failure
snapshots. The harness assigns request and logical invocation IDs before execution;
provider call IDs may recur. Diagnostics correlate session/run/request/invocation IDs.
Historical unknown timestamps/API/model remain absent. NH03 introduces V6 indexed session entries, immutable artifact revisions and recovery-metadata
containers. V5's entire graph is frozen. Per-session conversion is atomic/idempotent,
retains the original bytes and preserves unknown historical values. The UI uses the checked
active-path projection; presentation caches are rebuildable and cannot override canonical reads.
The compatibility writer records presentation changes as append-only branches. Runtime message
production with awaited barriers (NH05) and canonical tool replay (NH06) are described below. Keep fixture-version,
contract-version, JSONStorage-envelope, SwiftData-schema and pi-JSONL versions distinct.

`ChatSourceScope` persists meeting/tag/folder/library selection,
global transcript/summary/wiki/attachment/knowledge parts and optional per-meeting overrides
(including an empty selection). Legacy `includeWikis` payloads decode to the old defaults.
`ChatSourceTools` exposes bounded, paginated read-only source tools, validating
arguments and enforcing a fixed allowed-meeting/part snapshot on reads and search results.
Search uses transcript-enabled meetings only; listing masks disallowed availability,
and tools with no eligible meeting are omitted. Tool results are compact plain text
(`ChatSourceToolText`), not JSON: one `id | title | … | readable: …` line per source,
passages as `[m:ss] Speaker: text` (rounded, `h:mm:ss` past an hour — the transcript's own
`clockDisplay` form) under a `meeting <id>:` header written once per run,
and a final `page: … of N; next offset: n` (or `end`) line. Per-item JSON keys, quoting and
a meeting ID on every passage cost ~45% of a transcript page, and seconds made the model
convert to the `[mm:ss]` it must cite. Tool schemas and arguments stay JSON (vendor wire
formats require it); document tools use the same header/page-line text.
Explicit `AgentToolOutput.isError` results let tools report recoverable failures
without throwing. `SourceScopeResolver` shares transcribed-only selection with
the document composer; `LibraryChatSourceReader` snapshots SwiftData sources and
uses existing hybrid search, summary rendering and stored attachment text. Wiki
reads require opt-in. `MeetingChatViewModel` runs every question through
`HarnessChatService`; chat needs a provider with an `AgentModel`, so with Apple's on-device
model (or another non-agent provider) the chat shows `ChatArtifactProviderNotice` and the
composer is disabled. The earlier retrieval chat (`MeetingChatService`) was removed.
`ChatSourceScopeEditor` locks meeting selection to one ID or allows library scope
editing. `AgentRunTrace` reduces events to Codable structured steps and live usage.
The adapter removes wiki from global and override parts when `wikiEnabled` is off.
Replies cite meeting titles and `[m:ss]` timestamps in text; KurnCore's
`ChatTimestampCitations` turns those into tappable chips. Retrieval citations stored by the
removed chat are ignored when old turns decode. `ChatSourceSheet` edits meeting-locked parts or library
selections/global parts/per-meeting overrides; scope edits persist for the next message.
`ChatSourcePresentation` shares wiki gating and validation with the adapter; invalid
scopes disable Send/Retry and show inline guidance. The adapter retains a localized,
defensive validation error for sources removed after UI validation. The selector is
hidden for Apple on-device and other non-agent providers, which cannot chat.
`ChatStepTimelineView` shows a run as it happened, Claude Code-style (`ChatActivityPresentation` orders and words it): the model's reasoning as one line ("Thinking…" with the text streaming beneath it, then "Thought for N s", which expands), the narration it wrote beside tool calls, and each tool call with a status dot and a `⎿` result line, successive calls of one tool folded into one line ("Read 3 transcripts", `⎿` naming the first two meetings, queries or documents and "+N"; `ChatToolGroupRow`). While the run streams, reasoning shows only its two newest lines; once the reply is done the whole activity folds into one summary line ("Thought for 12 s · 6 actions", `ChatActivityPresentation.summary`) that expands on tap, with context and diagnostic steps under "Details". `AgentRunTrace` records reasoning (`thinking` steps, timed while observed live) and narration (`narration` steps), each bounded to 8,000 scalars, and restores both from committed messages; the streamed reply starts over after narration, which lives in its step. The live status line says what the run is doing, for how long and how many tokens it has written.
`ChatStepPresentation` maps structured tool/stop data to localization keys outside
Views; expandable arguments/output previews cap at 2000 scalars. The chat shows live
usage/cost and compact per-turn `ChatArtifactReference` title/version rows (no duplicate
document bodies in turn JSON). Optional references preserve old turn decoding;
`ChatArtifactCard` previews and saves artifacts into the document library.

`AgentContextResolution` is the immutable capacity snapshot for a run. Its source is
API (with cache flag and retrieval date), fixed table (with catalog revision), or
fixed fallback; it records the exact model ID, token value and input/combined
semantics. `AgentRunTrace` persists it as a context step, so reopening a chat
does not recompute provenance from today's catalog. Older traces show an unknown
origin. Provider metadata uses an endpoint/API-shape/exact-model keyed V2 cache
with a 24-hour lifetime; unscoped V1 values are not promoted to API evidence.
`ProviderModelsService` records Anthropic input/output limits, Gemini input/output
limits without collapsing versioned IDs, and compatible-server context/output
limits (bounded by routed OpenRouter limits when supplied). Anthropic and Gemini
list pagination is bounded and rejects missing/repeated cursors. The bundled
`ModelContextCatalog` supplies exact, reviewed current model capacities, including
GPT-6.1 Terra's 1,050,000 tokens, ahead of conservative legacy-family defaults.
`AgentModelCapabilities` (AgentHarness, version 1) is the run's capability snapshot: tools,
reasoning plus the effort the adapter sends, image input and the vendor's prompt caching, each
`supported`/`unsupported`/`unknown`. `ModelCapabilityCatalog` has exact reviewed entries and a Claude
3+ family rule; any other name stays unknown rather than inheriting a similar model's facts. Fresh
provider metadata (`ModelContextWindowStore.recordCapabilities`, from the Anthropic/Gemini detail
requests) overrides what it reports and qualifies an alias with its canonical ID. `HarnessChatService`
resolves it before the run, refuses a model known to lack tools (`chat.model.tools_unsupported`) and
records it in the context resolution and the run-start entry (`AgentRunBranch.capabilities`); the
context step lists it. `OpenAIProvider.agentReasoningEffort` is the single source of the effort sent.
The chat's reasoning level (`AppSettings.chatReasoningLevel`, nil = the vendor's default) is chosen with the
model in the composer's model chip (`ChatModelChip`/`ChatModelSheet`, `ChatModelPickerViewModel`; the chat
shares its model with summaries). AgentHarness's `AgentReasoningLevel` maps it per vendor in
`AgentWireFormat.requestProjection(reasoning:)`: Responses `reasoning.effort` plus `summary: auto` (visible
reasoning), Chat Completions `reasoning_effort`, Anthropic `thinking` and Gemini `thinkingConfig` with
`includeThoughts`, both with a token budget kept below the output limit (at least 1,024, else none). Summary
requests never carry it. `ChatReasoningPreference` decides whether a request carries it: never for a model the
capability catalog says cannot reason, and on a compatible endpoint only for one it says can;
`ProviderFactory.agentModel(reasoning:)` sets it on the vendor client, and the run's capability snapshot
records the level sent in place of OpenAI's fixed default. The system prompt's `user_context` section (between
`instructions` and `documents`) gives today's date, weekday, time zone and locale, so relative dates resolve
against the person's calendar; it changes once a day. Beside the chip, `ChatContextGauge` shows the context the
provider last reported against the newest run's window (`MeetingChatViewModel.lastContextTokens`, kept between
runs until the next report).
Prompt caching is keyed by the conversation: `HarnessChatService` builds the harness with
`NativeHarness.cachingPrompts(key:)` (the session ID), which puts `AgentTurnRequest.promptCacheKey` on every
normal and wrap-up request, never on a summary. Anthropic then gets two `cache_control` breakpoints
(`AgentWireFormat.markAnthropicCacheBreakpoints`): the end of the system prompt, which covers the tools and
changes only when the prompt does, and the last cacheable block of the newest message, so each request in a
tool loop reads the conversation before its new messages from the cache. OpenAI Responses gets
`prompt_cache_key`; Chat Completions endpoints and Gemini (implicit caching) are left unchanged, and a request
without a key is byte-for-byte what it was. Cache reads and writes are counted and priced as above.

The bundled catalogs can be corrected between releases by a remote one (`catalog/model-catalog-v1.json`,
format `kurn.model-catalog` schema 1, served from the default branch's raw URL; `catalog/README.md`).
AgentHarness's `ModelCatalogDocument` reads it strictly — one format and schema, at most 256 KiB and 2,000
models, IDs of lowercase letters, digits and `._:-`, windows of 1,024–20M tokens, an output limit within its
window, known capability values, prices of 0–10,000 USD per million tokens and cache multipliers of 0–10 —
and refuses the whole document on any break. `ModelCatalogOverlay` applies one over the bundled catalogs per
fact it states (`ModelContextCatalog.entry`, `ModelCapabilityCatalog.facts`, the app's `ModelPricing` by exact
ID before its prefix table), never one older than the bundled versions or than the one applied, nor dated more
than two days ahead; a run that used its facts records `remote-<version>` as its `catalogVersion`. The app's
`ModelCatalogUpdater` (built by `AppComposition`) applies the saved copy at launch and checks on activation,
only while the selected summary/chat provider is a cloud vendor with a key, at most once a day (a failed or
refused check waits too), with a header-less GET through `LLMHTTP.sendValidated` (15 s, response bounded by
the document limit); it saves a document only once it has been applied. `ModelCatalogDocumentTests` checks
that the published file agrees with the bundled facts it repeats. It changes estimates only, never an endpoint
or what is sent.

`ProviderModelMetadataService` refreshes the selected model in the settings picker
and before an agent run. Anthropic/Gemini details resolve aliases and retain both
the requested and canonical IDs; Groq details include completion limits (vendor/model
IDs are encoded as one path component). Compatible endpoints refresh their listing
instead of inventing a detail route. Official OpenAI model details have no documented
capacity fields, so no detail request is issued for them. Metadata requests use the
existing transport with an eight-second deadline; a coordinator deduplicates by
store/provider/API-shape/endpoint/model/credential in memory and permits four concurrent
lookups. Missing credentials, unsupported metadata and refresh failures do not block
the model's normal request. Cancellation still propagates to the caller.
Each field has its own timestamp; partial responses cannot renew or erase an omitted
field. Cache TTL is 24 hours; failed/incomplete lookups retry after 15 minutes, while a
manual refresh can force a lookup. Endpoint-scoped older metadata stays stored after
failure but expired fields cannot win capacity resolution. The immutable conversation
snapshot records the metadata lookup outcome and whether the selected window came from
the current fetch or cache. Optional fields preserve existing cache/trace decoding. The resolved output limit caps
both normal/wrap-up turns and compaction summaries; reserve size must never override
a smaller provider output limit.

Output budgets belong to `AgentHarness`, not the host. Before every normal, wrap-up
and summary request, `AgentOutputBudget` applies pi's `clampMaxTokensToContext` policy
(reference revision `f064465d10d6a8e5c19f687bba1b5b5499b51680`,
`packages/ai/src/api/simple-options.ts`). Desired output is the resolved model capacity,
or an explicit caller ceiling capped by that capacity. Unknown capacities use an explicit
4,096-token fallback. Estimate current input from the latest applicable provider usage plus
subsequent messages, otherwise from the request. Subtract input and a safety margin of
`max(4096, ceil(input * 0.15))` from the window; cap desired output to that room. If this
leaves less than 32,768 tokens, use `min(32768, window - input - 4096)` instead. The request
floor is one token, matching pi; oversized input still needs normal overflow recovery.
The Responses wire adapter enforces its API minimum of 16 tokens and emits a typed
budget-adjustment event, persisted in the same trace for normal and summary calls.
There is no 32k initial ceiling, 64k hard ceiling, or quarter-window output rule.

The compaction reserve remains a separate threshold. Never reserve the full model output
maximum as a reason to compact an otherwise fitting conversation. Summaries also start
from model capacity, not fractions of that reserve. Summary input is fitted only when it
cannot fit with even one output token and the framing margin; actual output is then
calculated from the fitted request. Serialization/fitting losses remain explicitly logged.

An empty, unseen response stopped below the desired output capacity can attempt forced
compaction and one retry per run, while turn/cost budgets allow it and only if context is
actually reduced. Its reported usage is counted. The interrupted response, tool calls and
replay metadata are discarded; previously committed tools never execute as part of recovery.
The app retains its visibility guard: partial visible replies are not automatically replayed.
Unknown usage, actual exhaustion of desired output capacity, explicit caller caps and failed
recovery remain explicit `outputLimit` outcomes. Retry preparation/denial and each request's
estimated input, desired/effective output, selected safety margin, available room and fallback
status are content-free trace facts. Older budget-extension diagnostic cases stay decodable.
Request completion diagnostics record the per-request budget, token usage, visible text
size, discarded tool-call count and output-limit flag; missing usage remains marked as
unreported. Responses/Chat Completions reasoning-token details and Gemini thought-token
counts are logged when reported, never inferred or accompanied by reasoning content.
Run totals are cumulative over requests and must not be read as current context usage.
`AgentUsage` also carries `cacheReadTokens`/`cacheWriteTokens` (NH07): prompt-cache reads and writes as the
provider reported them, both part of `inputTokens` — the whole input sent — and never added to it again,
just as reasoning is part of output. Anthropic reports cached input apart from `input_tokens`, so its
accumulator adds it to the total; OpenAI (`cached_tokens`), Responses and Gemini (`cachedContentTokenCount`)
already include it. Unreported counts stay nil when usages are added. `agent.usage.v1` entries record
them with the request they belong to (`requestID`), and `AgentRunTrace.restoring` and
`AgentSessionTree.usage` count one request's usage once (entries from before requests were named each count).
The cost estimator returns nil for a usage it cannot price (NH07). `AgentRunOutcome.estimatedCostUSD`
is the run's estimated cost, summaries included, or nil — unknown, never zero — when there was no estimator
or any usage went unpriced. `AgentLimits.maxCostUSD` is checked only against a known cost: without an
estimator, or once a usage could not be priced, the ceiling cannot be verified and counts as reached, so
no further request is sent. `HarnessChatService` passes `ModelPricing` as the estimator; it prices cache
reads and writes at the vendor's own rates (OpenAI and Gemini discount reads, Anthropic also surcharges
writes) and the rest of the input at the full rate, and the chat's per-answer cost uses the same usage. The figure is an
estimate from a price table, not a provider billing cap.
The session is the one retry owner for model requests (NH07, `AgentRetryPolicy`); the agent transport keeps
its own retries off. A request that failed with an `AgentTransientError` before any visible text is sent
again as a new request with its own identity, after a cancellable wait: exponential backoff from one
second, the provider's `Retry-After` when the error carries one, at most `maxAttempts` attempts and
`maxWaitSeconds` of waiting. A cancel during the wait starts no new attempt, and two generations are never
joined. Each failed attempt stays in the log as audit data, and `requestRetryScheduled` diagnostics record
the attempt and delay. `AgentRunProgress` shows the wait as `retryWaiting`. The chat uses `.standard`
(three attempts). `AppError` is transient for 408/429/5xx statuses and connection failures, but not for
timeouts or lost connections the provider may already be generating for, nor for auth, configuration,
quota or context errors. `AppError` cannot carry a `Retry-After`, so the agent stream
(`LLMHTTP.streamAgent`) throws a transient rejection whose response had one as an `AgentRetryAfter`
around the `AppError`: the policy waits that long and the harness unwraps it everywhere else, so the
run's failure, its audit and the stream classification only ever see the `AppError`.
Credentials are resolved per request (NH07): `ProviderFactory.agentModel` returns an `AgentPerRequestModel`,
which builds the vendor client from the Keychain for every request, compaction summaries included. A key
replaced during a run is used from the next request on, and a key removed fails that request explicitly.
The first resolution happens when the model is created, so a missing key still fails before the run.


`AgentDiagnostic` carries only fixed event/metric vocabulary, numeric counts and
opaque correlation IDs. The synchronous injected sink records lifecycle,
request/summary, compaction decisions, tools, skipped calls, first limit and
wrap-up independently of the UI consumer. `HarnessDiagnostics` mirrors these
to `AppLog.generation` at notice and records limit summaries in `ReliabilityLog`
even if wrap-up produces an answer. `HarnessTraceStore` keeps protected JSONL
per run, up to 512 KiB with an explicit incomplete marker and reserved terminal;
it retains 20 completed runs, preserves active runs and expires abandoned active
traces after seven days during pruning. Log export includes this trace independently
of console verbosity. No prompts, excerpts, bodies, tool arguments or raw errors
enter diagnostic records. Failed/cancelled partial answer text is removed, while
its trace and reported usage persist on the retryable question.

Transcript tool pagination preserves full passage text. A page is bounded by
8,000 Unicode scalars and an 18,000-byte budget including framing; a partial
passage returns the same passage `offset` plus `textOffset` for its unread suffix.
Search previews and metadata may still be clipped, but canonical transcript
reads no longer go through the 500-scalar field preview. Summary requests report
the count of characters omitted by per-result clipping and request fitting;
the source data remains in the app. Compaction that does not reduce the estimated
context is skipped rather than reported as a successful reduction.
`AgentTextPage` applies both scalar and byte bounds to canonical summary/wiki/attachment
and document reads, including room for headers and continuation framing. It never
silently returns a non-progressing continuation. Tool diagnostics separate preview loss
(`omittedScalars`/`omittedItems`) from retrievable continuation
(`deferredScalars`/`deferredItems`). Search reports its ranked top-100 window and whether
it is full, without claiming a count of undiscovered hits. Transcript counters include
all fetched passages, even after an early page break. Summary diagnostics distinguish
per-tool serialization clipping from history fitting. The trace remains content-free;
tool text, document bodies, credentials and error messages never enter numeric metrics.


`ChatDocumentWorkspace` owns versioned `ChatDocumentArtifact` values, initialized
from a persisted snapshot when reopening a conversation. `ChatDocumentTools` creates,
replaces, appends sections and reads paginated markdown (8000 scalars per page;
200000 per document). Mutations return ID/version and a human-readable summary,
not document bodies. Models are instructed to use artifacts for documents/reports/minutes
rather than paste them in chat. Saving artifacts into the document library is an app concern.
Each session restores its workspace and source scope. Document mutations persist artifacts
immediately, even if the reply is later cancelled; partial assistant turns are not saved.
Replayed history is canonical (NH06, `ChatReplayHistory`): an earlier answered question goes back
as the run that answered it recorded it on its branch (`AgentRunBranch.contextMessages` — its request,
tool calls, tool results and answer, without failed, aborted, deferred or output-limited replies and
their results). Runs record the question turn they answer (`questionID` start field). A question with
no completed run, or whose run was authorized for other sources or for a meeting the current run may
not read, replays as plain text, so narrowing the sources never replays older reads.

`NativeHarness` is an Apple-free, provider-neutral sequential tool loop. `AgentModel`
supplies streaming text and turn responses; `AgentTool` supplies schemas, optional
confirmation and execution. `AgentEvent` exposes turns, text, tools, compaction,
usage and the final outcome. Tool failures become error results for model recovery;
provider failures throw, and stream termination cancels in-flight work. Turn, tool
and optional estimated-cost limits finish with an explicit stop reason. Cost is
accounted from reported usage through the caller's estimator, including summary calls.
Context management follows pi-coding-agent's design (no code copied). `AgentContextPolicy`
holds the model's real `contextWindow`, a `reserveTokens` kept free for the reply (16,384) and
`keepRecentTokens` (20,000); a request is compacted once its context exceeds the window minus
the reserve (never below half the window), with no fraction and no practical cap.
`HarnessChatService` resolves the window per provider and model through
`ModelContextWindowStore.resolution` → AgentHarness's `ModelContextWindows.resolve`:
fresh capacity metadata reported by the endpoint, else the catalog/legacy table, else
`unknownWindow` (32,768). Unlike `ContextBudget` (summaries and the wiki) it applies no 100k
cap: every turn resends the whole context, so a long run on a large window costs more, and
`AgentLimits.maxCostUSD` is the guard. The context size is the provider-reported usage of the
latest turn (input + output) plus estimates of only the messages appended since; before any
usage, or after a compaction, it is a full estimate. Estimates are per message (text,
tool-call arguments, replay metadata, a fixed framing overhead) through an injected Sendable
estimator (the standalone default is the script-aware `TokenEstimate`), never by re-encoding already-JSON tool results.
`AgentContextCompactor.plan` walks back from the newest message until `keepRecentTokens`
(capped at half the threshold) and cuts at the nearest user or assistant message, never at a
tool result. A cut inside the current turn is a split turn: the turn's earlier part gets its own
prefix summary, so the kept suffix keeps its request. Summary requests are tool-less and send
the conversation as labelled text (`serialize`, tool results clipped to 2,000 characters) with a
structured prompt (goal, progress, findings with citations, sources and documents, next steps);
a later compaction updates the previous summary instead of replacing it. Summary output is
capped at 80% (history) and 50% (turn prefix) of the reserve, and at a quarter/eighth of the
window, and the serialized conversation is trimmed from its oldest end so the summary request's
input and output fit the window (an 8k model is never asked for 13k of output). A summary cut off by the output
limit is not used. Compaction runs before a turn when over the threshold, and is forced after a
provider rejects a turn as too long (`isContextOverflow`; the adapter passes
`AppError` conformance to `AgentContextOverflowError`, delegating to the harness's
`AgentContextOverflow` classifier, whose markers exclude rate limiting/throttling); the turn is then retried once, only if nothing was streamed
and the context actually shrank. No note ever stands in for a summary (NH06): a summary that is
cut off, unusable or whose own request overflows leaves the context unchanged and reports the
compaction failed. After an overflow that ends the run with `AgentContextReductionError` (the chat
says the conversation is too long for the model, `chat.context.reduction_failed`); an output-limit
recovery is denied and the run keeps its `.outputLimit` outcome; a threshold compaction sends the
request as it is. Compaction changes only model context; outcomes retain full history.
Manual compaction (`NativeHarness.compactingFirst`) summarizes the earlier context before a run's first
request whatever its size, through the same durable checkpoint; a conversation too short to summarize is sent
as it is and a failed summary changes nothing. The chat's "Summarize earlier messages first" toggle
(`MeetingChatViewModel.compactsNextAnswer`) applies it to the next answer of a saved conversation.
A summary compaction is a durable checkpoint (NH06, `AgentCompactionCheckpoint`): the harness hands it
to the awaited `persistingCompaction` sink before any request uses the compacted context, and
`AgentSession` commits it on the run's branch as `agent.compaction.v1` (summary, first kept message ID,
tokens before/after, split turn), so a request never runs on context the log lacks and a failed save
fails the run. Only real summaries are checkpoints; an unusable or failed summary, or
a kept message without an identity (legacy plain history) writes none. Replay applies the newest
checkpoint of a permitted run whose kept message is in the history (`ChatReplayHistory`), so a reopened
conversation reuses the summary and a later compaction updates it.
`AgentRunProgress.contextTokens` is the context size the provider last reported for a response (input
plus reply); it is nil — unknown, never zero — before any reported usage, after a compaction and when a
provider reports no input, and a summary request's usage never sets it.
System prompts are ordered sections (`AgentSystemPrompt`): the chat's `instructions` never change and
form a stable prefix, its `documents` index is the section a document mutation changes. Each run's
`agent.run-start.v1` records the first run's whole prompt (`system`) and then a patch on the previous
run's (`systemPatch`: changed or added sections, `null` removing one), plus its declared tools and their
delta from the previous run (`tools`: `AgentToolLoadout`). `AgentRunBranch.systemPrompts(of:)` folds
the patches back into each run's prompt.
Within a run, `NativeHarness.refreshingSystemPrompt` asks for the prompt again after each complete tool
batch: the chat rebuilds it from the workspace, so the request after a document mutation lists the new
version (diagnostic `systemPromptRefreshed`); the run-start entry keeps the prompt the run began with.
Queued input (NH08, `AgentInputQueue`): two FIFO queues, *steering* and *follow-up*, each draining one item
or all of them per boundary. Every change saves the complete lists through `persist` before it is applied
or acknowledged, and `updates()` streams the complete lists with stable item IDs. A harness given a queue
(`receivingInput`) injects steering after each complete tool batch and before it would finish, and a
follow-up only once no tool call and no steering is left. Each drained item is committed as a user
message carrying the item's ID; a run that stops leaves the rest queued, and `clear()` returns it.
`AgentRunSnapshot.exchanges` splits a run's conversation at each item it took in. In the chat, a reply that
is running offers "Steer" and "After this task" for the typed text (`MeetingChatViewModel+Queue`,
`ChatQueuedInputView`). The lists are saved in the session's `.queue` record (`ChatInputQueueRecord`), and
each item taken in shows as its own question and answer turn. A stop clears the queue before it aborts
and hands pending input back to the composer (`restoredDraft`), as does a failed run with the input it
took in. A reopened conversation hands back what a dead process left queued. `ChatReplayHistory` skips
the turns of input a replayed run already contains.
The session tree (NH09, `AgentSessionTree`): an entry is never rewritten, a new branch is new entries
under an older one, and the selected leaf picks the conversation. Runs hang off the question they answer
and never move the leaf; labels (`agent.label.v1`) and context edits are detached metadata with no parent.
The tree gives the alternatives at a message (the conversation's message entries with the same nearest
message ancestor and role), the leaf a navigation opens (the newest conversation entry of that branch),
a navigation commit that only moves the leaf, and copies for fork and clone (the path, the runs that
answered it, its labels and context edits; IDs, times and payloads kept, ordinals renumbered). Usage is
summed over every branch's runs or only over the runs of the selected path. In the app
(`SwiftDataAgentSessionStore+Tree`, `MeetingChatViewModel+Branches`), a question asked again in the
same place shows "‹ n of m ›"; navigating checks the revision, rebuilds the presentation caches and
saves atomically, and is offered only while no reply runs (`canChangeBranch`). Fork copies the path
before a question into a new conversation and hands the question back to the composer (nothing before
the first question means a new, unsaved conversation); "Duplicate conversation" copies the branch shown.
"Regenerate answer" and "Edit question" ask a saved question again in its place, in the same conversation
(`MeetingChatViewModel.askAgain`): `SwiftDataAgentSessionStore.rewind` adds a presentation state under the
question's parent (the sources and documents saved with the question) and selects it, so the conversation
shows just what came before; the question sent next is written beside the earlier one and reads as another
version. Nothing is removed. Editing puts the question in the composer (`editingQuestionID`, with a cancel
banner) until it is taken; a rewind that cannot be saved keeps the edit there. A conversation migrated from
before the session log has one state for all its turns, so asking an older question again (like forking from
it) starts with the sources and documents that state holds, not those of the moment it was first asked. The history sheet searches saved conversations (`ChatSessionSearch`): every query
word must occur, ignoring case and accents, in the title or the turns of the branch each is open on, and a
match in the turns shows an excerpt.
A copy ends on the conversation's state at that point (the state saved right there, else the nearest
before it), rebases its revision IDs and copies only the revisions it shows; the source keeps every
branch. Labels and renames are metadata. Artifact revisions are per branch: the same version written with
other content is a revision of its own (`branchRevisionID`, the version's ID plus a digest of its bytes),
never a conflict, and the save action reads a saved document as current only when it holds that version
with the same body (`ChatArtifactStore.action`). `ChatBranchPresentation.usageSummary` lists the branch
shown and every branch when they differ. "All branches" (`ChatBranchOutline`, `ChatBranchTreeView`) lists
every question as a tree — a question asked again opens a level, the branch shown is marked — and opens the
one chosen where it was left. Branch summaries are not implemented yet.
Session interchange (NH10, `AgentSessionArchive`): a native, versioned JSON Lines archive
(`kurn.agent-session` v1) — a header, one line per entry (encoded directly, so integers keep their exact
form) and namespaced host records kept opaque; unknown entries, record types and header fields survive a
round trip. Only LF separates records (`AgentJSONLLines` reads any chunking; U+2028/U+2029 are ordinary
characters). Reading rejects a missing or repeated header, another format or version, untyped lines,
payloads past the line/total/entry/depth limits, entries of another session and broken graphs; `copy(into:)`
moves the graph to a new identity. The app (`SwiftDataAgentSessionStore+Archive`,
`MeetingChatViewModel+Archive`, `ChatConversationMenu`) exports a conversation with its document revisions
(`kurn.artifact-revision`, exact stored bytes) and title (`kurn.conversation`), never run records, queued
input or receipts, through the share sheet as a protected temporary `.jsonl`. Records and header fields of
another host are kept as `.archived` recovery records on import and exported again unchanged (one past the
1 MiB recovery-record limit is left out and counted in the log). Import is a new conversation
in the current chat: revision IDs are rebased and checked against their bytes, every revision a branch
shows must be present, and nothing is written unless the whole archive holds; a restore keeps the archived
identity only when no conversation has it. "Export as…" writes the branch shown for a reader
(`ChatConversationMarkdown`) as Markdown, or as Word or HTML through `DocumentExport` and the meeting
export's renderers; the HTML is one self-contained page with every text escaped, no script, no external
resource and no link. The pi JSONL v3 subset is not implemented.
Context edits (`AgentContextEdit`, `agent.context-edit.v1`) change only what later runs replay: removing
an assistant message removes the results of its calls, a removed tool result becomes a stub so its call
keeps a result, and the log, the shown conversation and recorded usage are unchanged. A later edit can
include a message again (`restoredMessageIDs`), so what is left out is the net of every edit in order.
`ChatReplayHistory` applies them before the newest checkpoint. In the chat, a saved question's menu offers
"Leave out of later answers" / "Include in later answers" (`MeetingChatViewModel.setLeftOut`,
`SwiftDataAgentSessionStore.editContext`): the edit names the question and its answer turn, the whole
exchange stops being replayed (run or plain text alike), and the question is marked as left out.
Tools declare an effect (`AgentTool.Effect`: `read`, `write`, `destructive`); a destructive tool asks the
harness's `confirm` closure before it runs unless its owner sets `requiresConfirmation: false`. A declined
confirmation, or a tool result with `AgentToolOutput.terminatesRun` (pi's `terminate`, encoded only when set
so older outputs keep their bytes), ends the run after its batch as `AgentRunStopReason.terminated`: the
batch's remaining calls get skipped results, no further request is sent, nothing is wrapped up, the outcome
has no final text (the turn's text was narration beside the calls) and it is not recorded as a limit (`runTerminated` diagnostic). In the chat, `read_document` is a read,
`create_document`/`append_to_document` are writes and `update_document`, which replaces a body, is destructive
(`ChatDocumentTools.effect(of:)`): `HarnessChatService.confirmChange` (default no) is the view model's
`ChatChangeConfirmation`, a sheet (`ChatChangeConfirmationSheet`) showing the document, any new title and the
replacement text, answered only by its own buttons; a stopped run answers no. "Change declined" ends the run
with the question retryable. A document card offers Undo (`MeetingChatViewModel.undoLastChange`) while no
reply runs: each presentation state records, for every document revision it shows, the revision that one
replaced on this branch (`HarnessPresentationState.predecessors`: set when a write introduces a newer version,
carried forward by later states, absent when nothing was replaced, rebased with the revision IDs by copies and
imports, which also copy the revisions it names). `SwiftDataAgentSessionStore.undoLastChange` reads the shown
state's link (`previousVersion(of:in:)`), so a reused revision two branches reached from different versions
still undoes to its own branch's, and the earlier revision is found even though a document effect rewrites its
question as a sibling; it saves that revision again as a new version (`ChatDocumentEdit.restore`), so the change
undone stays saved and can itself be restored.
A tool call is shown while the model writes it (`AgentRunSnapshot.streamingToolCalls`): its arguments, which
the Anthropic, Responses and Chat Completions streams send in pieces, are read best effort by
`AgentPartialJSON` (the longest prefix ending on a whole value, open containers closed, a string value cut
off kept as far as it got, a key without a value, an unfinished number or literal and a half escape left
out) from their first 8,000 scalars, so a title or a query appears before the call ends. Each becomes a
running tool step with a stable identity; the chat shows them after the live reply's steps
(`MeetingChatViewModel.writingSteps`) until the call starts, the message ends or the run settles. Display
only: the call that runs is always the complete arguments, validated as usual.
`AgentLimits.wrapUpOnLimit` runs one extra turn after a turn/tool-call limit with
`NativeHarness.wrapUpInstruction` appended and `AgentTurnRequest.allowsToolCalls` false
(tools stay declared; the wire formats send `tool_choice: none` / Gemini mode `NONE`, and
calls returned anyway are dropped), so the run ends with an answer from what was gathered.
A wrap-up without text leaves no answer; one cut off reports `.outputLimit`; it never runs
past the cost limit.
Chat plans from `AgentWorkload` through the harness's `AgentBudgetPlanner`, not a
source-count-only extension in the app. `LibraryChatSourceReader` supplies only the
frozen authorized IDs and allowed source parts to `ChatWorkloadEstimator`. UTF-8
volume and the transcript's item limit give a conservative estimated page count.
Initial budgets range from 10–48 turns and 20–192 tool calls. The harness may add
eight turns/32 calls only after at least two distinct successful progress calls,
with progress in the last eight calls. Identical canonical arguments do not count
again. Read pages, item pages and committed document mutations report numeric
progress. Absolute ceilings are 64 turns/256 calls; explicit fixed limits keep
fixed behavior. A configured cost estimator/cost limit still stops the runtime
before an extension. `budgetExtended`/`budgetExtensionDenied` diagnostics record
the decision, current/hard limits, distinct progress and idle calls. `AgentRunState`
owns this bookkeeping; it contains no Kurn domain types. The prompt still steers
multi-meeting questions to listing, search and summaries first.
These estimates and limits do not guarantee a provider's hard context
or billing cap. `AgentMessage` and `JSONValue` are Codable for future persistence.
Output-token truncation finishes with `.outputLimit` and discards tool calls. Vendor streams
must include a terminal event before a turn response can be used.
`AgentHarness/Wire/` builds Anthropic Messages, OpenAI Responses/Chat Completions and Gemini
GenerateContent requests and accumulates their SSE data payloads. The app's three
cloud text providers conform to `AgentModel` through the existing bounded SSE
transport, with chat timeouts and no retry after streaming starts. OpenAI-compatible
custom endpoints follow the existing chat request shape.
All official OpenAI text calls use `/v1/responses` with `store: false` only when the
built-in provider ID and HTTPS `api.openai.com` origin (default/443 port) both match;
compatible endpoints stay on Chat Completions. `OpenAIResponsesText` (KurnCore)
shares that selection check and maps buffered text/summary requests and responses,
including JSON-schema/JSON-object formats to `text.format`; streaming reuses the
harness accumulator. Summary/wiki, correction, topic analysis and
auto-tagging all follow this route. Existing GPT-5 chat/agent low reasoning effort
maps to `reasoning.effort`; summary effort remains unspecified. Audio, speech and
model-list APIs are unchanged. Transport timeouts/retry policy remain per route.
Gemini call IDs are synthesized when absent; optional call metadata retains wire IDs and thought
signatures for replay. `ProviderFactory.agentModel(for:model:)` returns nil for
on-device and transcription-only providers, so callers can retain the chat fallback.
Apple's provider does not conform. App adapters import `AgentHarness` explicitly;
there is no re-export through KurnCore. The loop is inspired
by pi-agent-core's design only; no third-party implementation code was copied.

### Harness recovery and presentation reads

`HarnessStoreSalvage` reads and validates entries, artifact revisions and recovery
metadata independently. An unreadable component adds its own warning without hiding
intact siblings; retained records are recovery data, not a validated active path.
Pre-conversion copies are labeled separately. A decodable legacy artifact array is
validated per document, so an invalid item cannot hide intact neighbors. Component labels
and decode warnings use the seven app localizations. Recovery never mutates the source store.
Live session reads remain strict and use the nearest presentation-state ancestor of
the selected leaf, allowing checkpoint leaves without selecting a sibling's state.
Migration preserves `updatedAt`; new presentation writes update it atomically, including
the first write, and restore it if saving fails. Harness rows assign only their parent;
SwiftData maintains inverse collections.

### Where documentation lives

This file is the architecture and conventions reference; `README.md` describes
what the app does; `SECURITY_MODEL.md` is the threat model security scans
rerank findings against (keep its component names stable). `docs/` holds only documents with a lasting job:
`docs/architecture.md` (the module/layer/flow map, pointing back here for depth),
`docs/contracts/` (the native-harness contract and its machine-checked catalog),
`docs/roadmap.md` (the single list of open work — nothing shipped is described
there), `docs/pipeline-evaluation.md` (the recorded accuracy history),
`docs/supported-languages.md`, and the two release checklists
(`docs/app-store-submission-checklist.md`, `docs/release-physical-checklist.md`).
Do not add a separate plan or review document for a new track: put its open
items in the roadmap and, as items ship, move what stays true into this file
or the README and delete them from the roadmap. Code comments cite types or
`CLAUDE.md` sections, never a plan document that will be deleted.

## Commands

Builds/tests require macOS with Xcode 26+ (the iOS 26 SDK). CI uses `iPhone 17` as the simulator
destination (see `.github/workflows/swift.yml`); substitute an installed simulator
name locally if needed.

```bash
# Build
xcodebuild -project Kurn.xcodeproj -scheme Kurn \
  -destination 'platform=iOS Simulator,name=iPhone 17' build

# Run all tests
xcodebuild -project Kurn.xcodeproj -scheme Kurn \
  -destination 'platform=iOS Simulator,name=iPhone 17' test

# Run a single test (Swift Testing uses -only-testing:Target/Suite/test)
xcodebuild -project Kurn.xcodeproj -scheme Kurn \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test -only-testing:KurnTests/SummaryJSONParsingTests

# Lint (must pass before build in CI)
swiftlint lint --config .swiftlint.yml

# Xcode-free checks that also run in CI (work on Linux)
python3 Tools/check_static_policy.py
(cd Packages/KurnCore && swift test)
(cd Packages/AgentHarness && swift test)
```

If `xcodebuild`/SwiftLint can't find SourceKit, point the toolchain at Xcode:
`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

### Releasing

`fastlane/Fastfile` has eight public lanes.
`bump_version type:{patch,minor,major}` bumps
`MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` across all targets via direct text
substitution on `project.pbxproj` (not `increment_version_number`/`xcodeproj`,
which reorder unrelated parts of this file because it uses Xcode 16
file-system-synchronized groups), then commits, tags `vX.Y.Z`, and pushes —
run locally by a maintainer. Pushing that tag starts the pipeline in
`.github/workflows/swift.yml` once all six CI jobs pass: `release` publishes the
GitHub Release; `beta` signs via readonly `fastlane match`, uploads to TestFlight,
and waits for Apple processing; and `store-assets` calls the reusable
`.github/workflows/screenshots.yml` to capture iPhone/iPad/Watch screenshots and
sync them with all localized metadata to the exact project `MARKETING_VERSION`.
This uses deliver's beta `sync_screenshots` path (enabled only inside the
`store_assets` lane), which removes remote extras before uploading missing
images; the legacy uploader retries before Apple exposes checksums and can create
duplicates.
`beta` and the assets upload each use the protected `release` GitHub Environment,
so every App Store Connect mutation waits for administrator approval. Once both
succeed, the dependent protected `submit` job runs `submit_review`; that lane
derives version/build from the tagged project, verifies the `vX.Y.Z` tag,
attaches the processed build, and submits it to App Review with
`automatic_release: false`. The standalone
`.github/workflows/app-store-submit.yml` remains a manual retry path.
`Tools/validate_store_metadata.py` checks locale/file completeness, text limits,
URLs and the App Store search rules the listing is written against (no keyword
that repeats the name, subtitle, brand or a category; no competitor names; no
price term such as "free" in the name, subtitle or screenshot captions, so that
the app is free and open source is said in the description and promotional
text) in the regular CI job. The store languages are not the UI languages: Apple shows
English (U.K.) or Spanish (Mexico) in most storefronts, so `fastlane/metadata/`
carries regional variants (`en-GB`, `es-MX`, …) of the 7 UI languages.
Screenshots are captured in all 7 UI languages — one macOS job per language and device
in `screenshots.yml` (a retry or rerun repeats only the slice that failed), the seeded meetings following the launch language
(`DebugSupport/ScreenshotSeedText`) — and `scripts/screenshots/render.js` frames
every store language with its own captions over the capture of its language
(`es-MX` over `es-ES`, `en-GB` over `en-US`). The app asks for a rating through
`ReviewPromptCoordinator` (`Application/`): a finished transcript or summary is
a moment of value, KurnCore's `ReviewPromptPolicy` decides when one is due
(three moments, once per version, 120 days apart), and nothing asks during a
recording, in the background or in a UI test run. No Apple ID password or 2FA prompt is required;
App Store Connect calls use its API key, while signing credentials come from the
private `kurn-certificates` repository. `store_assets` also calls the private
`sync_accessibility_labels` lane to upsert draft Accessibility Nutrition Labels
from `fastlane/accessibility.json` for iPhone, iPad, and Apple Watch through
Apple's `accessibilityDeclarations` API; Fastlane 2.238.0 has no native model for
that endpoint, so `fastlane/accessibility_labels.rb` uses Spaceship's
authenticated request client directly. The public `accessibility_labels` lane
supports `dry_run:true` and `publish:true`; publishing is separate because Apple
rejects publication until the app has a live App Store version. The protected
manual `.github/workflows/accessibility-labels.yml` workflow exposes that
operation for a `v*` tag after the first public release.

SwiftLint limits worth knowing before adding code: file length warns at 600 lines,
function body at 120, cyclomatic complexity at 15, type body at 400.

### Verifying without a local macOS/Xcode toolchain

Builds and tests require macOS + Xcode, so they can't run in Linux/CI agents or
any environment without the Apple toolchain. When you cannot build or test
locally, **do not claim a change compiles or passes — verify it through the
GitHub Actions `iOS CI` workflow** (`.github/workflows/swift.yml`). It is five
independently-reporting test/check jobs plus the `coverage-gate` that follows them: `lint-and-validate` (SwiftLint, localization and
store-metadata checks), `static-policy` (`Tools/check_static_policy.py`, Linux),
`unit-tests` (`KurnTests` + `KurnSwiftDataTests` on a macOS simulator),
`ui-accessibility-tests` (`KurnUITests` minus the screenshot suite, run as two
`ui-tests` shards — `main` and `flows` — on separate runners and reported as
this one check) and `kurncore-linux` (a matrix running `swift test` and exporting
coverage separately for `Packages/KurnCore` and `Packages/AgentHarness`). `unit-tests` and both `ui-tests` shards compile nothing: they `needs:` the
`build-for-testing` job, which builds once and uploads the products and
`.xctestrun` (artifact `test-products`), and run `test-without-building`, so a
compile error shows up in `build-for-testing`. A cancelled or timed-out shard still fails
`ui-accessibility-tests`. The `release` job
needs all six. The weekly/on-demand `reliability-hardening.yml` adds a Thread
Sanitizer run over the concurrency-sensitive suites, a Release-configuration
test run and a UI-test flake measurement. The test jobs also upload
lcov coverage to Codecov (flags `unittests`/`uitests`/`kurncore`/`agentharness`, via
`.github/actions/upload-xcode-coverage`, which converts the `.xcresult`
coverage archive with `Tools/xccov_to_lcov.py`, and `llvm-cov export` on
Linux; the README
badge reads the `main` total). Codecov itself stays informational
(`codecov.yml`) and excludes SwiftPM checkouts and test sources; do not make
the Codecov upload fatal — the gate below is ours, so a Codecov outage never
blocks a merge. `codecov.yml` declares one component per
layer (`Kurn/Infrastructure`, `Providers`, `Models`, `Services`, `Application`, `ViewModels`,
`Views`, KurnCore, AgentHarness) and ignores `KurnWatch`, `KurnLiveActivityExtension`,
`Kurn/AppIntents` and `Kurn/DebugSupport` until a job executes them;
`Tools/coverage_report.py` renders the per-layer table into the job summary.
Every in-scope layer is above the 80% target; the remaining file-level gaps
are listed in `docs/roadmap.md`.

**Coverage gate (target: 80%).** `coverage-gate` unions the lcov reports
(app unit tests, both UI shards and both Swift packages) with
`Tools/coverage_gate.py` and fails a PR on either of two checks,
both restricted to the files `Tools/coverage_scope.json` puts in scope — app
logic (`Kurn/` minus `Views/`, `ContentView.swift`, `DebugSupport/`,
`AppIntents/`) and both Foundation-only packages' sources:

- **Patch:** the executable in-scope lines a PR adds must be ≥ 80% covered.
  Untested new logic is the failure this exists to catch; write the test in
  the same PR rather than moving the code somewhere unmeasured.
- **Floor:** the in-scope total and each layer may not drop more than 1pp
  below `Tools/coverage_floor.json`. The floor is a ratchet: a PR that raises
  coverage runs `python3 Tools/coverage_gate.py --write-floor <lcovs>` (the
  three reports are artifacts of the run; it never lowers a value) and commits
  the result. The simulator runs are not deterministic — `Services` and
  `Providers` measured 0.8–0.9pp apart on identical code — so raise only the
  layers the change moved, from the lower of two runs, never a whole table
  from one. Never lower a floor or add an exclusion to make a PR pass. The
  one exception: a PR that skips a whole flaky UI suite (whose lines are in the
  union) explains the drop and rewrites the floor in the same change.

An exclusion is legitimate only for code no test target can run: a SwiftUI
view body, or an **adapter** — a file that only wraps an API needing
hardware, a downloaded model, Metal/ANE or an entitlement, with every decision
it used to make already moved into a tested type. Each `exclude` entry states
that reason; new logic inside an excluded adapter is a review bug. An adapter
entry also records `maxLines`, its size when excluded, and `Scope.audit`
(`Tools/lcov.py`, run by `Tools/tests/` in `static-policy`) fails when an
adapter outgrows it or a pattern no longer matches any file: since excluded
code is unmeasured, its size is the signal, and raising a budget is a change
a reviewer sees. Pure
presentation logic does not belong in `Views/` (where it would be excluded);
put it beside the type it presents. `Tools/tests/` covers the gate itself and
runs in `static-policy`.

How coverage was raised to target, and how to keep it there:

- **Seams before tests, as constructor parameters with the production default**
  (`isProviderUsable`, `service`, `indexService`, `chatService`, an injected
  `LLMProvider` exercised with `KurnTests/Support/ScriptedLLMProvider`) — never
  `#if DEBUG` inside logic, and no test that needs the network, a downloaded
  model or the microphone.
- **A test that only touches KurnCore types lives in `Packages/KurnCore/Tests`**,
  not `KurnTests`, so it runs on Linux next to the code it tests.
  Harness-only tests similarly live in `Packages/AgentHarness/Tests`.
- **Never construct `AVSpeechSynthesizer` or `AVAudioPlayer` in a test**: on the
  CI simulator they hang and take the whole test process down
  (`ReadAloudEngineTests` records why).
- Framework-bound files are split the same way every time: the decisions move
  into a tested type (in KurnCore when Apple-free), and what remains — e.g.
  `ModelDownloadConsent+FluidAudio`, `TranscriptionScheduler+BGTask` — is an
  excluded adapter.

To verify a change through CI:

- Push the change to its branch and open (or update) a PR. Every PR runs CI,
  whatever branch it targets (work stacked on an integration branch included);
  pushing to a feature branch alone does not trigger CI.
- Read the run's outcome with the GitHub Actions tooling/API: fetch the
  `unit-tests` (or `ui-accessibility-tests`) job logs and grep for `error:`
  (compile failures), `recorded an issue` / `** TEST FAILED **` (test
  failures), and the final result line. Treat a green run as the source of
  truth that it compiles and passes.
- Iterate against CI: each fix can surface the next latent error (the Swift
  build stops at the first error), so expect several rounds. State plainly that
  results are pending/observed from CI rather than asserting local success.

### Live provider qualification

`.github/workflows/live-provider-smoke.yml` (`workflow_dispatch` only, since it spends API credit) runs
`LiveProviderSmokeTests` with `KURN_LIVE_SMOKE=1` and the `OPENAI_API_KEY`/`ANTHROPIC_API_KEY`/`GEMINI_API_KEY`
secrets: one agent run per vendor whose key is set, through the app's own clients and `NativeHarness`, with a
tool whose answer carries an offset the model cannot guess, so a pass proves the tool round trip. Models come
from the workflow's inputs or the providers' defaults. It prints `[live-smoke]` lines (time to the first
streamed block of any kind, to the first visible reply text and to the end, tool calls, stop reason, tokens) and
runs `ChatSessionScaleTests`, which opens a conversation of a thousand saved entries (`[session-scale]`: write,
projection and open times, the open read through a context that has never seen it; that suite also runs in
every CI). The same job counts the build's Swift concurrency warnings (the app and the
packages build in the Swift 6 language mode, where a visible data race is an error). No line carries a
prompt, an answer, a key or tool arguments, and no threshold is invented for the times: they are compared
between runs, like the pipeline evaluation.

### Measuring accuracy (WER / DER)

`KurnTests/Support/Evaluation/` implements the two standard metrics, so an
accuracy claim can be *measured* instead of inferred from the literature —
which is what every claim about this pipeline had been until it existed.

- `WordErrorRate` — Levenshtein over normalized tokens, reporting
  substitutions / insertions / deletions separately, because they mean different
  things here: dropped speech (VAD gating, a quality filter, a chunk boundary)
  is deletions, hallucination is insertions, mishearing is substitutions.
  Two-row DP carrying the counts forward — a full backtrace matrix for an
  hour-long meeting is ~320 MB.
- `TextNormalizer` — for comparison only, never applied to a stored or displayed
  transcript, which should keep its punctuation and case. Language-neutral
  (NFKC, case fold, punctuation strip); unsegmented scripts fall back to
  characters, which makes their rate a CER. Rates are comparable between runs on
  the same material, not against published figures.
- `DiarizationErrorRate` — NIST DER: missed + false alarm + confusion over
  reference speech, scored under the label mapping that maximises agreement
  (a diarizer's own labels are arbitrary — exhaustive search up to 7 labels,
  the Hungarian algorithm above that; the earlier greedy fallback over-reported
  DER by up to ~8pp against `pyannote.metrics` on synthetic 8–12-speaker
  timelines, which matters once VoxConverse's up-to-21-speaker files are in
  play) with a ±0.25 s collar around reference boundaries. Confusion is
  reported apart from missed time because this app's known failure — the
  clustering step collapsing to one speaker — is *all* confusion and *no*
  missed time.
- `RTTM` — reads and writes the annotation format the corpora and external
  scorers use.
- **Since 2026-09-26, `Tools/evaluation/rescore.py` re-scores every dispatch's
  raw output a second way**, with the reference tools themselves — Whisper's
  own normalizer + `jiwer` for a "WER standard" figure (the one loosely
  comparable to a published number), `meeteval` for cpWER (speaker-attributed
  WER, the one number that reflects what a user actually reads when
  diarization and transcription both have errors), and `pyannote.metrics` for
  DER at both a ±0.25 s collar and none. It exists as a cross-check on the
  harness above, not a replacement for it — on 1071 real cells its DER matched
  `pyannote.metrics` to 0.0000pp.

The corpus cannot live in the repository: meeting recordings are the most
private thing the app touches. `EvaluationDataset` reads `KURN_EVAL_DATA`
instead, and `EvaluationHarnessTests` is skipped entirely when it is unset —
which is how CI runs, so **a green run proves the metrics are correct and says
nothing about accuracy on real speech**. With a directory set, it scores
`<name>.reference.txt`/`.hypothesis.txt` pairs, `.rttm` pairs, and — the one
that catches regressions, because it re-derives the result every run — the
heuristic diarizer run over `<name>.m4a` against `<name>.reference.rttm`.

`Tools/evaluation/` has the recipe for producing that material — getting the
`.m4a` off the device (the app does not declare `UIFileSharingEnabled`, so Files
and Finder cannot see recordings, and that should stay true), annotating turns in
Audacity, and `prepare.py` to convert the app's Markdown export and the label
track into the two file formats the harness reads.

Deliberately no pass/fail threshold: a budget invented here would have no
provenance, and the first failure would just raise it.

### Pipeline evaluation matrix on public datasets

The private-corpus harness above answers "is this accurate on *my* meetings",
but never runs unattended — there is no corpus for CI to score against. It also
scores one hypothesis at a time, so it cannot say whether audio cleanup or a
given diarizer actually helps versus just asserting it does.
`PublicDatasetEvaluationHarnessTests` (`KurnTests/`) is the other half: it runs
the app's real pipeline — `TranscriptionService`, not a stand-in — once per
configuration in `PipelineEvaluationMatrix` (preprocessing on/off x VAD x
diarization x transcription engine, 36 on-device combinations, expanded on
request over whisper.cpp variants and the FluidAudio ASR/diarization model
axes, plus optional cloud Whisper/OpenAI/Groq entries when their API key
secret is present) over
public benchmark audio in English and Portuguese, scoring WER/DER against each.
Public audio carries none of the private corpus's restrictions, so this suite
is meant to run in CI on demand
(`.github/workflows/pipeline-eval.yml`, `workflow_dispatch`) — the practice is
to dispatch it after any change to a pipeline stage (preprocessing, VAD,
diarization, an engine, `TranscriptFusion`, …) to see whether the change moved
WER/DER, not just whether it still compiles.

Skipped like the private harness — via `KURN_PUBLIC_EVAL_DATA`, read by
`PublicEvaluationDataset` — but the corpus itself is fetched on demand rather
than committed (still too large for git, just not private), from
`Tools/evaluation/public_datasets/` (`manifest.json` + `fetch_all.py`; see its
README for what each corpus needs, including the `HF_TOKEN`/`OPENAI_API_KEY`/
`GROQ_API_KEY` secrets some entries are gated behind). Output is `[pipeline-eval]`
lines: per-item WER/DER, then aggregate tables per (language, configuration) and
per (corpus, configuration) — the ones to compare between runs — plus an
optional CSV via `KURN_PUBLIC_EVAL_REPORT`. Same no-threshold philosophy as the
private harness.

**The corpus mix is weighted toward meeting audio on purpose.** Rates are
micro-averaged by reference length, so the corpus with the most speech decides
the language number: AMI (four people around a table, `ami_rttm`, the only
corpus scored on **both** WER and DER) is sized to dominate English, while
LibriSpeech is kept small as a regression canary rather than a description of
real use. AMI's lexical reference comes from AMI's own manual annotation zip —
`fetch_ami.py` reads only `words/*.words.xml`, where each `<w>` carries its own
`starttime`, so a time-ordered transcript needs no speaker mapping; it is
best-effort and degrades to DER-only rather than risk a silently wrong
reference. A second grain exists because a language total otherwise blends read
speech with meeting speech. `huggingface_diarization` is the generic fetcher for
the `diarizers-community` layout (`timestamps_start`/`timestamps_end`/`speakers`
→ RTTM), which makes a DER corpus a manifest entry rather than a new script.
Cost scales as audio-seconds × configurations — prefer per-corpus dispatches
over one sweep.

**The CSV is appended row by row as each cell is scored**, and the aggregate is
printed before the failure assertion rather than after it. Both exist because
the report used to be built in memory and written once, after the loop *and*
after `#require(failures.isEmpty)`, so a run that hit the 360-minute ceiling, got
cancelled, or tripped over one broken cell produced nothing at all. A truncated
report is now a usable result and a resume point: `resume: true` (workflow) /
`KURN_PUBLIC_EVAL_RESUME=1` keeps the rows already in the file and runs only the
missing cells. Opt-in, because a row records nothing about the code that
produced it — reusing one is sound only while the pipeline is unchanged, which
per-stage versions in the CSV would make checkable instead of promised.

Two axes are provably redundant and worth knowing before adding cells:
`TranscriptFusion` is word-preserving (`splitCoarseSpan` returns the original
span unless the partition consumes every word), so **the diarizer cannot change
WER** — confirmed by Parakeet scoring identically across all four VAD × diarizer
combinations. whisper.cpp does vary there, which cannot be the diarizer and is
therefore its own decode non-determinism: roughly a 2-point noise floor that any
WER comparison has to clear. DER is *not* symmetric, since it is scored on the
fused segments whose boundaries come from the ASR spans.

**Results are recorded in `docs/pipeline-evaluation.md`**, newest run first,
and summarized in the README's "Accuracy And Evaluation" section. That file
exists because neither place the workflow writes to survives: the job summary
belongs to a run page and the artifact is deleted after 90 days, so without it
a measurement cannot be compared against one taken two months earlier — which
is the only thing these numbers are good for. `Tools/evaluation/report_to_markdown.py`
renders `report.csv` into exactly the Markdown that file expects (re-deriving
the micro-average from the raw counts rather than scraping the already-rounded
aggregate lines, and splitting the configuration label into one column per
stage so the table survives the label format changing again), and the workflow
runs it so the job summary hands a maintainer something paste-ready. Recording
a run is deliberately a human step: a partial or noisy dispatch is not worth a
commit.

## Architecture

MVVM with `@Observable` `@MainActor` view models, value-type async services, and a
single app-wide SwiftData `ModelContainer`. The layers (under `Kurn/`):

- **Models/** — SwiftData `@Model` classes (`Meeting`, `Recording`, `Transcript`,
  `Speaker`, `Summary`, `Tag`, `Folder`, `SmartFolder`, `SemanticChunk`,
  `WikiArticle`, `GeneratedDocument`, `ChatSession`, `MeetingPhoto`,
  `MeetingAttachment`) plus
  shared value types grouped by subject — `AIProvider.swift`,
  `PipelineEngines.swift` (one engine enum per pipeline stage),
  `ProgressPhases.swift` (the progress vocabulary reported to the UI),
  `LibraryEnums.swift`, `CaptureEnums.swift`, `Highlight.swift` — plus
  `MeetingFilter`, `MeetingLanguage`, `TranscriptionCheckpoint`, `FolderCatalog`,
  `SummarySection`, `SummaryTemplate`, `UsageStats`, `DocumentSourceResolver`).
- **Services/** — audio capture, transcription pipeline (`Services/Pipeline/`),
  on-device FluidAudio engines, diarization, live transcription preview,
  summaries, wiki and document generation, folder analytics, auto-tagging. These
  are mostly `struct`/`actor` types operating on plain values so they stay
  decoupled from SwiftData and safe off the main actor.
- **Providers/** — vendor clients behind one protocol per capability:
  `LLMProvider` (text generation — Apple's on-device `FoundationModelsProvider`
  plus the cloud vendors), `TranscriptionProvider` (cloud speech-to-text) and
  `SpeechSynthesisProvider` (read aloud). Shared
  networking is split by responsibility: `ProviderHTTPPolicy` owns budgets and
  request/replay semantics,
  `ProviderURLPolicy` owns destination validation, `ProviderHTTPTransport` owns
  bounded execution/retry, and `ProviderResponseParsing` owns decoding contracts.
- **Application/** — `@MainActor` use cases over the store that sit below the
  UI, driven by the scene and by non-UI entry points alike:
  - `MeetingLibrary` owns every user-initiated library mutation (create and
    delete meetings, recordings, photos, attachments, summaries; tags, folders, smart
    folders, generated documents), with their rules — trimmed names,
    case-insensitive tag uniqueness, journaled file cleanup — and throws the
    save failure as `AppError`. Views call it; they never `insert`/`delete`
    into a `ModelContext` themselves.
  - `TranscriptionCoordinator` owns every transcription run: start, pause,
    stop, resume budget, persisting the transcript, speaker reconciliation
    (`+Speakers`), correction retry, and the post-transcription enrichment
    it hands to `AITitleCoordinator`, `SemanticIndexCoordinator` and
    `WikiCoordinator`. It is `@Observable` because the meeting screen renders
    per-recording progress from it, but it serves the `BGProcessingTask`
    runner as much as the UI, which is why it is not a view model.
- **ViewModels/** — `@MainActor @Observable` state for one kind of screen:
  `SummaryViewModel` (generate/translate summaries), `RecorderViewModel`,
  `MeetingChatViewModel`, …
- **Views/** — SwiftUI screens, plus the UIKit glue that hosts them
  (`SecurityCoverWindow`).
- **Infrastructure/** — settings, errors, logging, keychain, export, extensions,
  the durable provider circuit used only by automatic cloud enrichment, the
  large-transfer policy shared by cloud audio and model downloads, and the
  durability layer (store boot/backup/salvage, trash, operation journal,
  quarantine/recovery, reliability events, resource scheduler — see
  "Durability & recovery" below).
- **AppIntents/** — `StartRecordingIntent`/`KurnShortcuts` (Siri, Shortcuts);
  the matching Control Center control lives in `KurnLiveActivityExtension`.
- **Composition root** — `Kurn/AppComposition.swift` builds every
  store-dependent coordinator (`TranscriptionCoordinator`, `SummaryViewModel`,
  `SemanticIndexCoordinator`, `WikiCoordinator`, …) with its dependencies
  passed at construction, runs the launch recovery sweeps once per container,
  and owns the instances for the life of the process. The scene
  (`KurnApp.appEnvironment`) and the `BGProcessingTask` runner
  (`TranscriptionScheduler`, via `BackgroundTranscriptionContext`) both get
  them from there — never build a second view model or `AppSettings` for a
  non-UI entry point, and never inject a dependency by assigning a property
  after construction.
- **DebugSupport/** — `#if DEBUG` only, compiled out of Release.
  `ScreenshotSeedData` seeds a handful of plausible meetings (text from
  `ScreenshotSeedText`, in the launch language) into the in-memory
  container `KurnApp` builds when launched with `"UI-Testing-Screenshots"`,
  backing both the fastlane screenshot run and `AccessibilityAuditUITests`. It
  never seeds a real recording or transcript.

Dependencies point down: Models/Providers/Services/Infrastructure/Application/
AppIntents never name a type declared in ViewModels/ or Views/, and ViewModels/
never name one declared in Views/. `Tools/check_static_policy.py` enforces this
(`upward-dependency`), together with no store mutations (`view-store-mutation`)
and no `KeychainManager` (`view-keychain`) in Views. There are no
grandfathered exceptions; keep it that way by moving a shared type down or
inverting the dependency, not by adding a baseline entry.

### Change discipline

Prefer coherent architectural boundaries over incremental patches. Before extending
an already large type or test suite, extract cohesive responsibilities into focused
files and keep dependencies directional. Remove obsolete paths when compatibility no
longer requires them, keep legacy adapters isolated from active production flows, and
make tests mirror the production boundary they verify. Treat approaching SwiftLint
file/type limits as a refactoring signal rather than using the remaining line budget.

### Data model

`Meeting` is the aggregate root. It cascades deletes to its `recordings`,
`speakers`, `summaries`, `semanticChunks`, `wikiArticle`, `chatSessions` and
`attachments` —
every transcript-derived artifact dies with the meeting it came from, which is
what makes "delete the meeting" a complete erasure rather than a partial one.
`GeneratedDocument` is the deliberate exception: it snapshots its sources
instead of relating to them, so deleting a meeting cannot destroy a document
already generated from it.

The spoken language is `MeetingLanguage` (`Models/MeetingLanguage.swift`),
carrying both the BCP-47 locale for the on-device recognizer and the code
Whisper expects in its `language` hint, plus `.autoDetect`. It is table-driven
rather than switch-driven so SwiftLint's cyclomatic-complexity and
function-length limits stay unaffected as languages are added. Its rawValues are
persisted in `Meeting.languageRaw` — **never rename or remove an existing
case.** Not every engine handles every language, so
`TranscriptionLanguageSupport.isSupported(_:by:)` pairs a `MeetingLanguage` with
a `TranscriptionEngine` and lets the picker warn up front, rather than letting
the user discover the gap as a transcription-time error. `.autoDetect` always
counts as supported — every engine either detects or ignores the hint.

Key persistence convention: **SwiftData can't store
arbitrary `Codable` arrays**, so `Transcript.segments` (`[TranscriptSegment]`) and
similar collections are encoded to/from JSON `Data` via computed properties
(`Transcript.segmentsData`). Relationships are set by assigning the parent (e.g.
`Recording(meeting:)`) — SwiftData maintains the inverse, so never append to the
parent collection manually. `Recording.transcriptionCheckpointData` uses the same
JSON-`Data` pattern to persist a `TranscriptionCheckpoint` (see "Resumable
transcription" below), and `Transcript.pipelineReportData` to persist the run's
`PipelineReport` (H5 PR 11) — which engine each stage was asked for, which one
ran, and whether it succeeded, degraded, was skipped or failed. It is optional
and `nil` means *unknown*, never *clean*: transcripts written before it existed
have no report. It carries only closed vocabularies and engine `rawValue`s, no
free text, so it stays exportable in diagnostics.

Organization is layered on top of `Meeting` rather than replacing the aggregate
root:

- `isFavorite: Bool` and `archivedAt: Date?` (`isArchived`) are plain fields on
  `Meeting`; `MeetingsLibraryBucket`/`LibrarySelection` (`Models/LibraryEnums.swift`)
  bucket meetings into All/Inbox/Favorites/Archive.
- `Folder` (`Models/Folder.swift`) — one folder per meeting (`Meeting.folder`,
  `.nullify`, so deleting a folder detaches rather than deletes its meetings).
  Self-referential `parent`/`children` support subfolders, with breadcrumb
  drill-down navigation (`Views/FolderSidebarView.swift`, driven by a
  `NavigationStack(path:)` of drilled-into folders). Icon/color are picked from
  the curated lists in `FolderCatalog.swift` (`FolderIconCatalog`,
  `FolderColorPalette`) via `Views/FolderFormView.swift`, so free-form
  icon/hex entry can't produce an invalid symbol or color. `FolderPickerView`
  mirrors the same drill-down to move a meeting into a folder.
  `FolderSidebarView` itself is host-agnostic — it only depends on a
  `Binding<LibrarySelection>` — so `ContentView` presents it two ways off the
  same binding: a sheet on compact width (from `MeetingsListView`'s toolbar,
  unchanged) and, on regular width (iPad, Mac Catalyst), a persistent
  `NavigationSplitView` sidebar column.
  `selection` lives on `ContentView` for both paths, so `MeetingsListView`
  holds it as a `@Binding` rather than owning it; `MeetingsListToolbar`'s
  library button is hidden on regular width since the sidebar column already
  shows the same picker persistently.
- `Tag` (`Models/Tag.swift`) — many-to-many via `Meeting.tags` (`.nullify`).
  `AutoTaggingService` (`Services/AutoTaggingService.swift`) can suggest
  existing/new tags from a transcript excerpt through the configured summary
  LLM provider; it's off by default and gated in Settings. Suggestions are
  reviewed in `AutoTagConfirmView` before `MeetingDetailAutoTagging` (a
  `MeetingDetailView` extension) applies them — attaching existing tags by id
  and creating new `Tag` rows for suggested names.
- `MeetingFilter` (`Models/MeetingFilter.swift`) — a `Codable` value type (not a
  `@Model`) ANDing date range, tags, status, summary presence, and duration.
  Used as live UI filter state and as a `SmartFolder`'s persisted predicate.
- `SmartFolder` (`Models/SmartFolder.swift`) — stores a JSON-encoded
  `MeetingFilter` and does not own meetings; `meetings(matching:)` filters an
  in-memory list dynamically, like a saved search rather than a folder.
- `FolderAnalytics` (`Services/FolderAnalytics.swift`) — pure value type
  computing counts/durations/status/tag/speaker breakdowns for a folder or any
  `[Meeting]`, rendered by `Views/FolderAnalyticsView.swift`.

### Audio storage format

Recordings are **always stored as mono AAC at
`AudioRecorderService.storageSampleRate` (24 kHz)**, never at the microphone's
native format. The recorder used to derive its encoder settings from
`inputNode.outputFormat`, which meant a 48 kHz file spending bits on a 24 kHz
band that nothing reads back: every machine consumer resamples to 16 kHz
(`AudioPreprocessor`, `DiarizationPreprocessor`, `VADAudioLoader`,
`SpeakerDiarizer`, `WhisperCppTranscriber`, and Apple Speech / FluidAudio
internally), and the only full-fidelity consumer is `AudioPlayerService`, for
which 24 kHz mono is transparent. Audio is never exported — `MeetingExport`
produces documents only (see "Export formats").

Three things follow from the fixed format:

- **`RecordingSink`** (`Services/RecordingSink.swift`, split out of the recorder)
  owns an `AVAudioConverter` and resamples every tap buffer on its way to the
  file. `AVAudioFile.write(from:)` requires buffers in the file's
  `processingFormat`, so this is not optional — the sample-rate conversion needs
  `convert(to:error:withInputFrom:)`, not the frame-count-preserving overload.
  The converted buffer is also what `onAudioBuffer` hands the live-transcription
  preview.
- **`AudioQuality`** (`Models/CaptureEnums.swift`) is now bit rate only — 64/48/32 kbps,
  defaulting to `.standard` — because the sample rate is no longer a free
  variable. The pairing is what makes the low tier clean: 32 kbps over a 12 kHz
  band is fine, over 24 kHz it artefacts. `approximateBytesPerHour` backs the
  Settings row.
- **A mid-recording input format change no longer invalidates the file.**
  `recoverEngineIfNeeded` rebuilds the tap and the sink's converter for the new
  input and keeps writing to the same `.m4a`; pausing with the
  `recorder.engine_stalled` banner is now only the fallback when that fails.

The capture session's category follows the input, in
`Services/CaptureAudioSession.swift`: the built-in mic records under `.record`,
never `.playAndRecord`. An output route is what makes iOS stream to connected
hearing aids or earbuds and switch them into their streaming program for the
whole meeting, even when the iPhone mic is capturing and nothing is played.
`.playAndRecord` + Bluetooth HFP is kept only when an external input is chosen
or the system route is left alone. `CaptureInputSelection` is the pure,
unit-tested decision.

`Recording.fileSize` caches each file's byte count (`0` = not measured yet, which
is also what lets the field be added without a SwiftData migration plan).
`RecordingRecovery` backfills it during the launch/foreground sweep it already
runs, and `Recording.effectiveBitRate` derives the stored rate from it.

Capture ownership is persisted before the audio file opens. New recordings use
`Recording.id` in their filename and move through `RecordingCaptureState`
(`preparing`, `recording`, `finalizing`, `ready`, `recoveryNeeded`). Playback,
transcription, export, compaction, and enhancement must gate on
`Recording.isReadyForConsumption`. `RecordingFileFinalizer` is the single
production definition of ready: after the sink closes, it reopens the file,
measures duration/bytes, and applies/verifies `.completeUnlessOpen`; both normal
stop and `RecordingRecovery` use it. The simulator cannot observe iOS file
protection, so enforcement is covered by the release device matrix while tests
inject protection failure through the finalizer seam.

**A killed capture keeps its audio through `CaptureJournal`**
(`Services/CaptureJournal.swift`). An `.m4a`'s sample table (`moov`) is only
written when `AVAudioFile` closes, so a process killed mid-recording — swiped
away from the app switcher, jetsammed — used to leave a file full of audio
that nothing could decode, and "recover" could only fail. So the capture file
the engine opens is a `JournaledCaptureFile`: every buffer also goes to an
ADTS stream in `Recordings/Capture/<name>.aac`, which has a header per frame
and no trailer, so it is decodable up to its last whole frame wherever it was
cut. The journal is a safety net, never a reason to lose the recording — one
that fails to open or write is detached and the recording carries on — and
the storage runway counts it (`CaptureJournal.storageMultiplier`).
Write-failure reporting uses a dedicated utility thread owned by
`CaptureJournalFailureReporter`, independent of the main-runloop meter timer.
The render thread only stores an atomic pending flag and signals a semaphore:
no reporting I/O, allocation or lock. The worker records `journal_write_failed`
once per file; poll, pause and close flushes remain idempotent backups. File
deinitialization signals the worker to flush pending failure before exiting;
the worker retains the reporter, not the file. An immediate process kill can
still beat worker scheduling or persistence, but a hung main thread no longer
prevents reporting.
`RecordingFileFinalizer` discards it once the `.m4a` is accepted and never on
a failure. After a kill, `CaptureJournalRepair` remuxes it (passthrough
export, no second lossy generation) into a verified temporary `.m4a` that
replaces the undecodable one; it never replaces a readable file. That runs
from the user's recover action (`RecordingRecovery.retryRecovery`, now
`async`) and on every activation after the sweeps
(`repairFromCaptureJournals`), for `.recoveryNeeded` rows only — which keeps
a live capture's file out of reach — leaving the row `.recoveryNeeded` as
`.interruptedDuringCapture` for the user to confirm. Journals follow their
recording through `AudioFileStore.delete`, `RecordingTrash` and "Delete All
Data". Separately, `RecordingCommandRouter` stops and saves the live
recording on `UIApplication.willTerminateNotification`, which iOS posts to a
background-audio app swiped away from the app switcher; when it does, the
recording finalizes normally and needs no recovery at all.

`RecordingCompactor` (`Services/RecordingCompactor.swift`) re-encodes
already-transcribed recordings down to the current quality, for libraries
recorded before the fixed format. It is user-triggered from Settings → Storage
via `RecordingCompactionViewModel`, never automatic, and is the app's only
destructive operation that isn't an explicit delete — so: only
`transcriptionStatus == .done` recordings (anything else is still going to be
read by the pipeline, and a checkpointed resume would be corrupted), only files
more than `minimumExcessRatio` above the target, never upsampling, no DSP chain
(the diarizer reads this file and depends on natural timbre), and a re-encode to
`kurn_compact_*` in the temp directory that is verified (frames rendered, then
decodable and long enough) and `RecordingProtection`-stamped before
`replaceItemAt` swaps it in. Any failure leaves the original untouched.

`OfflineAudioRenderer` (`Services/Pipeline/OfflineAudioRenderer.swift`) is the
shared offline manual-rendering loop behind `AudioPreprocessor`,
`DiarizationPreprocessor` and the compactor. Reading the app's own AAC files
**must** go through an `AVAudioEngine` player-node render — `AVAudioFile.read`
and `AVAudioConverter` both fail on them with a generic "erro 0" on device.
`VADAudioBufferReader` owns the synchronous pull-render loop; keep it in sync
with `OfflineAudioRenderer`. `VADAudioLoader.monoSamples` accumulates its output
for callers that still need an array; `VADAudioChunkReader` instead delivers
bounded sample chunks. The heuristic `SpeakerDiarizer` retains only per-100ms
features, not the decoded recording, preserving its frame boundaries and
strictly-greater-than-one-third trailing-frame threshold.

Silero `FluidAudioVAD` uses `VADProbabilityReader` to await inference between
4096-sample chunks from the same continuous mono render. It carries the SDK's
recurrent model state across chunks and retains one probability per chunk.
It ignores streaming start/end events and applies the SDK's original offline
segmentation to those probabilities, preserving padding, maximum-duration splits
and end-of-file handling. Raw decoded audio is bounded to chunk/render buffers;
probabilities, heuristic features and output regions still grow with duration.

Both loops create engines through `OfflineAudioEngine`, enabling offline manual
rendering on the stopped engine before attaching nodes or accessing the mixer.
`AVAudioEngine.h` recommends this order: early mixer/I/O-node access can configure
device rendering. This keeps offline setup off the device-rendering path implicated
by a RemoteIO teardown RPC that aborted a test host at the manual-mode switch.

### Secure local storage for recordings

Audio files live in `Documents/Recordings/` (not `Documents/` itself) with
`FileProtectionType.completeUnlessOpen` set on the directory so new `.m4a`
files inherit it. iOS wraps each file's AES key with a key derived from the
device passcode, so the bytes are unrecoverable from a backup or extraction
without the passcode. `.completeUnlessOpen` (rather than `.complete`) is
chosen so an in-progress recording survives the screen locking mid-meeting.

`RecordingProtection` (`Infrastructure/RecordingProtection.swift`) owns the
directory setup, the per-file attribute application, and the one-shot
migration of any legacy `.m4a` left in `Documents/` from older versions —
called from `RecordingRecovery.recoverOrphans` at launch. Every read path
resolves files through `AudioFileStore.resolveURL(fileName:)`, which prefers
the protected directory and falls back to `Documents/` for any
not-yet-migrated leftovers.

A separate access layer, `RecordingAccessGate`
(`Services/RecordingAccessGate.swift`), guards the app behind
`LAContext.evaluatePolicy(.deviceOwnerAuthentication, ...)` (Face ID /
Touch ID / passcode) once per foreground session, re-locking on every
`scenePhase == .background` transition. Disabling
`AppSettings.requireAuthForRecordings` (Settings → Recording) turns off the
prompt while leaving the on-disk encryption in place.

**The lock is a window, not a view branch** — and that distinction is the
whole design. It used to be `if isLocked { LockedRecordingsView } else { … }`
inside `MeetingsListView` (and a second copy in `DocumentsListView`), which
conflated "what is visible" with "what exists in the hierarchy": every
`.sheet` attached to the unlocked branch was *destroyed* on lock. That made
protecting content and preserving the user's work mutually exclusive, one
sheet at a time — keeping the Settings sheet inside the branch discarded an
in-progress template edit and reopened at the Settings root, while moving it
out preserved the edit. Moving the *wrong* ones out (meeting detail, the Ask
chat, share) silently removed the only thing keeping a pushed transcript off
the screen of a borrowed unlocked device, since `MeetingDetailView` has no
gate of its own.

So the cover now lives above everything, in its own `UIWindow`:

- `SecurityCoverState` (`Infrastructure/SecurityCoverState.swift`) is the pure,
  unit-tested decision — `.hidden` / `.privacy` / `.locked` resolved from scene
  phase plus gate state. A non-active scene always wins, so even a locked app
  shows the neutral privacy cover mid-transition, which is what the
  app-switcher photographs. Only `.locked` takes key window status, because
  only it has controls and a keyboard to feed.
- `SecurityCoverWindow` (`Views/SecurityCoverWindow.swift`) owns the
  window at `UIWindow.Level.alert + 1` and the `securityCover(…)` modifier
  `KurnApp` attaches. It hides rather than tears down, and learns its
  `UIWindowScene` from a `didMoveToWindow` probe rather than guessing through
  `connectedScenes`.
- `SecurityCoverView` (`Views/SecurityCoverView.swift`) renders
  `PrivacyCoverView` or `LockedRecordingsView` and hosts the Settings escape
  hatch — required because a device with no passcode configured can never
  authenticate, and nothing below the cover window is reachable. The hatch is
  offered **only** in that case (`RecordingAccessGate.offersSettingsEscapeHatch`)
  and is a minimal screen holding the require-authentication toggle alone,
  never the full `SettingsView`: anything reachable from the lock screen is
  reachable without authenticating, so it must not read meeting content,
  change where content is sent, or destroy it.

Being past the lock once is not enough for changes that weaken it or redirect
content. `SensitiveActionAuthorizer` (`Services/`) re-authenticates — when
`requireAuthForRecordings` is on — before turning the lock off, saving or
adding a provider (its key or base URL decides where transcripts go), "Delete
all data", and the store-recovery shell's salvage/restore/fresh start, which
run before the cover exists. A device with no passcode is authorized (there is
no protection to preserve); a dismissed prompt is a no-op, not an error. New
actions of the same kind should go through it rather than a bare tap.

Two consequences worth keeping: sheet placement in `MeetingsListView` is no
longer a security decision (nothing is torn down, so presentations go wherever
reads best), and the cover closes a gap the old `PrivacyCoverView` `ZStack`
sibling never could — a presented sheet renders *above* the root view, so the
app-switcher snapshot used to capture the Ask chat's transcript excerpts.

`RecordingRecovery` also no longer deletes unreadable orphans ≥1 MB outright.
`AudioRecorderService` separately recovers from
`AVAudioEngineConfigurationChange` (e.g. the engine bouncing when the device
locks) by restarting in place, or pausing with a banner if the audio format
changed.

### Playback

`AudioPlayerService` (`@MainActor @Observable`, one per `MeetingDetailView`)
wraps a single `AVAudioPlayer`, and owns two things beyond it.

`Services/Playback/NowPlayingController.swift` publishes to
`MPNowPlayingInfoCenter` and accepts `MPRemoteCommandCenter` commands
(play/pause/toggle, ±15 s, scrub). This is not optional polish: the app declares
`UIBackgroundModes: audio`, so without it playback continues when the screen
locks with **no controls and no metadata** anywhere — Lock Screen, Control
Centre, Dynamic Island, AirPods stem, CarPlay, Watch. Two rules hold it
together: commands are registered on `load` and *removed* on `stop`, because the
command centre is process-wide and a torn-down player must not keep answering
it; and metadata is published only on state changes, never on the player's 0.1 s
tick, because Now Playing extrapolates position from the rate.
`NowPlayingController.info(...)` is split out as a pure builder so the metadata
contract is testable without a Lock Screen.

Audio-session events are handled the same way the recorder handles them — the
player had none of this, so an incoming call left `isPlaying` true over a
stopped player: interruption `.began` pauses and `.ended`+`.shouldResume`
resumes, `.oldDeviceUnavailable` pauses (unplugging headphones must not dump a
meeting into the speaker), the category mode is `.spokenAudio` rather than
`.default`, and `stop()` deactivates the session with
`.notifyOthersOnDeactivation` so whatever was playing before can resume.

### Enhanced playback copies

Playback can use a second, derived `.m4a` per recording — loudness-normalized,
equalized and gently compressed — rendered offline by
`Services/Enhancement/PlaybackEnhancementRenderer.swift` and generated **on
demand**, the first time the user turns enhancement on for that recording.
Doing it offline is what keeps `AudioPlayerService` on `AVAudioPlayer`: the
player only picks which URL to open, so there is no realtime graph and no
reimplemented seek.

Two passes, because loudness cannot be known in advance. The first measures
integrated loudness to ITU-R BS.1770-4 (`Services/Enhancement/LoudnessMeter.swift`)
**at 48 kHz** — the only rate the standard's coefficients are valid at, so the
measurement pass renders there rather than re-deriving them. The second applies
the resulting gain *at the input*, ahead of the EQ and compressor, which is what
makes the compressor's fixed threshold mean the same thing for every recording
in the library. Tuning lives in `Services/Playback/PlaybackTuning.swift` as a
pure value type so tests can assert it stays gentler than the ASR chain in
`AudioPreprocessor` — different job, different ears.

**Copies live in `Documents/Recordings/Enhanced/` under the same file name as
the original, never beside it with a suffix.** Every existing sweep over the
recordings directory is shallow, so a nested directory is invisible to all of
them by construction. A suffixed copy would be worse than deleted:
`RecordingRecovery` parses the meeting ID from the name prefix, so it would be
adopted as a second `Recording` and shown in the library as a duplicate. The
same choice means adding the directory to `AudioFileStore.delete(fileName:)`'s
search list makes every existing deletion path drop the copy with the original,
without any caller knowing the copy exists. `AudioFileStore.enhancedDirectoryPath`
only computes a URL; `ensureEnhancedDirectory()` is the creating variant and is
called only by the writer, because `delete` runs in a loop and creating plus
re-stamping a directory on every iteration is filesystem work for nothing.
The derived copies can also be reclaimed together from Settings → Storage;
the original recordings and their transcripts remain untouched.

`Recording.enhancedAudioVersion` (`0` = none) doubles as an existence and a
staleness check against `PlaybackEnhancementRenderer.currentVersion`; bump that
constant when the tuning changes and existing copies regenerate instead of being
served. `AudioPlayerService.load(fileName:enhanced:)` keeps `loadedFileName`
reporting the **logical** recording name — the whole UI keys row-to-player
identity off `player.loadedFileName == recording.fileName`, so the variant must
stay an internal detail of which URL to open.

The chain is preceded by a neural denoise pass
(`Services/Enhancement/PlaybackEnhancementNeuralPass.swift`) running streaming
GTCRN, converted from its official PyTorch checkpoint by `Tools/gtcrn/` (macOS +
`coremltools`) and driven frame by frame by `SpeechEnhancer` over the existing
`Pipeline/STFT.swift`. GTCRN is small enough to run over complete meetings, so
there is no duration cutoff.

**Running with no model installed stays a supported configuration**, not a
degraded one: `SpeechEnhancer` returns `nil`, `renderNeuralMix` returns `nil`,
and the DSP chain renders the source directly. Denoising is the smaller half of
making a far-table voice audible — it removes the noise *around* a quiet talker
without making the talker louder, which is the compressor's and the loudness
normalization's job.

The model is 16 kHz, so the pass is **decode → enhance → resample → mix**, file
backed at every step (Float32 `.caf` in the temp directory) so memory stays
bounded by one 4096-frame block rather than the whole meeting. Four things about
it are load bearing:

- **The dry/wet sum** (`PlaybackTuning.wetMix`, 0.85) is not a hedge against the
  model. It restores the 8–12 kHz band a 16 kHz model cannot represent, which is
  otherwise simply gone from the enhanced copy.
- **`latencyFrames` is the number a mistake in is audible.** GTCRN's online
  overlap-add retains its first hop and flushes its final hop, so its file output
  is already aligned and reports zero. `SpeechEnhancerTests` still substitutes
  an enhancer that inverts its input and cross-correlates the rendered result
  against the source, so an alignment regression fails end to end.
- **A short wet tail is tolerated, not fatal.** Three stages each round their
  frame count, so the wet stream can end a few frames before the dry. Those
  frames are left dry and logged; throwing would discard the entire neural pass
  and silently revert to DSP-only over a rounding difference.
- **`STFT` uses GTCRN's exact framing:** a 512-sample square-root Hann analysis
  and synthesis window with a 256-sample hop. The squared windows overlap-add to
  one; using the diarization path's analysis-only Hann would amplitude-modulate
  the enhanced stream.

`ModelStoreProtection` (`Infrastructure/ModelStoreProtection.swift`) applies
the same `.completeUnlessOpen` file protection to the SwiftData store itself
(`default.store` plus its `-shm`/`-wal` sidecars in Application Support),
since transcripts and summaries live there as JSON `Data`. It must run before
the `ModelContainer` is created and is a no-op on a fresh install with no
store file yet. Despite the similar name, it is unrelated to `ModelStore`
(below), which manages downloaded FluidAudio model files, not app data.

**All meeting-derived persisted data is encrypted at rest by this same
mechanism.** The semantic-search index (`SemanticChunk` — passage text plus its
embedding `vectorData`) and any future chat-history model are `@Model`s in the
one app store, so they inherit `.completeUnlessOpen` automatically. The rule
this imposes: never write vectors, transcript-derived text, or chat content to a
loose file, a cache directory, or `UserDefaults` — keep it in the SwiftData
store. Embedding vectors are stored in-store as raw `Float32` `Data`
(`Infrastructure/Extensions/VectorData.swift`), deliberately not in a separate
on-disk vector file, precisely so no unprotected sidecar is introduced.

### Transcription pipeline (`Services/TranscriptionService.swift`)

Each stage is a protocol seam (`Services/Pipeline/PipelineStages.swift`:
`AudioPreprocessing`, `VoiceActivityDetecting`, `LanguageDetecting`,
`Transcribing`, plus `Diarizing` in `TranscriptionTypes.swift`) so the engine per
stage is swappable without touching the orchestrator. `PipelineConfiguration`
(built from `AppSettings`) picks one engine per stage; all defaults except the
FluidAudio diarization preference are no-download engines. Unconsented neural
diarization falls back to the heuristic so a fresh install works offline.
`TranscriptionService` holds reusable engine/router instances; non-default
FluidAudio ASR managers and weights have per-chunk lifetimes. The concrete choices per
stage (enums in `Models/PipelineEngines.swift`; `TranscriptionEngine` in KurnCore) are:

| Stage              | `AppSettings` property    | Default preference                                                                                                                                                            | Alternative (model download)                                                                                                                                                                             |
| ------------------ | ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Preprocessing      | `preprocessingEngine`     | `.standardDSP` (`AudioPreprocessor`)                                                                                                                                             | `.none` (passthrough — not FluidAudio, just skips cleanup)                                                                                                                                               |
| VAD                | `vadEngine`               | `.energyThreshold` (`Pipeline/EnergyVAD.swift`)                                                                                                                                  | `.fluidAudio` (`Pipeline/FluidAudioVAD.swift`, Silero VAD)                                                                                                                                               |
| Language detection | `languageDetectionEngine` | `.byTranscriber` (no-op, defers to the transcriber)                                                                                                                              | `.fluidAudioLID` (`Pipeline/LanguageDetectors.swift`'s `FluidAudioLanguageDetector`, transcribes a 60s prefix with FluidAudio Parakeet and classifies it with `NLLanguageRecognizer`)                    |
| Diarization        | `diarizationEngine`       | **`.fluidAudio`** (`FluidAudioDiarizationRouter`; default `.pyannote` uses `FluidAudioDiarizer` / `OfflineDiarizerManager`) — the one stage whose default *does* need a download; see "Choosing the diarizer" below | `.heuristic` (`SpeakerDiarizer`, pitch/timbre clustering) or `.transcriptionProviderNative` (speaker turns from the `.whisperAPI` provider's own response, e.g. ElevenLabs Scribe) are the no-download alternatives; `.sherpaOnnx` downloads its own model pair (`SherpaOnnxModelDownloader`, gated by `sherpaOnnxModelsConsented`) |
| Transcription      | `transcriptionEngine`     | `.appleSpeech` (`OnDeviceTranscriber`, fixed device locale)                                                                                                                      | `.fluidAudioParakeet` (the stored engine ID for all six FluidAudio ASR choices; default Parakeet v3), `.whisperCpp` (`Pipeline/WhisperCppTranscriber.swift`, Whisper on device via whisper.cpp) or `.whisperAPI` (cloud, any provider whose `AIProvider.supportsTranscription` is true — OpenAI's `whisper-1`/`gpt-4o-transcribe`/`gpt-4o-mini-transcribe`, Groq, ElevenLabs Scribe, or a custom OpenAI-compatible endpoint) |
| Correction         | `correctionEnabled`       | `.none` (`NoOpTranscriptCorrector` — returns the input with no allocation or network work)                                                                                       | `.llm` (`Pipeline/LLMTranscriptCorrector.swift`, cloud LLM pass over the fused segments; off by default, see "LLM transcript correction" below), preceded by a topic/vocabulary critique, `Pipeline/TranscriptTopicAnalyzer.swift`)                                                          |

**FluidAudio has a model axis, not new engine IDs.** The KurnCore catalogs
`FluidAudioASRModel`, `FluidAudioLiveModel`, `FluidAudioDiarizationModel`, and
`FluidAudioSegmentationBatchSize` are persisted by `AppSettings` as
`fluidAudioASRModel`, `fluidAudioLiveModel`, `fluidAudioDiarizationModel`, and
`fluidAudioSegmentationBatchSize` under the matching `settings.*` keys.
Missing/unknown selections default to `.parakeetV3`, `.automatic`, `.pyannote`,
and `.maximum` (32). Existing engine raw values and defaults are unchanged;
never migrate `.fluidAudioParakeet` to a model-specific engine string.

| ASR case | Runtime mapping | Language contract |
| --- | --- | --- |
| `.parakeetV3` (default) | Existing `FluidAudioTranscriber` / shared `FluidAudioModelStore`, `AsrModelVersion.v3` | 25 European languages + Auto |
| `.nemotronUnified` | `FluidAudioModelTranscriber` → `UnifiedAsrManager`, fp16 offline encoder | Same 25 + Auto; generic `pt`, no detected-language code returned in Auto |
| `.bark3`, `.bark3Clean`, `.phonon2` | `FluidAudioModelTranscriber` → versioned `AsrModels.loadLocal` / `AsrManager` | Explicit English only; Auto unsupported |
| `.nemotronTranscribeLite` | `FluidAudioModelTranscriber` → `NemotronTranscribeLiteModels` / manager, CPU + ANE | Explicit English only; Auto unsupported |

`FluidAudioRuntimePolicy` owns backend selection, language and installation
validation, and resource/error policy; `FluidAudioPipelineSelection` owns model
sets and checkpoint identity. Settings disables incompatible ASR choices and the
pipeline checks again before inference. An Auto recording is not an exception
for an English-only model. `TranscriptionLanguageSupport` uses the selected ASR
family, not the legacy engine name. The full language set is in
`docs/supported-languages.md`; `pt` does not imply validated Brazilian Portuguese
quality. Optional FluidAudio LID still uses Parakeet v3 independently of the
chosen batch/live model and requires the existing batch-v3 consent.

`TranscriptionService.transcribe` drives the stages in order:

1. **Preprocess** audio with the selected engine (`AudioPreprocessor` or a
   passthrough); on any failure it falls back to the original file so
   transcription never breaks. `AudioPreprocessor` runs **two passes**: the first
   renders the EQ'd signal into a `SpeechLevelMeter`
   (`Services/Pipeline/SpeechLevelMeter.swift`, O(1) memory) and the second applies
   the chain with the makeup gain that measurement implies. The chain used to lift
   every recording by a fixed +11 dB (a +8 dB makeup on top of the limiter's +3 dB
   pre-gain), which drives an already-healthy recording into near-constant limiting
   — and that distortion is the kind of artefact recent work finds *degrading*
   modern ASR rather than helping it. The gain decision itself
   (`SpeechLevel.makeupGainDB`) is pure and unit-tested: target speech at -20 dBFS
   RMS, never push the measured peak past -3 dBFS, clamp to 0…18 dB, never
   attenuate. Because the level is measured *before* the dynamics stage pulls peaks
   down, the peak bound is conservative by design — it errs quiet, and the limiter
   (now pre-gain 0, safety only) catches the rest.
2. **Detect language** (only surfaced as a phase when a real detector runs; the
   default no-op detector defers to the transcription engine).
3. **Detect speech** (VAD) — drives both silence-gating of the transcription
   input and the heuristic diarizer's segmentation.
4. **Transcribe + diarize** — concurrent (`async let`) for Whisper, since cloud
   transcription keeps almost nothing on-device; sequential for on-device
   engines, because running a large ASR model alongside the diarizer over a
   long recording can push peak memory past the jetsam limit. Diarization reads
   its own cleaned copy (`DiarizationPreprocessor`, minimal DSP preserving
   natural timbre) rather than the ASR-tuned one, unless
   `diarizationPreprocessingEnabled` is off. That cleanup intentionally remains
   limited to the fast high-pass, stationary spectral subtraction and peak
   normalization stages, so cleanup does not block speaker separation.
   See "Diarization accuracy" below for how the `.fluidAudio` engine's speaker
   count is controlled and repaired.
5. **Fuse** transcript spans with speaker turns into `[TranscriptSegment]`
   via the pure, unit-tested `Pipeline/TranscriptFusion.swift`. A span is
   attributed to the speaker holding the most of its *duration* (not the
   speaker whose turn contains its midpoint — a sub-second turn under the
   midpoint would otherwise take the whole utterance), then consecutive
   same-speaker spans are merged, capped at 30s. Group bounds are the earliest
   start and latest end, not the first and last word's times: providers can
   return slightly reordered word timings, and text must keep its original
   order. Malformed individual spans stay visible to the integrity gate rather
   than being hidden by merging. Same-speaker pauses of at least 1.5s start a
   new block. At the duration cap, fusion looks back for a sentence ending
   (including non-Latin punctuation and closing quotes), then a pause of at
   least 0.5s, in the latter half of the block; with no natural boundary it
   breaks at the span boundary. Speaker changes always take precedence.
   `splitCoarseSpan` distributes a long span's words across turns proportionally
   when it crosses a handover; with word timestamps now available (below) it is
   the fallback, not the normal path.
6. **Correct** (opt-in) — an LLM pass over the already-fused, speaker-attributed
   segments, fixing spelling, punctuation and homophones. Skipped entirely when
   `effectiveCorrection == .none`, which is the default.
7. **Validate** with `TranscriptIntegrityGate` before returning anything to the
   save path. `diagnose` preserves the existing failure codes and 30s bounds
   slack, adding a closed-vocabulary detail and segment index to local logs —
   never text, speaker identity or timestamps. Rejected output cannot replace
   an existing transcript.

#### LLM transcript correction

The only pipeline stage that runs *after* fusion, and the only one that can be
enabled without a model download but still needs the network. It is off by
default because it makes paid cloud LLM calls on every transcription.

`TranscriptCorrecting` (`Pipeline/PipelineStages.swift`) states the contract
every conformer must honor, and the contract is the feature: **never throw,
always return `segments.count` segments in the same order, and only ever touch
`.text`.** A correction stage that could drop, merge or reorder segments would
invalidate every timestamp, speaker attribution and `[mm:ss]` citation
downstream of it, so those properties are not left to the prompt.

Since H5 PR 11 it returns a `TranscriptCorrectionResult` rather than a bare
array: the segments plus a `PipelineStageOutcome`/`PipelineStageReason`, because
"no provider", "nothing eligible" and "ran clean" used to be the same value
(the input, unchanged) and therefore indistinguishable in the stored
transcript.

- **Enablement is a pair**, like `effectiveDiarization`: `effectiveCorrection`
  returns `.llm` only when `correction == .llm` *and* `correctionConsented`. The
  gate differs though — here it means "is this usable right now" (the correction
  provider has a key in the Keychain), not "has the user agreed to a download".
  This stage has no local model.
- **A critic reads the transcript first.** Before any batch,
  `TranscriptTopicAnalyzer` makes one LLM call acting as a critic: it reads a
  sample of the ASR result (KurnCore's `TopicAnalysisExcerpt` — whole segments
  from the start, middle and end, ≤ 8,000 characters, so cost does not scale
  with length), infers the topic and domain, and criticizes the vocabulary
  against them — domain `key_terms` spelled correctly, and
  `likely_mishearings` (`heard` → `intended`) for words that make no sense for
  the subject. KurnCore's `MeetingTopicProfile` bounds the reply (over-long
  strings dropped, not cut; lists deduplicated and capped) and **grounds** it:
  a finding whose `heard` form does not occur in the transcript is discarded
  as invented. This replaced a frequency-list-only corrector that did not move
  WER measurably: the frequency list (below) can only fix a term the ASR got
  right *somewhere*, while the critique can name one it got wrong every time.
  A failed critique still corrects with the meeting's own vocabulary and
  reports the stage `.degraded` / `.topicAnalysisFailed`; failing batches
  outrank it.
- **Which segments are sent combines confidence and the critique.**
  `isEligible` skips empty text, and marks a segment when it carries no
  confidence signal at all (Apple Speech and FluidAudio Parakeet expose no
  per-token probability, so "can't rule it out") or a Whisper confidence below
  `lowConfidenceThreshold` (0.85); outright hallucinations were already dropped
  by `TranscriptQualityFilter` before fusion. `candidates(in:flaggedBy:)`
  (`LLMTranscriptCorrector+Context.swift`) adds any confident segment
  containing a flagged form — a confident decode of the wrong word is what
  confidence alone cannot catch. Each segment is sent with its rounded
  confidence and ≤ 160 characters of the neighbouring segments' text
  (`before`/`after`, read-only), so a word is judged in the conversation it was
  said in.
- **Batching** greedy-packs segments
  bounded by both `maxBatchChars` (6,000) and `maxSegmentsPerBatch` (40), never
  splitting a segment.
- **Vocabulary.** `MeetingVocabularyExtractor` (`Pipeline/`) collects the
  meeting's *own* recurring proper nouns, acronyms and terms with digits
  (`minOccurrences = 2`); `CorrectionVocabulary.merge` puts them ahead of the
  critic's inferred terms. The list is sent once per request and not counted
  against `maxBatchChars`; the critic's profile rides along as a `topic` object
  with `topicGuidance` appended to the prompt, which tells the model the
  findings are a reviewer's hypotheses to apply only where a segment sounds
  like them.
- **Faithfulness is enforced in code, not left to the prompt.** On top of the
  magnitude guardrail and id-based application below, KurnCore's
  `CorrectionFaithfulness` accepts a correction only if every word it
  introduces is a respelling of a word the ASR wrote (normalized edit distance
  ≤ 0.45, near-exact for words of ≤ 3 letters), of two adjacent words joined
  ("cuber netes" → "Kubernetes"), part of a word split apart, or one of the
  grounded terms. "by Friday" appended to a sentence is rejected even when the
  guardrail's 35% budget would allow it. Measured on 2026-11-05
  (`docs/pipeline-evaluation.md`) on Nemotron Unified, where no confidence
  means every segment is sent: no measurable gain over the corrector it
  replaced (English still +0.54pp worse than no correction, Portuguese
  −0.38pp), so make no accuracy claim for the stage.
- **`TranscriptCorrectionGuardrail`** bounds how far a proposed correction may
  drift before it is rejected: `maxWordChangeRatio` 0.35, `maxLengthRatio` 1.5,
  `minLengthRatio` 0.6 — a plausible spelling fix, not a paraphrase, invention,
  or emptied segment. It deliberately does **not** reuse
  `KurnTests/Support/Evaluation/`'s `WordErrorRate`/`TextNormalizer`: those are
  test-target-only, and `TextNormalizer` must never touch stored or displayed
  transcript text. The guardrail works on raw, unnormalized strings and only
  needs to bound the *magnitude* of a change, not produce a comparable metric.
- **Application is by id lookup.** `apply(corrections:to:faithfulTo:)` walks
  the original array and replaces `.text` only where the id matches and the
  guardrail (and, as `correct` always asks, the faithfulness check) accepts. A missing id, a rejected correction, or an id matching no segment all
  leave the original untouched — which is what makes the "can't drop, merge or
  reorder" guarantee structural rather than a prompt instruction.
- **It fails open at every level.** `parseCorrections` reuses `ModelJSON`'s
  tolerant fence/prose stripping (the same parser the auto-tagger uses);
  any JSON failure yields an empty map, so that whole batch silently leaves its
  segments unchanged rather than failing the transcription.

#### Word timestamps

Three engines report per-word timings and used to discard them; all four now
feed `TimedWordSpanBuilder` (`Services/TranscriptionTypes.swift`), which
FluidAudio already used. This is what lets `TranscriptFusion` place a speaker
handover *inside* a sentence instead of estimating the split from turn
durations (`splitCoarseSpan`, now the fallback).

| Engine       | Where the timings come from                                                                                                                                                |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Apple Speech | `audioTimeRange` per `AttributedString` run, which the `.timeIndexedProgressiveTranscription` preset attaches. `String(result.text.characters)` used to flatten it away    |
| whisper.cpp  | `params.token_timestamps`, then `whisper_full_get_token_data`'s `t0`/`t1`; SentencePiece pieces are aggregated into words (a piece beginning with a space opens a new one) |
| Cloud        | `timestamp_granularities[]` = `segment` + `word`, returned as a **flat top-level array** that `OpenAIProvider` regroups under the segment each word's midpoint falls in    |

FluidAudio TDT and Unified use their native token timings. Transcribe Lite
reports only word starts; `FluidAudioWordTiming` estimates each end from the
next start but caps it at 1.5s (40ms for a backward-start fallback), always within
the chunk. A pause or trailing silence must not become part of one word and
steal its speaker attribution. The end estimates are not exact word alignments.

Two rules hold across all of them. **Missing timings are never an error** —
each engine falls back to exactly the span it produced before. And Apple's
timings are checked against the result's own range before being trusted:
timings on a different timeline would read as a correct transcript with every
word near zero, which nothing downstream could detect.

`timestamp_granularities[]` is an OpenAI extension a compatible endpoint need
not implement, so a `400`/`422` retries the upload once without it — losing word
timings to an old endpoint is acceptable, losing the transcription is not.

**A model that only speaks plain `json` reports no timings at all, not
degraded ones.** `gpt-4o-transcribe`/`gpt-4o-mini-transcribe` don't support
`timestamp_granularities[]`, so `OpenAIProvider` used to return one
zero-length (`start: 0, end: 0`) span per chunk — every word of up to ten
minutes sitting on one instant, which `TranscriptFusion` then handed in its
entirety to whoever held the floor at that instant (measured as 100% fused DER
on AMI). `WhisperTranscriber.spreadingUntimedSpans` detects an
all-zero-duration result (`hasOnlyUntimedSpans`) and gives it the chunk's own
duration, split evenly across its spans in order, before fusion ever sees it —
still an estimate, like any engine without real word timings, but an
attribution rather than none. Text is never touched.

Zero-duration word timings are retained when the provider actually supplied a
finite, nonnegative instant; they still carry real text. Invalid sentinel tokens
and words entirely outside the supplied range do not become invented timings.
Cloud word indices are assigned to at most one segment, including shared or
overlapping segment boundaries, so expansion cannot duplicate the same word.

#### Where chunks are cut

Before the shared chunk runner adds an offset or saves a checkpoint,
`ChunkTimestampNormalization` validates spans and native speaker turns against
that chunk's ownership duration. It repairs only bounded drift (at most 1s
before zero, a 0.1s inversion, or trailing padding within the existing integrity
gate's 30s slack); gross outliers and non-finite times fail explicitly through
the existing localized integrity error. Text, order, confidence and speaker
labels are preserved. Exported chunks use their planned lengths, not accumulated
AAC padding; unmodified chunks carry measured duration. Resumed checkpoint spans
are revalidated without another upload or a schema change when usable; an
unusable checkpoint is declined with a logged reason and the run starts fresh,
rather than failing on the same cached data on every retry. These policies run
in KurnCore tests without audio models or the network.

`ChunkBoundary` (bottom of `Services/AudioChunker.swift`) moves each nominal
boundary to the nearest silence within 30 s, subject to a minimum chunk length,
and leaves it alone when there is none. A fixed grid cut wherever 5 or 10
minutes landed — mid-word far more often than not, and a boundary is also a
decoder restart, which is the condition Whisper invents text over.

The candidates come from `TranscriptionService`, because only it knows which
timeline the engine will see: **not** the original one when VAD compaction ran,
in which case the safe cuts are the gaps the compactor itself wrote
(`CompactionResult.map`), not the original speech regions. The chooser is pure
and must stay deterministic — a resumed transcription reuses its checkpoint only
when the chunk plan comes out identical, so a boundary that wandered between
runs would silently discard every completed chunk.

Remapping compacted-timeline spans back to the original timeline
(`TranscriptionService`) must remap the provider's own `speakerTurns` with
them, not just the text spans — rebuilding the transcript from spans alone
silently dropped `speakerTurns`, so `.transcriptionProviderNative` fell back to
one synthetic speaker for the whole meeting whenever VAD compaction ran
(measured on AMI with ElevenLabs: 64% raw DER instead of ~18%). The same
per-chunk loss applied across `ChunkedTranscriptionRunner`'s chunk boundaries
until it started accumulating `speakerTurns` alongside spans (offset per
chunk, kept out of the durable `Progress` checkpoint on purpose — a resumed
run then only carries native diarization for the chunks it actually
re-transcribes, which is a lesser degradation than losing every chunk's turns
outright).

#### Choosing the diarizer

The default is `.fluidAudio`, and it is the only stage default that needs a
download. `.heuristic` — three scalars and one greedy nearest-centroid pass, one
speaker per VAD region — was what every user got who never opened Settings.

The selection is a **pair**: `PipelineConfiguration.effectiveDiarization`
reads `diarization` together with the selected model's `diarizationConsented`
and steps back to `.heuristic` until consent exists, with
`diarizationFellBack` saying that it did. Runtime loading is local-only; a
consent flag is not proof that the weights are still present or healthy.
Missing/corrupt diarization models produce visible model-preparation degradation
and a user download/repair action, not an automatic fetch.

That report is the other half. A user who never opens Settings never consents,
so without it "the default is now neural" would describe a setting rather than a
behaviour — which is why the transcript's diarization warning banner
(`MeetingDetailView`) carries the download action, and why
`ModelDownloadController` moved from `SettingsView` to `KurnApp`.

Within `.fluidAudio`, `FluidAudioDiarizationRouter` dispatches `.pyannote`
(the default) to the existing `FluidAudioDiarizer`, and `.nemotron3` to
`FluidAudioNemotronDiarizer`. Nemotron uses `Nemotron3Config.fast32`, supports
at most eight speakers, and has no exact-count constraint or compatible
speaker voiceprints. Its probabilities are accumulated by KurnCore's
`NemotronDiarizationTimeline` into bounded source-timeline turns. Do not infer
that its "fast32" profile is an iPhone speed benchmark.

Nemotron reads through `VADAudioChunkReader`, keeping decoded audio to one model
chunk plus the 4096-frame render buffer and the engine's converter buffers.
One continuous mono render at the model's sample rate preserves resampling state
and sample order across chunks; cancellation and the processing budget are checked
per chunk. Timeline/model state is separate from this decoded-audio bound.

Pyannote alone honors `fluidAudioSpeakerCount` as before. Its segmentation batch
size is user-selectable as 4/8/16/32 via `fluidAudioSegmentationBatchSize`;
32 remains the persisted default and 8 is the recommended memory-reduction
choice. `FluidAudioPyannoteConfiguration` applies this without changing the
existing exact-count/refinement semantics. This is a memory-control setting,
not measured evidence of improved throughput or diarization accuracy.

#### Diarization accuracy

The Pyannote (`.fluidAudio` + `.pyannote`) diarizer's weak point is the speaker count, not the
segment boundaries — its VBx clustering step routinely drives every mixture
weight but one to ~1e-20 on far-field/single-mic audio, so the whole meeting
comes back as one speaker. Four things address that, all outside FluidAudio:

- **`AppSettings.fluidAudioSpeakerCount`** pins an exact count
  (`clustering.numSpeakers`), which makes the library re-cluster the raw
  embeddings with KMeans. It deliberately does *not* set `minSpeakers`: FluidAudio
  decides whether to apply a constraint by comparing the bounds against the
  *pre-clustering* estimate (tens, on any real meeting), so a floor is always
  already satisfied and never engages. Only an upper bound trips.
- **`Pipeline/SpeakerClusterRefiner.swift`** is the automatic rescue used when
  the count is left on Auto. `OfflineDiarizerConfig.exposeChunkEmbeddings` hands
  back the per-window speaker embeddings VBx clustered, so a collapse can be
  undone with no CoreML re-run: re-cluster them (average-linkage AHC, speaker
  count chosen by silhouette), keep the diarizer's own segment boundaries, and
  re-attribute them by overlap-weighted vote. A split is only accepted when the
  cluster centroids are at least `minSpeakerSeparation` apart — the same
  same-speaker calibration FluidAudio's own agglomerative step uses — so a
  genuinely single-speaker recording is left alone.
- **`Pipeline/SpeakerTurnSmoothing.swift`** runs on every Pyannote result:
  merge same-speaker turns across short gaps, absorb sub-second turns into
  their neighbours (the mid-sentence flip), drop speakers with negligible total
  speech. It never returns an empty result for a non-empty input.
- **`FluidAudioDiarizer.processTimeout(forAudioDuration:)`** scales the
  processing budget to the recording. A flat timeout falls back to a single
  whole-clip turn, which reads as "diarization is inaccurate" rather than as
  the timeout it is.

#### Speaker identity

`"Speaker 2"` identifies nobody: the diarizer hands those labels out in order of
first appearance, freshly on every run, so a re-transcription routinely renames
the same voice. `Speaker` rows carry a name the user typed, and keying them on
the label was wrong in both available directions — deleting a row whose label
stopped appearing threw the name away, and keeping it under the old label would
hand that name to whoever the diarizer now calls Speaker 2.

So identity is the voice. `FluidAudioDiarizer` returns a `DiarizationOutcome`
(turns **plus** `voiceprints`) rather than turns alone; `SpeakerVoiceprints`
averages the model's per-window embeddings into one L2-normalized vector per
speaker, computed *after* smoothing and any collapse rescue so it describes the
speaker as finally reported. `Speaker.voiceprintData` persists it through
`VectorData`, in the store, never in a sidecar file.

`TranscriptionCoordinator.syncSpeakers` then reconciles as a total assignment
rather than a diff, **one recording at a time, in `recordedAt` order**: labels
are produced per *recording* (the diarizer numbers them independently on every
run) while `Speaker` is per *meeting*, so a recording's own labels are matched,
via `SpeakerIdentityMatcher`, only against whichever stored rows an earlier
recording in the same sync pass hasn't already claimed. Within one recording's
pass, matching is total — every candidate row against every one of that
recording's labels (the common case is the label set staying the same while
the assignment permutes — matching only what appeared or disappeared misses
exactly that) — voice wins; when there is no compatible voice match, the existing
reconciliation can fall back to this recording's unclaimed labels. A numbered
label is not evidence of voice identity. A row already placed by an earlier
recording can still be *reconfirmed* by a later one's
matching voice rather than relabelled or duplicated. `Recording.speakerVoiceprints`
is what makes this possible: each recording persists its own diarization run's
voiceprints, not just the one that just finished, so a second recording's
"Speaker 1" is judged on its own voice instead of being merged, by label
string alone, into whatever "Speaker 1" a different recording already
produced. Two recordings' independently-numbered same label — or a canonical
label a collision would otherwise create — never collide, since an unmatched
label is assigned the next free `"Speaker N"` rather than overwriting a
row another recording already claimed. The whole mapping across every
recording is applied at once so a swap has no colliding intermediate state.
The same-voice threshold is `SpeakerClusterRefiner.minSpeakerSeparation`,
inherited rather than invented.

Where no compatible voiceprint exists — including Nemotron 3 diarization,
the heuristic engine, or older transcripts — identity cannot be recovered from
a numbered label. **Review speaker names after reprocessing or changing models:**
the legacy label-only fallback may retain a name without confirming the voice.
Nemotron returns turns without voiceprints, so it cannot perform Pyannote-compatible
voice matching or produce cross-meeting voice-match suggestions. Labels already
claimed in a sync pass are never handed to another recording's same-numbered
speaker. `MeetingDetailTabs` filters chips and the speaker list to labels present
in the transcript; typed names are not evidence of a compatible voice embedding.

**Across meetings, identity is suggested, never applied.**
`TranscriptionCoordinator+CrossMeetingSpeakerMatch` asks "have we heard this
voice before, under a name, elsewhere" exactly once per row: when `syncSpeakers`
creates a brand-new `Speaker` from nothing, it compares that row's voiceprint
with every *other* meeting's named, voiceprinted rows through
`SpeakerIdentityMatcher.closestMatch(to:among:)` — a nearest-candidate search
with no label-uniqueness assumption, since `"Speaker 1"` names countless people
store-wide. A hit is staged on `pendingCrossMeetingMatches` and presented by
`CrossMeetingSpeakerMatchView` for the user to confirm or dismiss, the same
"suggest, never apply silently" shape as `AutoTagConfirmView`. It is
self-limiting: later re-syncs find the row through intra-meeting voice
matching and never reach the creation step again, so a dismissal is final
rather than a repeated nag. Only names the user already typed somewhere are
candidates; calendar attendees as candidate names are an open roadmap item.

#### Whisper hallucination filtering

Whisper's failure mode is not a wrong word, it is a fluent invention over
silence, music or noise — often the same sentence looped — with nothing in the
text to distinguish it from a real one. The decoder does report its doubt, so
both Whisper engines run their spans through
`Pipeline/TranscriptQualityFilter.swift` before returning:

- **silence** — `no_speech_prob > 0.6` **and** `avg_logprob < -1.0`. The
  conjunction is Whisper's own rule and matters in both directions: a confident
  decode overrides a high no-speech probability, and a low log-probability alone
  must not drop a quiet talker.
- **compression** — `compression_ratio > 2.4`. Cloud only; the field arrives in
  `verbose_json` (`WhisperVerboseResponse`, which modelled only start/end/text
  before) and whisper.cpp has no equivalent.
- **repetition** — found in the text instead, which is why the detector exists.
  It is deliberately blind to *what* repeats (a phrase blocklist would need
  maintaining in seven languages and still miss the next one): it looks for one
  cycle of tokens covering most of the segment. The coverage floor is what keeps
  a stutter inside a good sentence from taking the sentence with it, and scripts
  written without spaces fall back to per-character units.

Surviving spans are stamped with the confidence their log-probability implies
(`exp(avgLogProb)`), which is what finally fills `TranscribedSpan.confidence`. A
surviving segment carrying word timings is emitted **one span per word** rather
than one per segment (`TranscriptQualityFilter.ScoredSpan.words`); the words ride
with their segment through the filter rather than being judged separately,
because the quality signals are per segment and a hallucinated sentence's words
are exactly as invented as the sentence.
whisper.cpp's own temperature-fallback thresholds (`logprob_thold`,
`no_speech_thold`, `entropy_thold`) are set from the same constants, so its retry
and this post-filter judge a segment by one set of numbers.

VBx's warm-start priors are left at FluidAudio's community-1 defaults. Raising
them to fight the collapse (an earlier attempt) just trades it for the opposite
failure, since a diffuse prior makes VBx keep the agglomerative init's cluster
count.

Every stage call is preceded by `ResourceGuard.requireTranscriptionHeadroom()`
(`Infrastructure/ResourceGuard.swift`, 750MB disk floor), which throws
`AppError.resourceUnavailable` rather than let the pipeline run out of disk
mid-transcription; `TempFileCleaner.cleanupOrphanedTempFiles()` runs at the
start of every `transcribe` call to sweep temp files (`kurn_clean_`,
`kurn_vad_`, `kurn_diar_`, `kurn_chunk_`, `kurn_compact_`, `kurn_enh_`, `kurn_capture_` prefixes,
plus stale
Whisper upload spool files) older than an hour that earlier interrupted runs left
behind; the same cleaner backs the manual "Free up space" action in Settings.

Progress is reported via a `@Sendable` `PhaseHandler` (`TranscriptionPhase`); the
receiver must hop to the main actor itself.

#### On-device Whisper (whisper.cpp)

`.whisperCpp` is Whisper's accuracy and language coverage with nothing leaving
the device. It is the one engine whose dependency is a **binary**: the app links
whisper.cpp's official prebuilt XCFramework through the local
`Packages/WhisperCpp` package (`.binaryTarget(url:checksum:)`, so nothing large
lands in git). Bumping the version means bumping the URL *and* the checksum
(`swift package compute-checksum` on the release zip). Everything that touches
the library is guarded by `#if canImport(whisper)` with a throwing `#else` stub —
the same pattern the FluidAudio files use, and required because `KurnTests`
doesn't link the package.

Three things are deliberately *not* parallel to the FluidAudio stack:

- **Its own downloader.** GGML weights come straight from HuggingFace
  (`Services/WhisperCppModelDownloader.swift`), because whisper.cpp ships no
  downloader of its own. It and `SherpaOnnxModelDownloader` are the app's two
  direct model downloads, both delegating fetch → verify → atomic install to
  the shared `ModelFileDownloader`. The files land in
  `Application Support/WhisperCpp/Models/<variant>/`, excluded from iCloud
  backup, and `ModelStore.ModelGroup.whisperCpp.root` points there rather than at
  FluidAudio's cache — the snapshot-diff folder discovery is skipped for this
  group since the app names the folders itself.
- **A variant axis.** `WhisperCppModel` (`Models/WhisperCppModel.swift`) offers
  base/small/large-v3-turbo, all q5-quantized, defaulting to `.small`. Because
  the model set has to say *which* file to fetch, `ModelSet` gained a payload
  (`.whisperCppASR(WhisperCppModel)`) and `TranscriptionEngine.requiredModelSet`
  is a function rather than a property. Switching variants re-runs the consent +
  download flow, and the variant is folded into the transcription checkpoint's
  `providerID` so a resume can't splice two models' output together.

  The variant axis forces two departures from the FluidAudio consent UI, both in
  `ModelDownloadController`. First, selecting the engine can't use the plain
  yes/no consent dialog: the size picker only renders once whisper.cpp *is* the
  selected engine, i.e. after the download it would otherwise have picked for
  the user. `showingWhisperCppModelChoice` breaks that circle with a
  `confirmationDialog` listing every variant and its size, so choosing a size
  and consenting are one step. (`showingWhisperCppConsent` remains for the size
  picker's own path, where the variant is already chosen.) Second, the download
  gate keys on the file being present, not on `whisperCppModelsConsented` —
  each variant is a separate file and Storage deletes them individually, which a
  single consent flag can't express. That individual deletion is why Storage
  lists one row per installed variant
  (`ModelStore.ModelGroup.listsFoldersSeparately`, the only group that does), and
  why `deleteModel` clears consent and reverts the engine only when the *last*
  variant is gone, re-pointing `whisperCppModel` at a surviving one otherwise.
- **Chunked, not single-pass.** `whisper_full` takes the whole clip as one
  `[Float]`, so the transcriber reuses `AudioChunker` +
  `ChunkedTranscriptionRunner` at 5-minute chunks (the cloud engine uses 10).
  That caps resident samples at ~19 MB instead of ~460 MB for a two-hour meeting,
  and brings resumable checkpoints and per-chunk cancellation with it. Audio is
  decoded to whisper's required 16 kHz mono float by the existing
  `VADAudioLoader.monoSamples`. `whisper_full` blocks, so the context lives on a
  private serial `DispatchQueue` and never occupies a cooperative thread.

`AudioChunker` **slices, it does not re-encode**: the export runs with
`AVAssetExportPresetPassthrough`, so a chunk inherits the source's format —
16 kHz mono, since `AudioPreprocessor` has already rendered it there. The fixed
`AVAssetExportPresetAppleM4A` it used to use carries the preset's own sample rate
and bit rate, unrelated to the source, so it re-encoded that cleaned audio *up*,
inflating every cloud upload and temp file and spending a lossy generation for
detail nothing downstream reads back. `preferredPreset` asks
`AVAssetExportSession.determineCompatibility` rather than assuming, and keeps the
old preset as the fallback. Two consequences to preserve: a passthrough export
cuts on compressed-frame boundaries, so `Chunk.offset` stays the *requested*
start (a running sum of measured durations folds that slop in once per chunk and
drifts forward), and `AudioChunkerTests` asserts the chunks keep the source's
format and size — the older assertions only covered counts and offsets, which is
why the inflation went unnoticed.

Like the FluidAudio engines it can't run from the background (Metal is
unavailable there), so `TranscriptionScheduler.pipelineUsesCoreML` covers it too.

#### FluidAudio on-device models and download consent

FluidAudio is pinned to 0.18.3. 0.18.2 made Pyannote's turns overlap by default (`exclusiveSegments` false); `FluidAudioPyannoteConfiguration` pins it back to true, so fusion keeps receiving one speaker per instant. Its `Diarizer`, `NemoTextProcessing` and `TTS`
traits are selected explicitly on the Xcode package reference, matching the
upstream defaults. Without explicit selection Xcode can compile 0.18 without
its diarization API, leaving `OfflineDiarizerManager` and related types missing.
The shared SPM cache restores only exact manifest/lockfile keys: Xcode validates
selected traits against a restored checkout before updating it, so falling back
to a 0.17 checkout makes a 0.18 trait selection fail before dependency resolution.
The selected `TTS` trait is not an implementation of the new model choices as
TTS, Canary translation, or voice cloning; this integration is transcription
and diarization only.

**Runtime loading and downloading are separate boundaries.** ASR (including
legacy v3), Pyannote/Nemotron diarization, automatic live, and Unified live
load local files only. `FluidAudioASRModelRuntime`,
`FluidAudioDiarizationModelRuntime`, `FluidAudioAutomaticStreamingRuntime`, and
`FluidAudioModelAvailability` check the relevant artifacts rather than trusting
a consent flag or a folder's existence. Compiled-model contents and partial
artifacts are checked; Pyannote additionally validates its cached revision and
PLDA parameters locally (`PyannoteDiarizationCache`, `PyannotePLDAParameters`).
Missing/corrupt weights require a user download/repair, not a framework
`downloadAndLoad` recovery call. A missing new ASR variant surfaces the existing
ASR-model-required UI/error, not a cellular-network error. The legacy Silero
VAD framework loader is the exception: it remains gated by runtime network
policy because it can still download.

`ModelDownloadConsent.download` is the explicit network boundary. It validates
`LargeTransferPolicy` **on every explicit call, even if a cache appears installed**:
upstream download/recovery may access the network. Runtime preflight excludes
local-only model sets from download-network checks, retaining `.vad`; it must
not block installed local inference merely because the device is on cellular.
`ResourceGuard.requireModelDownloadHeadroom()` (2.5GB disk floor) and the model
loading resource reservation also gate downloads. Whisper/sherpa sets remain
handled outside the FluidAudio import branch.

The model-to-consent mapping is explicit (`Models/FluidAudioModels+ModelSet.swift`,
`AppSettings+FluidAudio.swift`):

| Choice | `ModelSet` | Persisted consent |
| --- | --- | --- |
| Parakeet v3 ASR / independent FluidAudio LID | `.onDeviceASR` | Existing `fluidAudioBatchASRModelsConsented` |
| Non-default ASR variant | `.fluidAudioASR(model)` | Its raw value in `fluidAudioASRModelConsents` |
| Pyannote | `.diarization` | Existing `fluidAudioDiarizationModelsConsented` |
| Nemotron 3 diarization | `.fluidAudioDiarization(.nemotron3)` | `fluidAudioNemotronModelsConsented` |
| Automatic live | `.liveTranscriptionASR` | Existing `fluidAudioASRModelsConsented` |
| Unified live | `.fluidAudioUnifiedStreaming` | `fluidAudioUnifiedStreamingConsented` |

`ModelDownloadController+FluidAudioSelection` stages a pending selection and
applies it only once installation succeeds (or when the required variant is
already installed). New variants may be selected from a valid existing cache
without a transfer; legacy default choices still require their legacy consent.
Cancel/failure does not silently switch engines, and ASR language compatibility
is rechecked before applying a pending choice. Settings exposes an explicit
missing-model download button even when the selected case has not changed.
Batch Unified and live Unified have separate consent/installation checks: a
shared folder does not mean the other encoder has been installed or consented.

`Services/FluidAudioModelStore.swift` (`actor`, `.shared`) still caches **only
Parakeet v3** so `FluidAudioTranscriber` and `FluidAudioLanguageDetector` share
one loaded manager. `AppSettings.usesFluidAudioModel` prewarms it in the
foreground only for v3 ASR or LID with batch-v3 consent. Other ASR managers and
weights are loaded locally and released per chunk; do not add them to this
process-wide cache and defeat the long-recording memory bound. The v3 decoding
path otherwise stays unchanged.

`Services/ModelStore.swift` is the distinct on-disk manager under
`Application Support/FluidAudio/Models`. Storage shows one grouped row per
variant, not one per weight component. Non-default ASR folders are listed
separately in `.fluidAudioASR`; Nemotron diarization uses
`.nemotronDiarization`. Unified's offline and fp16 streaming encoders share
`nemotron-labs-unified-asr`, while their required file sets differ. Deleting
that row clears both the ASR-variant and Unified-live consent flags, resets the
selected ASR/live cases as needed, and disables affected live preview. Other
variant deletion invalidates only its matching consent/selection. If the
fallback v3/Pyannote model lacks cache or consent, the active engine falls back
to Apple Speech/heuristic rather than trying to run absent default weights.

Model licenses are not inherited from FluidAudio's Apache-2.0 framework:
Unified, Transcribe Lite, and Nemotron 3 diarization use NVIDIA's OpenMDW-1.1;
Bark 3.0/Clean (Conway Research) and Phonon-2 (Fermion Research) use CC-BY-4.0.
`THIRD_PARTY_NOTICES.md` retains attribution, and Settings → Acknowledgements
opens the bundled offline copies in `Kurn/Resources/FluidAudioModelLicenses.txt`
(full agreements and required origin notices, not just model-card links).

KurnCore tests cover the pure catalog, timeline, timing, and cache/PLDA
validation policies without model inference. The iOS 26 floor makes the APIs
available; it does not validate physical-device ANE behavior, fp16 memory or
speed. Accuracy on public audio has been measured since (2026-11-01,
`docs/pipeline-evaluation.md`); device speed and memory remain to be measured,
and upstream Mac/M5 benchmarks are not iPhone results.

#### Resumable transcription

Long transcriptions survive backgrounding, app termination, and cancellation
instead of restarting from scratch:

- `Models/TranscriptionCheckpoint.swift` persists JSON (via
  `Recording.transcriptionCheckpointData`) after every completed chunk: engine,
  language, whether the VAD-compacted input was used, total/completed chunk
  counts, and spans transcribed so far. `Pipeline/ChunkedTranscriptionRunner.swift`
  is shared by cloud Whisper, whisper.cpp, chunked Apple Speech, and every
  **non-default FluidAudio ASR** model. `FluidAudioPipelineAdapters.swift` sends
  those five ASR choices through `AudioChunker(chunkDuration: 300)` with the
  existing deterministic silence-cut adjustment (±30 s); each chunk loads and
  releases its own model manager/weights. This bounds retained ASR input and
  model lifetime for long recordings (including 96-minute sessions), not a
  claim of measured device peak memory or speed. Parakeet v3 keeps its existing
  decoding path rather than adopting this outer chunk runner.
- A resume requires matching source/pipeline fingerprints and the re-derived
  chunk plan, including language, compaction, count, and boundary digest.
  `FluidAudioPipelineSelection.checkpointProviderID` records
  `fluidaudio:<model raw value>` separately from the unchanged
  `.fluidAudioParakeet` engine ID for non-default ASR (v3 retains `nil`).
  Switching FluidAudio models must invalidate a checkpoint, never splice two
  models' output; an incompatible/malformed checkpoint starts fresh.
- `Services/WhisperBackgroundUploader.swift` uploads Whisper chunks over a
  background `URLSession` (file-based request bodies) so an in-flight upload
  survives the app suspending or the device locking.
- `Infrastructure/TranscriptionScheduler.swift` registers the
  `ai.kurn.transcription.processing` `BGProcessingTask` and submits a request
  on backgrounding whenever pending/in-progress work remains (skipped for
  FluidAudio engines, which can't compile CoreML models in the background).
  The task resumes pending recordings and checkpoints cooperatively before its
  time window expires, on the app's own `TranscriptionCoordinator` (from
  `AppComposition`), so a run finished there gets the same indexing and wiki
  post-processing as a foreground one.
- `Infrastructure/TranscriptionRecovery.swift` sweeps recordings stuck at
  `.inProgress` on launch and every foreground activation: recordings with a
  checkpoint reset to `.pending` (resumable), others to `.failed`.
- `Infrastructure/BackgroundActivity.swift` wraps
  `UIApplication.beginBackgroundTask`/`endBackgroundTask`, requesting a finite
  execution window so a long transcription isn't suspended the instant the app
  backgrounds; its `onExpiration` callback lets the checkpoint machinery pause
  cleanly instead of being frozen mid-chunk when the system reclaims the
  window.

### Live transcription preview (`Services/LiveTranscriptionService.swift`)

An opt-in (`AppSettings.liveTranscriptionEnabled`, off by default),
preview-only transcript shown while recording — nothing it produces is
persisted; the authoritative transcript still comes from `TranscriptionService`
after the recording stops. `RecorderViewModel` feeds it live audio buffers
through a `nonisolated append(_:)` entry point wired to
`AudioRecorderService.onAudioBuffer`. `AppSettings.fluidAudioLiveModel` is
independent of the post-recording ASR model:

- **`.automatic` (default)** preserves the legacy language routing: English
  uses `StreamingModelVariant.parakeetEou160ms`; other supported languages and
  Auto use `FluidAudioMultilingualStreamingManager`, adapting
  `StreamingNemotronMultilingualAsrManager`. The explicit-language set is
  `en/es/fr/it/pt/de/zh/ja`, plus Auto. `FluidAudioAutomaticStreamingRuntime`
  validates the relevant local installation before creating either manager.
- **`.nemotronUnified`** uses `FluidAudioUnifiedStreamingManager` /
  `StreamingUnifiedAsrManager` with the **fp16 streaming encoder** and the same
  25-language + Auto contract as Unified batch. Batch's offline encoder is not
  sufficient; the streaming encoder needs its own consented download even
  though decoder/vocabulary files and the folder are shared.

Both paths load local models only and expose missing-model repair through the
shared download controller. `BoundedSessionQueue` keeps up to eight seconds of
copied audio behind one session pump; buffers are dropped oldest-first only
when that bound is exceeded. Session tokens prevent a stopped or stale load,
callback or pump from mutating a later recording. Appending from the render
thread creates no per-buffer task. Preview remains best-effort, not a measured
latency guarantee. Unified drains consumed token timings because preview text
is not a durable word-timing transcript.

### Providers (`Providers/`)

`LLMProvider` (`Sendable`) abstracts text generation — `summarize`, `streamSummary`,
`chat` — for every backend, cloud or local. Cloud speech-to-text is the
separate `TranscriptionProvider` (`transcribe`), so each vendor conforms to
what it actually serves: OpenAI-compatible endpoints to both, ElevenLabs only
to `TranscriptionProvider`, Anthropic, Gemini and on-device only to
`LLMProvider`. They used to be one protocol with each vendor's missing half
stubbed as a throw; routing a vendor to a capability it lacks is now a compile
error, not a runtime one. `ProviderFactory` is the single place that resolves a provider from `AppSettings`
+ Keychain and throws `AppError.noAPIKey` when a cloud key is missing or
`AppError.onDeviceModelUnavailable` when the on-device model can't run. Vendor
API shapes are modeled by `AIProviderKind` (`openAICompatible`, `anthropic`,
`googleGemini`, `elevenLabs`, `appleOnDevice`); Groq reuses the OpenAI-compatible
client. `.elevenLabs` (`Providers/ElevenLabsProvider.swift`) is its own shape
(`xi-api-key` auth, Scribe speech-to-text) and is **transcription-only** — it
has no chat/summarize route, so `AIProvider.supportsSummarization` is false only
for this kind (true for every other kind, including on-device), and it's
excluded from the summary/chat provider pickers the same way Anthropic/Gemini
are excluded from the transcription picker.
`.appleOnDevice` is `FoundationModelsProvider`
(`Providers/FoundationModelsProvider.swift`, Apple's `FoundationModels`, no
`#available` guard because the floor is iOS 26): no key, no network, and the
default `aiProviderID` for new installs — an existing user's stored selection is
left alone. `AIProvider.isUsable` (key present, or on-device) is the single
"can this provider be selected" check the pickers and services share. Cloud
calls go through `ProviderHTTPTransport`/`ProviderHTTPPolicy` (timeouts, bounded
retries, redirect limits), `ProviderURLPolicy` (HTTPS-only base-URL validation)
and `Infrastructure/ProviderCircuitBreaker.swift` (a per-provider breaker that
opens after repeated failures so a failing vendor is not hammered on every
retry, and emits a reliability event when it trips). **Cloud (`.whisperAPI`) transcription is not pinned to
OpenAI** — `AIProvider.supportsTranscription` is true for any `openAICompatible`
provider (OpenAI, Groq, or a custom OpenAI-compatible endpoint the user adds)
plus `.elevenLabs`, since between them they're the only kinds exposing a
transcription route (a Whisper-shaped `/audio/transcriptions` for the former,
Scribe for the latter); Anthropic/Gemini are excluded. OpenAI itself now offers
three transcription models — `whisper-1`, `gpt-4o-transcribe`,
`gpt-4o-mini-transcribe` — kept in `AIProvider.fallbackModels` regardless of
what the live `/models` fetch returns, since that endpoint is dominated by chat
models and can otherwise leave the transcription picker with nothing to show.
`AppSettings.transcriptionProviderID`
picks which one to use, independently of the summary provider, surfaced as a
"Transcription provider" picker in Settings shown only when the Whisper engine
is selected. `ProviderFactory.whisperProvider(for:model:)` resolves the chosen
provider + model (Groq defaults to `whisper-large-v3`, ElevenLabs to
`scribe_v1`, everything else to `whisper-1`).

**Native diarization is a provider capability, not an ElevenLabs special
case.** `AIProvider.supportsNativeDiarization` (true only for `.elevenLabs`
today) is the whole seam for a transcription provider whose response already
carries speaker turns (ElevenLabs Scribe's `diarize` parameter): flip that flag
for a future provider's `kind` and have its `TranscriptionProvider.transcribe` populate
`RawTranscript.speakerTurns` however its API shapes that data — nothing else
needs to know the wire format. `DiarizationEngine.transcriptionProviderNative`
is the matching diarizer choice; `PipelineConfiguration.effectiveDiarization`
honors it only when the transcription engine is `.whisperAPI` *and* the
selected provider supports it, otherwise stepping back to `.heuristic` like the
other diarizer fallbacks — no download and no consent flag either, since it
fetches nothing. Transcription and diarization otherwise stay fully independent
axes: choosing `.heuristic`/`.fluidAudio`/`.sherpaOnnx` always runs that exact
engine regardless of which transcription engine or provider is configured, so
e.g. ElevenLabs for transcription with FluidAudio for diarization is an
ordinary, unremarkable combination.

`Providers/ProviderModelsService.swift` separately lists a provider's available
summary models by querying its own `/models` endpoint (auth style branches on
`AIProviderKind`), falling back to `AIProvider.fallbackModels` on a 403 or an
empty response (some vendors, e.g. Groq, reject otherwise-valid keys) — this
backs the model picker in Settings and is distinct from the
completion-calling `LLMProvider` clients above.

Summaries are template-driven: `SummaryPrompt.system(for:)` builds the system prompt
from the chosen `SummaryTemplate` (`Models/SummaryTemplate.swift` — a name and
instructions, which also name the sections the template wants; built-ins are
`.general`, `.standup`, `.interview`, and `.outline`, collected in
`defaultTemplates`). **The reply is plain Markdown in which each `## ` heading
opens a section**, parsed by KurnCore's `SummaryMarkdown` into
`[SummarySection]` (title, Markdown body, plus bullet items and photo
timestamps) — the stored, rendered, exported, translated and read-aloud shape is
unchanged. It replaced a `{ "sections": [...] }` JSON contract: prose inside JSON
strings was where models failed (double-escaped `\n`, fences, prose around the
braces) and needed per-vendor JSON modes, so no vendor is asked for JSON mode or
a response schema any more, and the on-device model generates text rather than
a guided struct. The parser is tolerant: `#### ` stays inside a section, headings
inside code fences never split, a lone `# ` document title is dropped, `# `
headings serve as sections when there are no `## ` ones, a reply with no heading
becomes one untitled section, a fence around the whole reply is removed, and a
reply in the old JSON shape is still accepted (`SummaryJSON`). A line made only
of `📷` and `[mm:ss]` stamps lists the photos a section drew on
(`photoTimestamps`) and leaves the body; translation writes those lines back
(`SummaryService.markdownText(from:includingPhotoReferences:)`) so they survive.
A truncated Markdown reply still parses, so the vendor's finish/stop reason is
what raises `AppError.summaryTruncated`. Templates used to carry a separate list
of suggested section headings; it was folded into the instructions, and a stored
or iCloud-synced template that still has one is migrated on decode
(`SummaryTemplate.instructions(_:foldingIn:)`), while encoding always writes an
empty `sections` key so an older app version can still decode a synced
template. The line under a template's name in the picker and in Settings is
`summaryDescription`: the one-line `details` the user wrote, else a built-in's
localized purpose (`template.<id>.desc`), else the first sentence of the
instructions — never a list of sections. Templates
(built-in presets + user-defined, created/edited via `Views/TemplateEditorView.swift`
— built-ins can't be renamed or deleted) live in `AppSettings.summaryTemplates`; the user
picks one per summarization via `SummaryTemplatePicker`. `Summary.sections` holds the
template-driven body that the views and export render. `SummaryView` renders inline
Markdown in titles, body text, and item text, with lightweight block handling for
headings and lists.

**A meeting accumulates summaries; it does not have one.** `Meeting.summaries`
is `[Summary]`, one per generation run, and each `Summary` records the
`templateName`, provider and model it came from. Running the same transcript
through General and then Standup keeps both, so templates can be compared
side by side instead of overwriting each other — which is why the summary
provenance is stored per summary rather than read from current settings.

The consequences show up across the UI, and new code should follow the same
convention rather than reaching for a singular summary:

- `Meeting.latestSummary` (max by `createdAt`) is the **default selection**,
  not the meeting's summary. `MeetingDetailView` holds `selectedSummaryID` and
  re-points it at the latest whenever `meeting.summaries.count` changes, so a
  freshly generated summary is the one shown.
- `MeetingDetailTabs` renders a switcher over `summaries` sorted newest-first,
  with per-summary delete. `MeetingsListComponents` shows a count badge, and
  `MeetingShareSelectionView` lets the user pick which summaries to export.
- `MeetingFilter`'s `hasSummary` tests `summaries.isEmpty`, not a nil check.
- Single-summary consumers pick deliberately: `MeetingExport` and the chat's
  context builder both take `latestSummary`, because "the newest one" is the
  sensible default when only one can be used.

Every provider HTTP call funnels through `LLMHTTP.sendValidated`, which retries
transient transport errors and `429/500/502/503/504` with exponential
backoff + jitter (honoring `Retry-After`), instead of failing outright on a
momentary blip. `SummaryService` sends the whole transcript in one request
whenever it fits the model's `ContextBudget`, and only otherwise takes a
map-reduce pass (condense each block, then summarize the combined notes); it
raises the output budget/timeout (8192 tokens, 300s) so long transcripts don't
truncate mid-JSON or time out; a truncated response surfaces as
`AppError.summaryTruncated` instead of a confusing decode error.

**The single-pass budget is per model, in tokens** (`ContextBudget`, Application/Generation).
It used to be a fixed 80k characters for every cloud model — sized for the
smallest window any vendor had, so a two-hour meeting always went through lossy
staged notes, and wrong by a factor of four for Chinese, where a character is
about a token. `ContextBudget.resolve(provider:model:)` takes the window the
provider's `/models` listing reported (Gemini `inputTokenLimit`, Groq
`context_window`, OpenRouter `context_length`, remembered by
`ModelContextWindowStore`), else AgentHarness's `ModelContextWindows` table by
model family, else `ContextBudget.conservative` (the old thresholds); Apple's
on-device model always gets `ContextBudget.onDevice`. From a window it reserves
the output budget, prompt overhead and a 20% margin, and caps any single
request at 100k tokens. `TokenEstimate` counts per script (3.5 characters per
token for alphabetic text, 1 for CJK/Thai/Hangul), deliberately pessimistic.
A wrong window is safe by construction: a provider rejecting the input as too
long (`AppError.isContextOverflow` — 413, or a 400/422 whose message names
the context) sends the same work down the staged path with the conservative
budget, or rethrows when that would not split anything. The same budget and
fallback drive the wiki (through `SummaryService`); the services take a
`ContextBudget.Resolver` at construction so tests can force either path. The
agent chat plans against the model's window instead (see "Agent harness").

**Summary requests stream.** `SummaryService` calls `LLMProvider.streamSummary`
for the single pass, every map block and the reduce: the same Markdown contract
as `summarize`, received over SSE (OpenAI and Anthropic `"stream": true`,
Gemini `streamGenerateContent?alt=sse`). That swaps the buffered request's
fixed 300 s total timeout for `HTTPPolicy.streamingSummary` — 300 s of
*silence* (`idleTimeout`, applied as the request's `timeoutInterval`, which
URLSession enforces as inactivity) within a 900 s total — so a long
generation that keeps writing is no longer cut off. Truncation is read from
the stream's final finish/stop reason, exactly as the buffered parse did.
`streamSSE(retriesBeforeFirstPayload:)` retries a 429/5xx or an unopened
connection by `sendValidated`'s rules (Retry-After honoured, ambiguous
timeouts not replayed) but never after the first payload; chat does not opt
in. While it streams, the Summary tab shows a live, unformatted draft the way
the chat shows its reply: a "thinking for Ns" row (`ThinkingRow`, shared with
the chat in `Views/StreamingIndicators.swift`) until the first fragment, then
the text growing in a bounded window with a trailing cursor, replaced by the
formatted summary when generation finishes. The raw stream is Markdown, and
KurnCore's `SummaryDraftPreview` passes it through character by character with
the syntax a reader should not see removed — `#` markers (the title stays, after
a blank line), photo-reference lines and fence lines — holding back only the
start of a line while it could still be one of those; plus a word count
(`StreamedWordCount`). `SummaryService` reports it as numbered
`SummaryDraftSnapshot`s — empty at the start of every map block and the
reduce — and `SummaryViewModel.recordSummaryDraft` ignores one that lands
after a newer snapshot or after the run ended. The on-device model and test
doubles fall back to the extension default, which is just `summarize`, so
they show only the thinking row. Summary generation is
owned by `SummaryViewModel.startSummary`, which keeps the Summary tab in a
non-reentrant progress state and supports cooperative cancellation.

### Export formats

The share sheet (`MeetingShareSelectionView`) exports each selected summary or
transcript as its own file in one `MeetingExportFormat`: Markdown, Obsidian,
PDF, Word (.docx), HTML or plain text. **There is one document and many
renderers**: `MeetingExport` turns SwiftData into a format-neutral
`ExportDocument` (KurnCore, `Export/`), and every format renders that value —
so a section added to the export shows up everywhere, not just in whichever
renderer remembered it.

- `ExportDocument.blocks` is semantic and keeps LLM Markdown as written, which
  is what lets `MarkdownExportRenderer` emit it verbatim (its output is pinned
  byte for byte by `MeetingExportTests.markdownKeepsItsExactLayout`).
  `richBlocks` expands it through `MarkdownBlockParser` and `InlineMarkdown`
  into styled runs, and the other renderers consume only that — none parses
  Markdown itself. Transcript text and user notes are never parsed as
  Markdown. Links keep only their text, for the same reason
  `MarkdownPresentation` disables them on screen.
- Word is written directly as Office Open XML into a stored (uncompressed)
  ZIP by `ZipArchiveWriter` — no dependency, deterministic output. Lists are
  indented paragraphs with a glyph rather than `numbering.xml`.
- `PDFExportRenderer` (app target) typesets with Core Text into a Core
  Graphics PDF context — not UIKit's renderers or TextKit — because neither is
  main-actor-bound, so the share sheet renders off the main actor
  (`MeetingExportItem.writeTemporaryFile`). Core Text draws no strikethrough
  or backgrounds; those are carried by colour and font instead.
- The words the export adds — section headings, the duration label, the
  date — follow the language of the exported content, not the app's UI:
  `ExportLanguage` (app, `NLLanguageRecognizer`) reads the summary, else the
  transcript, else the notes, and falls back to `Meeting.language` below
  `minimumSampleLength`/`minimumConfidence`, then English. `ExportLabels`
  (KurnCore) is a table rather than `Localizable.strings` because a meeting
  can be in a language the app is not localized into; HTML's `lang` and
  Word's proofing `w:lang` carry the same code.
- Copy puts the format's own text on the clipboard for Markdown, Obsidian and
  plain text, and Markdown for the file formats.
- **Several meetings at once** come from the list's selection mode
  (`MeetingsListSelectionMode`, which only renders `MeetingListSelection` —
  picks, chrome titles and the delete), which bulk-deletes through
  `MeetingLibrary.deleteMeetings` — one journaled
  operation, refused whole if any meeting is being recorded. Actions apply to
  the selected meetings *shown*, never to ones the current filter hides.
  `MeetingBulkExportView` renders `MeetingBulkExportViewModel` (file writing
  and the pasteboard injected), and `MeetingBulkExport` plans the export: each meeting's latest summary and/or
  transcripts, either one file per meeting (named `yyyy-MM-dd title`, one note
  each in a vault) or a single file built by KurnCore's
  `ExportDocument.combining`, which puts each meeting's own document under a
  level-1 heading — so every renderer handles a collection with no code of
  its own.

### Cross-device control (Watch + Live Activity)

`RecordingCommandRouter` (main-actor singleton) is the single dispatcher: the live
`RecorderViewModel` registers `onPause/onResume/onStop/onTogglePause` closures while
recording. Both the Lock Screen Live Activity (via `RecordingControlIntent`, a
`LiveActivityIntent` hidden from Shortcuts — the app declares no URL scheme, since
any app could open one and stop a meeting being recorded)
and the Apple Watch (via `PhoneSessionController` over WatchConnectivity) route
through it. The recorder pushes state to the Watch with `updateApplicationContext`
(survives disconnects). There is deliberately no continuous audio-level stream to
the Watch: the recorder screen used to animate a decorative, already
`.accessibilityHidden` level meter fed by a 0.2s-throttled `sendMessage` push on
every audio buffer, which cost real battery/radio on both devices for a purely
cosmetic element — the title and ticking timer already communicate that
recording is active, which is what watchOS HIG glanceability calls for on a
single-screen remote control. `Services/LockScreenRecordingController.swift` owns the
ActivityKit (`Activity<RecordingActivityAttributes>`) lifecycle — `start`/
`update`/`end` mirror `AudioRecorderService.State` into the activity's
`ContentState`; the actual Live Activity UI is rendered separately by the
`KurnLiveActivityExtension` widget target. The Live Activity's Stop and
Pause buttons also end or update the activity inside
`RecordingControlIntent.perform()` and await it: once capture stops or pauses,
nothing may keep a backgrounded app alive, so the controller's own unstructured
tasks could be suspended before they ran, leaving the Lock Screen timer
counting over a stopped or paused recording. Pause applies
`ContentState.togglingPause(at:)` to the state read *before* the recorder acts,
and only when `RecordingCommandRouter.handle` reports a live session handled it.

The watchOS target does **not** share source files with the app — types like
`WatchCommand` and the wire-contract constants in `WatchSessionProtocol.swift`
(the `WCSession` application-context/message dictionary keys and state
strings) are intentionally duplicated byte-for-byte in `KurnWatch/`. Keep both
copies in sync.

`AppSettings.hideLiveActivityMeetingTitle` (**default on**) is applied in
`RecorderViewModel.displayTitle`, which substitutes a generic localized string
for `meeting.title`. That one property feeds **both** the Live Activity and the
paired Watch, because both are glanceable surfaces someone other than the owner
can read — the Lock Screen and Dynamic Island on one side, a wrist on the other
— and a title like "Performance review — Ana" would otherwise leak from the
locked device the rest of the app is careful to protect. Anything else pushed to
those surfaces should honor the same setting through the same property rather
than reading `meeting.title` directly.

`RecordingActivityAttributes` (`Infrastructure/RecordingActivityAttributes.swift`)
is, by contrast, a single file compiled into both the `Kurn` and
`KurnLiveActivityExtension` targets — unlike `WatchCommand`, there was no reason
for it to drift, so it's shared rather than duplicated.

### Minimizable recorder (`ViewModels/RecordingSessionController.swift`)

The live recording is an app-wide session, not a property of the screen that
shows it. `RecordingSessionController` (built by `AppComposition`, one per
store) owns the session's `RecorderViewModel` and the task that starts it;
`RecorderView` only presents it. `RecordingSessionPresenter`, attached once in
`ContentView` above both layouts, shows the recorder as a sheet while the
session is expanded and, once minimized (the chevron, or swiping the sheet
down), a floating Liquid Glass mini bar — status, title, elapsed time,
pause/resume, stop — in the bottom safe area of every screen; tapping it
expands the recorder again. Capture, the Live Activity, the Watch and
`RecordingCommandRouter` never depended on the view, so none of them changed.

Rules that keep it safe:

- **Only a running capture minimizes** (`canMinimize`): while the mic is being
  chosen, permission was denied or the engine is still starting there is
  nothing to collapse into, so dismissal stays disabled.
- **Attention brings it back.** An error or permission denial is presented by
  the full recorder, so `surfaceIfNeeded` re-expands a minimized session.
  Every stop path (recorder, mini bar, Live Activity, Watch) lands on
  `didSaveRecording`, which the presenter turns into `finishIfSaved()`.
- **One session.** `begin(meeting:)` while one exists re-opens it rather than
  starting a second capture; the list's record button and a meeting's "Add
  segment" both go through it.
- **The meeting being recorded stays reachable, so its live row is
  protected.** `Recording.isCaptureInProgress` (`.preparing`/`.recording`/
  `.finalizing` — launch recovery moves a dead process's leftovers to
  `.recoveryNeeded`, so at runtime these mean a live capture) makes
  `RecordingSegmentRow` show "recording in progress" instead of the recovery
  affordance, and `MeetingLibrary` refuses to delete a meeting or recording
  in that state; "Delete all data" is refused while
  `RecordingCommandRouter.hasActiveSession`.

### Frictionless capture (`AppIntents/`, `Services/RecordingLauncher.swift`)

`StartRecordingIntent` (Siri / Shortcuts via `KurnShortcuts`) and
`StartRecordingControl` in `KurnLiveActivityExtension` (Control Center, Lock
Screen, Action Button) and that target's `StartRecordingWidget` (Home Screen,
Lock Screen accessory and StandBy on iPhone and iPad) all open the app and post a process-local start request;
`RecordingLauncher` creates and queues the meeting, which
`RecordingSessionPresenter` starts through the same session a tap uses, and the existing pause/resume/stop commands still
converge on `RecordingCommandRouter`. Capture deliberately starts **without**
waiting for `RecordingAccessGate` — a control that first demanded Face ID would
miss the moment it exists for — while `SecurityCoverWindow` keeps meeting content
hidden. External commands are idempotent (a duplicate start/stop is a no-op, not
a second meeting), and the intent distinguishes "request accepted" from
microphone permission and actual capture.

`StartRecordingWidget` is static on purpose: one timeline entry with
`.never` refresh, no App Group, nothing read from the app. A widget is
visible on a locked device and in StandBy, so it must never show a meeting
title, count or last recording — the same reasoning as
`hideLiveActivityMeetingTitle`.

### Durability & recovery (`Infrastructure/`)

The H1–H10 resilience track (closed; its remaining gaps are in
`docs/roadmap.md`) came out of a repository-wide failure-path audit and turned
six operational invariants into tested contracts:

- **H-I1** Once capture is acknowledged as running, a write failure is detected
  and surfaced; the app never keeps counting while silently dropping audio.
- **H-I2** The only copy of user audio is never automatically deleted merely
  because its metadata is missing, malformed or unreadable.
- **H-I3** Success is reported only after the authoritative state is durable; a
  failed save cannot leave the UI claiming an operation completed.
- **H-I4** A fallback may preserve useful work, but it is recorded and visible;
  degraded output is never indistinguishable from the requested pipeline
  succeeding (`PipelineReport`, the transcript's "completed with warnings"
  banner).
- **H-I5** A custom network destination is exact: invalid configuration fails
  closed and never falls through to another vendor or host.
- **H-I6** Cancellation, transient failure, permanent failure, degradation and
  resource deferral are distinct states, with bounded automatic retry
  (`Recording.automaticResumeAttempts`, default 3, reset by a manual retry).

A green CI run proves the tested paths pass, not that disk exhaustion, a locked
background launch, process death or a malformed provider response behaves
safely — so **every new durability or state transition lands with a
deterministic fault-injection test in the same PR** (the fakes live in
`KurnTests/Support/FaultInjection`, `DebugSupport/` holds the debug hooks), and
the failures no simulator can reproduce are the release gate in
`docs/release-physical-checklist.md`. Diagnostics stay on device; no
recording, transcript, title, key, provider body or URL query ever goes into a
reliability event, a fixture or an export. Keep these when touching anything
that writes audio, the store, or the network:

- **The store never silently opens somewhere else.** `ModelStoreBootCoordinator`
  is a boot state machine (`KurnSchema` is the versioned SwiftData schema
  baseline). If Application Support can't be resolved it enters
  `.recoveryRequired(.applicationSupportUnavailable)` instead of falling back to
  a temporary directory; `ModelStoreBootViews` hides restore/salvage/fresh-start
  when there is no durable directory to act on. `ModelStoreProtection`,
  `ModelStoreBackupManager` and `ModelStoreSalvage` own protection, protected
  backup/restore and salvage. **Never let a `@Model` instance outlive the
  `ModelContainer` it was fetched from**: SwiftData resets a deallocated
  container's context and destroys its instances, which is why
  `ModelStoreSalvage.recoverReadOnly` fetches *and* exports inside the
  container's lifetime and returns only value types.
- **Move, then purge.** `RecordingTrash` deletes by atomically moving files into
  a protected trash folder before the model mutation and purging only once the
  save committed; `sweep(context:)` reconciles a crash mid-delete on the next
  launch. `RecordingOperationJournal` records every delete/replace boundary with
  `intent` → `trashed` → `committed` states; unreadable records are quarantined
  under `Journal/Unreadable` (never dropped), and `advance(_:to:)` returns `Bool`
  so a failed rewrite surfaces as a reliability event.
- **"Delete All Data" erases the recovery copies too.** Every durability
  mechanism above keeps meeting content somewhere on purpose — store backups
  and quarantined stores are whole copies of every transcript, the recordings'
  trash/quarantine/journal hold audio — so the user's explicit erase goes
  through `LibraryEraser` (`Infrastructure/`), never an ad hoc model delete in a
  view. It deletes every content model (including library-wide `ChatSession`s
  and `GeneratedDocument`s, which no meeting cascade reaches), saves, and only
  then removes audio, photos, attachments and every recovery location
  (`ModelStoreBackupManager.eraseAllRecoveryCopies()` is that type's one
  deletion of anything but a redundant backup). Tags, folders, smart folders,
  reliability events and diagnostic reports are kept — none carries meeting
  content. A new store of meeting-derived content must be added there.
- **Malformed or future data is not accepted silently.** `JSONStorage` wraps
  authoritative JSON in a versioned envelope; `JSONDecodeOutcome` distinguishes
  `.corrupted(originalData:)` from `.unsupportedVersion(_, originalData:)` and
  preserves the original bytes in both cases. `RecordingProtection`,
  `RecordingQuarantine` and `RecordingRecovery` handle protected audio,
  quarantine of files that fail integrity checks, and explicit (never automatic)
  recovery; `TranscriptionRecovery` resumes from durable checkpoints keyed by a
  pipeline fingerprint (`PipelineDigest`).
- **Capture failures are visible.** `CaptureReliability` and
  `RecordingSink`/`RecordingFileFinalizer` treat sink write failures, stalls
  and storage headroom as first-class outcomes; `Services/RecordingCompactor`
  re-encodes to a temporary file, verifies it and only then swaps it in
  atomically, and only when the user asks from Settings → Storage.
- **Network and models have limits and rollback.** `LargeTransferPolicy` gates
  model downloads by network cost (Wi-Fi-only unless
  `allowsExpensiveNetworkTransfers`), `ModelFileDownloader` resumes and stages
  into a verified location, and `ModelVerification` checks integrity before a
  model replaces the previous one. `KeychainManager` returns typed outcomes and
  credential saves are explicit.
- **Concurrency has one owner.** `ResourceScheduler` is the global admission
  scheduler with per-kind weights and cooldowns; wrap work in
  `withResourceReservation(_:on:_:)` so the reservation is released on success,
  error and cancellation in the same async flow (never `defer { Task { … } }`).
  `TranscriptionScheduler` and `ResourceGuard` sit on top of it.
- **Reliability events are redacted, bounded and durable.**
  `ReliabilityEvent` (KurnCore) carries an operation ID, a kind and a log code —
  never a path, title, audio, raw text or `localizedDescription`; use
  `Error.publicLogCode` (`Extensions/Error+LogCode.swift`) for anything logged
  with `privacy: .public`. `ReliabilityEventStore` keeps at most `maxEvents`
  (500) encrypted JSONL records; `LogExport` produces the redacted export, and
  `Views/Settings/HealthRecoveryView.swift` is the single repair surface that
  dispatches to the existing per-item recovery functions rather than
  reimplementing them.

`Tools/check_static_policy.py` enforces the log-redaction and unchecked-save
rules statically, alongside the layer rules described under "Architecture"
(baseline in `Tools/static_policy_baseline.txt`; a stale baseline entry fails
the check), and `DebugSupport/` holds the debug-only fault
injection hooks the recovery tests use.

### Semantic search & chat (`Services/Embedding/`, `Services/SemanticSearchService.swift`, `Services/HarnessChatService.swift`)

On-device semantic search over transcripts plus "chat with your meetings", built
with **no new external dependency**: embeddings come from Apple's `NaturalLanguage`
framework (`NLContextualEmbedding`, multilingual, loaded once via the
`EmbeddingModelStore` actor — same coalesced-load pattern as
`FluidAudioModelStore`), and chat is the agent harness over the cloud providers.

- **Indexing.** After a transcript is persisted, `TranscriptChunker` splits it
  into short passages (absolute meeting timestamps + dominant speaker),
  `SemanticIndexService` embeds them off-main, and `SemanticIndexCoordinator`
  (`Application/`, `@MainActor`, app-wide, built by `AppComposition`) persists them as `SemanticChunk`
  rows. Indexing is automatic after transcription completion and a low-priority
  launch/foreground **backfill** re-indexes meetings transcribed before the
  feature existed (or by an older embedder, tracked via `modelIdentifier`). Gated
  by `AppSettings.semanticSearchEnabled` (on by default). Title generation,
  indexing, and optional wiki generation run as independent best-effort
  post-transcription work: the recording is already `.done`, and the UI reports
  each enrichment phase separately instead of holding the transcription bar at
  "Finalizing".
- **Search.** `SemanticSearchService` embeds the query once and ranks stored
  chunk vectors by cosine similarity (`vDSP` dot product on unit-normalized
  vectors). `MeetingsListView` runs a debounced hybrid pass: instant substring
  matching plus semantically-relevant meetings the substring pass missed.
- **Chat.** `MeetingChatViewModel` + `MeetingChatView` drive an agent conversation
  (`HarnessChatService`, see "Agent harness") whose source tools read transcripts,
  summaries, wiki articles and attachments and search with
  `SemanticSearchService.hybridSearch` (dense `NLContextualEmbedding` cosine + BM25,
  fused with Reciprocal Rank Fusion). Replies cite `[m:ss]` and answer in the
  question's language. It is surfaced as a per-meeting Chat tab (`MeetingDetailView`)
  and a library-wide "Ask" sheet (`MeetingsListView`); cited timestamps are tappable and
  seek the transcript. Conversations are saved as `ChatSession`
  (`Models/ChatSession.swift`) — the same "reopen a past chat, start a new one,
  delete one" affordances Claude's own mobile app offers, via the history/new
  toolbar buttons on `MeetingChatView` and `Views/ChatSessionListView.swift`'s
  history sheet. A session is created when the conversation's first question is
  sent: the question is saved before any request (the NH05 persistence barrier),
  so a crash or suspension mid-reply never loses it. A cancelled/failed reply is
  never saved (`dropPartialReply` removes those turns first), and a chat opened
  and abandoned with nothing sent leaves no row in history. Turns (including steps, artifacts and token usage/cost) are
  JSON-encoded into `ChatSession.turnsData`, the same `Transcript.segmentsData`
  pattern; like every other `@Model`, it's encrypted at rest by
  `ModelStoreProtection` with the rest of the store. Scoped like the feature
  itself: a per-meeting conversation's `ChatSession.meeting` cascade-deletes
  with the meeting, same as `summaries`/`semanticChunks`; a library-wide one
  has `meeting == nil` and its own history list. `KurnSchemaV2`
  (`Infrastructure/KurnSchema.swift`) is the first real use of
  `KurnSchemaMigrationPlan` — a lightweight stage, since adding `ChatSession`
  and its relationship is purely additive. **Only the current version lists
  the live `@Model` classes.** `KurnSchemaV1.models` resolves to the frozen
  copies in `Infrastructure/KurnSchemaV1Models.swift` (`KurnSchemaV1.Meeting`,
  …, nested types with just the stored properties), because a `VersionedSchema`
  built from the live classes is redefined by every edit to them: the first
  cut of V2 did exactly that, so "V1" already contained `chatSessions`, no
  real 1.0.0 store matched it, and the migration failed on upgrade while
  `LegacyStoreAdoptionTests` stayed green (its fixture was written with the
  same live classes). `KurnSchemaV3` (1.2.0, adding `MeetingPhoto`) and
  `KurnSchemaV4` (1.3.0, adding `MeetingAttachment`) followed that recipe;
  V5 (1.4.0) adds optional session scope/artifacts and generated-document artifact
  provenance, with V4 frozen in `KurnSchemaV4Models.swift` and
  `KurnSchemaV4LibraryModels.swift`. `SchemaV4MigrationTests` writes every V4 entity
  and verifies migration and persisted harness state. V6 (1.5.0) adds the canonical
  harness session storage and V7 (1.6.0) the Knowledge Engine's canonical layer, with V6
  frozen in `KurnSchemaV6Models.swift`, `KurnSchemaV6LibraryModels.swift` and
  `KurnSchemaV6HarnessModels.swift`; `SchemaV6MigrationTests` writes every V6 entity to
  disk and opens it through the plan. The next model change means: edit the live class,
  add a new schema listing live classes, freeze V7, add the stage, and bump
  `KurnModelGraph.currentSchemaVersion` (which backup metadata records). When
  `wikiEnabled` is on, the agent can also read the condensed per-meeting articles
  (`read_wiki`) — see "Derived artifacts" below.

### Derived artifacts: wiki and documents

Two further LLM-derived artifacts sit on top of a finished transcript. Both are
`@Model`s in the one app store, so their text is encrypted at rest by
`ModelStoreProtection` with everything else — the same rule as `SemanticChunk`:
transcript-derived text never goes to a loose file or a cache.

**`WikiArticle`** (`Models/WikiArticle.swift`) is one condensed article per
meeting: dense, factual, timestamped notes over the whole transcript —
decisions, action items, numbers, names. `Meeting.wikiArticle` is one-to-one and
`.cascade`, so it dies with its meeting.

- **Why it exists is synthesis across meetings.** A 1–4 KB article condenses a
  whole meeting, so the agent's `read_wiki` tool lets it compare, count and trace a
  decision across many meetings without reading every transcript, then cite the
  transcript for exact quotes. It is also readable from the meeting's detail screen
  (`MeetingWikiView`).
- **`WikiService` delegates rather than reimplements.** It calls `SummaryService`
  with that service's internal `notesTemplate` — the same "capture every
  decision, action item, number, name, with `[mm:ss]`" format the summary's map
  stage already produces — so chunking, staging, cancellation, retry and
  rate-limit behaviour are inherited rather than duplicated. A long meeting is
  condensed in stages, a short one in a single pass.
- **Staleness is tracked, and a rebuild replaces.** `sourceContentHash` /
  `generatorModelIdentifier` are the wiki analogue of `SemanticChunk`'s
  `modelIdentifier` check; when the transcript or the generating model changes
  the article is rebuilt, never appended to. `WikiCoordinator` (`Application/`)
  owns the main-actor/SwiftData half; the LLM call runs off-main in the service.
- Gated by `AppSettings.wikiEnabled`, **off by default** — it makes a paid cloud
  LLM call per transcription.
- **It is being refactored into the Knowledge Engine** (roadmap, "Knowledge
  Engine — wiki refactor"). The article stays as the *episodic* layer — a
  per-meeting condensation that may orient extraction but is never evidence —
  while a canonical layer of attributed, evidence-backed, bitemporal assertions
  feeds a global wiki, a timeline and a graph. Until that ships, nothing here
  changes; new wiki work should go through that plan rather than extend
  `WikiCoordinator`'s own generate/backfill loop, which the plan folds into a
  shared knowledge job queue.

**`GeneratedDocument`** (`Models/GeneratedDocument.swift`) is a saved agent artifact.
The Documents library's plus button opens library chat. Ask the agent for a
document, report, or minutes; document tools create versioned workspace artifacts.
Ordinary assistant replies cannot be saved as documents.

- `ChatArtifactCard` previews the latest workspace version, including from older
  turns, and offers Markdown copy and Markdown/Word/HTML export through the same
  `DocumentExport` adapter used by `DocumentDetailView`.
- `ChatArtifactStore` owns save/update decisions and source snapshots resolved
  through `SourceScopeResolver`. A newer artifact updates the same saved document;
  an up-to-date artifact is marked saved, and deleting it enables saving again.
  Provenance records the session, artifact and version. Optional per-artifact turn
  metadata preserves the generating question/model through retries and reopening;
  older conversations leave an unknown model empty rather than inventing it.
- **Source labels and meeting ids are snapshots.** Deleting a meeting, retagging
  it, or moving it between folders must not retroactively damage a document that
  was already generated, so the document keeps its own copy of what it was built
  from rather than a live relationship.
- Chat artifacts persist independently of reply completion. Failed/limited runs
  retain artifact references and provenance on the pending question, including
  across retries. There is no separate one-shot document generation flow.

### Knowledge Engine decisions

The wiki refactor ("Knowledge Engine — wiki refactor" in `docs/roadmap.md`)
follows an external specification (v1.3 with its §20 private-corporate
extension) that is deliberately not kept in the repository. These decisions
hold for every phase; code comments cite this section.

- **Canonical facts, projected views** (ADR-001). Attributed, evidence-backed
  assertions and events are the source of truth; the global wiki, the timeline,
  the graph and the search documents are projections of one canonical revision
  and never updated by independent pipelines. Markdown is never the only record
  of a decision, and nothing extracted from a generated page counts as evidence.
- **SwiftData, locally** (ADR-002); **bitemporal from the first schema** (ADR-003:
  valid time and transaction time apart, half-open intervals, explicit
  precision, no "latest meeting wins").
- **Full context first, evidence-grounded** (ADR-004): `ContextBudget` decides
  between the whole transcript and semantic blocks; the strategy and coverage
  are recorded, never a silent truncation; the meeting's `WikiArticle` and
  summary orient extraction but are never evidence.
- **Knowledge as a primary destination** (ADR-005) and **timeline before graph
  animation** (ADR-006); navigation changes wait for review.
- **Read-only agent access** (ADR-007): knowledge is queried through more
  `AgentTool`s registered in `Application/Agent/Tools/` on the existing
  `NativeHarness`, answering in the compact text form of `ChatSourceToolText`
  with a final revision/coverage/warnings line, not a second harness or JSON
  envelopes. `AgentBudgetPlanner` keeps sizing runs; hop, evidence and node
  bounds are per-tool argument limits. Reading knowledge (pages, timeline,
  graph, search) works offline with no provider; only Ask needs an `AgentModel`.
- **Separate opt-in, default-deny egress** (ADR-008, spec §20.5).
  `AppSettings.knowledgeEnabled` (off by default, independent of
  `wikiEnabled`) gates everything. KurnCore's `KnowledgePolicyEvaluator`
  decides each operation (`KnowledgeOperation`: extraction, page narrative,
  semantic lint, embedding, answer synthesis, export) under the intersection of
  every `KnowledgeProcessingPolicy` in play — workspace, sources, contexts —
  so a derivative inherits the strictest restriction and the most restricted
  `KnowledgeClassification` of its sources. The default policy keeps all work
  on the device and exports nothing; a remote destination needs the policy to
  name the provider, a classification ceiling covering every source, and then
  the user's consent, checked in that order because consent never substitutes
  for corporate authorization. No policy, or no source, is a refusal. Denials
  are a fixed snake-case vocabulary safe for logs, and
  `KnowledgePolicyEvaluator.revisionKey` names the policy revisions every cache
  key must include. It is checked before retrieval, before a prompt is
  assembled, before egress and before export.
- **Closed vocabularies and host-side checks (K1.1).** KurnCore's `Knowledge/`
  holds the canonical layer's persisted vocabularies (`KnowledgeEntityKind`,
  `KnowledgeModality`, `KnowledgePolarity`, `KnowledgeReviewState`,
  `KnowledgeConfidenceBand`, `KnowledgeClaimKind`, `KnowledgeAuthorityStatus`,
  `KnowledgeContextKind`, `KnowledgeOrganizationRole`) — raw values never change
  once shipped, and an unknown term from a model is rejected or queued for
  review, never stored as a free string. `KnowledgePredicate` is the closed
  predicate set with a versioned registry (`registryVersion`, `rule`: allowed
  subject kinds, entity object kinds or value types, symmetry, and whether an
  explicit statement is required — ownership, assignment, influence, adoption);
  `KnowledgePredicate.violation(subjectKind:objectKind:value:)` checks that rule
  and then the value's closed vocabulary (`hasStatus` takes only
  `KnowledgeStatus`, the spec's decision/action/risk states plus open, blocked,
  revised and ready), returning a fixed snake-case `KnowledgeSchemaViolation`.
  `KnowledgeTemporalValue` keeps the stated precision (`yyyy-MM`, `yyyy-MM-dd`,
  an instant in UTC), accepts ASCII digits only and rejects impossible dates; `KnowledgeTypedValue` is the string/number+unit/boolean/date/enum
  object whose wire form always carries the value as a string.
  `KnowledgeEvidenceValidator` checks every citation against the transcript
  revision being compiled — known, distinct segments, contiguous and cited in
  transcript order (so a quote cannot be stitched across a skipped "not" or a
  reordered line), a quote verbatim under a conservative normalization
  (canonical composition, typographic quotes folded, whitespace collapsed;
  case, diacritics and punctuation kept) and a time range whose both ends fall
  inside a cited segment (it may cross a pause between them, never sit in one)
  — and returns a fixed `KnowledgeEvidenceRejection`.
  Quote hashing needs CryptoKit and is the app's job.
- **The canonical store (K1.2, `KurnSchemaV7`).** Ten models in
  `Models/KnowledgeCanonicalModels.swift` (`KnowledgeEntity`, `KnowledgeAssertion`,
  `KnowledgeEvidence`, `KnowledgeEvent`, `KnowledgeRelation`) and
  `Models/KnowledgeOperationalModels.swift` (`KnowledgeJob`, `KnowledgeRevision`,
  `KnowledgeReview`, `KnowledgeContext`, `SourceContextLink`). They relate by persisted
  UUIDs, never by a relationship to `Meeting` or to each other, and store every closed
  vocabulary as its KurnCore raw value (`KnowledgeStoreVocabulary.swift` adds the job,
  review-item and event vocabularies). An assertion keeps valid time as stated
  (`validFromText`/`validToText` at their precision, half-open) apart from transaction
  time (`recordedAt`, `retractedAt`) and records the predicate registry version it was
  checked under; a merged entity is a redirect (`mergedIntoID`); evidence carries the
  transcript fingerprint it cites and `isAvailable` for when that revision is gone.
  `KnowledgeJob.idempotencyKey` and `KnowledgeRevision.number` are unique, and a
  revision is the projection outbox while `projectionPending`. A meeting without a
  `SourceContextLink` is in context `unknown`, so the V6 → V7 stage is lightweight and
  writes nothing. `LibraryEraser` deletes all ten. `KnowledgeStore` (K1.5) is
  their canonical writer. K1.6 wires the shared queue, meeting articles and
  disabled-by-default, local-only canonical extraction.
- **Transcript revisions and anchors (K1.3).** KurnCore's
  `KnowledgeTranscriptSnapshot` freezes transcript array order and UUID anchors
  (lowercase strings), and produces versioned, length-prefixed UTF-8 canonical
  bytes over language and every segment's ID, speaker label, exact IEEE time
  and confidence bits, and unnormalized text. Creation dates, pipeline reports
  and speaker display names are not revision inputs. Duplicate IDs, non-finite
  values, inverted/negative or unrepresentable times fail closed; millisecond
  anchors round start down/end up without dropping sub-millisecond spans.
  The app's `KnowledgeTranscriptRevision` hashes those bytes with SHA-256
  (lowercase hex) and resolves evidence only when its fingerprint matches;
  preserving a quote or UUID after an edit never makes an old revision valid.
  `Transcript.knowledgeRevision()` decodes authoritative bytes directly and
  rejects corruption rather than fingerprinting the presentation getter's empty
  fallback. There is no transcript history or new persisted field/migration.
  `KnowledgeStore` recaptures the revision at commit and marks replaced
  evidence unavailable when its source revision is gone. Readers must still
  resolve against the current fingerprint: an edit may precede recompilation.
- **Extraction contract (K1.4).** KurnCore's `KnowledgeExtraction.decode`
  validates the complete version-1 Codable document before it can leave a pass:
  known fields/vocabularies only, local unique references, predicate/object rules,
  stated dates, original contiguous verbatim evidence, cited attribution anchors
  and explicit examined-segment coverage. Models cannot set review state, confer
  human confirmation, or emit merge/context-link operations. Events require a
  supporting assertion with a compatible predicate; a superseded event belongs
  to the object of `supersedes` (the replaced entity). Replies are capped at 2 MB;
  decoding errors expose fixed codes rather than content.
  `Application/Knowledge/KnowledgeExtractionService` is value-in/value-out: K1.6b
  composes it through `KnowledgeCompilationCoordinator`. It accepts an injected `LLMProvider`, `ContextBudget` and live
  authorization callback. Full context goes first when it fits; otherwise
  segment-aligned blocks retain every anchor. Planning reserves half the response
  allowance for assertions/evidence and budgets the UUID coverage list against
  the other half. Both initial and targeted input use the full allowance when
  possible. Provider-reported output truncation permits one split of a pass
  into two smaller passes, never recursive, within the same 64-pass ceiling.
  The effective output allowance follows the provider: Apple extraction reserves
  from its 1,024-token ceiling, including coverage planning and repair/split calls.
  Structured calls ask the Apple adapter to reject unfinished JSON as truncation,
  enabling the bounded split rather than repeating an oversized repair; balanced
  schema errors still use the normal single repair. Prose calls are unaffected.
  Oversized individual segments fail explicitly. One targeted round requests unexamined anchors; a remaining gap
  fails the run. At most 64 extraction passes, each with one fresh repair on a
  schema/validation error (never on transport failure); repair sends only the
  original input and a fixed diagnostic, never echoes the bad reply. Validation
  uses the full original transcript order even for noncontiguous targeted input,
  preventing stitched evidence across omitted segments. Pass-local references
  stay separate for K1.7 entity resolution. Policy/consent is re-evaluated before
  constructing prompts and before each provider call, including repairs; output
  records source fingerprint, strategy, examined anchors and targeted pass count.
  This does not enable cloud processing, write canonical rows, or establish
  semantic extraction accuracy: K0.4 benchmarking remains.
- **Canonical writer and projection outbox (K1.5).** `KnowledgeStore` is a
  `@ModelActor` over the existing protected container. The host must own one
  writer per container; K1.6a's `KnowledgeStoreHost` constructs it off-main,
  lazily and once for its queue; UI
  continues to read through its own context. Only Sendable source snapshots,
  encoded extraction documents and receipts cross its boundary. Each operation
  opens a fresh context, avoiding cached source bytes across commits.
  A source token covers the meeting's complete, UUID-ordered recording set
  (including missing transcripts), transcript identities/fingerprints, recording
  dates and capture state, meeting metadata and the persisted context. Missing,
  corrupt, unready or ambiguously contextualized sources fail closed. Compilation
  must cover every nonempty transcript; each pass is decoded and evidence-checked
  again against persisted source order. Local refs remain separate per pass and
  recording. K1.7 emits lexical review candidates while retaining distinct IDs;
  neither people nor shared names are auto-linked.
  A live authorization callback is awaited immediately before the synchronous
  transaction; persisted context classification cannot lower the host's source
  classification, and a named context policy must be present. Source, policy
  revision and canonical revision are rechecked before mutation. The canonical
  graph, succeeded job, retained attribution/ref-map provenance, coverage and
  `KnowledgeRevision.projectionPending` outbox are saved together; failures roll
  back all rows and retractions. Authoritative JSON (provenance, coverage, aliases,
  typed values and evidence anchors) uses `JSONStorage` envelopes with checksums; unreadable/future job data is refused
  without overwriting its bytes. The injected `beforeSave` seam proves rollback.
  KurnCore's `KnowledgeCompilationIdentity` encodes an unambiguous, reversible
  job key over scope, meeting ID, meeting source fingerprint, extractor version
  and extraction schema version (independent of SwiftData's schema version).
  Completed retries return the original receipt even after an unrelated
  canonical commit or writer recreation. A later compilation in the same scope
  makes the earlier job obsolete: restoring A after A → B cannot replay retracted
  A as current knowledge; it fails explicitly and requires a new generation.
  Replay also requires the original assertions to remain unretracted and
  supported, covering invalidation caused by a compilation in another scope. Changed source or policy is never a replay;
  a completed key under an earlier policy revision is refused and requires an
  explicit rebuild/generation change. Cancelled jobs cannot be committed.
  Recompilation retracts previous machine assertions in its own scope, retaining
  history and human-confirmed assertions whose evidence still resolves. Evidence
  from changed/removed recordings is marked unavailable across scopes and
  unsupported assertions are invalidated. Relations and events remain historical
  records tied to their assertion/revision; readers must filter through them.
  The latest pending projection is durable across reopening. K2.1 publishes
  pages and acknowledges covered revisions in the same transaction, requiring
  the exact current canonical/source/policy snapshot. There is no standalone
  acknowledgement API; a stale worker cannot erase newer work.
  No schema migration or cloud processing is enabled by this boundary.
- **Durable article scheduling (K1.6a).** `KnowledgeJobQueue` is owned by
  `AppEnvironment`, shared by the wiki facade and future canonical producer.
  Typed host intents and lease-checked, versioned checkpoints live in
  `KnowledgeJob`, written through the environment's one `KnowledgeStoreHost`.
  A stale worker cannot checkpoint or resurrect erased work. A failed clear keeps
  its original cutoff and publication barrier, retrying on later opportunities.
  Obsolete source/provider cancellations allow a fresh coalesced generation,
  while deliberate cancellations remain final. Deferrals do not
  consume the failure limit; three genuine failures require manual retry.
  `ResourceWorkKind.knowledgeGeneration` reserves 50 units locally or 5 remotely
  (initial estimates); the reservation is released before completion is observed.
  Recording-session start cancels admission/in-flight work before capture starts;
  ending the session permits resume. Backgrounding pauses, foreground activation
  resumes, and automatic admission is capped at five jobs per activation. Direct
  user requests do not silently grant another automatic quota. Deferred original
  user requests remain distinct from fresh permission to override a circuit.
  A launched provider call interrupted remotely requires explicit retry; crashes
  before resource admission can resume. Recovery checks for an already committed
  article before repeating a call; forced rebuilds must differ from their captured
  prior article revision (independent of wall-clock order), covering a crash between article save and job
  completion. Foreground resume remains authoritative. The optional
  `ai.kurn.knowledge.processing` BG window admits on-device work only, checks
  protected-data/store availability and expires cooperatively without late
  publication or a model download. It never grants cloud background processing.
  `WikiCoordinator` keeps its observable/menu/bulk API, consent and provider
  circuit; it is now the queue's `meetingArticle` producer. Source and provider
  configuration are rechecked before publication, failed article saves propagate,
  and staged notes belong to the job checkpoint. The legacy meeting summary
  checkpoint may seed a compatible wiki run but is never overwritten or cleared
  by it. Clear Wiki erases article-job checkpoints; meeting deletion includes
  article jobs in its journaled model commit. Late replies refetch the meeting
  and cannot recreate deleted articles/jobs. Repeated forced requests coalesce
  while unfinished; a completed rebuild allows a new generation.
  Canonical extraction is a separate producer (K1.6b, below). The independent
  `knowledgeEnabled` flag remains off by default, and existing wiki consent
  never authorizes compiling knowledge across meetings.
- **Canonical extraction producer (K1.6b).** `KnowledgeCompilationCoordinator`
  is retained by `AppEnvironment` and shares the article queue/writer. Successful
  transcription submits canonical work only while `knowledgeEnabled`; there is
  no implicit library backfill or new Settings/navigation UI. The selected
  Knowledge provider/model is captured. A cloud provider is admitted only under
  its automatic grant in the cloud-consent ledger (see "Cloud consent"), checked
  at submission, before every request and in the queue's eligibility, even if an
  injected policy permits more; on-device needs no grant. A cloud run uses the
  `.conservative` context budget, on-device keeps `.onDevice`. No model download
  is triggered. The stable host-owned workspace policy (`localPolicy`) names every
  provider with a grant for `.internal` sources and keeps the default's revision
  (a new grant must not hide Knowledge compiled before it; egress is re-checked
  live against the ledger), and is default-deny without one; named context
  policies must be supplied explicitly, never silently replaced by that default.
  Local scope/control preferences and backfill UI are described in K2.7 below;
  corporate-policy editing remains gated.
  `KnowledgeCompilationIdentity` retains exact v1 keys and adds reversible v2
  keys with a generation digest covering provider configuration, model, policy
  revisions and an explicit rebuild operation UUID. Retries keep their operation
  identity; restoring an obsolete/cancelled compilation requires an explicit
  new rebuild identity rather than silently minting a generation.
  Recording dates are UTC instants; the host does not invent a historical
  capture timezone. Persisted context kind is supplied to extraction.
  Completed recording passes are checkpointed in the protected job, bound to
  its exact source/policy identity and revalidated on restore. An interrupted
  recording restarts; earlier complete recordings do not. Source/context and
  live authorization are rechecked before retrieval, prompts, every call/repair,
  each checkpoint and commit. A changed source/provider/policy discards the old
  intent; disabling the feature defers it. Deleting a meeting purges unfinished
  extraction jobs, preventing late publication; its canonical history is then
  purged through a deletion tombstone ("Knowledge deletion (K2.8)" below).
  Canonical commit requires the running queue lease and saves that same job's
  succeeded state, graph, provenance and projection outbox atomically. Expired
  or erased leases cannot publish or recreate jobs. Generic queue completion
  cannot mark extraction successful, and operational erasure retains succeeded
  canonical provenance. Completed submissions validate replay/current support
  before the terminal shortcut. No schema migration or cloud activation is
  introduced by this integration. Genuine producer failures emit content-free
  `knowledge_compilation` reliability events with operation ID, elapsed time and
  fixed error code; expected deferrals/obsolete intents are not failures.
- **Review-only entity resolution and reversible redirects (K1.7).**
  KurnCore's `KnowledgeEntityResolver` normalizes case/diacritics and whitespace,
  preserves punctuation for exact matching, and records exact-name, alias and
  token-Jaccard features. Different kinds and generic shared words alone are
  excluded. Ties sort by UUID. The external specification's numeric weights
  were unavailable; `experimental-v1` is an explicit, configurable STARTING
  profile, not a reproduction of those numbers or a calibrated probability:
  0.60 exact name + 0.15 alias + 0.25 token similarity, minimum 0.15, top five.
  Every match requires human review, including every person/homonym. No threshold
  or flag enables automatic linking before the K0.4 holdout gate is met.
  Canonical commit retains separate UUIDs and stages `mergeCandidate` reviews in
  the same graph/provenance transaction. Candidate origins are restricted to the
  already-authorized meeting, compilation scope and current policy revision.
  Up to 128 historical jobs, 1,024 entities and 128 suggestions are considered;
  truncation and the profile are retained in optional provenance metadata.
  Cross-meeting reads require the host's explicit authorized meeting-ID set
  (up to 16), never just a scope label. Each current source/context passes live
  local policy before origin-bound provenance, names or aliases are returned.
  Unauthorized redirect targets are omitted, with incomplete resolution marked;
  alias unions are scoped views, never destructive writes to the target row.
  `KnowledgeStore.mergeEntities` / `undoEntityMerge` are host-only seams for an
  explicit human decision, not model tools. They check fresh source/policy and
  canonical revision, kind, visible state, all affected inbound origins, cycles
  and depth. Redirects are not path-compressed. Assertions, relations, events,
  evidence and original names/aliases are never reassigned or rewritten.
  Mutation proofs are separate from discovery limits: fresh write snapshots
  contain source tokens only, origin discovery pages through matching jobs, and
  audits pin exact origin job IDs for all affected identities. Undo verifies
  those specific jobs even after 128 newer compilations or 1,024 other entities.
  The edge, versioned/checksummed review audit, candidate state and a new
  projection-outbox revision commit atomically. Operation UUIDs are idempotent;
  undo records its own receipt and reopens its candidate. An undone operation
  cannot accidentally reapply itself. Undo may prove historical origins under
  CURRENT live policy without exposing old-policy names as fresh candidates.
  Unknown/corrupt audit data is refused without overwriting its bytes. The
  extraction pipeline is `knowledge-extractor-v2`; queued older versions are
  discarded rather than relabelled as current work. Existing provenance remains
  readable; no schema migration, navigation or cloud activation is introduced.
  Review UI, broader authorized candidate browsing and holdout calibration stay
  in K2.6/K0.4; numeric/semantic matching accuracy has not been established.
- **Public material is synthetic.** The golden set
  (`Packages/KurnCore/Tests/KurnCoreTests/Fixtures/knowledge/`, format
  `kurn.knowledge-fixture` v1) holds fictional meetings in Portuguese and
  English with stable segment IDs, the entities and assertions a correct
  extraction yields, what it must not assert and which entities it must not
  merge. `KnowledgeFixtureTests` checks that every quote is verbatim in the
  segments it cites, every reference resolves, values use the spec's closed
  vocabularies, organizations are named `Example …`, and each hard case the
  set claims (negation, irony, homonyms, wrong speaker, provisional decisions,
  relative dates, late arrival, reopening, supersession, units, corrected
  transcripts, prompt injection, external contexts, forecasts that are not
  decisions) is structurally present: every case names the segments that
  exhibit it (`caseSegments`), each of those is cited as evidence or named by a
  refusal (a refusal must name it for irony, injection, wrong speaker,
  provisional decisions and forecasts), every refusal quotes its tempting span
  verbatim (a planted instruction in full; a corrected value from the earlier
  revision and absent from the current one), every relative-date segment resolves to a date or a month, and a
  reopening is an asserted status change — so removing or rewording the
  segment that makes a case hard fails the suite. Fixtures, screenshots, issues and
  commits never name a real organization or use real meeting content.

Where the checkout makes the specification bend:

| Spec says | The checkout has | Decision |
| --- | --- | --- |
| A separate `KnowledgeHarness` with its own tool loop and JSON envelopes `{data, revision, coverage, …}` | `NativeHarness` (AgentHarness) driving `HarnessChatService`; source tools return compact plain text (`ChatSourceToolText`) because JSON per item cost ~45% of a page | Register knowledge tools as more `AgentTool`s in `Application/Agent/Tools/`; keep the compact text form and add a final `revision: … coverage: … warnings: …` line instead of a JSON envelope. Tool *arguments* stay JSON. No second harness |
| Harness limits of 8 tool calls / 2 hops / 12k context tokens | `AgentBudgetPlanner` sizes 10–48 turns and 20–192 calls from the workload; the context window is resolved per model | Keep the planner; the 2-hop / 20-evidence / 40-node bounds become per-tool argument limits, not run limits |
| A local planner + synthesis call when the provider has no tool calling | Chat requires an `AgentModel`; Apple's on-device model shows `ChatArtifactProviderNotice` | Ask stays agent-only. What must work without a provider is *reading*: Knowledge Home, pages, timeline, graph and lexical/semantic search, all offline |
| Full-context-first extraction for meetings up to 2–3 h | `ContextBudget` already fits a whole transcript per model window, with `SummaryService`'s map/reduce as the overflow path; the on-device model's window is far too small for a full transcript | Reuse `ContextBudget` for the full-vs-blocks decision; the on-device model may run only the blocks strategy, and only once the K1 evaluation shows it meets the gates. No silent truncation: the strategy and coverage are recorded on the job |
| `transcriptRevisionID`, evidence pointing at a transcript revision | `Transcript` has no revision identity and keeps no history; `TranscriptSegment.id` is a UUID that a re-transcription regenerates | K1 adds a revision fingerprint (SHA-256 over the canonical segment encoding, as `WikiCoordinator.contentHash` does today) and segment IDs as evidence anchors. With no retained history, evidence from a superseded revision is marked unavailable (spec §12.1 permits this) rather than pretending to be verifiable |
| Single writer `ModelActor` for commits | Coordinators are `@MainActor` over the app's main `ModelContext`; services run off-main on value types | ADR: a `KnowledgeStore` `@ModelActor` on the same container for canonical commits and the projection outbox, with Sendable DTOs at its boundary; UI reads stay on the main context. Measure main-thread fetch cost before adding any second store |
| New models alongside existing ones | `KurnSchemaV6` (1.5.0, the harness session storage) listed the live classes | Done in K1.2: `KurnSchemaV7` (1.6.0) freezes V6, adds the ten knowledge models additively through a lightweight stage, and `SchemaV6MigrationTests` writes every V6 entity |
| Graph as SwiftData relations | `Meeting` cascades its derived artifacts; there is no shared-entity model yet | Entities, assertions and evidence relate by persisted UUIDs, never by `@Relationship` to `Meeting` (no blind cascade across shared entities, spec §13). Deletion is explicit: `MeetingLibrary` commits a tombstone with each meeting or transcribed-recording deletion, `KnowledgeDeletionCoordinator` purges it, and `LibraryEraser` removes every knowledge row ("Knowledge deletion (K2.8)") |
| Typed `AppRoute` and `kurn://entity/…` deep links | The app deliberately declares no URL scheme (any app could open one, see "Cross-device control") | Typed in-process routes only; Markdown links in generated pages resolve through a router that accepts `entity:`/`evidence:` IDs and nothing else, consistent with `MarkdownPresentation` disabling links. No registered URL scheme |
| Embeddings and hybrid retrieval | `SemanticSearchService.hybridSearch` (on-device `NLContextualEmbedding` + BM25 + RRF) over `SemanticChunk` | Extend the same index with typed documents (page, assertion, event, alias) carrying `modelIdentifier`; no cloud embeddings, so no extra consent for indexing |
| Export bundle (JSONL, Markdown, GraphML) | Meeting export via share sheet (`MeetingExport`, `DocumentExport`) | Knowledge export (K6.2) is off by default (`AppSettings.knowledgeExportEnabled`, which sets the local policy's `exportAllowed` and `.export`); the browser saves a `kurn.knowledge-export` JSON bundle through `fileExporter`, with no generic share sheet |
| Settings → Knowledge with provider, scope, backfill | Settings → Wiki (`WikiSettingsView`) with `wikiEnabled` and bulk missing/rebuild | Settings → Wiki becomes Settings → Knowledge: the meeting wiki keeps its own toggle and consent, Knowledge adds its own; neither implies the other |
| `ProcessingPolicy`, `KnowledgeWorkspace`, `KnowledgeContext` (§20.1) | Provider consent is per feature (`wikiEnabled`, `correctionEnabled`, …); the provider circuit breaker gates automatic calls | One workspace in `mode=privateCorporate`; `KnowledgeProcessingPolicy` (KurnCore, pure) evaluates destination × operation × classification and is checked before retrieval, prompt assembly, egress and export. Folders are not ACLs |

### Global wiki projection (K2.1)

`KnowledgeWikiProjector` in KurnCore builds deterministic structured entity
pages from host-checked assertions. Redirects group views without rewriting
fact or evidence IDs; incoming relationships preserve their direction. Every
claim retains modality, negation, authority, confidence, review state,
attribution, valid-time precision and transaction time. It makes no temporal
state inference or last-mention-wins choice; that remains K3. Sections and
entries have stable ordering. Markdown escapes all untrusted text and emits
only host-owned `entity:`/`evidence:` links, with no registered URL scheme.

`KnowledgeStore.wikiProjectionSnapshot` requires an explicit allowed meeting-ID
set (currently at most 16), live feature/policy authorization for local page
processing, and every persisted context policy. It binds assertions to exact
succeeded compilation provenance in the requested scope/current policy,
revalidates evidence against current transcript bytes, and resolves attribution
through the original segment. Retracted/rejected/unsupported claims and
redirects outside the selected origins do not contribute pages, names or IDs.
Scope strings are not ACLs. Candidate-discovery caps are not projection caps:
entity origin proofs traverse authorized history. Projection bounds are 2,048
entities, 4,096 active source assertions, 16,384 evidence items and an 8 MiB
stored envelope; exceeding them is an explicit refusal, never silent truncation.

`publishWikiProjection` re-reads and compares all inputs, rebuilds pages, and
atomically saves a versioned checksummed projection in a succeeded `.projection`
job's `checkpointData` in the existing protected store. Its stable key covers
scope and selected source IDs. Only revisions whose complete source/scope
dependencies are covered are acknowledged; unrelated and unrecognized work
stays pending. Old-policy work is retired only when a newer succeeded
compilation in the same scope/current policy covers every affected source and
its current fingerprint; no historical canonical rows are deleted. Human
merge/undo coverage is checked against its retained audit.
Invalid output or save failure preserves the previous valid pages and outbox;
unreadable/future payloads are never overwritten. Reads recheck authorization,
policy, source tokens, canonical revision and canonical content before returning
a cached page; stale caches return nil. No provider is needed to build/read.

Optional local narrative output is a versioned list of plain-text paragraphs
with assertion IDs. Each paragraph needs unique citations belonging to that
page; the host renders their evidence links. Missing/foreign/future/oversized
output is refused for the whole publication. This checks citation integrity,
not semantic entailment. Narratives stay visibly separate from attributed
claims and never become canonical evidence. "Rebuild pages" generates them
(`KnowledgeSettingsCoordinator.pageNarratives`): KurnCore's
`KnowledgeNarrativePrompt` shows the model a page's claims (up to 40) as `[c1]`
references and keeps only paragraphs citing them, within the projector limits.
Narratives go to the 24 pages with the most claims, from the Knowledge provider
under the extraction host checks (`narrativeModel`: a cloud provider only with its
automatic grant, `.pageNarrative` evaluated over the meetings' classifications,
checked once at the start). Generation is best effort: a failed or uncited page
keeps its claims alone. The browser read loads the published narratives and drops
any that no longer validate; the entity page shows them under "Notes", labelled
as generated, above the claims, and Ask reads them with `get_wiki_page`.

### Knowledge maintenance lint (K2.2)

`KnowledgeMaintenanceLinter` in KurnCore returns the v1 Codable maintenance
schema: stable deduplicated finding IDs, closed codes/recommendations, canonical
revision, completeness and per-recording segment examination counts. These are
measured coverage counts, not semantic recall/precision. Broken entity/evidence
links identify only the readable source page; unknown targets never appear in
reports. Stale caches are not inspected for old IDs or counts. Duplicate identity
candidates stay suggestions for human review, with reversed/repeated pairs folded
into one finding. Recommendations never execute merges, deletion or repairs.

`KnowledgeStore.maintenanceReport` is a host-only read API with fresh contexts and
no awaits after authorization. The shared `KnowledgeSourceAuthorization` (also
available as `KnowledgeWikiAuthorization`) checks the local `.semanticLint`
operation independently of `.pageNarrative`, plus the explicit source-ID ACL,
feature flag, inherited classification and persisted context policies. It reads
only the requested scope's source-bound compilations. The latest canonical job
in that scope determines coverage; an old policy/fingerprint is an explicit gap.
Invalid/duplicate/unknown examined anchors cannot count as complete coverage.
Only current visible, unmerged entities without a readable evidence-backed claim
are orphan candidates; historical identities retained by recompilation are not
reported as garbage. Selected candidate subject envelopes and current source/
policy/entity bindings are verified before reading review payloads.

The report contains no names, quotes, prompts, Markdown or free-form error text.
Canonical corruption produces an incomplete report and suppresses speculative
identity/page details; unrecognized future selected schemas are refused without
rewriting bytes. Unselected review subjects disclose no IDs, payloads or counts
and cannot block this scope on their schema. Well-formed but broken projection
pages can be diagnosed through the envelope-only reader; normal wiki reads still
require full validation. No job/review/page/canonical/outbox state changes during
inspection. Reports are freshly computed, never a cached authority for later
reads or repair. The JSON maintenance contract does not change SwiftData schema.

Limits fail explicitly rather than returning a clean truncated report: 16 source
meetings, 4,096 succeeded jobs examined per source, existing wiki entity/fact/
evidence limits, 1,024 recording coverage entries and 8,192 review rows/findings.
This step enables no model calls, semantic LLM lint, egress, automatic scheduling,
new navigation or maintenance UI; the latter remains K2.6–K2.7.

### Meeting detail Knowledge mode (K2.3)

`MeetingDetailMode` is the meeting-local mode catalog. Recordings / Transcript /
Summary / Chat remain available; the disabled-by-default `knowledgeEnabled`
flag adds Knowledge between Summary and Chat. This does not change root
navigation; the global navigation prototype/review gate remains K0.5.
`MeetingWikiContent` is shared by the old sheet shortcut and the inline notes
section, so article viewing/read-aloud remains one presentation path.

`KnowledgeCompilationCoordinator.readMeetingKnowledge` authorizes exactly the
route's meeting ID under live host/local page policy and persisted context
policy, reads the canonical snapshot and computes contributions without a
provider, extraction, projection publication, outbox acknowledgement or writes.
The DTO rejects foreign-meeting assertions; redirect-aware entity contributions
retain original claim IDs, evidence, attribution, modality and negation. Header
counts deduplicate claims by assertion ID and passages by recording, ordered
anchors, time bounds and normalized quote. Distinct evidence-link UUIDs for the
same passage do not inflate its count; identical passages in different recordings
remain distinct. Structured claims show subject, localized predicate and object/
value in their original direction, separately from the quoted evidence. Generated episodic notes are separate from those
source-backed contributions and never become evidence.

`MeetingKnowledgeViewModel` clears old data before each read, rejects stale
request completions, cancellation, feature revocation and foreign meeting
results. Presentation is keyed to the current route even before its next task
starts. `MeetingKnowledgeRefreshDriver` treats store saves as invalidation
signals only (no models/notification payloads are read), debounces repeated saves,
and refetches on foreground activation. Access denial/corruption shows generic
unavailable copy without names, counts or raw errors. Disabling the flag hides
the mode/header immediately and returns selection to Recordings.

Inline article content/actions appear only after a current authorized read.
Once that read has loaded, the Knowledge tab is the wiki's only home, as the
Transcript and Summary tabs are for theirs: the overflow menu drops "View wiki"
and "Generate/Regenerate Wiki". It keeps them whenever no tab shows the wiki:
Knowledge off, the meeting excluded from Knowledge, or the read unavailable. The inline chip has the menu's gate (`canGenerateWiki`). With
Apple on-device it revalidates the meeting and calls the existing wiki queue with
`localOnly: true`; that admission checks the selected provider before
assembling/queuing work, whose immutable provider remains local on recovery.
With another provider it runs the menu's explicit, forced episodic generation.
Provider changes obsolete the work rather than switching destinations. Existing
episodic wiki consent/legacy shortcuts remain independent. This step enables no
canonical cloud processing or automatic generation.

UI tests opt in through the ephemeral UserDefaults argument domain, seed a
synthetic meeting through the real canonical commit boundary in an in-memory
store, audit the new mode, and retain compact / inline-notes / accessibility-size
screenshots. `ui-tests (main)` exports attachments as `ui-review-previews` for PR
review. All seven app languages include the new labels; the existing default-off
four-mode accessibility audit remains in place. Entity/evidence destinations,
review/settings UI and the global Knowledge Home remain later K2 work.

### Scoped Knowledge reader and navigation prototype (K2.4 / K0.5)

Meeting contribution names open `KnowledgeBrowserView`, a separate scoped
reading stack behind `knowledgeEnabled`. Knowledge Home lists entities from
exactly the selected source IDs (currently 1–16); each entity has Overview and
Sources, then evidence detail and a source transcript with the cited anchors
highlighted. Routes hold UUIDs only. No model output or arbitrary URL creates
a destination. Structured claims keep original relation direction, modality,
negation and stated valid-time precision; quotations and source attribution
remain separate. This is a current supported-assertion view, not a temporal
state reducer (K3). The production meeting entry selects that meeting only;
it never expands access to the rest of the library.

`KnowledgeStore.browserRead` awaits live host authorization, then uses one fresh
context with no intervening suspension: existing source/context policy checks,
canonical provenance/evidence validation and redirect-origin proofs precede
source titles and the selected recording's transcript/file reference. A missing,
foreign, stale, rejected or unavailable citation refuses the destination. Home
and pages do not preload transcript DTOs; only an explicitly selected evidence
route receives its source transcript. Reads neither queue work, call a provider,
publish/repair projections nor acknowledge the outbox. No new schema is needed.

`KnowledgeBrowserViewModel` masks results for another source set or evidence
selection, clears on reload and ignores invalidated/cancelled/superseded reads.
Store saves are invalidation signals only, debounced before refetch. Route
changes, closing the reader, feature revocation and scene deactivation stop
playback and clear content; returning active revalidates. Audio is explicit,
recording-relative, and checked against fresh evidence before setup and again
after asynchronous player loading. Pending setup cannot resurrect revoked audio
or overlap a newer setup. Setup defers remote transport registration until
authorized playback. The adapter only releases an audio session it has acquired;
opening/refreshing an idle reader cannot stop another consumer's shared session.
Source names are not passed into setup's Now Playing metadata. The reader offers
no native text-copy/export actions that would bypass the corporate export policy.
The fake audio adapter tests these boundaries without opening the
simulator's audio session; real playback remains a physical-device check.

With `knowledgeEnabled` there is still one main screen, the meetings list in
its original stack (the compact stack, or the regular-width sidebar), with its
buttons moved (`MeetingsListToolbar`). The bottom bar holds the four places —
Meetings / Knowledge / Ask / Documents — in one glass group and, after a
flexible `ToolbarSpacer`, the red Record button in its own (its title gives
way to its icon at accessibility text sizes). Meetings is the screen itself,
marked current by its filled symbol, the accent colour and the selected trait
(never colour alone). The list's controls — Library, Filters, Sort and Select
— are each open in the navigation bar, not collapsed into a menu, and Settings
has its own group after a fixed spacer; on regular width the sidebar replaces
the Library button. Selection mode keeps its bottom Export/Delete, as without
Knowledge. With the feature off the original placements stay (Library, Filters,
Ask and Documents at the bottom, Select and Sort beside Settings at the top).
The navigation review first chose a `TabView` with a custom root bar; it was
replaced by this single screen, so there is no tab bar to hide.

Knowledge opens `KnowledgeLibraryDestination` as a sheet with a Done button;
Ask opens the library conversation in its existing sheet
(`MeetingChatView(meeting: nil)`, the app-owned conversation; provider/source
validation, history, draft and artifact behaviour are unchanged, and it is
offered even with semantic search off, while a provider without agent support
still disables the composer); Documents pushes `DocumentsListView` with its
artifact detail/create flows. No chat/provider capability is enabled by
navigation. The list hosts the recording mini bar as before, and so do the
Knowledge and Ask sheets that cover it (`hostsRecordingMiniBarInSheet`):
there, expanding the recorder closes the sheet and opens the recorder once the
sheet has disappeared, since the recorder is presented from the root and cannot
present over it or during its dismissal. The Knowledge
sheet's source selection belongs to the list (`knowledgeSourceIDs`), so closing
and reopening the sheet keeps it; turning Knowledge off closes the sheet and
forgets the selection.

`KnowledgeLibraryDestination` starts without an inferred library source scope.
Its picker requires an explicit selection of up to 16 meetings and disables
additional unchecked rows at that bound. Done applies the draft; Cancel keeps
the current scope. Changing scope recreates the reader and clears old routes,
content and playback. Every read still uses the existing live host/context
policy checks; the picker never turns an accessible meeting title into a grant
for canonical knowledge. Scope is session-local, not a persisted authorization.

`KnowledgeNavigationPrototype` is a DEBUG-only deterministic launch of that same
screen, opened on the Knowledge sheet with the synthetic meeting preselected for
captures (`MeetingsListView.initialKnowledgeSourceIDs`). Ask and Documents are
the real screens rather than preview placeholders. `MeetingKnowledgeUITests`
checks the four places and the record button on one bottom row, artifact access,
the open top controls with Settings apart, retained filters/bucket after Ask,
and explicit Knowledge source selection kept across closing the sheet.
CI exports the captures as `ui-review-previews`; copy is localized in seven
languages. Wider-layout and physical-device recording/audio checks remain part
of release validation.

### Knowledge local search (K2.5)

Knowledge Home has an offline search field over the explicitly selected meetings.
`KnowledgeSearchIndex` projects typed page, alias and assertion documents from the
same freshly authorized, evidence-validated pages used by the reader. IDs retain
those types; assertion documents are per canonical evidence ID, so the matching
snippet and opened passage always agree even for multi-citation claims. A pure
`KnowledgeSearchCorpus` DTO keeps Services independent of the Application reader.
No fabricated recording IDs/timestamps are inserted into transcript
`SemanticChunk`s. Canonical event indexing waits for K3's validated temporal read.
The corpus is disposable memory, not a second persisted canonical/embedding store,
so this stage changes no schema or migration. Limits are explicit: 16 meetings,
8,192 documents, 8 MiB corpus, 256 query characters/1,024 UTF-8 bytes and 40 results.
Oversized input fails closed, never silently indexes only a prefix.

`HybridSearchRanking` in KurnCore supplies the same BM25/RRF engine to transcript
retrieval and typed knowledge retrieval, with stable ties. Knowledge additionally
folds case/accents and ranks literal/name matches, including Chinese substrings.
Names, aliases, structured qualifiers and source quotes are searchable. Snippets
are literal, bounded source quotes/aliases; they are not generated summaries or
Markdown links, and offer no copy/export bypass. Pages/aliases open the scoped
entity reader; assertions open freshly resolved evidence by canonical IDs.

Lexical search works with semantic search disabled and without OS assets. Dense
ranking requires the existing semantic-search opt-in, a separate `.embedding`
policy grant and fresh authorization after resource admission. It uses only
already installed NLContextualEmbedding assets (never `requestAssets`), on-device,
under the shared scheduler. Dense work is all-or-nothing for corpora up to 128
documents/128 KiB; larger corpora and unavailable/invalid vectors keep the entire
lexical corpus. Vectors carry their document/revision and model identifier and
are released with the request; no cloud or model-download path is introduced.

`KnowledgeSearchViewModel` checks source scope, full content/revision and policy
before work, again before embedding, and after asynchronous ranking before
publication. It validates returned document bytes/IDs against the fresh corpus.
Presentation always observes the state even when a different query/scope masks
its content, so publication triggers a SwiftUI redraw. Epochs and cancellation
prevent old queries replacing newer results; query,
source/store/policy, route, feature, semantic-setting and scene changes clear old
results. The search controller stays installed across canonical loading states;
a query revision advances after invalidation so lifecycle/onChange ordering
cannot leave the results permanently loading. Submission dismisses the keyboard
while retaining the query. Seven
languages cover the search prompt and result types; synthetic UI coverage checks
alias → page and quote → evidence with semantic search off.

### Knowledge review inbox (K2.6)

The scoped Knowledge reader opens Review from its native toolbar. It shares
that explicit 1–16 meeting selection, and never enumerates a library-wide inbox.
`KnowledgeReviewRows` authorizes `.semanticLint`, proves entity origin bindings
before showing candidate names/history, and validates canonical passages in a
fresh context. Discovery pages through reviews in batches of 256, caps open, dismissed and merge-history
results independently at 128 each, and labels incomplete scans (16,384-row budget) rather than
blocking a selection on unrelated history. Reads
never insert reviews, acknowledge jobs, repair citations or mutate identities.
Unknown schemas fail closed. Missing, changed or invalid evidence produces an
inspection notice with no unvalidated quote or payload.

Candidates offer **Keep separate**, **Review again**, and a confirmed merge into
the displayed target identity. History exposes the existing audited merge/undo
boundary. `KnowledgeStore.reviewDecision` refetches the inbox, compares the exact
source fingerprints, policy key and canonical revision, checks a separate local
extraction-policy grant, and derives merge endpoints from the authorized review
rather than accepting UI-supplied names/IDs. Merge and undo retain the K1.7 origin,
redirect-graph, incoming-member and audit validation. Dismiss/reopen updates only the existing review state within a freshly
validated transaction; a failed save rolls it back. These metadata-only decisions
preserve the canonical revision, published pages and projection outbox. The
command checks the current review state as well as source/policy/canonical proof;
merges and undo still advance the canonical revision through their audited path.
The view never changes SwiftData directly. No model/provider or automatic identity
linking path is added, including for people; experimental match weights are not
presented as calibrated confidence.

`KnowledgeReviewProjection` generates deterministic inspection hints for exact
opposing polarities with matching entity/predicate/value/modality/claim kind and
compatible stated intervals, and for dates stated at month precision. It does
not select a current truth, infer a day, or rewrite assertions. Dates absent from
the source remain absent. Temporal/event reasoning and resolution follow K3.
Source warning passages open an ID-only evidence route through the fresh reader.
Expanded warning rows bound displayed claims/passages and label truncation.

`KnowledgeReviewViewModel` refetches before publication and before a decision,
rejects mismatched scopes/stale content, prevents duplicate decisions, and guards
late completions with epochs/cancellation. Feature, store, source and scene changes
invalidate visible content and cancel pending work. Seven languages cover the
inbox, native merge confirmation and recoverable errors. Synthetic UI fixtures
exercise keep-separate/reopen, merge/undo and warning → evidence without a model
or network call; physical-device and wider-layout release checks remain open.

### Knowledge settings and explicit backfill (K2.7)

Settings → Knowledge exposes the separate, off-by-default feature flag, an
opt-in future-transcription trigger, a compilation pause, on-device provider,
source scope/exclusions, explicit batch preview/confirmation, segment coverage
and page rebuilding. Turning Knowledge on never enumerates older meetings or
starts a backfill. The summary provider remains independent; canonical cloud
processing is still refused even under an injected permissive policy. Its UI
control and corporate-policy administration remain future reviewed work.

`KnowledgeControls` is a versioned, bounded value stored through observable
`AppSettings` accessors. Missing controls use safe local defaults; wrong types,
corrupt bytes and future versions remain unreadable. Draft revisions and reset
generations prevent stale/ABA writes. Reset turns the feature off, preserves
meeting/canonical data and never falls back to a wider scope silently. All vs
explicitly selected meetings (including an empty selection) are distinct;
exclusions win. Preferences contain IDs/configuration only, not source content.
They narrow the live source ACL without changing corporate policy revisions or
invalidating still-authorized canonical evidence. Reader, search, playback,
review and source-picker lifecycles invalidate on control changes.

`KnowledgeJobQueue` has per-producer live eligibility and refresh. Pausing or
revoking canonical extraction cannot cancel an active meeting article. Execution
invalidation is separate from the durable cancellation-request epoch, preventing
one producer's settings update from stranding another producer's cancellation
barrier. Publication checks the active execution epoch and live source/provider
permissions. The automatic toggle governs new transcription triggers; already
approved pending jobs may resume, with Pause as the explicit execution stop.

`KnowledgeStore.backfillRead` authorizes an explicit 1–16-meeting selection
before metadata/coverage reads and bounds input to 8 MiB. Preview never enqueues,
repairs, loads a model or calls a provider. It distinguishes current, missing,
no-transcript and explicit-rebuild cases, including a restored source whose normal
identity was already cancelled. `KnowledgeSettingsCoordinator` retains
the confirmed operation beyond the Settings view, refetches scope/fingerprints
and policy before each item, and binds compilation admission to the previewed
source expectation. Regular work keeps normal idempotency; explicit recompiles
retain the plan's generation across retries. Current sources are skipped in
missing-only mode. On-device provider fees are zero; runtime is not estimated as
a guarantee. Unavailable Apple models remain unavailable, with no asset download
or cloud fallback. Old progress counts are hidden when the control/source scope
changes. Source content is never written to preference storage.

`KnowledgeSettingsViewModel` owns asynchronous presentation, request epochs,
source/control checks and recoverable errors; stale/cancelled responses cannot
restore metadata after invalidation. The native view only binds controls and
forwards user actions. Scope-edit transformations live in tested KurnCore values.

Page rebuilding uses the existing fresh projection snapshot/publication boundary
without an LLM. Coverage reports examined segments, not accuracy or semantic
recall. Seven languages cover the controls, safe-reset notice, scope editor,
preview, local-cost confirmation and progress. Synthetic UI captures use a
separate in-memory store; no real sources or paid calls are involved. "Delete
Knowledge" goes through K2.8's resumable purge (below). No canonical schema
migration is introduced.

### Knowledge deletion (K2.8)

Knowledge relates to meetings by UUID, so no cascade reaches it; deletion is a
durable **tombstone** plus a purge. A tombstone is a `KnowledgeJob` of the
existing `.deletion` kind (no schema change): `KnowledgeDeletionRows` keys it
`knowledge.deletion.v1:<scope>:<id>` and stores its `KnowledgeDeletionScope` in
`strategyRaw` (raw values never change). `MeetingLibrary` inserts it in the SAME
journaled commit that deletes a meeting (`.meeting`) or a recording that had a
transcript (`.source`), so a process death between the two cannot leave rows
quoting a deleted transcript. "Delete Knowledge" in Settings → Knowledge saves a
`.corpus` tombstone first, re-authenticates through `SensitiveActionAuthorizer`
like "Delete all data", and interrupts only an active canonical extraction
(`KnowledgeJobQueue.refresh(kind:)` is producer-scoped, so a wiki article being
generated is not cut off).

`KnowledgeDeletionCoordinator` (built by `AppComposition`) drains tombstones at
launch, on activation and after any store save (the save notification is only a
signal), coalescing requests. `KnowledgeStore.purgeNextDeletion` handles the
oldest tombstone in one transaction: the canonical rows, the cache removals, a
revision bump and the tombstone's own deletion commit in one save, and a failed
save (fault seam `beforeSave`) or a process death leaves all of it for the next
drain. Failures record a content-free `knowledge_deletion` reliability event once
per code per process; an unknown scope or pipeline is refused, never dropped.

- **Meeting/source:** every assertion, event and evidence row of that meeting,
  their relations and all its extraction jobs (provenance included). Entities
  named by its provenance, assertions or events are removed unless another
  source's assertion or event still names them. A survivor merged into a
  removed identity has its redirect cleared; its own name, aliases and claims
  are untouched. Reviews whose subjects include a removed entity, or whose
  candidate/merge audit names the meeting, are removed. Page caches whose source
  set includes it are removed, as is any cache that cannot be decoded (it cannot
  prove it excludes the source). `.meeting` also removes the meeting's
  `SourceContextLink`; `.source` keeps it, because the meeting remains and can be
  recompiled from its other recordings (passes are per recording, but
  provenance and entity origins are per compilation, so the whole meeting is
  purged rather than a partial job rewritten).
- **Corpus:** all entities, assertions, evidence, events, relations, reviews and
  every non-article job; meetings, their episodic `WikiArticle` work, contexts
  and links are kept. Other tombstones are kept and purged after it, since only
  a meeting's own purge removes its context link.
- **Revisions** are content-free and kept: a revision whose job or merge audit
  was removed stops waiting for projection (it could never be acknowledged),
  and a new revision (`policyRevisionKey` = `knowledge-deletion-v1`, not
  pending) makes every page, search or review snapshot taken before the purge
  stale. The search index is in-memory only, so the bump is its purge.

`LibraryEraser` still deletes every knowledge row, tombstones included.

### Temporal reducer (K3.1)

KurnCore's `KnowledgeTemporalReducer.state(of:validAt:knownAt:claims:)` answers
"what held for this entity at valid time T, as known at transaction time K". It
is pure, Foundation-only and not yet wired to the store or any reader; the host
will supply `KnowledgeTemporalClaim`s that already passed source authorization
and evidence checks.

- **Two clocks, never mixed.** A claim is known when `recordedAt <= knownAt` and
  `knownAt` is before `retractedAt` (half-open). Valid time is the stated
  `validFrom`/`validTo` at its precision, read as a half-open UTC interval
  (`KnowledgeTemporalValue.bounds`: an instant covers its second, a day 24 hours,
  a month the whole month). A meeting imported late changes what is known only
  from its import.
- **Precision is certainty.** A moment inside a bound's stated period gets
  `possible` ("in October" asked about Oct 15), past it `definite`. A claim with
  no `validFrom` is always `possible` and never displaces or conflicts.
- **No last meeting wins.** Single-valued predicates (`singleValued`: `hasStatus`,
  `dueOn`, outgoing only) are reduced by stated start alone: a different
  statement (value or polarity) whose start is wholly after a claim's start
  displaces it — definitely once that start has definitely passed, to
  `possible` while it may have. `recordedAt` and input order decide nothing.
  Other predicates and incoming relations (e.g. being `blocks`'s object) are
  kept per other entity/value, with negation displacing the same way.
- **Tentative claims never establish state.** `tentative` modalities
  (`proposed`, `hypothetical`, `disputed`) are shown as their own holdings
  (`isTentative`, with every supporting `modalities`), never displace or
  conflict with anything, and never merge into an established claim of the
  same value; a later established statement still displaces them (an approval
  ends a proposal).
- **Conflicts are surfaced, not resolved.** Different established statements
  whose stated starts overlap both stay as holdings and add a `Conflict` per
  reason, classified pair by pair (`unordered_values` for different values,
  `contradictory_polarity` for a statement and its negation), so three
  overlapping claims can yield both. Same statements from several meetings
  fold into one holding with every claim ID.
- Output is sorted (predicate, direction, detail, polarity, claim IDs), so it is
  identical for any input order. Known gap: an explicit `validTo` on a later
  status does not end an earlier status by itself. `KnowledgeTemporalReducerTests`
  checks it against the `pt-provisioning-timeline` fixture.

### Lifecycle state machines (K3.2)

KurnCore's `KnowledgeLifecycle` (`decision` for `decisionThread`, `action` for
`actionItem`, `risk`) projects an entity's status history from the claims known
at a transaction time (`project(entityID:knownAt:claims:)`); a status is never
the latest mention. The machines follow `KnowledgeStatus`: a decision is
proposed → approved/rejected/deferred → revised → superseded/revoked (a rejected
or deferred one may be proposed again); an action is proposed → committed →
inProgress → completed/cancelled, reopened explicitly; a risk is identified →
mitigated/accepted/closed, reopened explicitly. A decision is also superseded by
a `supersedes` claim naming it as the replaced entity. Pure and Foundation-only;
like the reducer it is not yet wired to the store or a reader.

- **Transitions come from stated valid time**, ordered by their stated period.
  A group of changes whose periods overlap (directly or through each other) is
  ordered as a whole by the machine: every order that keeps disjoint periods in
  date order and is a valid path from the status before the group is tried
  (groups above `maximumSearchedGroup`, 6, are not searched). One valid order is
  `lifecycle` (a reopening on the 12th puts "completed in November" first);
  several are `ambiguous` and none is `unresolved`, both reported as anomalies
  and never `definite`. Inside the search a statement of the status already in
  force is a restatement, not a transition, and orders that differ only in
  where a restatement falls count as one; overlapping statements of one status
  are therefore never an order question, while a reopening between two
  completions in one month keeps both cycles.
- **Nothing is dropped.** A forbidden transition is kept and reported
  (`invalid_transition`), as is a status outside the machine
  (`out_of_vocabulary`) and an ambiguous or unresolved order. Hypothetical, disputed or
  proposed claims (except a proposal that something is `proposed`), negated
  claims and undated ones are listed in `setAside` with their reason. A status
  restated right after itself joins the transition it repeats, keeping its
  earliest date.
- `state(at:)` returns the status in force at a valid time: `definite` only when
  its transition has definitely started, the next has definitely not, and
  neither was ordered `ambiguous` or `unresolved`. A transition ordered by the lifecycle is bounded
  by its neighbours. `KnowledgeLifecycleTests` checks the provisioning decision
  (proposed → approved → revised → superseded) and the runbook action
  (completed in November, reopened on the 12th) from the golden fixtures.

### Knowledge timeline (K3.3)

The scoped Knowledge reader opens a Timeline from Knowledge Home
(`KnowledgeBrowserRoute.timeline`, `KnowledgeTimelineView`). It is a projection of
the same authorized, evidence-checked pages the reader shows (KurnCore's
`KnowledgeTimeline.build(pages:filter:)`), never a second store, and reads offline
with no provider.

- **Placed by stated time, shown with recorded time.** Each claim sits in the UTC
  month its stated `validFrom` falls in, shown at its own precision (a month stays
  a month); the meeting it came from and the date it was recorded (the
  assertion's transaction time, `recordedAt`, set when its meeting was compiled
  into knowledge, not the meeting's own date) are shown beside it and never move
  it. Within a month, the earlier stated start comes first, a narrower period
  first when two start together. A stated date after it was recorded is marked
  "planned ahead" (`isAhead`).
- **Unknown dates are kept apart.** A claim with no stated date is listed under
  "No stated date" in recorded order instead of being given one.
- **One entry per claim.** A relation on both entities' pages is shown once.
  Kinds: status, due date, supersession, other relation, other value.
- **Filters** keep chosen kinds (`Filter.showing` never hides the last one) and
  can hide tentative (proposed, hypothetical, disputed) or negated claims;
  filter state is per view and never persisted.
- **Lifecycle findings reach their claims.** K3.2's projection runs per stated
  identity over the claims shown (filters apply afterwards), and each
  `invalid_transition`, `ambiguous_order`, `unresolved_order` or
  `out_of_vocabulary` finding is shown on every claim it names. Nothing is
  resolved or rewritten.
- Rows open the claim's first cited passage through the existing ID-only evidence
  route. `KnowledgeTimelinePresentation` (Application) holds the wording and is
  tested; the view only binds it.
- Not yet: context lanes on iPad (the read carries no context per claim yet),
  canonical `KnowledgeEvent` rows and known-at ("as of") navigation.

### Knowledge comparison (K3.4)

An entity page opens "Compare dates" (`KnowledgeBrowserRoute.compare`,
`KnowledgeCompareView`): the entity's state at the end of two days the person
picks, from the same authorized pages the reader shows, offline.

- KurnCore's `KnowledgeStateComparison.compare(entityID:earlier:later:claims:)`
  runs the K3.1 reducer at two `Point`s (a valid time and a transaction time
  each) and lines up their holdings: the same statement at both is
  `unchanged` (with `certaintyChanged` when it is definite at one point and only
  possible at the other); one statement replaced by exactly one other in the
  same slot (another status, a negation) is `changed`; anything else is
  `started` or `ended`, so two conflicting values are never paired into a
  change. Conflicts stay on their side. Output is sorted and independent of
  claim order.
- `Point.endOfDay` is the last second of a stated day (UTC): a claim stated for
  that day is `possible` there, since a day's precision cannot say whether it
  had already happened. The app reads the picked days in the person's calendar
  (`KnowledgeComparePresentation.day`) and orders them.
- "As known on each date" sets each point's transaction time to its own moment,
  so a meeting imported later does not change what was known then; otherwise
  both days are read with everything recorded so far. A page fact's
  `recordedAt` is its assertion's transaction time (when its meeting was
  compiled into knowledge), so "known" means "compiled by then", not "said in a
  meeting by then".
- `KnowledgeStateComparison.claims(from:)` turns pages into temporal claims that
  name the identities the pages show, so a merged identity compares as one.
- Rows read like the reader's claims, in their own direction (an incoming
  `blocks` names the other side first), mark tentative and uncertain holdings,
  show what a change replaced, and open the first cited passage through the
  ID-only evidence route.

### Knowledge late arrivals (K3.5)

An entity page's overview ends with "Revised later" when knowledge recorded after
the fact changed what held on earlier days (`KnowledgeLateArrivalsView`,
`KnowledgeLateArrivalPresentation`). Nothing derived is stored, so there is no
cache to invalidate: "recomputing the affected interval" is computing, on read,
only the stretch of valid time an arrival changed.

- KurnCore's `KnowledgeLateArrival.recompute(entityID:arrivedAt:claims:)` takes
  the claims recorded at one transaction time that name the entity. It needs
  earlier knowledge of the entity and starts at the earliest moment the new
  claims could hold (an undated one reaches back to the entity's earliest stated
  bound). From there it compares the K3.1 state as known just before the arrival
  with the state as known at it (two K3.4 `Point`s on the same valid time) at
  every stated bound that could change it, and keeps the stretches that differ,
  merging neighbours whose differences name the same claims (so a change that
  only grows certain stays one stretch; the last one is open while it lasts).
- An arrival is late only when what it changed starts before the UTC day it was
  recorded on: a status stated for its own recording day revises nothing past.
  `revisions(of:claims:)` lists every late arrival for an entity, oldest first,
  independent of claim order.
- A page holds every claim about its entity in both directions, so the page
  alone is the input. `recordedAt` is the assertion's transaction time (when its
  meeting was compiled into knowledge), so "late" means "compiled after the days
  it changed". Stated days are shown in UTC, the recording date in the person's
  time zone; a stretch's rows are the K3.4 change rows (every change, and an
  unchanged statement only when it grew or lost certainty).
- Not yet: `KnowledgeEvent` rows written from these reductions, and a marker on
  the timeline for late claims.

### Knowledge graph query (K4.1)

The relationship graph of a scoped knowledge read, queried a neighbourhood at a
time. Positions come from K4.2 below and the drawing from the Graph Explorer (K4.3).

- KurnCore's `KnowledgeGraphIndex(pages:)` indexes the reader's authorized,
  evidence-checked pages once; it is a projection, never a second store. A node
  is an identity a page shows (a merged identity is the one it was merged into)
  and an edge is one claim between two entities, in its stated direction, with
  its predicate, polarity, modality and first cited passage (for the ID-only
  evidence route). Value claims are not edges, a claim shown on both ends'
  pages is one edge, and a claim whose two ends a merge made one identity is
  not drawn.
- `query(_:)` walks breadth first from a root within `KnowledgeGraph.Query`'s
  bounds (default depth 1, 40 nodes, 80 edges; clamped to depth 0–2, 1–40
  nodes, 0–80 edges), optionally following only chosen predicates and leaving
  out tentative or negated claims. Nodes come root first, then by depth and
  name; edges nearest first (the deeper end's depth), so an edge bound drops
  the farthest. `isTruncated` says a node or edge bound cut the walk short (the
  depth bound alone does not), and `frontier` lists shown nodes with a followed
  claim the graph does not show: where to expand next. It returns nil for a
  root the pages do not show. Output is identical for any page order.
- `supersessionCycles` reports each set of identities whose established,
  positive `supersedes` claims form a cycle (Tarjan, over every page, a
  self-supersession after a merge included) and that touches a shown node. A
  cycle is surfaced, never ordered through.
- The app's `KnowledgeGraphQueryService` (`Application/Knowledge`,
  `@MainActor`) keeps one index and up to 32 recent answers (least recently
  asked evicted) per scope: the canonical revision, the meetings, the policy
  revision and the pages of the read themselves, since a read can change
  without a new revision (a corrected transcript drops a claim's evidence).
  Any other scope rebuilds the index and drops every answer, so nothing is
  answered from an older read; `clear()` forgets everything.

### Knowledge graph layout (K4.2)

Positions for a graph neighbourhood, computed in KurnCore and cached by the
app; the Graph Explorer (K4.3) draws them.

- `KnowledgeGraphLayout.layout(_:seed:fixed:iterations:)` is a force-directed
  (Fruchterman-Reingold) layout in the unit square, every position kept
  `margin` (0.06) inside its edges. It is deterministic by node ID and seed:
  nodes are visited in ID order, start on rings by depth at angles drawn from a
  SplitMix64 hash of the seed and the ID (stable across processes, unlike
  `Hasher`), and move for a fixed number of steps (150) under a cooling step
  budget. The same graph, seed and fixed positions give the same layout
  whatever the order of the graph's nodes and edges; several claims between one
  pair pull harder.
- Nodes in `fixed` keep exactly that position (clamped inside the margins); the
  root sits at the centre unless it is fixed elsewhere; the forces place every
  other node. Coincident nodes are pushed apart in a direction drawn from their
  IDs, never by chance.
- The app's `KnowledgeGraphQueryService.laidOut(_:in:seed:)` computes one layout
  per cached answer and remembers where each node was last shown in the scope
  (`shownPositions`): a neighbourhood that grows, or is re-rooted on a shown
  node, keeps the nodes already on screen where they were and places only the
  new ones. A new scope or `clear()` forgets the positions with the answers,
  and another seed is a new drawing that drops every layout and shown position.

### Knowledge graph explorer (K4.3)

An entity page opens "Relationships" (`KnowledgeBrowserRoute.graph`, `KnowledgeGraphView`): the
neighbourhood K4.1 answers, at the positions K4.2 gives, from the same authorized read as the page,
offline. Four modes share one neighbourhood and its positions: All (every claim the query shows),
On a day (evolution), Compare and Contexts (lanes).

- **Drawn on a `Canvas`, touched through an overlay.** The canvas is hidden from assistive
  technologies. Each node has a 44-point button laid over it, whose label carries its name, how many
  relationships are shown, and whether it is the centre or has more. That button is also what
  VoiceOver reads. The centre is a square and other nodes circles; a selected node is ringed and its edges drawn thicker. Edges have an arrowhead in
  their stated direction. A tentative claim is dashed, an inferred one dotted and a negated one
  crossed out. A dotted ring marks a node on the query's frontier. No state is shown by colour alone.
- **The list alternative.** A segmented control switches between the drawing and a list of every
  node with the claims that touch it. While VoiceOver runs, the list is the default until the reader
  chooses. Claims read like the reader's, in their stated direction, and open their first cited
  passage through the ID-only evidence route.
- **Selection and recentring.** The selected node's section offers "Open page" (the entity route)
  and "Centre the graph here". `KnowledgeGraphPresentation.Exploration` holds the centre, the
  selection, the filters and the chosen view. `KnowledgeGraphQueryService` keeps it per entity the
  graph was opened from, because the reader re-reads, and so rebuilds its destinations, on every
  navigation. A page opened from the graph therefore comes back to the graph as it was left. It
  holds IDs only. A centre no longer in the read falls back to the entity the graph was opened from.
  The reader clears the service on disappearing and when the scene leaves the foreground.
- **Filters** (per view, never persisted): distance 1 or 2, and tentative, negated and inferred
  claims. Inferred claims (`KnowledgeModality.inferred`) are off by default
  (`KnowledgeGraph.Query.includesInferred`, which defaults to on for other callers).
- The footer says how much is shown. It also says when a bound truncated the walk and names each
  supersession loop by every member, named from the whole read even beyond the bounds. Words, labels and links are `KnowledgeGraphPresentation` (Application,
  tested); the view only binds them. The UI fixture's graph variant
  (`UI-Testing-KnowledgeGraphFixture`) adds a team that blocks the portal.
- **On a day and Compare** ask KurnCore's `KnowledgeGraphTimeline`, which runs the K3.1 reducer for
  each edge's source: `holdings(of:at:claims:)` gives how certainly each edge held at a point
  (`KnowledgeStateComparison.Point`, the end of a picked day in the person's calendar, as known now or,
  with "As known on each date", as known then), and `compare(_:from:to:claims:)` whether it started,
  ended or held at both. Nothing orders claims by recording date, and an edge keeps its own claim's
  certainty: a holding folds equivalent claims and is definite when any of them is, so each edge is
  capped by `KnowledgeTemporalReducer.holds` for its claim alone. An edge that did not hold is not
  drawn, while its nodes keep their places. The drawing marks a relationship that started with a
  plus and one that ended with a square, and rings one that may not have held on a day it is shown
  for (`EdgeState` keeps each day's certainty, compare included); each mode's footer and every row
  say so in words. The days default to today and, for Compare's earlier day, the first
  stated start on the opened entity's page; they are part of the kept exploration. Day reading, states
  and wording are `KnowledgeGraphPresentation+Timeline` (tested).
- **Contexts** lays the same neighbourhood out in one horizontal lane per context its relationships were
  said in (`KnowledgeGraphPresentation+Lanes`). The read carries each meeting's context
  (`KnowledgeBrowserRead.meetingContexts`, from its `SourceContextLink`, read in the same authorized
  context as the pages; a meeting with no link is in context `unknown`). A relationship belongs to its
  meeting's context; lanes are ordered by `KnowledgeContextKind` (unknown last), then by title, which is
  the context's name or else its kind in words. A node sits in the lane most of its shown relationships
  belong to (the earlier lane on a tie), keeps its x and keeps its order within the lane's middle 70%.
  Each lane is named at its top left, and every relationship row and node label names its context in
  words, so lanes are never told apart by position or colour alone. Nothing is filtered: Contexts shows
  what All shows.
- Not yet: graph performance targets measured on a physical device.

### Knowledge tools for Ask (K5.1)

Ask can read canonical knowledge through ten read-only tools (`Application/Agent/Tools/ChatKnowledgeTools`):
`search_knowledge`, `get_entity` (an entity's page), `get_timeline` (claims by stated time, undated last),
`get_evidence` (one cited passage) and the structure tools of `ChatKnowledgeTools+Structure`: `resolve_entity`,
`get_graph`, `compare_state`, `list_open_actions`, `list_contexts` and `get_context`. They read through `ChatKnowledgeSource`, the same authorized,
evidence-checked read the Knowledge reader shows (`KnowledgeCompilationCoordinator.readKnowledgeBrowser`),
never a second store, and answer in `ChatSourceToolText`'s compact form (`ChatKnowledgeToolText`): one line per
item with the IDs the model passes back, vocabulary raw values (modality, polarity as a leading `NOT`, review
state, stated validity), each name and quote clipped to one line, a `page:` line and a final `revision:` line.

- **Sending knowledge to the model that answers is `answerSynthesis`** under the default-deny policy
  (ADR-008). `ChatKnowledgeGate` offers the tools only when the feature is on, the source controls allow
  1–16 of the run's meetings, and `KnowledgePolicyEvaluator` allows the operation for the run's provider: for a
  cloud provider the policy must name it, cover the sources' classification and have the person's consent.
  `ChatKnowledgeSource(coordinator:)` reads that consent from the provider's on-request grant in the
  cloud-consent ledger ("Cloud consent"); a policy alone never stands in for consent.
- **Every call is authorized again**: before the read, and after it with the read's own source
  classifications (`KnowledgeBrowserRead.sourceClassifications`, from each meeting's context), so a context
  reclassified or consent withdrawn since the run started sends nothing. A refused or failed read is a
  recoverable tool error with a fixed message, never source text.
- **The structure tools are projections of that same read** (KurnCore, no new store query).
  `resolve_entity` folds case and accents (`KnowledgeEntityResolver.normalizedName`) and ranks exact name,
  alias, prefix, then every query word in the name, optionally of one kind. `get_graph` is a
  `KnowledgeGraphIndex` query (depth 0–2, default 1, the K4.3 node/edge bounds; inferred relations hidden unless
  asked for, as in the Graph Explorer): nodes, then one edge per claim in its stated direction with its
  endpoint node IDs and evidence ID, the truncation, frontier and `supersedes` cycles in the header. `compare_state` is
  `KnowledgeStateComparison` at the end of two `yyyy-MM-dd` days, as known now or, with `asKnownThen`, as known
  on each day; certainty shifts and conflicts are listed, never resolved. `list_open_actions` projects each
  action item's lifecycle (`KnowledgeLifecycle.action`) at the tool clock (`make(now:)`) and leaves out only a
  definite `completed` or `cancelled`, with the assignees (`assignedTo`, or `owns` pointing at it) and due dates
  that hold at that moment (`KnowledgeTemporalReducer`, proposals marked tentative) and lifecycle anomalies; an entity filter keeps actions with a claim naming it. `list_contexts`/`get_context`
  group the selected meetings by `KnowledgeBrowserContext` in the Graph Explorer's lane order, meetings with
  none under context `unknown`.
- **`get_coverage` is the K2.2 coverage measure**, not a projection of the browser read: `ChatKnowledgeSource.coverage`
  reads `KnowledgeStore.coverageRead` (the maintenance report's per-recording examined/total segment counts and
  state, grouped by meeting, under the same `.semanticLint` source authorization, without the wiki, catalog or
  review reads). It is authorized like the other tools before and after its read, with each meeting's context
  classification, and carries no names or quotes. The counts say how much the latest compilation read, not how
  accurate it was; the description tells the model to check it before saying something was not discussed.
- **Knowledge is a chat source part (K5.3)**: `ChatSourcePart.knowledge` is in `ChatSourceScope.defaultParts`, and
  `HarnessChatService` offers the knowledge tools only for meetings whose effective parts select it, before
  `ChatKnowledgeGate` authorizes them; the part is removed with the feature off (`effectiveScope(knowledgeEnabled:)`)
  and hidden from `ChatSourceSheet`. It is never a readable part of the source tools. A scope saved without the
  `knowledgeSelectable` marker (before K5.3) gains it wherever parts were selected, so old chats keep offering
  knowledge; an empty selection stays empty. An entity page's Ask button opens a separate library conversation
  scoped to the meetings its facts come from, with a drafted question.
- `get_wiki_page` returns a page's generated narrative (`KnowledgeWikiNarrative` paragraphs with the assertion IDs
  each summarizes), labelled as not evidence, or says the page has none. `trace_influence` (KurnCore `KnowledgeInfluenceTrace`) lists, in stated order, every claim about
  or naming an entity, the earlier claims on the same subject and predicate each replaces, its meeting, speakers and
  evidence IDs.
- **Knowledge-first query policy (K5.2)**: when a run offers the knowledge tools, `HarnessChatService.system(knowledge:)`
  adds a `knowledge_policy` section last, where a patch adding or removing it replays it
  (`HarnessChatService.knowledgePolicy`): query knowledge first, keep modality/negation, cite through evidence, call
  `get_coverage` for the meetings it answers from and use the offered source tools for meetings not compiled, stale,
  not fully examined or without knowledge; a missing fact is reported as absent from the compiled knowledge, never as
  never said; the transcript wins a disagreement.
- **Knowledge egress (K6.1)**: the `knowledge-network` rule in `Tools/check_static_policy.py` rejects `URLSession`,
  `URLRequest`, `LLMHTTP`, `ProviderHTTPTransport`, `NWConnection` and CloudKit/iCloud key-value stores in Knowledge
  code (`Application/Knowledge/`, `ChatKnowledgeTools*`, `Views/Knowledge*`, `Views/MeetingKnowledge*`, KurnCore
  `Knowledge/`); its only egress is the provider call admitted by the policy and the consent ledger.
- **Knowledge export (K6.2)**: `KnowledgeCompilationCoordinator.exportKnowledge` authorizes `.export` before the
  browser read and again with the read's classifications, then encodes KurnCore `KnowledgeExportBundle` (format
  `kurn.knowledge-export`, schema 1: meetings, entities, claims with qualifiers and evidence, sorted by ID). The browser
  writes it with `fileExporter` (a save to a chosen location), never the generic share sheet. Runs without knowledge tools keep the old prompt.

### Attached documents (PDFs)

A meeting can carry PDFs as reference material for its summaries
(`MeetingAttachment`, one-to-many on `Meeting`, `.cascade`). Unlike a
`MeetingPhoto`, an attachment belongs to the meeting rather than a recording:
it has no moment on a timeline.

- **Two entry points, one importer.** "Add PDF" in the Recordings tab (and the
  overflow menu) opens a `.fileImporter`; a PDF shared from another app arrives
  through `CFBundleDocumentTypes` (PDF, `LSHandlerRank` Alternate,
  `LSSupportsOpeningDocumentsInPlace` **false**, so iOS copies it into
  `Documents/Inbox/`) and `onOpenURL` → `IncomingFileInbox`, which
  `ContentView` turns into `AttachToMeetingView` (pick a meeting or start a new
  one). Both call `MeetingAttachmentImporter`: copy into
  `AttachmentFileStore` (`Recordings/Attachments/`, same protection and
  shallow-scan invisibility as `Photos/`), extract the text off main under the
  `.photoTextRecognition` reservation (`PDFTextExtractor` — PDFKit's text
  layer, Vision OCR for at most `maxOCRPages` scanned pages), then
  `MeetingLibrary.addAttachment`. Each step undoes the previous on failure; a
  locked or unreadable PDF is refused (`AppError.attachmentImportFailed`), one
  with no readable text is kept and adds nothing to prompts.
- **The two screens hold no logic.** `MeetingDetailAttachments` renders
  `MeetingAttachmentsViewModel` (picker, Quick Look preview, import in flight,
  delete) and `AttachToMeetingView` renders `AttachToMeetingViewModel` (search
  via `Meeting.matches(search:)`, attach to a meeting, or
  `MeetingAttachmentImporter.importPDFsIntoNewMeeting`, which deletes the new
  meeting again when nothing went in); the row text is
  `MeetingAttachment.detailsText`. Both view models take their importer and
  library as factories, and `MeetingLibrary`'s `persist` seam lets tests fail
  a commit to reach every rollback.
- **The Inbox copy is unprotected, so it never outlives the decision.**
  `IncomingFileInbox.finish()` deletes it whichever way the sheet closes,
  deletes only files inside the Inbox (never a URL elsewhere), and
  `sweepStaleCopies` on every activation removes what a killed process left.
  The sheet sits below `SecurityCoverWindow` like every other presentation.
- **Prompts read it through `Meeting.assembledContextText()`** — the
  transcript followed by KurnCore's `AttachmentPromptContext` block — used by
  summaries, the wiki (so adding a PDF makes the article stale), the per-meeting
  chat and generated documents. The block is capped per document and in total,
  hard-wraps long lines (`SummaryService.splitTranscript` only breaks on lines),
  and is empty when nothing is transcribed: a document is context for a meeting,
  not a meeting. `SummaryPrompt`, the map-stage `notesTemplate` and the
  full-context chat prompt tell the model the documents are reference material,
  never speech, and carry no `[mm:ss]`.
- Deletion goes through the journal like photos (`RecordingTrash` knows the
  `attachments` source and the sweep counts attachment rows), and
  `LibraryEraser` deletes the rows and `AttachmentFileStore.deleteAllAttachments`.

### Read aloud (text-to-speech)

Summaries, wiki articles and generated documents can be read aloud from an
inline `ReadAloudControl` above each (`Views/ReadAloudControl.swift`: play/pause,
previous/next paragraph, stop, progress, and the failure shown inline under the
control whose text failed — an alert could land behind the wiki sheet).

- **The on-device voice is the default.** `ReadAloudPreferences`
  (`Models/SpeechSynthesisCatalog.swift`, one JSON blob in
  `AppSettings.readAloud`) starts on `.appleOnDevice`, which here means
  `AVSpeechSynthesizer` — not FoundationModels, so `isUsableForSpeech`, unlike
  `isUsable`, is true on every device. Picking a cloud voice in Settings → Read
  Aloud is the opt-in for sending the text being read to that provider.
  `AppSettings.speechProvider` falls back to on-device when the stored choice
  loses its key.
- **Which providers speak is keyed off `AIProviderKind`**
  (`AIProvider.speechSynthesisAPI`): OpenAI-compatible `/audio/speech`,
  ElevenLabs `/text-to-speech/{voice_id}`, Gemini `generateContent` with an
  `AUDIO` modality; Anthropic has none. Groq is special-cased by id like
  `defaultTranscriptionModel`: Orpheus models, WAV only, 200 characters per
  request. Voices and models are suggestions — Settings also accepts free text.
- **`SpeechSynthesisProvider` is a separate protocol from `LLMProvider` and
  `TranscriptionProvider`** (`Providers/SpeechSynthesisProvider.swift`,
  conformers in `CloudSpeechProviders.swift`), one per capability, so a
  speaking vendor gains no text-generation route it cannot serve. Request builders are `static` for tests; speech requests are
  marked idempotent (a replay only costs money) and a 2xx body that is not audio
  is rejected before `AVAudioPlayer` sees it. Gemini's bare PCM is wrapped by
  KurnCore's `PCMWaveFile`.
- **What is said comes from KurnCore's `SpokenText`**, not the raw Markdown:
  headings and bullets become sentences, `[mm:ss]` citations, links, emphasis,
  code fences and URLs are dropped, tables read row by row. It also chunks the
  text to `maxSpeechCharacters` at paragraph → sentence → word boundaries,
  never dropping a word. Pure Foundation, tested on Linux.
- **Audio never touches disk.** `CloudSpeechEngine` plays each chunk with
  `AVAudioPlayer(data:)` and prefetches the next one; the audio is as
  meeting-derived as the text it speaks.
- **One reader for the app.** `ReadAloudController.shared` (a singleton like
  `RecordingCommandRouter`, which also keeps it reachable from Settings in the
  security cover window) owns the `.playback`/`.spokenAudio` session, Now
  Playing (skip = paragraph) and interruption/route-change pauses. It shares
  the route with `AudioPlayerService` through `readAloudCoordination`
  (`Views/MeetingDetailReadAloud.swift`): starting to read calls
  `player.yieldToOtherAudio()` (pause, keep position, release Lock Screen
  controls), playing a recording stops reading *without* deactivating the
  session under the player, and leaving a meeting or document stops what it
  owns. This is also why `NowPlayingController` removes only the command
  targets it added — `removeTarget(nil)` would detach the other owner.

### Cloud consent

One rule covers every feature that sends content to a cloud provider: content
leaves the device only under a grant for that provider's destination
(`provider.id|baseURLString`) and purpose. KurnCore's `CloudConsentLedger`
(`Consent/CloudConsentLedger.swift`, stored by `AppSettings+CloudConsent.swift`
under `settings.cloudConsents.v1`) holds the grants. There are two purposes:
`onRequest` (summaries, chat, documents, regenerating a title) and `automatic`
(per-recording: cloud transcription, automatic titles, wiki, correction, Knowledge
extraction). An automatic grant also covers on-request use. A changed endpoint is
a new destination, and the on-device provider never needs a grant. Feature
toggles still choose which features run, and `wikiEnabled`, `correctionEnabled`
and `aiTitleCloudEnabled` mean "send to my summary provider": turning one on, or
choosing a summary provider while one is on, records that provider's automatic
grant, so the ledger always shows where they send. Audio keeps its own
per-destination upload consent (`hasCloudTranscriptionConsent`, the cloud-upload
dialog): audio and text consent never authorize each other.
`revokeAutomaticCloudConsent` withdraws the grant, clears the legacy transcription
consent key and turns off the summary provider's per-recording features. Choosing a cloud summary provider
records its on-request grant, and `revokeAllCloudConsent` (Privacy & Cloud's "Remove
all permissions") also moves the summary and Knowledge providers on that
destination, and Read Aloud on it, to on-device. A summary-provider fallback
(`ensureProviderSelectionsAreUsable`) never picks a destination marked withdrawn
(`CloudConsentLedger.withdrawn`, set by removing all permissions, cleared by a new grant). The
first launch with no stored ledger migrates what was already allowed (a keyed
cloud summary provider and its enabled per-recording features; audio consent is
kept as it was), so an upgrade asks nothing again. Settings → Privacy & Cloud
(`PrivacyCloudSettingsView`) lists each destination's grants, its audio upload
consent and the features using it, plus the non-AI sharing (template sync, diagnostic reports).
Consent is enforced when work starts: work already running (a multi-chunk upload,
a staged summary, a conversation's earlier tool results) finishes under the
consent it started with.
Knowledge uses the same grants: Settings → Knowledge lists on-device and every
keyed cloud provider, and choosing a cloud provider without the automatic grant
asks first (`knowledge.settings.cloud_message`). Extraction needs the automatic
grant and Ask the on-request one.
On-device model downloads keep their own per-model consent because none of
the user's content is sent.

### Settings & secrets

`AppSettings` (`@MainActor @Observable`) holds non-secret preferences in
`UserDefaults`, persisting on `didSet`. **API keys never go here** — they live in the
Keychain via `KeychainManager`, keyed by `AIProvider.keychainAccount`. Built-in
providers keep a `legacyKeychainAccount` for backward compatibility; custom providers
use `provider_<id>_api_key`. A few preferences also mirror to non-persistent global
state in their `didSet` — e.g. `logLevel` pushes to `AppLog.minimumLevel` so the
logging gate reflects the user's choice immediately (also synced once on init).

Settings is a **hub, not one long form**. `SettingsView` is a short list of
`NavigationLink` rows grouped into Intelligence / Capture / Library / System,
each pushing a focused screen in `Views/Settings/` (`ProvidersSettingsView`,
`SummarySettingsView`, `SemanticSearchSettingsView`, `RecordingSettingsView`,
`TranscriptionSettingsView`, `TagsSettingsView`, `WikiSettingsView`,
`StorageSettingsView`, `DiagnosticsSettingsView`, `AboutSettingsView`). Only
the destructive "Delete all data" reset stays on the root.

**Key status is observable through `AppSettings.credentials`**
(`Infrastructure/CredentialStore.swift`). The Keychain is not observable, so
the screens used to pass a `keyRevision` counter down by hand and read
`SecItemCopyMatching` on every render — and the transcription settings opened
from Recording or from a meeting got a constant `0` and never refreshed. Every
UI key read and write now goes through the store: `hasKey(for:)`,
`isUsable(_:)` and `isUsableForSpeech(_:)` cache definitive answers (never a
failed, e.g. locked, read) until the next `saveKey`/`invalidate`, which bumps
an observable `revision`. Views never call `KeychainManager` directly;
non-UI code (`ProviderFactory`, services off the main actor) still does,
through `AIProvider.isUsable`, because it needs the value at call time. Each
write also runs `AppSettings.ensureProviderSelectionsAreUsable()`
(`AppSettings+ProviderSelection.swift`, alongside `configuredProviders` and
its summary/transcription subsets): a key removed anywhere must never leave
the summary or transcription provider pointing at one without a key. The
Settings root re-runs it on appear for what no write announces, such as the
on-device model becoming unavailable.

`ModelDownloadController` (`ViewModels/`, `@MainActor @Observable`) owns the
FluidAudio download machinery — which `ModelSet` is in flight, the per-feature
consent dialogs, the engine choices deferred until a download succeeds, and the
installed-model list. It is created in `KurnApp` and injected app-wide: the
Transcription, Recording and Storage screens all read `isDownloading` and can
all start a download, and so can the diarization prompt on a meeting's
transcript — two controllers would each track a download the other knew nothing
about. Screens that can trigger one attach `.modelDownloadAlerts(_:settings:)`.

**Four settings are off by default, for two different reasons.** `wikiEnabled`
and `correctionEnabled` make paid cloud LLM calls on *every* transcription, so
neither can be a default; `aiTitleCloudEnabled` likewise gates the automatic
post-transcription title when the summary provider is a cloud vendor, since it
sends the whole transcript (on-device titles and an explicit regenerate are
never gated — `AITitleCoordinator.allowsGeneration`). `templatesSyncEnabled` costs nothing per
transcription and involves no LLM at all, but it is the first setting that
sends anything off the device — which is reason enough here.

**Template sync is iCloud key-value, deliberately not CloudKit.**
`CloudSettingsSync` (`Infrastructure/`) is a thin wrapper over
`NSUbiquitousKeyValueStore`, in the same spirit as `KeychainManager`: no
business logic, just get/set/observe. Adopting SwiftData+CloudKit instead would
pull the app's whole model container — meetings, transcripts, summaries —
toward iCloud, which is exactly what the local-first design rules out. Only
`AppSettings` decides what gets written; the `CloudKeyValueStore` protocol is
the seam that keeps this testable on CI, which has no signed-in iCloud account.
`TemplateSyncMerger` is the pure merge: per id, whichever side has the later
`updatedAt` wins. Built-ins never sync — `AppSettings.mergedTemplates` already
re-seeds them locally — so only user-created templates are reconciled. Deletions
deliberately do **not** propagate in this v1: an id reappearing after a delete
just means the other device hasn't synced its own delete yet.

`UsageStats` (`Models/UsageStats.swift`) holds local-only counters — recordings
completed, per-`TranscriptionEngine` and per-`SummaryTemplate` tallies —
persisted as a JSON blob in `AppSettings` the same way `summaryTemplates` is,
and rendered by `UsageInsightsView`. Pure on-device self-observability; it is
never transmitted anywhere.

### Crash and hang diagnostics

`Infrastructure/CrashReporting/` turns MetricKit payloads into readable reports
that stay on the device unless the user explicitly shares one.

`DiagnosticsSubscriber` registers with `MXMetricManager` unconditionally in
`KurnApp.init()` — so subscription never depends on `AppSettings`' construction
order — and checks consent at **delivery** time instead, reading `UserDefaults`
directly in `didReceive(_:)`. Without consent every payload is discarded without
touching disk. Nothing is transmitted automatically under either setting:
reports leave the device only through the explicit Share action in
`DiagnosticReportsListView`. iOS usually delivers these in a batch on the next
launch after the crash or hang, not at the moment it happens.

`DiagnosticReportFormatter` is pure and MetricKit-free *in its signature* — it
takes primitives the caller already extracted from the live payload — so it is
unit-testable against hand-authored fixture JSON rather than OS-constructed
objects. It re-serializes Apple's own `jsonRepresentation()`, which already
carries symbolicated-if-available frames and thread state, instead of walking
the call stack by hand and risking silent information loss.
`DiagnosticReportStore` owns the on-disk side.

### Navigation chrome (Liquid Glass)

The app used to hide the navigation bar on every main screen and hand-draw its
own header, bottom bar and floating record button. It no longer does — the rule
now is **use the system's toolbar, and only fall back to custom content when a
toolbar would be the wrong control**:

- `MeetingsListView` uses `.navigationTitle` + `.searchable` and a single
  `.toolbar { listToolbar }`. The toolbar content lives in
  `Views/MeetingsListToolbar.swift` as an extension, which is why several of
  `MeetingsListView`'s members are non-private — a `private` member is invisible
  to an extension in another file.
- **`ToolbarSpacer` is how glass groups are split.** In `listToolbar`, the
  bottom items (library/filter/Ask/Documents, or with Knowledge on the four
  places) share one glass capsule and
  `ToolbarSpacer(.flexible, placement: .bottomBar)` gives the record button
  (`.buttonStyle(.glassProminent)`, `.tint(Theme.accent)`) a capsule of its own.
  `MeetingDetailView`'s `toolbarContent` uses `ToolbarSpacer(.fixed,
  placement: .topBarTrailing)` the same way to separate the favorite toggle from
  the overflow menu.
- Three places deliberately stay custom content: `RecorderView`'s transport
  controls (full-width, thumb-sized targets mid-recording — they take
  `.buttonStyle(.glass)`/`.glassProminent` but are not toolbar items), the
  minimized recorder's mini bar (`RecordingMiniBar`, a `.glassEffect` capsule in
  a root `.safeAreaInset`, since it has to float over every screen's own
  toolbar rather than belong to one),
  `MeetingChatView`'s composer (an input surface: an inset glass card laid
  over the transcript with `.overlay(alignment: .bottom)` rather than a
  `.safeAreaBar`, so the conversation keeps scrolling beneath both the card
  and the keyboard instead of stopping above them).
- `MeetingDetailView` uses four sections, plus Knowledge when its independent
  flag is enabled, in a segmented `Picker`, not a bottom
  bar: they're view modes of one meeting rather than top-level destinations, and
  a bottom bar there would collide with the Chat tab's composer.
- Do not reintroduce `.background(.bar)`, hand-drawn `Divider` bar tops, or
  `.toolbar(.hidden, for: .navigationBar)` on a main screen. The lock screen
  used to be the one exception; it no longer needs to be, because it is not in
  the navigation hierarchy at all — it renders in the cover window above it
  (see "Secure local storage for recordings"), so there is no toolbar to hide.
- Accessibility identifiers used by `KurnUITests/ScreenshotUITests.swift`
  (`nav.settings`, `meetingCard`) must survive any further chrome rework.
- Empty states use `ContentUnavailableView`, not a hand-rolled `VStack` of an
  icon and two `Text`s — `DocumentsListView` was first; `MeetingsListView` and
  `ChatSessionListView` were migrated to match. Follow the existing pattern for
  a new empty state rather than reinventing it.
- On regular-width layouts (iPad, Mac Catalyst), `ContentView` presents
  `FolderSidebarView` as a `NavigationSplitView` sidebar column instead of a
  sheet — see "Organization" above for the binding it shares with
  `MeetingsListView`.
- **Button language** — `Theme.swift`'s "Button language" table is the one
  decision per situation: `.glassProminent` + `Theme.accent` for a screen's
  primary action, `.bordered` for a secondary action beside it, `kurnDialog`
  for a confirmation/destructive decision, and `.plain` for list/menu rows and
  chips (correct there, not an oversight). `.borderedProminent` is not used.
- **Modal weight** — `Theme.swift`'s "Modal weight" section: a quick binary
  decision is a `kurnDialog` (or `.confirmationDialog` for a contextual choice
  among several options); a decision carrying real content is a `.sheet` with
  `NavigationStack`, a `.cancellationAction` and `.presentationDetents`
  (`CrossMeetingSpeakerMatchView` is the reference). Short utility pickers open
  at `.medium` / `[.medium, .large]`, and every sheet has an explicit
  Cancel/Done independent of the swipe.
- **`kurnDialog` is the app's alert component, deliberately.** The shared
  `errorAlert(_:)` modifier wraps it and the UI flows drive it through
  `dialog.title`/`dialog.primary`/`dialog.secondary`, which a native `.alert`
  does not expose — so do not migrate it to native alerts, and add a native
  `.alert` only where the OS must own the control. Its destructive button is
  `Theme.accent`, which *is* system red (`#FF3B30`); its primary label is bold
  `.subheadline` because white
  on `Theme.accent`/`Theme.info` measures ~3.55:1 / ~3.65:1 — under AA for
  normal text, above the 3:1 large-text floor that ≥14 pt bold qualifies for.
- **Knowledge screens share one look** (`Views/KnowledgeStyle.swift`), taken from the screens before
  them: content on `Theme.background` with 20-point insets; section titles as
  `KnowledgeSectionLabel` (the meeting tabs' uppercase, tracked `caption2Emphasized` label in the
  tertiary colour); content in `knowledgeCard()` (`kurnCard` with 16-point corners); tappable rows
  as `KnowledgeLinkCard` (an accent `KnowledgeIconWell`, primary text, secondary detail and a
  chevron, like `DocumentsListView`); quotes as `KnowledgeQuote`; and secondary actions as
  `KnowledgeChipButton` (the summary tab's grey `Theme.fill` capsule). No action is a bare tinted
  text link; a screen's one decision (merging two identities, choosing sources) takes
  `.glassProminent` + `Theme.accent`, and confirmations use `kurnDialog`. Settings keep the native
  `Form`, like every other settings screen.
- **Error dialogs offer the error's recovery action.** `errorAlert` reads
  `AppError.recoveryAction` (`ErrorRecovery` in `View+ErrorAlert.swift`) and
  makes it the primary button beside OK: Try Again only when the caller passes
  `onRetry`; Open Settings, Manage Storage, Change Model, Recover Audio and
  Export Diagnostics open Providers, Transcription, Summary, Storage, Health
  or Diagnostics in a sheet, and a passcode error opens the app's page in the
  Settings app. `permissionDenied` opens Transcription (cloud consent), while a
  refused iOS speech recognition permission is its own case,
  `speechRecognitionDenied`, and opens the app's page in the Settings app, the
  only place it can be granted again. The Wi-Fi-only error is offered only
  through `onOpenNetworkSettings`. The
  decision lives in `Application/ErrorRecovery.swift` so coverage measures it.
  A screen that is itself the destination passes `offersRecovery: false`.
- **Fixed font sizes need a reason.** `.font(.system(size:))` appears only on
  icons constrained by a small fixed well or grid cell, each with an inline
  comment saying so; everything else uses a `Theme` font or a scalable
  `.system(.textStyle, weight:)`.
- The iPad split view has not had a hands-on device pass yet; see
  `docs/roadmap.md`.

### Accessibility

VoiceOver, Dynamic Type, and Reduce Motion are supported throughout the app,
the Watch companion, and the Lock Screen/Dynamic Island Live Activity —
enforced by lint and by a CI audit test, not just convention:

- **`Kurn/Infrastructure/Accessibility/`** — `ColorAccessibility.swift` gives
  `FolderColorPalette`/`TagColorPalette` (closed, curated hex sets) a static
  `accessibleName(for hex:)` lookup into localized names, so a color swatch
  reads as "Red"/"Blue" rather than a hex string or nothing at all.
  `MotionSafeAnimation.swift`'s `View.kurnAnimation(_:value:)` wraps
  `@Environment(\.accessibilityReduceMotion)` so call sites don't each
  re-implement the check; a `repeatForever` loop (e.g. `RecorderView`'s
  `PulsingDot`) instead gates its own start on that environment value and
  renders the final static state when Reduce Motion is on, since wrapping a
  looping animation in `kurnAnimation` alone doesn't stop it from starting.
- **Dynamic Type** — `Theme.swift`'s "Typography" section provides semantic,
  Dynamic-Type-aware `Font` constants (`Font.system(_:design:weight:)`, never
  `Font.system(size:)`) that all real reading text should use. Fixed-geometry
  UI (icon glyphs, a circular avatar, `RecorderView`'s big timer) stays a
  fixed size via `@ScaledMetric(relativeTo:)` with a capped
  `.dynamicTypeSize(...DynamicTypeSize.accessibility2)` on that subtree,
  rather than scaling unbounded and breaking a fixed-dimension layout — this
  is a deliberate, narrow exception, not the app-wide default.
- **Lint guardrail** — `.swiftlint.yml`'s opt-in `accessibility_label_for_image`
  and `accessibility_trait_for_button` rules are `severity: error`, so a new
  unlabeled icon-only control or untraited tappable view fails CI, not just a
  warning. Note the rule attributes a violation to the *enclosing view's
  declaration line*, not the modifier call site — a misplaced
  `// swiftlint:disable:next` comment a few lines below the real declaration
  silently does nothing. When violations need triage beyond what the console
  log shows (SwiftLint lints in parallel, so log-line adjacency to a
  "Linting 'X'" message is not a reliable attribution signal), the CI job
  also uploads `swiftlint-report.json` (`--reporter json`, exact file/line)
  as a build artifact.
- **`KurnUITests/AccessibilityAuditUITests.swift`** — runs
  `XCUIApplication.performAccessibilityAudit(for: [.sufficientElementDescription,
  .trait])` over six screens in three tests: the meetings list
  (`testMeetingsList`), the Meeting Detail Recordings, Transcript, Summary and
  Chat tabs (`testMeetingDetailTabs`, one launch with one activity per tab —
  each UI test relaunches the app, and that launch was most of each audit's
  CI time), and the Settings root (`testSettings`). It reuses the same seeded
  `"UI-Testing-Screenshots"` launch state and identifiers as the screenshot
  tests. It's wired into the `Kurn.xcscheme`'s default `TestAction` alongside
  `KurnTests` (`KurnUITests` wasn't in the scheme before this was added, so it
  never ran in CI), with `ScreenshotUITests` explicitly skipped there since it
  depends on fastlane's snapshot setup.
- **`KurnUITests/Flows/`** — user flows over the same seeded launch, driven
  only through `accessibilityIdentifier`s (`settings.link.*`,
  `settings.providers.*`, `settings.transcription.engine`, `health.*`,
  `tags.*`, `folders.*`, `folder.*`, `detail.more`/`detail.share`, `share.*`,
  `chat.*`, and `dialog.title`/`dialog.primary`/`dialog.secondary` on the
  shared `kurnDialog`): `SettingsFlowUITests` (Providers, declining a model
  download keeps the engine, Storage, Health & Recovery),
  `LibraryFlowUITests` (tag and folder create/delete),
  `ShareAndChatFlowUITests` (share sheet up to the Obsidian format, Ask with
  no provider → empty state, composer disabled) and
  `BulkSelectionFlowUITests` (selection mode: pick count, bulk export with one
  file per meeting or one file, bulk delete cancelled then confirmed). Every
  flow launches with UIKit animations off (`UITestLaunchOptions`, DEBUG only)
  and the language pinned to English, never sleeps, and confirms a tap that
  starts a transition by its outcome, repeating it once if UIKit dropped it
  (`FlowUITestCase.tapUntilCovered` / `tap(_:until:)`); CI runs them with test
  timeouts so a hang fails in minutes. The open stability and speed work is in
  `docs/roadmap.md` ("UI test stability and speed"). They run in the required
  `ui-accessibility-tests` job (promoted after 5/5 green attempts in
  `reliability-hardening.yml`'s `ui-flake-rate` lane); a suite that starts
  flaking is demoted with a `-skip-testing` line in `swift.yml` and
  re-measured there before coming back.
- **Speaker identity, not color, carries meaning** everywhere it matters: the
  Live Activity says "Recording"/"Paused" in words — under "Kurn" on the Lock
  Screen, beside the dot in the expanded Dynamic Island — rather than with a
  colored dot alone, and status text is never color-only.
- **Locale parity** — `KurnWatch/` and `KurnLiveActivityExtension/` each carry
  the same 7 locales as the main app (`en`, `pt-BR`, `es`, `fr`, `it`, `de`,
  `zh-Hans`), not just `en`/`pt-BR` — a VoiceOver user on the Watch or reading
  the widget in one of the other 5 languages would otherwise hear/read
  English. Keep new strings in these two targets in sync across all 7 the
  same way the main app's `Localizable.strings` are — which CI enforces for
  the main app (see the Localization convention below).
- **Known gaps, left out of scope deliberately**: `ScreenshotUITests` and the
  accessibility audit both run at the system's default text size, so neither
  catches a layout break at large accessibility text sizes — that needs
  manual testing (Accessibility Inspector / Simulator) per screen.
  `KurnWatchUITests` doesn't run in `iOS CI` today (the watchOS runtime is
  downloaded so the scheme *builds*, but `test` runs only against
  `$IOS_DESTINATION`), so Watch VoiceOver is verified manually, not by CI.
  **`RecorderView` and `FolderFormView` are not audited either** — worth
  knowing before trusting the audit as a safety net, since the recorder is the
  screen with the most icon-only controls. `testMeetingDetailTabs` audits the
  Chat tab's structural chrome only: seeded data carries no semantic index, so
  the run never leaves the empty/disabled state and composer — the actual
  conversation UI (the "thinking" reasoning row, a streaming reply, the retry
  affordance, citation and timestamp chips) only renders once a configured
  provider returns a real answer, so it stays a manual/on-device check. Adding
  a test for a new screen is the cheap part; the audit's coverage is exactly
  the six screens listed above and nothing more.

## Conventions

- **Errors:** surface recoverable failures as `AppError` (`Infrastructure/AppError.swift`),
  a `LocalizedError` whose messages come from `NSLocalizedString`. New error cases
  must add a matching localization key.
- **Localization:** user-facing strings use `NSLocalizedString`; the app ships
  **seven languages** — English, Brazilian Portuguese, Spanish, French, Italian,
  German, and Simplified Chinese (`Kurn/Resources/{en,pt-BR,es,fr,it,de,zh-Hans}.lproj/`).
  Every new user-facing string must be added as a key to **all seven**
  `Localizable.strings` files in the same change — none skipped. `displayName` on
  enums is the localization seam. This is **enforced by CI, not by convention**:
  the "Check localization files" step in `.github/workflows/swift.yml` fails the
  build when any locale's key set differs from `en.lproj`, or when a file
  contains a duplicate key. That step exists because neither of those is
  otherwise detectable — SwiftLint does not read `.strings`, and Xcode compiles
  them into a binary plist that silently collapses duplicates, so a duplicated
  key is invisible to the linter and to the test suite alike.
- **Logging:** use `AppLog.<category>` (subsystem `ai.kurn.app`), which wraps
  `os.Logger` in a `CategoryLogger` that gates every message by `AppLog.minimumLevel`.
  Pick the severity per call site — `.debug` for high-frequency/per-iteration traces,
  `.info` for details (counts, formats, timings), `.notice` for lifecycle milestones,
  `.error`/`.fault` for failures. The user controls the threshold in Settings
  (persisted via `AppSettings.logLevel`); `.off` silences everything. The launch
  default is `.notice`, overridable with `KURN_LOG_LEVEL=debug|info|notice|error|off`
  or `KURN_LOG=0`. Mark interpolated values `privacy:` explicitly. Never log an
  error's `localizedDescription` at `.public`: log `error.publicLogCode`
  (`Infrastructure/Extensions/Error+LogCode.swift` — an `AppError`'s `logCode`,
  otherwise NSError domain and numeric code) at `.public` and the text at
  `.private`. `Tools/check_static_policy.py` fails CI on a new `.public`
  description, and its baseline only shrinks (a stale entry is an error).
- **Reliability events:** a failure the user may need to recover from later —
  capture, store boot, journal replay, model install, provider circuit,
  transcription/document stages — is recorded as a `ReliabilityEvent`
  (`KurnCore`) via `ReliabilityLog.record`, never only as a log line. Events
  carry fixed codes and short IDs (`OperationID`), no content, paths or error
  text; `CaptureReliability` is the seam for the capture path.
- **Concurrency:** services are `Sendable` value types callable off the main actor;
  view models and anything touching SwiftData/UI are `@MainActor`. Preserve these
  boundaries when adding code. Heavy pipeline work (preprocessing, ASR, diarization,
  enhancement, model loading) reserves its `ResourceWorkKind` weight through
  `withResourceReservation(_:on:_:)` (`Infrastructure/ResourceScheduler.swift`),
  which releases in the same async flow on return, throw and cancellation — do not
  pair `acquire` with a `defer { Task { release } }`.
- **Tests:** Swift Testing (`@Test`, `#expect`). Use
  `TestModelContainer.make()` for an in-memory `ModelContainer` when exercising real
  SwiftData relationship behavior. Suites whose fixtures live in the shared
  recordings directory belong inside `RecordingsDirectorySuite`: its serialized
  parent prevents recovery sweeps or directory-wide deletion from moving another
  test's file while its writer is open. `tempFileTestLock` alone does not serialize
  against those recording-directory operations.
- **Git & PRs:** write all commit messages and pull request titles/descriptions in
  English, regardless of the language used in chat. (User-facing app strings are
  still localized per the localization convention above — this rule is only about
  repository metadata.) Use **Conventional Commits** for the commit subject line:
  `<type>(<optional scope>): <summary>`, type one of `feat`, `fix`, `docs`,
  `chore`, `refactor`, `test`, `perf`, `style`, `build`, `ci` — e.g.
  `fix(chat): dismiss the keyboard on tap outside the composer`. Existing history
  is mixed (older commits predate this rule); new commits should follow it.
- **Meeting content leaving the app's sandbox:** copy to the clipboard only
  through `MeetingPasteboard` (local-only, expiring), never
  `UIPasteboard.general.string`; LLM-written Markdown is rendered with links
  disabled (`MarkdownPresentation.inlineAttributedString`), since a transcript
  can steer the model into a link that exfiltrates it; and a downloaded model
  is fetched from an immutable revision with a `pinnedSHA256` in its catalog
  entry — `ModelFileDownloader` refuses to install a file it has no digest to
  check against.
- **CI supply chain:** every `uses:` in `.github/` is pinned to a full commit
  SHA with the version in a trailing comment (Dependabot keeps both current),
  checkouts set `persist-credentials: false`, and workflow inputs reach `run:`
  scripts through `env:`, never `${{ }}` interpolation.
- **Do not commit directly to `main`:** create a feature branch for every change,
  push it, and open a pull request. Only merge through the GitHub PR workflow so
  CI runs before the change lands on `main`. The only exceptions are fastlane
  version/tag bumps run explicitly by a maintainer.
- **Accessibility is not optional on any UI change:** every new icon-only
  control needs an `.accessibilityLabel`, every view carrying a tap/long-press
  gesture needs either an `.isButton`/`.isLink` trait or a documented
  `// swiftlint:disable:next accessibility_trait_for_button` with the reasoning
  (see "Accessibility" above for the existing pattern and why the disable
  comment attributes to the *enclosing view's declaration line*, not the
  modifier). Both rules are `severity: error` in `.swiftlint.yml` and fail CI,
  not just warn — check this before pushing UI changes, not after `lint-and-validate`
  fails.


### Awaited runtime persistence and initial session owner

AgentHarness's `NativeHarness` can install awaited message and usage commits. Canonical user
messages precede model IO; assistant finals precede tool effects; results precede the next
request. Audit failures and synthetic blocked results use the same message sink. A failed
commit throws and prevents dependent work. `AgentRunHandle` separates producer completion
from observation lifetime: `start` has disposable events (`.bounded`, the newest 128, or
`.complete` for a reducer that cannot tolerate a gap) and explicit cancellation, while
`result()` waits for producer termination. The legacy `run` API retains its existing
stream-consumer cancellation semantics.

`AgentSession` is Foundation-only run ownership infrastructure; the chat runs each reply through
one (see "A run's model history is durable" below). It reserves busy state before store awaits, persists run/message/usage/end entries,
and awaits producer termination plus terminal persistence before releasing ownership. A
terminal-save retry never reruns inference/effects and recognizes an identical committed
entry after a lost acknowledgement. Persistence failure is explicit and blocks new prompts;
message/usage failures require host recovery. Store adapters must implement atomic checked
append groups. One retained owner per session and authorized history projection are host
responsibilities; constructing an owner never resumes a saved run. `AgentSessionAppendMode.branch`
chains a run's entries from the leaf at run start without moving the selected leaf — the shape the
chat's run branches use. Each append is built
against the snapshot it commits on; a conflict (another writer committed first) rebuilds it on the
new snapshot, up to `conflictAttempts` (4) tries, and the terminal entry keeps one append identity
across retries so a lost acknowledgement is recognized by ID and payload. `start` is `prompt` with
the run's events (`AgentSessionRun`): it takes the host's own `runID` and extra run-start fields (the
host's authorization; `runID` cannot be overridden), and its disposable stream ends only once the run
has settled, throwing the run's failure — `AgentSessionOwnerError.persistenceFailed` for any history
write that failed (a terminal entry that could not be saved after an answer included, ahead of any
other failure), never the store's own error, and otherwise `CancellationError` after `abort()`. A run-start
that cannot be saved fails the run without blocking the session, since nothing of it was written.
`start(commandID:)` makes a command idempotent across processes: the ID is written into the run-start
entry (`AgentSessionEntry.commandID`), and a start whose command is already in the log — checked on
every snapshot an append attempt is built on, so a writer that committed in between is caught too —
writes nothing, calls no model and ends with `AgentSessionOwnerError.duplicateCommand`. The chat's
command is the question turn a run answers (`MeetingChatViewModel.send(commandID:)` can name another).
`AgentRunProgress` projects a run's phase with its identities from its events — `preparing`,
`streaming`, `executingTools`, `compacting` (between `compactionStarted` and its end, restoring the
interrupted phase), `retryWaiting` (an output-limit retry until its request starts) and
`finished` — with the current turn index, request identity, started-but-unfinished call IDs and the
turn's registered invocations. It is presentation only and never orders persistence; there is no
`waitingForUser` until a tool asks for confirmation. A retry's wait lasts across its `turnStarted`
and any compaction until its request starts, and `finish()` closes a run that ended without
`runFinished`. The chat keeps it as `MeetingChatViewModel.runProgress` (reset with the conversation),
and `ChatRunPhase.following(_:)` derives the shown phase from it, beside its own `cancelling`.
The chat does not read the event stream itself: `HarnessChatService.Run.snapshots` is
`AgentRunSnapshots.coalescing(events)`, a reducer that drains the complete observation into
`AgentRunSnapshot`s (streamed text, trace, progress, finished tool calls, outcome) and keeps only the
newest for the view. A busy view skips intermediate snapshots instead of growing a queue, the last
snapshot always arrives before the stream ends with the run's failure, and the view model finds the
document tools finished since the last snapshot it saw by count. Ending observation stops the
reducer, never the run.

**Chat conversations are host-owned (NH05 host activation).** `ChatConversationHost`
(`ViewModels/`, built by `AppComposition`, injected app-wide) retains one
`MeetingChatViewModel` per scope — a meeting, or the library-wide Ask shared by the meetings
list and documents — so `MeetingChatView` only resolves and renders it. A reply keeps running
when its sheet or tab is dismissed (the view model used to cancel from `deinit`). At most
`capacity` (4) conversations are kept, evicting the least recently opened idle one, never a
running one; "Delete all data" awaits `closeAll()` before `LibraryEraser`. The run is the
`HarnessChatService.Run` from `HarnessChatService.start` (complete observation, an
`AgentSession` run once the conversation is saved): every exit aborts it and waits for it to settle
first. `cancel()` only requests: the conversation stays busy in
`ChatRunPhase.cancelling` until settled (`waitUntilSettled()`), the Stop button disables, and
`send` refuses until then. `reset`/`load` fence the old run by generation; it still owns the
busy state until it terminates. A run whose meeting or open session was deleted writes nothing
(`persistOrThrow` throws `CancellationError`, which `persist` swallows), and `delete` refuses
the open session while its run is active. A run holds a finite background-execution window
(`BackgroundExecutionWindow`, `BackgroundActivity` in production, injected through
`makeBackgroundWindow`). `BackgroundActivity` calls its owner's expiration handler once
`BackgroundDeadline.windDownLead` (8 s) of background time remains, while the task is still
held — the system's own expiration handler must end the task and is too late for async
clean-up, so it is only the fallback. The chat cancels the run there like a user stop, and it
settles as a retryable interruption (reliability code `background_expired`) inside the window,
never frozen mid-request or mid-tool. That interruption is kept as `pendingForegroundResume` (the
question, provider and model); on the next `.active` scene phase `KurnApp` calls
`ChatConversationHost.resumeAfterForeground()`, which sends each such question again once
(`background_resumed`) after its run has settled — only if it is still the unanswered retryable
question with no error, and only if the stopped run committed no document change (a resumed run
would call the tool again under a new invocation identity no receipt matches; such a question stays
for the user's Retry, `background_resume_declined`). A user stop, a new question, `reset` or `load`
(opening another saved conversation in the same scope) clear it; each scope keeps its own, so moving
between meetings does not. The host does
not evict a conversation that holds one. The resumed run starts over from the saved question; nothing
of the stopped run is replayed. The transcription coordinator's background cancellation
gets the same earlier, checkpointable moment.
The composer's unsent text (A68) is `MeetingChatViewModel.draft`, not view state, so it outlives the
view; a saved conversation keeps it as its `.draft` recovery record (`ChatDraftRecord`), written when the
scene goes to the background (`ChatConversationHost.saveDrafts()`), when another conversation opens and
before the host evicts the view model — never per keystroke. A reopened conversation puts it back; a
question sent from the composer clears it (a resumed question leaves it); a new, unsaved conversation's draft
lives in memory only, goes along ahead of an opened conversation's own draft, and keeps its view model from
being evicted. A draft that cannot be saved is never dropped: it stays in the composer and the chat says so.

**The question is a barrier, and every run leaves a record.** `send` saves the conversation
with the new question before any request; if that save fails nothing is sent and the question
stays retryable. A `ChatRunRecord` (`Infrastructure/Agent/`, an `AgentRecoveryRecord` of kind
`.run` in the session) is written `.running` right after, and `.ended` when the run settles.
`ChatRunRecovery.sweep`, one of `AppComposition`'s launch sweeps, marks every record still
`.running` as `.interrupted` (reliability code `run_interrupted`): no run is live when a store
opens, the saved question already reopens as the retryable one, and committed document effects
keep their own receipts. It never re-sends or resumes anything. Evidence is closed rather than
deleted: any run's branch that nothing ended — a dead process's, or a run that settled without
saving its own end entry — gets the `agent.run-end.v1` it is missing (`ChatRunBranch.closeIfOpen`,
`end` `interrupted` or `persistenceFailed`, reliability code `run_branch_closed`), as the last entry
of that branch, without moving the selected leaf. In process, a run that failed on a history write
retries its own end entry once (`AgentSession.retrySettlement`) before it settles. A reopened conversation whose
retryable question is one of those (`ChatRunRecovery.interruptedQuestionIDs`) says so above
Retry (`retryableQuestionWasInterrupted`, `chat.run.interrupted`), so an unanswered question left
by a crash reads differently from one the user stopped. It also shows what that run had done:
`ChatRunRecovery.restoringInterruptedRun` rebuilds the run's steps and usage from its canonical
branch with AgentHarness's `AgentRunTrace.restoring(run:from:)` and puts them under the retryable
question when it has none of its own. Only committed entries are shown — a restored tool call has
no output summary (that is a live event, never saved), a call without a saved result reads as
failed, and there is no stop step without a saved end. Restoring writes nothing and never re-runs
anything; a later save of the conversation keeps the shown steps on the question, as it does a
stopped run's. The interruption is then resumed, once: `load` stages
`MeetingChatViewModel.interruptedResume` when `ChatRunRecovery.resumableInterruptedRun` allows it
(the run committed no document change, was not itself a resume and was not resumed before), and
`MeetingChatView` calls `resumeInterruptedRun(provider:model:)` with the provider and model the chat
uses now, as Retry would. The resume runs under the durable command
`ChatRunBranch.resumeCommand(for:)` (`resume-<runID>`), so it never repeats in this process or after
another launch (reliability code `interrupted_resumed`); a run that changed a document is left for
the user's Retry. Both resumes live in `MeetingChatViewModel+Resume.swift`.

**A run's model history is durable, on its own branch, written by `AgentSession`.** Each chat run
is started through a per-run `AgentSession` owner in `.branch` mode (`ChatRunBranch`,
`Infrastructure/Agent/`; `HarnessChatService.start(owner:runID:)`), with the run's `ChatRunRecord`
ID as its `runID`. The owner is installed as the harness's message and usage sinks, so the question,
each assistant turn with its tool calls, each tool result and each request's usage are committed to
the session before the work that depends on them. The branch opens with `agent.run-start.v1`
carrying the run's `ChatRunAuthorization` (effective scope, the meeting IDs it resolved to, the
`provider:model`) as a host start field, written before any model IO, and closes with
`agent.run-end.v1` (how it ended plus the harness stop reason). Its entries chain from the leaf at
run start (the accepted question) but never move the selected leaf: the presentation path,
`SwiftDataAgentSessionStore.projection` and the compatibility writer's prefix diff see none of them.
A presentation or effect write that lands between an owner append's load and commit is a revision
conflict, and the append is rebuilt on the new snapshot. The chat reads the owner's event stream,
which ends only once the run has settled; a stop is `abort()` plus waiting for settlement. A failed
history write ends the stream with `AgentSessionOwnerError.persistenceFailed`, which fails the run
(question retryable, `run_transcript_write_failed`) and shows `chat.storage.run_failed` — saying
nothing more was sent — instead of the store's own error text (`MeetingChatViewModel.presentedError`);
a run whose session was deleted under it ends as a cancellation. One owner per run is safe because the
view model admits one run at a time and a retry starts a new branch. The next run replays these
branches as canonical history (see "Agent harness", `ChatReplayHistory`).
