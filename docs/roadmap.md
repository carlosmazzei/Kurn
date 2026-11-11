# Roadmap

The single list of **work that is still open**. Everything that has shipped is
documented where it lives permanently — `CLAUDE.md` for architecture,
invariants and conventions, the `README.md` for what the app does — and is
deliberately not repeated here. When an item below ships, move what is worth
keeping into those two files and delete the item; do not open a separate plan
document for a new track, add a section here instead.

The verdicts matter less than the reasoning attached to them. A "no" with a
recorded reason stops the same idea from being re-litigated every few months; a
"yes" with its coupling point named is most of the design work already done.

## The filter

Kurn is a local-first meeting recorder. That sentence is load-bearing, and these
five invariants are what it decomposes into. Every entry below is judged against
them, and where an entry creates tension the tension is stated rather than
smoothed over.

|        | Invariant                                             | What holds it up today                                                                                                  |
| ------ | ----------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| **I1** | Nothing leaves the device without an explicit request | Network only on opt-in cloud transcription or a cloud LLM provider; a fresh install works offline                       |
| **I2** | Meeting-derived content lives in the encrypted store  | `ModelStoreProtection` (`.completeUnlessOpen`) covers the SwiftData store; never a loose file, cache, or `UserDefaults` |
| **I3** | Accuracy is measured, not asserted                    | `KurnTests/Support/Evaluation/` (WER, DER, RTTM) plus the public-dataset matrix                                         |
| **I4** | The subject is meetings, not dictation                | The value is a 90-minute multi-speaker file, not a six-second insert                                                    |
| **I5** | Heavy dependencies are opt-in                         | `ModelDownloadConsent` gates every model fetch, with a working fallback when declined                                   |

Two further rules follow from I1 that are easy to violate by accident: a feature
that makes a paid cloud call *per transcription* cannot ship enabled (this is
why `wikiEnabled` and `correctionEnabled` default off), and a feature that
merely moves data off-device still needs consent even when no LLM is involved
(why `templatesSyncEnabled` defaults off).

## Native harness evolution — app-only implementation plan

Planning baseline: `feature/native-harness` at
`429cc866498de94864dc8da7b9af76a27998e5ae`, inspected on 2026-11-08.
Reference: the seven attached pi specification documents, describing pi revision
`f064465d10d6a8e5c19f687bba1b5b5499b51680`. Their PI/IOS/EXT statements are
reference contracts and alternatives, not instructions to adopt every subsystem.
The requested product constraints take precedence: execute the harness entirely
inside Kurn, require no application backend or external extensions, preserve
context selection, and continue saving conversation artifacts as documents.
This section proposes implementation work; it does not claim that it has shipped.

### Scope and decisions

- Keep the Swift implementation with the app depending on the independent
  `KurnCore` and `AgentHarness` packages. Keep domain logic Foundation-only and
  Linux-testable. Do not port the TypeScript runtime or replace SwiftData.
- Interpret app-only as local ownership of loop, tools, sessions, context,
  artifacts and credentials. Existing, explicitly selected cloud models remain
  direct HTTPS integrations. No gateway, RPC server, hosted workspace or sync
  service is required. App-only does not mean inference is already offline.
- Retain the current supported agent routes: official OpenAI Responses,
  OpenAI-compatible Chat Completions, Anthropic Messages and Gemini. The Apple
  on-device provider currently has no `AgentModel`; offline agent inference is
  a separate, optional adapter deliverable, not a prerequisite or a claimed
  capability of this plan. Never silently switch a local selection to cloud.
- Tools operate on Kurn's selected meeting content and document artifacts.
  Do not declare bash, PowerShell, desktop build tools, arbitrary filesystem
  write/edit, Node, MCP, codemode or downloaded executable plugins. Retain
  internal typed policy seams without implementing a public extension framework.
- Preserve the app's existing consent, store protection, deletion, export,
  localization, accessibility and dependency rules. New harness data belongs in
  the same protected store; JSONL is an interchange format, not a second live
  database containing unprotected meeting text.
- Target the applicable local behavior of C01–C19 and C24–C26. Explicitly record
  app-specific adaptations instead of advertising complete pi compatibility.
  C20–C23 and C27 are not required for this product scope.

### Gaps to close in the existing implementation

| Current boundary | Required evolution |
| --- | --- |
| `AgentMessage` has user text, assistant text/calls and text results | Stable identities, ordered content blocks, system state, terminal status, provider/model identity and opaque replay data |
| `AgentModelEvent` exposes only text deltas | Block-aware stream reduction, authoritative final messages and terminal error/abort events |
| `NativeHarness` is a stateless sequential run | One session owner, lifecycle barriers, queues and observable cancellation; retain limits and wrap-up behavior |
| `ChatSession.turnsData` persists presentation turns | Durable canonical entries and an active leaf; visual turns become a derived projection |
| `MeetingChatViewModel.buildHistory` intentionally drops old tool payloads | Replay a bounded, authorized projection of canonical history, not all saved tool content |
| Compaction updates only a run's in-memory context | Persist checkpoints and reuse them after the next question or relaunch |
| Artifacts save on successful tool events and on caught failures | Commit document effects durably before reporting tool success, including crash recovery |
| `ChatDocumentWorkspace` stores each artifact's latest version | Recoverable revisions and branch-aware artifact state without losing current save/update behavior |
| `AgentUsage` tracks input/output; chat does not inject a cost estimator | Explicit unknown values, cache/reasoning usage and consistent estimated/reported accounting and cost guards |
| `cancel()` immediately clears the view's busy state | Cancellation request followed by confirmed termination and persistence, then settle |
| Sources and artifact/document UI already exist | Preserve them and add regression coverage; do not build a second source picker or document generator |
| Reliability logging records a coarse view-model outcome, while timeline events carry limits only in memory/UI | Record every harness decision with correlated, structured diagnostics, including limits even when wrap-up produces an answer |

`CLAUDE.md` contains some stale harness descriptions (for example, artifact cards
being future work) despite their implementation. Resolve these descriptions as
the relevant boundaries ship; use code and tests for the baseline inventory.

### Architecture and ownership

These are responsibilities and suggested types, not eleven new packages.

| Location | Responsibility and suggested types |
| --- | --- |
| `Packages/AgentHarness/.../Domain/` | Versioned message/block/event/entry types, recursive JSON, usage and capability values; no HTTP, SwiftData or SwiftUI |
| `Packages/AgentHarness/.../Runtime/` | `AgentRuntime` evolving `NativeHarness`: one run's loop, scheduler, limits, cancellation and ordered canonical events |
| `Packages/AgentHarness/.../Session/` | `AgentSession` actor: exclusive commands, queues, model selection, projection, compaction/retry and settle; depends on store/model/tool protocols |
| `Packages/AgentHarness/.../Tools/` | Static registry, validator, execution pipeline, progress and execution policy; no dynamic plugin discovery |
| `Packages/AgentHarness/.../Wire/` | Evolve the existing request builders and accumulators; normalize replay for each supported protocol |
| `Packages/KurnCore/.../Agent/` | Keep source scopes, source/document tools, artifact workspace, citations and presentation reducers; add source provenance and artifact persistence protocols |
| `Kurn/Infrastructure/` | `SwiftDataAgentSessionStore`, schema migration, recovery and protected export staging; return Sendable values rather than persistent models |
| `Kurn/Providers/` | Reuse bounded HTTP/SSE, URL policies, catalog and Keychain; build a model per request with current credentials/capabilities |
| `Kurn/Application/` | `ChatSessionCoordinator` and artifact/document use cases; compose session actors and MainActor store adapters through `AppComposition` |
| `Kurn/ViewModels/` and `Kurn/Views/` | Observe presentation snapshots, submit commands and render sources/artifacts; never own the canonical agent transcript or start work during rendering |

The execution path is:

```text
MeetingChatView → view model → ChatSessionCoordinator → AgentSession → AgentRuntime
                                  │                     │              │
                                  │                     └─ projection / store
                                  │                                    │
                                  └─ MainActor SwiftData adapter        ├─ model adapter → selected provider
                                                                       └─ native source/document tools
```

Keep all SwiftData model access on MainActor as the repository currently requires.
The session actor owns scheduling, not persistent model objects; await a store
protocol that exchanges value snapshots. Actor reentrancy requires an explicit
busy/generation guard across awaits: using an actor alone does not reject a
second prompt or navigation. The coordinator owns session lifetime beyond a
single view. Closing a view unsubscribes; Stop explicitly cancels. App suspension
still follows the bounded local policy below.

Expose a typed native API rather than emulating stdin/stdout RPC. Proposed
commands are `prompt(input, scope, delivery)`, `steer`, `followUp`, `clearQueue`,
`abort`, `waitUntilSettled`, `selectModel`, `selectThinking`, `compact`,
`navigate`, `fork`, `clone`, `snapshot` and `export`. Each command has a stable
local request ID and returns a disposition or validation/conflict error; model
execution finishes asynchronously through ordered events. Subscribe before
issuing commands. Reject a duplicate request ID with a different payload and
return the saved disposition for an identical accepted command. Event sequence,
entry ID and tool invocation ID are separate identities. Snapshot revision and
subsequent event subscription must be consistent when a view reattaches.

### Context selection is a product contract

Preserve `ChatSourceScope`, `ChatSourceScopeEditor`, `ChatSourceSheet`,
`SourceScopeResolver`, `LibraryChatSourceReader` and `ChatSourceTools`:

- Per-meeting chat remains locked to its meeting. Library chat retains meeting,
  tag, folder and library modes, global part toggles and per-meeting overrides,
  including empty overrides. Wiki remains opt-in; old `includeWikis` data still
  decodes. No selected meetings/parts continues to disable Send and Retry.
- Persist a scope-change entry and keep the latest scope as session metadata.
  At task acceptance, capture selected rules, resolved meeting IDs, permitted
  parts, source revisions/hashes and the wiki gate in an immutable
  `ResolvedSourceScope`. All turns of that task share that authorization ceiling.
  Missing/deleted sources fail reads; retagging or a new meeting must not expand
  a running task's access. Re-resolve and validate for the next accepted task.
- Apply authorization to listing, search, reads and metadata, not just tool
  descriptions. The model cannot enlarge the scope. Continue paginating source
  results and preserving the current timestamp citation format.
- Distinguish **selected sources** from **conversation memory**. Today plain
  earlier user/assistant text is replayed even after selection changes. Do not
  silently change that meaning: show that earlier conversation text remains
  context and provide an explicit “Use only the current sources” action.
- That action starts a new context segment without erasing the visible history.
  It excludes earlier derived messages, tool payloads, summaries and artifact
  content/metadata unless their provenance is demonstrably within the new
  selection or the user explicitly includes the artifact as context. Legacy
  messages with unknown provenance are excluded in this mode. Compact only the
  authorized segment. Simply filtering fresh tool reads is insufficient.
- The default migration preserves today's plain conversation memory, but must
  not start replaying historical source-tool bodies that the old implementation
  deliberately omitted. New detailed tool history is replayable only within its
  authorized context segment; scope reduction creates a projection boundary for
  those payloads. Raw history and costs stay available independently.
- Persist scope/context-segment identity with queued prompts, compactions and
  artifact provenance. Queue consumption revalidates availability and the current
  session/branch binding; never substitute a newly broadened selection silently.

### Artifact and document contract

Retain all four document tools and existing limits, paginated reads, card
previews, Markdown copying and Markdown/Word/HTML export. Keep a conversation
artifact distinct from a `GeneratedDocument` saved to the library. Ordinary
assistant responses do not become documents automatically.

Move the application use case behind `ChatArtifactStore` into `Application/`
so store/coordinator code does not depend upward on ViewModels. Keep the UI
adapter small. Preserve `MeetingLibrary.saveDocument`, `ChatArtifactOrigin`,
`ChatArtifactSources`, and the source label/ID snapshots:

1. Saving a new artifact creates one document. Saving the same session/artifact
   revision twice returns the same document. A newer revision offers Update;
   saving an already saved revision does not duplicate it. Deleting the saved
   document permits saving again.
2. Store artifact revisions with stable artifact ID, revision identity, monotonic
   version within its session/lineage, originating entry/call, previous revision,
   title/body and source provenance. Resolve the current revision from the
   active path. Keep the current latest-version card behavior; label historical
   references and offer explicit version inspection when branches are enabled.
3. Going back to a branch does not mutate an independently saved document.
   Saving an older/divergent revision requires an explicit replace/copy action;
   the existing `version > savedVersion` check alone cannot express that case.
   Fork/clone copies its selected artifact state into the new session namespace;
   document identity remains `(sourceChatSessionID, sourceArtifactID)`.
4. Persist a tool-effect receipt and new artifact revision in one store save
   before emitting success. The receipt includes the stable invocation identity,
   durable output and committed revision. If transcript append has not completed
   at a crash, recover its result from the receipt without executing the mutation
   again. Append canonical batch results in assistant call order.
5. A failed save is a tool/persistence error and stops dependent work. A committed
   document remains visible after later model failure, cancellation, limit or
   relaunch. Never roll it back because the last answer failed.
6. A committed local effect is recoverable, not an exactly-once promise about
   arbitrary external effects. A receipt with an unresolved outcome is shown as
   interrupted and is not automatically replayed. Do not deduplicate unrelated
   model calls by equal argument text.
7. Preserve generating question/model and accumulated source snapshots through
   retries and reopening. Deleted meetings/chats must not delete an independently
   saved `GeneratedDocument`; per-meeting chat data keeps its existing cascade.
8. Route artifact copying through `MeetingPasteboard`, consistent with the app's
   local-only expiring clipboard rule. Preserve safe Markdown rendering and
   explicit export staging/cleanup rather than caching document bodies in files.

### Mandatory diagnostics and the thirteen-meeting regression

User-reported reproduction: thirteen transcribed meetings with summaries,
`gpt-6.1-terra`, roughly 33k tokens displayed, about five context compactions,
about ten `toolCallLimit` occurrences and clipped source content. These are
observations to reproduce, not a confirmed root cause or a recorded trace.
Instrumentation and targeted fixes are the first P0 delivery, before the large
session migration. Preserve the source selector and artifact/document flows
throughout this work.

**Facts established from this branch:**

- `ModelContextWindows.windowsByPrefix` has no `gpt-6.1-terra` match. Unless
  `ModelContextWindowStore` contains a positive window reported by that
  provider/model, the harness uses `unknownWindow = 32_768`. With the default
  reserve of 16,384, `max(window / 2, window - reserve)` is 16,384, and
  `effectiveKeepRecentTokens` is only 8,192. This is a plausible explanation for
  early repeated compaction, not proof of which value the tested device used.
  Do not infer the model's actual supported window from its name.
- With exactly thirteen resolved source meetings and no explicit limits
  override, `AgentLimits.chat` allows fourteen ordinary turns and fifty-one tool
  calls, plus the existing conditional tool-less wrap-up. Calls are counted
  before tool validation/execution, so unknown/invalid/denied calls also consume
  the present counter. After exhaustion, each remaining call in the batch gets
  its own error result. Ten such results do not establish ten exhausted runs or
  ten executed calls beyond the limit.
- `MeetingChatViewModel` records success when an answer exists, even if that
  answer came from a run stopped by a limit. Its coarse reliability code can
  therefore omit the actual `toolCallLimit`; the structured UI stop step is not
  a durable diagnostic trace.
- `ChatSourceToolText.passages` routes passage text through `field`, clipping
  each passage at 500 Unicode scalars. Transcript offsets page passages, not
  characters within a passage, so the clipped suffix cannot currently be
  recovered by requesting the next passage offset. This is lossy truncation,
  independently of the model window.
- Other distinct constraints include 8,000-scalar text pages, ten transcript
  passages per page, a source-output body target of 18,000 UTF-8 bytes, a
  top-100 search window, 2,000-character tool-result clipping in summary input,
  and fitting summary input by dropping its oldest text. They need separate
  reason codes; a UI preview cap must never alter canonical/model content.

**Diagnostic contract.** Add a Sendable `AgentTraceSink`/typed event seam in the
Foundation-only package and inject an app recorder through `HarnessChatService`.
Use stable event codes and typed, allowlisted metadata instead of interpolating
unrestricted dictionaries or raw error strings. Each event carries a trace
schema version, session/run/turn/request/attempt/call identity as applicable,
sequence, timestamp, monotonic duration and phase/outcome/reason. Correlate
compaction requests and wrap-up with their parent run and an explicit purpose.

The protected local trace must record all semantic steps and decisions, even
when nothing fails. Do not depend on the view staying open, `.debug` being
enabled, a tool being successful or an answer being empty. Preserve
`AppLog.minimumLevel`/`.off` for console output; keep a documented bounded
content-free run trace and canonical recovery records independently of console
verbosity, following the existing local reliability-store precedent. No
transcript, question, answer, summary, artifact body/title, search term, tool
argument content, secret, endpoint URL or raw provider payload belongs in that
trace. Use opaque source IDs and numeric counts/ranges where needed. Token
deltas need counts/stream milestones, not a separate log of their text.

| Boundary | Required event and diagnostic fields |
| --- | --- |
| Input/scope | Accepted/rejected/queued/dequeued; resolved source count, permitted-part counts, scope revision and validation code |
| Model/budget resolution | `context_window_resolved` with configured provider/model IDs, effective model when reported, chosen token value and source (`api`, `fixed_table`, `fixed_fallback`; `native_framework` for a local framework), cache status, decision reason, metadata revision, separate operational overrides, reserve/retained/output budgets and thresholds |
| Each model request | Preparation, sent, stream started, terminal received/error/cancel; request purpose, message/tool counts, estimated input components, latest reported input/output and usage-anchor identity; absent values stay unknown |
| Each context check | Check ID, estimated/anchored tokens, threshold, headroom, estimate method and decision (`not_needed`, `planned`, `no_valid_cut`, `forced_overflow`); never use cumulative billed tokens as current context occupancy |
| Compaction | Decision/start, history versus split-prefix request IDs, completion/failure/cancel/skipped, before/after tokens, entries retained/summarized, prior checkpoint ID, summary-input/output sizes, clipping/omission counters and actual reduction; one compaction can involve two model requests |
| Tool lifecycle | Requested, validation/policy disposition, actually started, progress milestone, committed/result persisted, finished/error/cancel/skipped; stable tool name, call ordinal, per-run attempted/executed/failed/rejected/skipped counts and counters before/after |
| Limit | First exhaustion event with `tool_call_limit`, `turn_limit`, `cost_limit` or `output_limit`, configured ceiling/current value, queued batch size and remaining work; separate per-call skip events linked to that first exhaustion |
| Paging/truncation | Layer (`search_preview`, `source_read`, `summary_serialization`, `summary_fit`, `provider_output`, `ui_preview`), unit, requested/returned/available counts where known, reason, remaining/capped/unknown state and retrievable next range |
| Retry/queue/cancel | Schedule/start/stop, reason, attempt, delay, queue disposition, cancellation requested/confirmed and whether a tool effect had committed |
| Persistence/artifact | Save requested/committed/failed/recovered with opaque entry/revision/receipt IDs; replay decision and no re-execution of an already committed effect |
| Run/settle | Exactly one run terminal and one eventual session settle; original limit trigger, final stop reason, wrap-up attempted/result, answer-present flag, usage/cost knowledge and totals, compaction counts, skipped calls and trace completeness |

Persist the first limit independently of final answer/stop status: an output
limit in wrap-up must not overwrite evidence of the original tool limit. Emit
one limit-exhaustion event per budget/run, plus one skip per blocked call; a
summary reports both counts. Record exact schema/policy failures separately
from tool execution failures so repeated malformed requests are diagnosable.
Do not encode these details as the generic `agent_limit` string alone.

Use the existing content-free `ReliabilityLog` for discoverable warning/failure
summaries and add structured numeric harness trace storage/export rather than
putting numbers into free-text error codes. The current global
`ReliabilityEventStore` keeps roughly 500–600 events; it is insufficient as the
only full trace for repeated multi-meeting runs. Bound diagnostics by explicit
byte/run retention, rotate completed runs as units, preserve their start/budget/
first-limit/terminal summaries and mark evicted ranges. Never silently present a
partial export as complete. A run exceeding the trace quota gets a visible
`trace_incomplete`/dropped-count marker with a reserved terminal summary; no
unbounded queue. Capture diagnostic write failures through a separate bounded
fallback without recursion; diagnostics are best-effort and cannot promise
successful disk writes under disk-full conditions. Canonical effect persistence
keeps its stronger stop-on-save-failure rule.

Mirror lifecycle, compaction, truncation and first-limit summaries at `.notice`
so they are visible at the normal console setting; use `.info`/`.debug` for
verbose intermediate checks. Provide on-device run inspection and explicit
JSONL diagnostic export through the current diagnostics/sharing use cases.
Export includes effective settings and trace-schema/app version, never content
or credentials, and never uploads automatically.

**Corrective work to drive from the trace:**

1. Resolve context capacity with explicit provenance and a validated per-provider,
   exact-model override when the endpoint does not publish it. Keep a visible
   conservative fallback; do not guess a larger GPT-family value. Scope values
   to the configured provider/endpoint identity and invalidate stale metadata
   when that configuration changes. Confirm whether the provider value is an
   input limit or a combined input/output window and reserve output once.
2. Separate cumulative session/run usage, latest request occupancy, estimated
   next-request occupancy, cache tokens and summary usage in both trace and UI.
   A displayed 33k total is insufficient to establish the compaction trigger.
   Compare estimator/usage-anchor values against the provider's usage without
   counting already-included cache/reasoning tokens twice.
3. Make every automatic compaction explain its threshold crossing or explicit
   overflow. A no-reduction/increased-size result cannot be reported as success
   and trigger repeated paid compaction against an unchanged context. Reuse a
   successful checkpoint, invalidate stale usage anchors, and stop/offer an
   explicit action if sufficient headroom cannot be obtained. Distinguish five
   compactions from five summary requests or five displayed step events.
4. Preserve passage text through retrievable subranges using stable passage
   identity plus Unicode-scalar text offset/next offset, or split a long passage
   into contiguous tool pages. Keep 500-scalar clipping for search/label
   previews only when the full source is actually readable. Every excluded
   suffix must have a usable continuation; paging to the next passage is not
   that continuation. Count headers, continuation metadata and an oversized
   single item when enforcing the output-byte budget.
5. Keep tool page size bounded but derive its effective budget from remaining
   request headroom, and expose the used bounds. Distinguish ordinary paging
   from irreversible clipping. Give the planner enough information to use
   summaries first for comparisons and selectively read full transcript ranges;
   it must not claim to have reviewed unread pages.
6. Reassess tool/turn budgets using source volume, requested task and pagination
   work, not source count alone. Log the chosen policy and count attempts versus
   execution separately; a hard cap on attempts still prevents infinite invalid
   calls. Offer bounded explicit continuation with progress/checkpoint reuse,
   rather than repeatedly restarting at source listing after exhaustion.
   Do not remove safety/cost ceilings or raise them blindly to hide the issue.
7. Make summary serialization losses explicit and recoverable: preserve source/
   artifact references and read coverage, summarize in bounded chunks when
   needed instead of silently dropping the oldest evidence, and ensure repeated
   compaction does not cause rereading the same pages solely because retrieval
   provenance was lost. Acknowledge missing material in final coverage state.

**Required regression evidence:** use synthetic non-sensitive fixtures for
thirteen meetings with summaries, long transcript passages and multi-page text.
Parameterize exact model identity with missing metadata, a validated large
window and the current 32,768 fallback. At fixed next-request occupancy of
33,000 tokens below a configured large-window threshold, automatic compaction
must not run without an explicit provider-overflow event; with fallback it must
log that fallback and its 16,384 threshold. Test 500/501-scalar passages,
Unicode boundaries, 8,000-scalar continuation, exact byte caps and summary-input
clipping. Reading all continuations must reconstruct the full authorized text.

Test a batch whose remaining calls cross the fifty-one-call budget: exactly
one exhaustion marker, an exact blocked-call count (including a ten-call blocked
tail), no blocked effects, recorded wrap-up and retained limit reason even if
the final answer is nonempty or wrap-up hits its own output limit. Test retry,
reopen, trace rotation and diagnostic-write failure, and assert that every
semantic start has a terminal or a recovery-interrupted marker. Logs must show
why every one of the reported compactions/limit occurrences happened. Measure
coverage, rereads, calls, compaction count, summary cost and elapsed time; do not
invent a universal acceptable compaction count for thirteen meetings of unknown
duration or use exact real-model answer text as a test oracle.

### Model API coverage and maintained fallback catalog

Audit date: 2026-11-08. This compares `ProviderModelsService`,
`ModelContextWindowStore` and `ModelContextWindows` with the providers' current
public API contracts. It is not an authenticated live test of the user's keys,
custom endpoint or cached device settings. Listing model IDs and retrieving
their context capacities are distinct capabilities.

| Provider / API shape | Published source for limits | What this branch does | Required NH00 change |
| --- | --- | --- | --- |
| Official OpenAI `/v1/models`, `/v1/models/{id}` | Model identity/lifecycle metadata; no documented context-window or max-output field | Tries compatible-server `context_window`/`context_length`; official OpenAI normally supplies neither, so uses the family table | Retain live model discovery; enrich missing capacities from the curated exact-ID OpenAI catalog |
| Anthropic `/v1/models`, `/v1/models/{id}` | `max_input_tokens`, `max_tokens` and `capabilities` in the current reference | `AnthropicModelListResponse.Model` decodes only `id` and drops all limits | Decode optional positive input/output limits and capabilities, persist them and resolve aliases via the detail endpoint when needed; verify response behavior with the app's API version before changing that header |
| Gemini `/v1beta/models`, `/v1beta/models/{id}` | `inputTokenLimit`, `outputTokenLimit`, supported generation methods | Reads input limit only; maps returned name to `baseModelId` where present | Preserve full requestable ID/version and aliases, read both limits, and avoid collapsing distinct versions into one capacity record |
| Groq `/openai/v1/models`, `/openai/v1/models/{id}` | `context_window`; detail response also documents `max_completion_tokens` | Reads list context limits for active models; does not retain max output | Retain both limits; retrieve selected-model details if the list omits a required field |
| OpenRouter `/api/v1/models` through the compatible adapter | `context_length`, `top_provider.context_length`, `top_provider.max_completion_tokens`; routing/request constraints can further restrict use | Reads top-level context only | Decode advertised limits and distinguish model-wide from routed-provider limits; do not assume the largest advertised window applies to every allowed route |
| Other OpenAI-compatible endpoints | No universal extra metadata contract beyond their implemented listing schema | Recognizes two optional context spellings | Add explicit parsers only for documented server fields/detail APIs; absent data uses a verified catalog mapping or an explicit unknown fallback, never a guess based on display name |
| Apple Foundation Models | Local framework, not `/models`; current Apple docs expose `SystemLanguageModel.contextSize` | Fixed on-device policy; no agent adapter | Query the property when available in the deployment SDK/OS, with a documented SDK-compatible fallback; do not make local chat support a prerequisite for the cloud catalog work |
| ElevenLabs | Speech model catalog, not conversational LLM context | Uses separate speech/fallback lists | Keep outside the agent context-window resolver; speech limits must not become chat-window values |

Primary references:
[OpenAI model-list schema](https://developers.openai.com/api/reference/resources/models/methods/list),
[Anthropic model-list schema](https://platform.claude.com/docs/en/api/models/list),
[Gemini Model schema](https://ai.google.dev/api/models),
[Groq list/retrieve schemas](https://console.groq.com/docs/api-reference),
[OpenRouter catalog schema](https://openrouter.ai/docs/api/api-reference/models/list-all-models-and-their-properties),
and [Apple contextSize](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/contextsize).

**Resolution contract and freshness:**

1. Keep model availability driven by the configured provider's listing. For each
   capacity field prefer a valid fresh provider response, then its unexpired
   cached value for that same endpoint/model, then a versioned curated record,
   then the explicit conservative unknown policy. Missing max output does not
   invalidate a known input/context limit or vice versa. A catalog value never
   replaces a smaller valid provider limit. User operational caps are separate
   from advertised capacity and cannot silently enlarge a known API ceiling.
2. Persist typed input-limit, combined-window and max-output fields separately,
   with their semantics/source field, source URL or provider identity, retrieval
   date, expiry, catalog revision, exact model ID and verified alias/snapshot
   mapping. Calculate request budgets according to each adapter's semantics;
   do not confuse a pricing threshold, rate limit or max output with context
   capacity, or subtract the full maximum output twice.
3. Key cached metadata by provider configuration/normalized endpoint identity,
   API shape/version and exact requestable model ID. Invalidate after endpoint
   changes; respect account/workspace changes where limits differ. Preserve the
   identity of an alias and the concrete model reported in a response. Do not
   blindly strip the final slash component and apply another provider's limits.
   Migrate or invalidate the current `providerID|lowercasedModel` cache because
   it has neither endpoint provenance nor freshness. A legacy value must not
   permanently mask a corrected catalog record.
4. Handle all listing pages: Anthropic `has_more`/`last_id` with `after_id`,
   Gemini `nextPageToken`/`pageToken`, and pagination when a compatible catalog
   documents it. The current generic fetch reads one response only. Fetch detail
   metadata lazily for the selected model when needed, with bounded concurrency,
   request deduplication, timeout and existing URL/auth policies. Do not issue
   detail calls for every model on every chat turn or for official OpenAI fields
   its detail endpoint does not expose.
5. Refresh when the user refreshes/selects a provider and when metadata expires,
   while retaining a usable offline snapshot. Define TTL explicitly in policy,
   retain last-known metadata with a stale marker on refresh failure and use a
   logged conservative policy when required. Validate positive integral bounded
   token counts; optional null/zero/malformed fields must not break model-ID
   discovery. Record chosen value, source, freshness and any invalid field.

**Verified catalog seeds for the implementation.** These are published API-model
capacities, not the app's selected output budget. Keep exact IDs and explicit
documented snapshots/aliases; every grouped ID below is a separate catalog
record. Values are intended to replace broad family guesses when no applicable
provider metadata exists. The table is a verified starting set, not a claim to
cover every model an arbitrary compatible endpoint can invent.

| Provider | Exact model ID(s) | Context / input limit (tokens) | Max output (tokens) | Official source |
| --- | --- | --- | --- | --- |
| OpenAI | `gpt-6.1-terra` | 1,050,000 combined window | 128,000 | [Terra](https://developers.openai.com/api/docs/models/gpt-6.1-terra) |
| OpenAI | `gpt-6.1-sol` | 1,050,000 combined window | 128,000 | [Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol) |
| OpenAI | `gpt-6-astra` | 1,050,000 combined window | 128,000 | [Astra](https://developers.openai.com/api/docs/models/gpt-6-astra) |
| OpenAI | `gpt-6-luna` | 1,050,000 combined window | 128,000 | [Luna](https://developers.openai.com/api/docs/models/gpt-6-luna) |
| OpenAI | `gpt-5.4` | 1,050,000 combined window | 128,000 | [GPT-5.4](https://developers.openai.com/api/docs/models/gpt-5.4) |
| OpenAI | `gpt-5.4-mini` | 400,000 combined window | 128,000 | [GPT-5.4 Mini](https://developers.openai.com/api/docs/models/gpt-5.4-mini) |
| OpenAI | `gpt-5.2` | 400,000 combined window | 128,000 | [GPT-5.2](https://developers.openai.com/api/docs/models/gpt-5.2) |
| OpenAI | `gpt-5` | 400,000 combined window | 128,000 | [GPT-5](https://developers.openai.com/api/docs/models/gpt-5) |
| OpenAI | `gpt-4.1`, `gpt-4.1-mini`, `gpt-4.1-nano` | 1,047,576 combined window | 32,768 | [GPT-4.1](https://developers.openai.com/api/docs/models/gpt-4.1), [Mini](https://developers.openai.com/api/docs/models/gpt-4.1-mini), [Nano](https://developers.openai.com/api/docs/models/gpt-4.1-nano) |
| Anthropic | `claude-fable-5-1`, `claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5` | Published as 1M context; preserve API-reported integer when available | Published as 128K | [Current model comparison](https://platform.claude.com/docs/en/models/overview) |
| Google | `gemini-2.5-pro`, `gemini-2.5-flash`, `gemini-2.5-flash-lite` | 1,048,576 input limit | 65,536 | [Pro](https://ai.google.dev/gemini-api/docs/models/gemini-2.5-pro), [Flash](https://ai.google.dev/gemini-api/docs/models/gemini-2.5-flash), [Flash-Lite](https://ai.google.dev/gemini-api/docs/models/gemini-2.5-flash-lite) |
| Google | `gemini-3.6-flash` | 1,048,576 input limit | 65,536 | [Gemini 3.6 Flash](https://ai.google.dev/gemini-api/docs/models/gemini-3.6-flash) |
| Groq | `llama-3.3-70b-versatile` | 131,072 context | 32,768 | [Groq model card](https://console.groq.com/docs/model/llama-3.3-70b-versatile) |

Resolve rounded vendor labels such as 1M/128K to exact integers using a verified
API response or explicit provider definition before encoding numeric records;
do not silently choose decimal versus binary units. Preserve older supported
entries with individual evidence, lifecycle status and review dates. Replace
blanket `gpt-5 → 272_000`, `claude- → 200_000` and `gemini- → 1_000_000`
assumptions with exact records and narrowly documented aliases. In particular,
GPT-5.4 Mini must not inherit GPT-5.4's 1.05M window. A model absent from the
catalog remains visible if its endpoint lists it, but its capacity is explicitly
unknown until API metadata or an intentional validated configuration supplies it.

Store the catalog as a bundled versioned resource or typed pure-Foundation
data, with per-record official reference and `verifiedAt`. Update it in ordinary
app releases, checking newly listed IDs and changed/deprecated models as a
release-maintenance item. No backend, startup scraping of documentation or new
external catalog dependency is required. The model picker/details and trace
must show API/catalog/fallback origin and freshness. Keep existing summary/wiki
single-pass policies distinct from the harness window while sharing the same
underlying capacity facts.

**Visible provenance in the conversation trace is mandatory.** Every capacity
resolution emits a structured `context_window_resolved` event before the first
context check/request that uses it. Include `contextWindowTokens`,
`contextLimitKind`, `source`, `cacheStatus`, `resolvedAt`, `fetchedAt` when
applicable, `catalogVersion`/`catalogVerifiedAt` for table data, a stable
`resolutionID` and an allowlisted `reasonCode`. Provider/model and endpoint
configuration identity remain correlated without exposing a raw URL. Reasons
distinguish API field present/missing/invalid, metadata fetch failed/expired,
catalog match/miss and final unknown fallback.

Render that event as an inspectable step in the conversation's existing trace,
not just the model picker or console. Show the token count and one of the
localized labels “API”, “Tabela local” or “Fallback fixo”. For an API-origin
cached value show “API (cache)” plus retrieval date/freshness; cache is a delivery
status and must not disguise its original source as a fixed table. If native
framework data is used, label it separately rather than calling it a remote API.
An explicit operational cap shows both advertised capacity/origin and the lower
effective budget; it does not replace provenance with an ambiguous “override”.

Persist the resolution snapshot used by each request and link context checks,
compactions, retries and wrap-up through `resolutionID`. Reopening an old chat
must show the value/source actually used at that time, not recompute it from
today's catalog. If metadata or the selected model changes during a session,
append a new resolution event and bind subsequent requests to it. Diagnostic
JSONL export includes the same provenance. Legacy runs without this information
show “Origem não registrada”; never infer a historical API/table source from a
matching number. New labels follow the seven-locale accessibility conventions.

Acceptance requires API, API-cache, fixed-table and fixed-fallback examples to
show their correct origins in console, persisted trace, reopened conversation
and export. Test equal token values from different sources, API absence versus
invalid data, endpoint/model changes, catalog updates after a run and incomplete
legacy traces. The recorded source must explain the capacity used to decide a
compaction, even when no provider request ultimately starts.

Acceptance fixtures must cover every API row, all listing pages, optional
fields, smaller API values winning over the table, missing input/output
independently, stale cache and endpoint changes, distinct Gemini versions,
OpenRouter routing limits, unknown custom aliases, and matching exact IDs before
allowed aliases. Add the current public OpenAI `/models` shape without limits
and Anthropic's shape with limits. Replace the existing test that expects
GPT-5.4 to resolve to 272,000 with verified full-window semantics; add
GPT-6.1 Terra → 1,050,000, GPT-5.4 Mini → 400,000, and a separate explicitly
unknown model → fallback test. Capture only sanitized API fixtures; authenticated
provider smoke tests remain opt-in and cannot be claimed from this audit.

### Delivery sequence and reviewable increments

Each increment includes its relevant fixtures/tests and leaves the app buildable.
Use `feature/native-harness` as the integration branch and review implementation
increments through pull requests against it before the broader session migration.

The first NH00 implementation increment covers exact-model capacity records,
endpoint-scoped metadata with freshness, Anthropic/Gemini limit decoding and
pagination, persisted visible window provenance, content-free run diagnostics
and export, first-limit versus skipped-call accounting, and lossless transcript
continuation. Enduring contracts are in `CLAUDE.md`, "Agent harness". The first
increment passed iOS CI and remains under draft review. The next NH00 increment
adds selected-model detail refresh, independent field freshness,
canonical-alias caching, bounded/coalesced metadata requests, preview-versus-continuation
telemetry and byte-bounded text reads. Workload planning and progress-gated extensions
replace the source-count-only default; every grant/denial and hard ceiling is logged.
An integration regression reads thirteen synthetic transcripts and summaries (about 33k
estimated tokens), executes 68 valid calls including a document mutation, and expects no
premature compaction or canonical clipping on Terra.
The supplied device log with 33 sources identifies a separate output failure: every
request used an app-imposed 4,096-token output budget, then stopped at `outputLimit`
with 43/192 tool calls and approximately 54,879 context tokens against a correctly
resolved 1,050,000-token window. No compaction occurred; 147,800 input tokens were a
cumulative run total. The log does not identify how much output was reasoning versus
text/tool arguments. A follow-up removes the host's 4k cap, adds bounded capacity-aware
output budgeting using pi’s input/headroom calculation (including summaries) and bounded
compact-and-retry recovery for early, empty length stops inside the harness, and records per-request
usage, reasoning counts when supplied, visibility, discarded calls and recovery decisions.
Regression coverage simulates 33 selected sources and 43 successful reads before an
output-limited turn, then checks a single committed artifact and persisted trace after
one forced compaction/retry. Output starts from the actual model capacity; it is reduced
only by current input and pi’s safety margin, without the previous 32k/64k/quarter-window
ceilings. The compaction trigger remains independent of desired maximum output. NH00 still needs the fixed build retested against that corpus on a physical
device, authenticated provider smoke tests and continued catalog review; synthetic
regressions are not evidence that the fixed build has passed the user's data/device.
NH01 now freezes the NH00 compatibility baseline in package/app fixtures and defines
[native contract v1](contracts/native-harness-v1.md). Its machine-checked catalog maps
C01–C27/A01–A70 separately from Kurn characterization cases; legacy evidence does not
claim target completion. The fixtures cover opaque replay data and four provider
requests, source parts/empty overrides, legacy session/history restoration, and
save/update of conversation artifacts as library documents. CI checks versions,
fixture hashes and evidence links. The canonical v1 format is not activated and no
store migration runs in that increment. NH02 implements the local message/stream profile described below; NH03 implements the store/migration boundary described below; NH04 implements the native tool pipeline and durable local artifact boundary described below; NH05 has an initial package ownership/barrier increment and a first host-activation
increment (host-owned conversations, owned run handles, settled cancellation); NH06–NH10 have
not started. The next implementation increment is NH05 canonical writer activation and recovery. This is not full harness parity. Physical-device/provider qualification for NH00 remains open.

The first NH02 increment adds checked native user/assistant blocks, exact Unix-ms
codecs, an ordered bounded reducer, authoritative final reconciliation and all four
wire adapters. It retains interrupted tool calls with synthetic errors, fences late
callbacks and emits terminal preparation/transport failures. Request replay is a copy,
with compatible signature handling and logged omissions/ID/argument normalization.
The NH02 completion adds checked native tool-result messages, optional unknown historical
timestamps and API/model values, owner-assigned request/logical invocation identities,
canonical error/abort snapshots (including preparation before the first block), and
paired synthetic results for interrupted calls. Repeated provider call IDs are relinked
by logical invocation on disposable wire copies. Failed/aborted/deferred messages and
their paired results are excluded from replay with numeric omission diagnostics.
Namespaced calls retain their wire identity but cannot dispatch to unqualified bundled
tools. Supplied private protocol facts remain in native metadata, outside logs/replay.
Session/run/request/invocation correlation is persisted in the existing diagnostic steps;
new chats reserve their eventual ChatSession UUID without creating empty saved rows.
At the NH02 boundary the app still saved V5 presentation turns; indexed storage and
migration followed in NH03, with local effect receipts in NH04. Canonical model-history
restoration remains NH05/NH06. Session barriers,
queues and model-level capability qualification remain in their planned increments.
Evidence and the exact activation boundary are in `docs/contracts/native-harness-v1.md`.

NH03 adds a frozen V5 graph and additive SwiftData V6 (1.5.0). Indexed checked entries,
immutable artifact revisions and run/queue/draft/effect metadata containers live in the
protected app store. Conversion runs lazily per session, atomically marks completion,
retains original turns/scope/artifact bytes and preserves legacy IDs, usage, costs and
unknowns. Native entries are authoritative for checked loads; presentation caches remain
rebuildable. The compatibility writer appends changed suffixes as branches and maintains
an independent selected leaf. Failed saves restore only their staged group, allowing a
clean retry. Backups use the centralized V6 graph; salvage includes chats, retained
messages/revisions, metadata and saved documents; erasure covers cascades and orphan rows.
This does not activate queue consumption, effect reconciliation or an awaitable session
owner. Those remain NH04/NH05; native tool-history replay and durable compaction remain NH06.


NH04 registers bundled tools through a checked, bounded JSON Schema subset; rejects duplicate
names and unsupported schemas before model IO; validates invocations before and after the
typed policy seam; fences terminal progress and logs validation, denial, error and abort.
Model content, UI details and structured output remain separate. Independent reads use at
most four workers; a sequential tool serializes its whole batch, with result messages in
assistant call order and progress/completion events in execution order. Source IDs, parts,
content revisions and search candidates are captured as immutable values before metadata
refresh/model IO; deletion fails instead of returning an empty success. Document edits are
planned as domain values, then the app commits the immutable revision, presentation state,
provenance and invocation receipt in one SwiftData save. A shared local mutation lease spans commit and
workspace publication across executors; stale UI saves preserve committed artifacts and provenance. Matching committed invocations replay the saved result without
reapplying an edit; changed arguments/request identity conflict. Failed saves publish neither
revision nor receipt, and cancellation after commit preserves the known success. Opening a
chat does not resume work. Session-wide ownership, durable model-message/result barriers
and automatic recovery orchestration remain NH05; canonical model replay remains NH06.


NH03 review follow-up (#339): component-isolated salvage, first-write history dates,
ancestor presentation lookup for checkpoint leaves and parent-only SwiftData relationship
insertion are implemented in the review correction increment. Targeted regressions cover
partial corruption, index validation, rollback, migration dates and sibling-branch state.
iOS CI qualification is pending; this prerequisite does not activate NH05 ownership.


The initial NH05 package increment adds awaited canonical-message and usage sinks to every
runtime append path, plus `AgentRunHandle` for producer cancellation/completion independently
of its bounded, disposable observation stream. `AgentSession` reserves ownership before
store awaits, serializes accepted runs, appends native entries and start/end/usage metadata,
and holds cancellation through producer termination and terminal persistence. Failed durable
writes block new prompts; retrying a terminal save does not repeat model/tool work, including
lost commit acknowledgements. Caller-supplied authorized history remains mandatory.

The first host-activation increment retains conversations in `ChatConversationHost`
(composition-owned, one per scope, bounded, never evicting a running one) instead of the view,
so a reply survives dismissal. The chat runs on an owned `AgentRunHandle` with complete
observation and awaits producer termination on every exit; cancellation keeps the
conversation busy in `cancelling` until settled and refuses new prompts until then. Reset/reload
fence the old run; deleted meetings/sessions receive no further writes; "Delete all data"
settles and drops every conversation first. A running reply holds a finite background window;
on expiry it is cancelled and settles as a retryable interruption. The question is saved before
any request, and each run writes a durable `ChatRunRecord` (`.running` → `.ended`); a launch sweep
marks records a dead process left running as interrupted, so the question reopens as retryable,
with a note above Retry saying the app closed before the reply finished. Each run also commits
its native messages and per-request usage through the harness's awaited sinks, before dependent
work, between start (frozen scope authorization and model) and end entries, on a branch of the saved session anchored at the accepted question; the selected leaf never
moves, so the presentation path is unchanged, and a failed commit fails the run with the question
retryable.

**Still open in NH05:** make `AgentSession` the app's run owner (the host now writes native
message/usage entries in its shape, on per-run branches, including scope authorization); canonical UI/history
restoration from those branches; full phase/identity projection (run/turn/
call IDs, compacting/retry/waiting phases); durable command idempotency; resuming an
interrupted run on return to the foreground; persistence-failure recovery UI. The package owner
requires one retained actor per session; it does not enforce uniqueness across independently
created actors. Failed message/usage commits require explicit host recovery, rather than
retrying inference on an incomplete log. The chat now uses `start(observation: .complete)`; coalesced
snapshots with back-pressure instead of an unbounded presentation stream remain open. NH06 projection and compaction, and NH08 queues, remain
separate. Package tests do not qualify the inactive SwiftData/UI owner integration.


The architecture prerequisite separates domain from runtime:

- `AgentHarness` owns model capacity resolution/catalog, script-aware token estimation,
  overflow classification/contracts, the execution/compaction loop and generic
  `AgentRunTrace`/`AgentRunStep`. Compaction prompts are injectable with domain-neutral
  defaults; the meeting-specific profile stays in the app. It depends on Foundation,
  with no Kurn imports.
- `KurnCore/Chat` owns source scope, source reader/domain values and document workspace
  rules. Its package has no dependency on AgentHarness.
- `Kurn/Application/Agent` composes the harness and binds source/document tools, host
  diagnostics and presentation. HTTP/SwiftData remain app adapters; the generation-only
  `ContextBudget` lives in `Application/Generation` and does not govern agent compaction.
- Existing serialized step field names and enum values remain compatible; moving the
  types/modules requires no SwiftData schema migration. Source selection, artifact
  saving and trace provenance retain their current behavior.
- Package and integration tests follow the new owners. Static policy rejects cross-imports.
  This prerequisite changes ownership, not the remaining NH01–NH10 feature scope.

| Increment | Priority / dependency | Concrete work | Exit condition |
| --- | --- | --- | --- |
| NH00 — Trace and diagnose current budgets | P0, first | Add complete semantic diagnostics, audit all configured model-list/detail schemas, implement missing limit decoding and the maintained exact-model fallback catalog, reproduce the thirteen-meeting scenario and fix verified paging/budget defects | Every selected model resolves to API/catalog/explicit-unknown metadata; every compaction, limit and loss of source text has an explanation; full source text is retrievable; fixes have regression evidence |
| NH01 — Characterize and define contracts | P0, NH00 | Capture current source/artifact/history behavior in fixtures; define versioned contracts and acceptance map | Existing behavior is explicit, including intentional adaptations and unsupported capabilities |
| NH02 — Messages, streams and wire adapters | P0, NH01 | Extend types and all four wire formats together; block reducer, final-message reconciliation, errors and replay normalization | Fragmented/interleaved streams converge to authoritative final messages; no partial tool execution |
| NH03 — Store and migration | P0, NH02 | Add entries, leaf, run/queue/draft metadata, artifact revisions and effect receipts; V5→V6 migration and recovery | Existing chats/documents/scope survive real on-disk upgrade; migration is idempotent and performs no model/tool calls |
| NH04 — Native tool pipeline and durable artifacts | P0, NH03 | Central validation/policy/progress, authorization snapshot, document commit seam and per-artifact serialization | Known committed mutations survive crash/retry exactly once per invocation identity; failures cannot report success |
| NH05 — Session owner and lifecycle | P0, NH02–NH04 | Extract loop ownership from view model; canonical persistence barriers, terminal states, limits, cancellation and settle | One loop per session; cancellation settles after work terminates; reopen uses canonical history |
| NH06 — Projection and persistent compaction | P0, NH05 | Active-path projection, system sections, source/context boundaries, context edits, durable checkpoints and overflow recovery | Reopen reuses summaries; branch/scope filtering is correct; failed/cancelled compaction creates no fake summary |
| NH07 — Provider capabilities, accounting and retry | P0, NH05–NH06 | Per-request credential/model resolution, supported thinking, normalized usage/cost, bounded session retries and cost estimator wiring | No stacked retries, replayed document mutation or double-counted usage; unknown cost remains unknown |
| NH08 — Queues and execution UI | P1, NH05–NH07 | Steering/follow-up, queue editing/restoration, phase/retry/context UI and draft persistence | Queued input enters at documented boundaries; UI stays busy until settled; source picker and artifact cards keep working |
| NH09 — Tree and artifact revisions | P1, NH03–NH08 | Navigate, fork, clone, rename, labels, branch summary and revision-aware save actions | Branches preserve siblings and costs; context/artifact state follows active ancestors; saved library documents stay independent |
| NH10 — Interchange and release qualification | P1, NH09 | Versioned native export/import, supported JSONL v3 subset, safe HTML/Markdown, migration/stress/device qualification and documentation | Every supported criterion below has evidence; export limits and pi divergences are explicit |

NH00–NH07 form the reliability milestone. NH08–NH10 complete the proposed local
profile. Do not describe the reliability milestone as full specification parity.
Estimate implementation effort after NH01 exposes fixture/migration complexity;
the highest-risk work is NH03–NH06, not adding more tools or provider brands.

**NH02 details.** Separate `AgentMessage`, `SessionEntry` and presentation state.
Use text/thinking/tool-call blocks in order, image blocks where the adapter
supports them, opaque signatures/unknown metadata, provider/model identity,
timestamps and normalized stop reasons. Preserve exact millisecond units on pi
interchange. Final message replaces accumulated deltas; cumulative usage replaces
partial usage. Retain raw invalid tool arguments and mark them invalid. An output
limit blocks every call from that response and records synthetic error results
instead of dropping the calls from audit history. Error/abort gets a terminal
protocol event even when preparation failed before streaming started. Deferred
responses are represented as unsupported/recoverable metadata unless an adapter
explicitly implements them; do not invent background polling.

**NH03 details.** Prefer indexed `@Model` entries over repeatedly rewriting one
ever-growing transcript blob: session/entry/parent IDs, append ordinal, type,
versioned checksummed payload and timestamp. Add run/effect records and artifact
revision storage as necessary. Persist leaf separately from append position and
validate append groups before committing. Extend `KurnModelGraph`, backup,
salvage, erasure and test-container graphs together. Freeze V5 models before
changing live classes, introduce V6 and its migration stage; do not redefine V5.
Use lightweight schema migration for additive fields/entities where verified,
then a resumable per-session content migration with a completion marker.

Convert legacy turns into a linear path with stable existing IDs, source scope
and artifact snapshots. Preserve usage/cost, origins and unknowns; do not invent
historical tool results, intermediate artifact versions or model identities.
Retain original `turnsData` for recovery until conversion is committed. Corrupt
authoritative data is surfaced, never converted to a successful empty chat.
After conversion, entries are canonical; any turns snapshot is rebuildable and
must not become a second independently writable source of truth.

**NH04 details.** Register only bundled tools, with unique names and declared
schemas. Define an intentionally strict supported JSON Schema subset covering
their schemas, validate schemas at registration, reject unsupported schema
features and validate every invocation before execution. Keep semantic checks
for scope, IDs, sizes and paging in the tool. Exact pi coercion/full dynamic
JSON Schema is not promised. Revalidate any policy-transformed arguments.
Emit start/progress/end for validation failure, denial, success, error and abort;
ignore late progress. Separate model `content`, UI `details` and programmatic
`structuredContent`; structured data is not implicitly sent to the model.
Parallelize independent read tools with a bounded task group; persist results
in call order, show progress in completion order. A sequential tool makes its
whole batch sequential. Initially mark document mutations sequential and keep
read-modify-write serialized per artifact through the durable commit. Retain
Unicode-safe pagination and truthful truncation rather than adopting desktop
file-tool offsets/limits for Kurn's existing tools.

**NH05 details.** Guard concurrent prompt/navigation/model changes, append user
input before the request, persist final assistant before tool effects and
persist results before the next request. Persist final error/abort metadata and
known usage instead of deleting evidence; the UI may collapse interrupted
attempts and retain a retryable question. Distinguish model output limits from
run turn/tool/cost limits and retain the current bounded, tool-less wrap-up.
Expose idle/preparing/streaming/executingTools/waitingForUser/compacting/
retryWaiting/cancelling/interrupted with run/turn/call IDs. `agent_end` closes a
run; `agent_settled` follows all recovery and required durable writes.
Unbuffered visual listeners must not block canonical progress: persistence and
policy barriers are awaited; UI receives coalesced snapshots. Bound queued
events and retained partial output, propagate backpressure through an awaitable
transport bridge or terminate explicitly on overflow; never silently drop a
canonical event. Abort clears/restores pending UI input before cancellation,
cancels provider/tools/compaction/backoff, awaits confirmation and preserves
committed effects. Late events from an old generation cannot alter a new session.

**NH06 details.** Keep distinct raw entries, active branch, model projection and
provider request. Reconstruct ordered system sections/tool declarations and
apply context edits only to the projection. Use Kurn's meeting-assistant
identity and source trust rules, not pi's coding-assistant preamble. Stable
system prefixes support provider caches; artifact indexes and scope revisions
are explicit sections updated on mutation, not on every token.
Reuse the existing token estimator and split-turn planning, but persist
`firstKeptEntryId`, structured summary, effective system/tool checkpoint,
source segment, captured model/settings, usage and tokens-before. Preserve
tool/result groups and previous summaries across repeated compactions. Validate
budgets against the effective model; do not copy 16k/20k defaults blindly to a
small local model. Provide manual compact and optional branch summary.
For overflow, record the failed attempt, context edit and successful checkpoint
before one bounded retry. Replace the current forced omission-note fallback
with an explicit context-reduction failure/action: an omission notice must not
masquerade as a successful summary. The next request cannot use unsaved context.

**NH07 details.** Model identity is provider plus ID, with a cached capability
snapshot for context/output limits, modalities, tools, thinking and usage/cache.
Existing generic model listings are inputs, not proof of every capability.
Changing models transforms a request copy, preserving saved signatures; remap
call IDs/results together, resolve orphan results synthetically and never
re-execute tools to repair a transcript. Keep official OpenAI `store: false`
and custom-endpoint routing. Resolve credentials per request, including
compaction, and redact diagnostic payloads. OAuth remains separate work.

Add input/output/cache-read/cache-write/reasoning counters and provider-reported
versus estimated cost; reasoning is included in output and must not be summed
again. Deduplicate usage by request identity, including failed attempts with
reported usage, compactions and abandoned branches. Unknown billing stays
unknown; missing usage is not zero. A configured cost ceiling needs a price
source or an explicit token/request fallback, and remains an estimate rather
than a hard provider billing cap. Pass the estimator from the app into the
harness: a `maxCostUSD` value with no estimator cannot enforce a real guard.
Keep cache warming off for this profile to avoid unsolicited paid requests.

Use one retry owner for harness calls: the session, with transport retries
disabled for those calls. Classify auth/configuration, quota, context,
transient HTTP/network, invalid tool arguments and user cancellation separately.
Retry only eligible model requests with bounded attempts/deadline, cancellable
backoff and `Retry-After`; retain the current no-transparent-retry-after-stream
policy. A partial stream can offer an explicit new attempt with its own ID,
never concatenate two generations. Persist attempt state; no automatic
relaunch replay of an interrupted mutation or potentially billed request.

**NH08 details.** Keep FIFO steering and follow-up queues with one/all modes.
Steering enters after the current response and its complete tool batch;
follow-up waits until tools and steering are exhausted. Queue updates contain
the complete lists and stable IDs. Persist accepted queued input before
acknowledging; expose accepted/queued separately from executed. Show “Orientar”
and “Depois desta tarefa”, edit/remove/restore actions, retry delay and confirmed
Stop status. Keep source editing disabled while a task is active as today;
queued messages carry the same binding. Model changes apply only at defined
request boundaries. Preserve scroll when reading older messages, text selection,
safe Markdown, unknown-tool fallback, Dynamic Type, VoiceOver and iPad layouts.
New UI strings ship in all seven locales; use existing glass/navigation patterns.

**NH09 details.** Navigate only while settled, with atomic leaf updates and no
partial switch on conflict. Fork creates a new session from before the selected
user message and restores its draft; clone includes the current position.
Labels and rename are metadata. Branch summaries require an explicit model
operation and preserve source restrictions. Session totals include every branch;
current-context usage describes only the active projection. Artifact state
follows its branch revision map, not the newest append anywhere in the session.

**NH10 details.** Export a native versioned session bundle containing entries,
branch/leaf state, scopes, context boundaries, artifact revisions/provenance and
known usage, with no credentials or active operations. JSONL v3 can represent
the supported pi message/system/compaction/usage entries; Kurn-specific data uses
namespaced custom entries. Preserve unknown records/fields opaquely and render
unsupported tools read-only. Imported shell/plugin calls never become executable.
Reject invalid IDs/cycles/versions, oversized/deep payloads and conflicting
session identities rather than overwriting silently. A new-copy import remaps
the entire graph consistently; a restore preserves identity only when safe.
Validate artifact blobs/references and round-trip unknown metadata. Preserve an
imported cwd as inert origin metadata; the actual workspace is Kurn's library.
Support LF framing and U+2028/U+2029 correctly. Do not promise byte-for-byte pi
interchange until fixtures demonstrate it; native round-trip is the release
requirement. Use system share sheets and safe HTML without script execution,
remote embeds or hosted links. Export active-path reading formats separately
from full-session archival exports, making included historical sources clear.

### Local suspension, recovery and resource limits

Run interactive agent work in foreground. At background transition, persist
draft/selection/queues and finalized boundaries, request cooperative stop and
use only the finite OS-granted completion window for an in-flight local commit.
Do not introduce an always-running background mode or abuse audio capture to
keep the agent alive. If the process is suspended/killed, launch recovery reads
run/effect records, restores committed results and marks unfinished work
interrupted. Resuming requires explicit user action; restore queues for review
instead of launching paid requests at startup. A temporary app network failure
is an execution/retry state, not an imaginary connection to a harness server.

Keep existing document/source size limits and add configured limits for imported
session size, retained stream buffers, parallel reads and in-memory history.
Page entry/revision reads instead of loading every branch or document body into
the prompt. Use the existing resource scheduler where local inference or heavy
search requires it, and test locked-store, low-storage and memory-pressure errors.
Do not add content to public logs or automatic diagnostic uploads. Measure local
request latency, memory, cancellation latency, compaction reuse and source/tool
volume with fixed operation IDs and content-free codes before tuning constants.

### Acceptance and specification traceability

Do not label an unimplemented or excluded case as passed. Add deterministic
scripted models, controlled tools and fault-injecting stores; compare state,
event order, requests and effect counts, never exact real-model prose.

| Specification cases | Treatment in this local profile | Evidence required |
| --- | --- | --- |
| A01–A10 | Required | Basic/tool runs, exclusivity, replayed system/loadout, fragmented blocks, terminal-before-start errors, awaited durable barriers |
| A11–A17 | Required | Parallel completion versus transcript ordering, sequential batches, steering/follow-up priorities/modes and continue validation |
| A18 | Adapted | Test internal end/continue scheduling and no duplicate request; no external hook API |
| A19–A22 | Required with documented strict-schema adaptation | Unknown/schema/argument/output-limit failures cause no effect; policy denial and structured error data persist |
| A23–A24 | Conditional | Test content/structured-result replacement or unanimous termination only if those internal policy features are exposed; public extension hooks are excluded |
| A25 | Required | Late progress is ignored after terminal completion |
| A26–A33 | Desktop tool contracts excluded | Substitute Kurn tests for Unicode paging/truncation, scoped search and serialized document mutation; do not claim shell/file-tool parity |
| A34–A44 | Required for supported models | Active-path projection, fork/clone, context edits, repeated compaction/failure, overflow/retry/cancel, nonduplicated usage and small-model budgets; virtual routing excluded |
| A45–A48 | Required | Settled UI, restored queue, stable scroll and unknown-tool fallback |
| A49 | RPC dialogs excluded | Native policy dialogs, if used, still require explicit response or cancellation; never approve on timeout |
| A50–A52 | Required | Busy navigation conflicts, accessibility and inert hostile Markdown/HTML |
| A53–A62 | External resource/plugin/MCP/codemode contracts excluded | Bundled-tool policy and source authorization have separate native tests; no external resource manager is needed |
| A63–A64 | RPC transport excluded | Native command dispositions, stable command IDs and subscribe-before-command behavior receive equivalent local tests |
| A65 | Required at JSONL import boundary | LF framing, partial chunks and U+2028/U+2029 fixtures |
| A66–A67 | Gateway/replay transport excluded | Test local relaunch from consistent store snapshot and partial-UI reset without duplicate prompts/effects |
| A68 | Required | Background/foreground, draft/queue restoration and interrupted-run status on real device |
| A69 | Required for native format; qualified for JSONL subset | Round-trip IDs/tree/metadata/cost/artifacts; record unsupported pi cases explicitly |
| A70 | Remote effect excluded; local analogue required | Crash at each artifact receipt/revision/result boundary recovers known effects without re-execution |

Additional Kurn release scenarios:

- All selection modes, per-meeting locks, empty overrides, wiki disabled,
  deleted/retagged sources and legacy scope payloads retain their behavior.
  Strict-current-sources mode cannot leak earlier excerpts through tool replay,
  assistant memory, compaction or artifact metadata; default memory behavior is
  visible and tested rather than silently redefined.
- Create/update/append/read → cancel/fail/limit → reopen → retry → save/update
  produces one intended artifact/document, retains original provenance and
  does not lose a committed revision. Cover save failure, divergent branches,
  deleting/re-saving a library document and deleting the originating meeting.
- A disk-full/store-save failure before assistant persistence prevents tool
  execution; after an artifact commit it preserves a recoverable receipt.
  Recovery interruption at each migration/commit step neither loses content
  nor creates a second mutation.
- Cross-provider replay drops incompatible signatures only in the request copy,
  preserves paired call IDs and never repeats source/document effects.
- Repeated questions after a successful compaction reuse the persisted summary
  instead of summarizing the same old history again. Large archives open with
  paged reads and do not load unrelated branches into context.

### Validation, rollout and completion

Keep package-only tests in `Packages/AgentHarness/Tests` and
`Packages/KurnCore/Tests`; app/service tests in `KurnTests`, on-disk migration/
store recovery in the appropriate SwiftData test boundary, and user flows in
`KurnUITests`. Extend existing harness, scope, artifact-store, history, retry,
wire and document-export suites instead of creating a competing implementation.

Required checks per implementation PR: both package `swift test` suites,
`Tools/check_static_policy.py`, SwiftLint/localization, simulator unit/store
tests, applicable UI accessibility/flow checks and the repository coverage gate
(80% changed in-scope logic; do not lower floors or add exclusions for logic).
Use macOS/Xcode 26 CI for iOS compile/test evidence. Run concurrency/Thread
Sanitizer checks on the new session/store/tool boundaries, and qualify new UI
flows with the existing flake-measurement workflow. Physical-device qualification
must cover Data Protection, foreground/background termination, low storage,
memory pressure and cancellation. No paid provider call is needed in unit tests;
manual direct-provider smoke tests are opt-in and do not assert prose equality.

Integrate dormant store/contracts first, migrate one session only after its
validation succeeds, then switch that session's coordinator to canonical entries.
Do not run old and new loops for the same prompt or silently fall back to a
second provider call after a failure. Preserve original legacy data until the
migration is durably validated; disable new execution on a migrated session if
recovery cannot establish consistency. An older binary is not a safe rollback
for a new SwiftData schema; use verified backup/recovery and forward fixes.

The reliability milestone is complete when existing source/artifact behavior
passes unchanged, durable state survives faults, and NH00–NH07 checks pass,
including the mandatory diagnostic/coverage regressions above.
The local profile is complete only after NH08–NH10 and all applicable acceptance
cases pass, unsupported capabilities are documented, and the physical-device
checks are recorded. Move enduring architecture into `CLAUDE.md`/`README.md` and
remove completed work from this section as required by repository convention.

Planning verification on 2026-11-08: the static-policy check passed on the
baseline. Both package test commands were attempted but could not start because
this environment has no `swift` executable; iOS compilation/tests were not run.
No runtime implementation or test-pass claim is part of this document change.

## Product capabilities

### Adopt

Ordered by payoff, not by effort. None of them creates tension with the five
invariants.

#### F2 · User-maintained meeting glossary

|                |                                                                                                   |
| -------------- | ------------------------------------------------------------------------------------------------- |
| **Couples to** | New `@Model` in the store · `WhisperCppTranscriber` · `OpenAIProvider` · `LLMTranscriptCorrector` |
| **Invariant**  | I2 for storage; I3 because the effect is measurable                                               |
| **Effort**     | Medium                                                                                            |

`MeetingVocabularyExtractor` derives terms from the transcript itself with
`minOccurrences = 2`, on the premise that the term appears spelled correctly
*somewhere* in the same recording. That premise fails for exactly the words
that matter most in a meeting: a participant's name, a product name, an
internal acronym — mis-heard consistently, in all fourteen occurrences, with
nothing correct to copy from.

The correction stage's topic critique (`TranscriptTopicAnalyzer`) now covers
the part of this that inference can: a critic pass names domain terms the ASR
garbled every time, grounded in the transcript. It cannot know a name that
nothing in the meeting implies, and it acts only after ASR — so a
user-maintained list remains the way to reach both, and to feed the decoder.

**Two application points, with uneven engine support.**

- *Before ASR, as a decoding hint.* whisper.cpp accepts `initial_prompt` in
  `whisper_full_params`; cloud Whisper accepts `prompt`; Apple Speech exposes
  contextual strings. FluidAudio Parakeet has no equivalent hook. This unevenness
  must surface in the UI rather than be promised uniformly across engines.
- *After ASR, as deterministic replacement* over `TranscriptSegment.text`, and as
  a term list handed to `LLMTranscriptCorrector` alongside the auto-extracted
  ones. This path works for every engine, which is what makes the feature
  coherent despite the gap above.

**The identity connection.** `Speaker` rows carry user-typed names. Those are
free glossary entries for the meeting they belong to — and because
`Speaker.voiceprintData` matches voices across runs and meetings, a name
learned once can seed the hint for later meetings with the same voice.

This is also the only entry whose effect the project can *prove*: run the
public-dataset matrix before and after and compare WER. Under I3, that is part
of shipping it, not an afterthought — and since KurnCore runs `swift test` on
Linux, the pure half of it is verifiable without waiting on simulator CI.

#### F4 · Calendar context at record time

|                |                                                                          |
| -------------- | ------------------------------------------------------------------------ |
| **Couples to** | `MeetingFormView` · `Speaker` · `SpeakerIdentityMatcher`                 |
| **Invariant**  | I2 — attendee names are meeting-derived content, so they go in the store |
| **Effort**     | Low-medium                                                               |

Offer the calendar event happening now as the meeting title, and its attendees
as pre-created `Speaker` rows. Read-only EventKit access with
`NSCalendarsUsageDescription`.

This is more than a convenience. Cross-meeting voice matching already suggests
a name typed in another meeting (`TranscriptionCoordinator+CrossMeetingSpeakerMatch`),
but a name only enters the system when a user types one *somewhere*. An
attendee list gives the app a *candidate set* of names for the voices in the
room, independent of whether a name was ever typed before — the half of
speaker identity the voiceprint work could not deliver on its own. It wants F2
in place to pay off fully, since attendee names are also glossary entries.

#### F5 · Action items to Reminders

|                |                                                                       |
| -------------- | --------------------------------------------------------------------- |
| **Couples to** | `SummarySection.items` · the `AutoTagConfirmView` review pattern      |
| **Invariant**  | Compatible — local write; any syncing is the user's Reminders setting |
| **Effort**     | Low-medium                                                            |

`Summary.sections` already produces `SummarySection.items`. Today they are text a
person retypes somewhere else. Writing them as `EKReminder`s, with the meeting in
the note and a deep link back, is a small amount of work on top of output that
already exists.

Non-negotiable: a review step before anything is written. LLM output must never
silently create reminders — which is precisely the pattern `AutoTagConfirmView`
already establishes for suggested tags. Reuse it rather than inventing a second
review flow.

#### F6 · Import audio recorded elsewhere

|                |                                                                       |
| -------------- | --------------------------------------------------------------------- |
| **Couples to** | New extension target · `RecordingProtection` · `OfflineAudioRenderer` |
| **Invariant**  | Compatible — a file comes in, nothing goes out                        |
| **Effort**     | Medium                                                                |

Kurn can only transcribe what Kurn recorded: there is no Share Extension, no
Action Extension, no document picker. But plenty of meetings are captured by
something else — the system voice recorder, a conferencing tool's export, a file
a colleague sent.

The pipeline already starts from a file: `TranscriptionService.transcribe` works
from a `Recording`'s `.m4a`. Import is mostly creating the `Meeting` and
`Recording` and landing the file in `Documents/Recordings/` through
`RecordingProtection` — and through the same `RecordingCaptureState` /
`RecordingFileFinalizer` contract a capture uses, since every consumer gates on
`Recording.isReadyForConsumption`.

**The format trap.** 24 kHz mono AAC is guaranteed for the app's own files, not
for imports. `RecordingCompactor`, `Recording.effectiveBitRate` and the offline
render path all assume the app's encoding. Either normalize on ingest —
`OfflineAudioRenderer` already performs exactly this kind of render — or make
tolerance of foreign formats an explicit, tested requirement at each of those
points. Choosing neither is how a silent corruption bug gets shipped.

### Evaluate

Good ideas carrying a condition, a disproportionate cost, or an unresolved
tension.

#### F7 · OAuth for cloud providers

Signing in with an account the user already pays for, instead of a separately
provisioned API key. It changes nothing about the privacy posture — cloud is
still cloud — but it changes *who can reach it*: today the barrier is creating a
developer account and entering a credit card.

The cost is real: OAuth with PKCE, token refresh, a local callback.
**Condition:** the on-device provider (`FoundationModelsProvider`) already
delivers "works with no key at all" wherever Apple Intelligence is available.
How often that is actually true across the install base is unmeasured (see
"On-device LLM" under follow-ups) — that number decides whether F7 is worth it.

#### F8 · Reading mode

Filler-word removal and paragraph reflow for readability. This **cannot be a
pipeline stage**: `TextNormalizer` is explicitly comparison-only, and the stored
transcript keeps its punctuation and casing by design.

So: a render-time transform over `Transcript.segments`, plus an option in
`MeetingExport` (an `ExportDocument` transform, so every format gets it). Cheap,
pure and testable — a natural KurnCore candidate.

#### F9 · On-device translation of transcripts

Apple's `Translation` framework runs entirely on-device with language packs
downloaded on demand. Kurn already transcribes many languages; reading an
English meeting in Portuguese is a real case and the fit with I1 is exact.
(Summary translation through the selected LLM provider already exists; this is
about the transcript, and about doing it with no provider at all.)

The pack download is a heavy dependency, so it goes through I5 — reuse the
`ModelDownloadConsent` pattern rather than fetching independently.

#### F10 · Spotlight indexing

The value is obvious: find a meeting from system search. The problem is specific
and disqualifying by default. The `CoreSpotlight` index lives outside the app's
store, and I2 exists precisely so that `.completeUnlessOpen` covers every piece
of transcript-derived text. Indexing excerpts would place meeting content in a
system index the app does not control and cannot encrypt.

Two defensible versions: index **title and date only**, with no transcript text;
or make excerpt indexing an explicit opt-in with the trade-off written in plain
language. **Do not index excerpts by default.**

## Diarization

### D4 · Retire sherpa-onnx, and decide on Nemotron 3

`.sherpaOnnx` shipped as an opt-in, segmentation-first diarizer whose only
justification was surviving the failure `FluidAudioDiarizer` is known for —
VBx collapsing a meeting into too few speakers. Read per file
(`docs/pipeline-evaluation.md`, "D4 per file"), it never does: on the one
recording where Pyannote collapses (VoxConverse `0000`, 81 s confused) it
confuses more (112 s), and it trails Pyannote on 7 of 8 files. The decision
left is removal: the engine, its download and consent flag
(`sherpaOnnxModelsConsented`), the Storage row and the matrix axis.

Nemotron 3 (`.fluidAudio` + `.nemotron3`), added since, is what does recover
that file (0 s confused; raw DER 1.39% against Pyannote's 10.61% over the four
VoxConverse files, same run). On AMI (2026-11-03) the picture splits: raw DER is
worse (28.26% against 18.08%) because it misses twice the speech, but it
confuses less than half as much, so the transcript a user reads is better
attributed (cpWER ~25% against ~33%), and it fixes Pyannote's worst meeting
(`EN2002a`). **Decision left:** whether that is worth its costs as the default —
it is ~2× slower, caps at eight speakers, and returns no voiceprints, so
choosing it gives up voice-based speaker identity (CLAUDE.md, "Speaker
identity"). A Settings choice, with Pyannote staying the default until the
voiceprint gap is closed, is the conservative reading.

### Speaker names from outside the app

Cross-meeting voice matching is in place, but it can only suggest a name the
user already typed somewhere. Candidate names from the calendar are F4.

## App Store presence

The listing itself is in the repository (`fastlane/metadata/`, the captions in
`scripts/screenshots/config.json`) and `Tools/validate_store_metadata.py`
enforces the search rules it is written against. What is left needs App Store
Connect or a decision the repository cannot make:

- **Custom product pages with keywords.** Since July 2025 a custom product page
  can be assigned keywords and is then shown in organic search for them, each
  keyword pointing to one page only. Candidates: students (lecture, class),
  interviews (journalists, hiring), and privacy-sensitive work (legal, health).
  Fastlane's `deliver` has no model for these, so they are created by hand or
  by a small Spaceship lane like `accessibility_labels.rb`.
- **In-App Events.** Indexed in search and shown as cards in results. A
  release with a user-visible feature, or the start of a school term, is the
  natural occasion.
- **Featuring nomination** (App Store Connect → Featuring Nominations) before
  each larger release: Liquid Glass, Apple Intelligence through
  `FoundationModelsProvider`, accessibility and privacy are the story Apple's
  editors look for.
- **Traditional Chinese (`zh-Hant`)** is the default store language of Hong
  Kong, Macau and Taiwan, which fall back to English today. It needs the app
  UI localized first — a store page in a language the app does not speak
  would mislead — and then a `zh-Hant` metadata directory.
- **Apple Search Ads** on the brand term and on the long-tail terms the
  listing already targets, once there is a rating count worth showing.

## Follow-ups on shipped work

Gaps each shipped track recorded about itself. None blocks feature work; each
is listed so it is not rediscovered.

### Topic-aware correction

- Not yet measured. Dispatch `pipeline-eval.yml` with `correction: only` on a
  corpus whose earlier `corr=llm` row (the frequency-list corrector it
  replaced) is in `docs/pipeline-evaluation.md`, record the new row, and only
  then describe an effect on WER (insertions are the number to watch: the
  faithfulness check exists to keep them flat).
- `CorrectionFaithfulness` uses spelling closeness as its only proxy for
  "sounds like"; a homophone spelled very differently ("sequel" → "SQL") is
  accepted only through the grounded vocabulary. A per-language phonetic key
  would widen what it can verify.
- The critic sees a ≤ 8,000-character sample, not the whole meeting; a term
  that occurs only outside the sampled windows is found only by the batch
  that contains it.

### On-device LLM (`FoundationModelsProvider`)

- **Measure the on-device budgets.** `ContextBudget.onDevice` and
  `FoundationModelsProvider`'s output-token ceiling are conservative first-cut estimates against Apple's
  documented ~4096-token session window, commented as such in the code — not
  measured against real on-device runs the way the transcription pipeline is.
- **Exercise the untested paths.** `LLMTranscriptCorrector` and `WikiService`
  can select the on-device provider through the
  generic factory path, but that has not been exercised or validated the way
  tagging, chat and summaries were.
- **Measure availability.** `SystemLanguageModel.default.availability` depends
  on Apple Intelligence hardware and the user's setting; how often a fresh
  install actually gets a usable on-device provider is unknown, and is what F7
  should be decided against.

### KurnCore

- **`KurnCoreAccelerate`.** `SpeakerClusterRefiner`, `SpeakerIdentityMatcher`
  and `SpeechLevel` stayed in the app because they import `Accelerate`, which
  does not exist on Linux. If picked up, the plan is a second package target
  gated by `#if canImport(Accelerate)` in `Package.swift` so a Linux
  `swift test` never sees it — not a portable rewrite of the `vDSP` calls.
- **Pure presentation types still in `Views/`.** `MarkdownPresentation` (and
  any sibling) is excluded from coverage by living there; move it beside the
  type it presents, as `CLAUDE.md` asks of new code.

### Reliability

The H1–H10 hardening track is closed; its invariants and types are in
`CLAUDE.md` ("Durability & recovery"). What each track left open:

- **Release gate, recurring.** The physical-device matrix in
  `docs/release-physical-checklist.md` (Data Protection, interruptions, route
  changes, background expiry, low storage, thermal/memory, Watch, model
  compilation) — run per release, not a one-off task.
- **Model integrity.** Models installed before verification existed read
  `.unverified` until re-downloaded. Download resume data survives
  backgrounding but not a relaunch, and there is no automatic
  retry-with-backoff.
- **Operation state.** A full operation-state enum (queued / running / paused /
  deferred / retryScheduled / permanentFailure with reason codes and
  `nextAttemptAt`) was deferred — the bounded `automaticResumeAttempts` counter
  over `TranscriptionStatus` suffices until a concrete UI need appears (e.g.
  "retrying in 2 minutes").
- **Network.** A dedicated "waiting / rate-limited" UI; FluidAudio's
  mid-transfer network path changes are unobservable (the library exposes no
  session to preflight against); background cloud upload stays off while
  origin-lock cannot be guaranteed there.
- **Error UX.** Contextual recovery actions reading `AppErrorMetadata.recoveryAction`
  (the data exists, no UI reads it); a short reference ID shared by an error
  dialog and the reliability-events list (needs widening `errorAlert`'s shared
  binding at ~19 call sites); optimistic-UI rollback; `persist()` and AI-title
  errors are not yet recording-scoped; the non-`AppError` raw-log sweep (~46
  sites) is unaudited.
- **Untested by construction today.** End-to-end resume of a staged
  summary/wiki against a mocked `LLMProvider` (the `SummaryMapRunner` loop is
  tested in isolation); `TranscriptionService.transcribe` actually throwing
  `transcriptIntegrityFailed` (the gate is tested in isolation); the
  ActivityKit start/end race; Watch command timeouts, reconnect reconciliation
  and intent acceptance (no `WCSession` seam, `KurnWatchUITests` not in CI);
  Keychain migration on a locked device; `ModelStoreOpenFailureClassifier`'s
  `NSError` mappings against a real device failure.
- **Unmeasured constants.** `ResourceScheduler`'s weight table and the
  memory/thermal cooldowns are first-cut estimates, not measurements.
- **CI.** The fault-injection seams exist per component (`ClockProviding`,
  `FakeFileSystem`, `ModelDownloading`, …) but there is no single fault-matrix
  artifact; the three macOS jobs each run a full clean build (no
  build-once/test-many — see "UI test stability and speed").

### Design and accessibility

- **iPad split view needs a hands-on pass.** `ContentView`'s
  `NavigationSplitView` on regular width is structurally complete but has never
  been checked on an iPad simulator/device: sidebar balance, collapse/expand in
  Split View and Slide Over, VoiceOver order sidebar → detail.
- **Audit coverage.** Bring `RecorderView` (the screen with the most icon-only
  controls) and `FolderFormView` into `AccessibilityAuditUITests`; no automated
  check covers large accessibility text sizes; Watch VoiceOver is verified
  manually because `KurnWatchUITests` does not run in CI; the Chat tab's live
  conversation UI only renders against a real provider.

### UI test stability and speed

The flow suites (`KurnUITests/Flows/`) are a required check, so a flake costs a
re-run and a slow one costs every PR. Already in place: identifiers instead of
text, the seeded in-memory store per launch, per-launch name suffixes, no
sleeps, `tapUntilCovered`/`tap(_:until:)` for taps that start a transition,
UIKit animations off and the language pinned to English
(`UITestLaunchOptions`, `FlowUITestCase`), test timeouts in CI, and the
measured `ui-flake-rate` lane. Open, in the order they pay off:

1. **Measure every new flow suite before trusting it.** Dispatch
   `reliability-hardening.yml` on the branch that adds it; 5/5 green attempts
   is the bar the existing suites met. A suite that later flakes is demoted with
   a `-skip-testing` line in `swift.yml` and fixed, never retried into green.
2. **Build once, test many.** Each `ui-tests` shard and `unit-tests` runs its
   own `clean test`, so the app and test bundles are compiled three times per
   PR — most of each job's wall time. `build-for-testing` in one job, the
   `.xctestrun` plus products uploaded as an artifact, and
   `test-without-building` in the shards removes two builds; the artifact
   transfer has to be measured against the build it saves.
3. **Boot the simulator before `xcodebuild`.** `xcrun simctl boot` +
   `simctl bootstatus -b` in `prepare-simulator` keeps the cold boot out of the
   first test's time budget, which is where launch-time waits most often run
   out.
4. **Fewer launches per suite.** Each test relaunches the app (~10–15 s on a
   CI runner); checks that share a screen belong in one test, as
   `testMeetingDetailTabs` already does for the audit. Separate tests only
   where a failure would otherwise hide the next check.
5. **Rebalance the shards from measured times.** `main` now also runs
   `BulkSelectionFlowUITests`; read the per-suite durations from the
   `.xcresult` and move suites so neither shard waits on the other.
6. **Replace the remaining text handles.** Menu-picker options, segmented
   segments ("Single file") and the selection title ("Selected: N") are still
   matched by their en string, because SwiftUI does not surface an identifier
   set on a picker option. A custom `Menu` of identified `Button`s, or an
   `accessibilityValue` on the title, would remove the last locale coupling.

Deliberately not used: `-retry-tests-on-failure`. It would turn a flaky test
green on its second attempt and hide exactly the signal the flake-rate lane
exists to count.

### Test coverage

Every in-scope layer is above the 80% target and the floor ratchets
(`Tools/coverage_floor.json`). Still below the target at file level:
`RecorderViewModel` (~74%) and the core of `TranscriptionCoordinator` (~76%).
Changes to `TranscriptionService` or `AudioRecorderService` seams should run the
Thread Sanitizer lane (`reliability-hardening.yml`) before merge.

## Deliberately out of scope

These are not bad features. They are bad fits, and the reasoning is recorded so
the question doesn't reopen without new information.

**R1 · CloudKit content sync.** Syncing transcripts across devices is the one
change here that contradicts the premise outright. CloudKit's private database
is encrypted in transit and at rest but is not end-to-end encrypted the way
`.completeUnlessOpen` is — those records can be served under legal process.
`CloudSettingsSync` is the correct precedent: iCloud key-value for non-secret
preferences, deliberately not the SwiftData container.

**R2 · A system-wide dictation keyboard.** Different product (I4). A meeting
recorder delivers value in a 90-minute file; a dictation keyboard delivers it in
a six-second insert. Building one would double the target count and the
cross-process IPC surface for something nobody installs this app to get.

**R3 · Chasing provider count.** The `AIProviderKind` shapes already reach
almost any vendor, because `openAICompatible` accepts a custom endpoint. Adding
seventeen named providers is a settings screen, not a capability.

**R4 · Bridging to CLI agents on a desktop.** Routing AI processing through a
coding agent running on the user's own machine is useless without that machine
powered on and serving HTTP. Anyone able to operate such a server is already
served by the custom OpenAI-compatible endpoint.

**R5 · Representing overlapping speech.** `SpeakerTurn` is flat and fusion
attributes an overlapped span to whoever held most of its duration. Modelling
concurrent speakers would mean a new turn shape, a fusion policy and UI/export
answers — and none of it would have content to show, because **no transcription
engine in this app produces separate text for simultaneous speech**. Revisit
only if an ASR approach producing independent hypotheses per overlapping
speaker becomes feasible; that question is upstream of anything here. It also
means a diarizer's overlap detection is never a reason to adopt it (see D4).

**R6 · Automatic diagnostic upload or a third-party analytics SDK,** and a
numeric reliability SLO before an instrumented baseline exists. Diagnostics
stay on device and leave only through an explicit share.

## Suggested sequence

1. **F2 · Meeting glossary.** Its WER effect is measurable, and the pure half
   is verifiable on Linux.
2. **F4 · Calendar context.** Feeds F2 real names and supplies the candidate
   names cross-meeting voice matching lacks.
3. **F5 · Reminders and F6 · Import.** Independent of each other and of the
   rest; slot them in as room appears. F6 widens the capture surface, so it
   lands with the same fault-injection discipline as capture itself.
4. **D4's per-file measurement**, on its own clock — it is a dispatch, not code.
5. **Reassess F7–F10.** F7 after the on-device availability number exists.

The follow-ups above are picked up opportunistically, ahead of any feature that
widens the surface they concern.
