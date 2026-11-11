# Native harness contract v1

Status: **local message/stream profile implemented (NH02); store/migration profile implemented (NH03); tool/local-effect profile implemented (NH04)**. NH01 froze the NH00
compatibility baseline. NH02 now produces native v1 assistant blocks at the provider
boundary and consumes them in the harness. Indexed session storage and lazy legacy conversion are active; detailed runtime
message persistence barriers and tool-history replay remain NH05/NH06; complete pi compatibility is not claimed.

Baseline: `6ec656b93c6cf59cbc3dc32f9bd08e1abb1517ed`. The attached reference documents
describe pi revision `f064465d10d6a8e5c19f687bba1b5b5499b51680`. Their A/C identifiers
are reference criteria, not identifiers of upstream pi test functions.

The [catalog](native-harness-v1.json) maps all C01–C27 and A01–A70 individually to
scope, delivery increment, legacy evidence and target evidence. `partial` means that
some named behavior is exercised; baseline and target evidence remain separate and do
not establish the full target. Kurn characterization cases are separate from pi conformance.

## Versions and ownership

| Version | Meaning | Current reader/writer |
| --- | --- | --- |
| Fixture v1 | Frozen synthetic test inputs and expected legacy output | Test bundles and catalog validator |
| Contract v1 | Native canonical message/event/entry rules specified here | Provider boundaries write user/assistant content envelopes; checked entry writer and presentation compatibility projection are active |
| JSONStorage envelope v1 | Existing checksum envelope around authoritative app values | Existing app persistence; bare legacy JSON remains readable |
| SwiftData V6 (1.5.0) | Current model graph | Frozen V5 (1.4.0), additive schema migration and atomic per-session conversion |
| pi JSONL v3 | Qualified future interchange boundary | Not a native store schema; NH10 |

`AgentHarness` owns generic messages, streams, execution, compaction and run contracts.
`KurnCore` owns meeting/source/document domain values and has no harness dependency.
The app binds storage, HTTP, credentials, source authorization, artifact persistence and
presentation. Contract types must not pull SwiftData, SwiftUI or Kurn into AgentHarness.

Product constraints are app-only ownership of execution and data; no application backend,
gateway, shell, Node runtime, downloaded executable extension, MCP or codemode. Existing
explicitly selected model providers remain direct HTTPS integrations. Source selection and
saving conversation artifacts as library documents are required product behavior.

## Frozen compatibility baseline

The catalog names three fixtures and pins their SHA-256 checksums. They were captured from
the baseline codecs once; tests must not regenerate expected values with the current
encoder. Review a fixture change explicitly, retain old versions needed for compatibility,
and update its version/catalog when semantics evolve.

| Fixture | What it protects |
| --- | --- |
| `nh01-runtime-v1.json` | Legacy AgentMessage/AgentToolCall/AgentRunStep JSON, raw invalid arguments, opaque replay metadata, reported reasoning usage and all four provider request serializers |
| `nh01-domain-v1.json` | Meeting/tag/folder/library scope, global parts, empty per-meeting overrides, legacy wiki defaults, artifact bodies and historical title/version references |
| `nh01-session-v1.json` | Bare pre-envelope turns/scope/artifacts, stable turn IDs, ignored retrieval citations, trace/usage/cost restoration, retryable question and saving/updating a library document |

The fixtures are synthetic and contain no user recordings or credentials. Frozen provider
requests characterize serializers; they are never sent to a real provider and do not prove
that a service accepts every opaque fixture field.

Important current adaptations/gaps:

- Reopen restores presentation turns, the current scope and latest artifact snapshots.
  The next request replays plain user/assistant text. Old retrieval citations, tool audit
  payloads and document bodies do not enter that history; artifact title/version metadata
  is supplied separately. Plain earlier assistant text remains memory under the current
  default, even after narrowing sources. Strict-current-sources behavior is future NH06.
- Artifacts retain their own latest body/version. A historical reference retains its saved
  title/version and must not silently become the newest revision. Saving again updates the
  same library document for the session/artifact identity. Legacy missing model provenance
  stays unknown; it is not reconstructed from today's selected model.
- Runtime compaction changes only the current request projection. Reopen/another question
  does not yet reuse a durable checkpoint. Retained branches and local effect receipts
  are stored, but automatic session recovery and canonical replay remain NH05/NH06.
- Output-limited calls never execute. NH02 retains native call blocks/raw arguments and
  appends synthetic error results in the in-memory audit history. A successful output
  recovery excludes that interrupted exchange from retry context. The V6 app compatibility writer still saves
  presentation turns/trace rather than this complete native tool history; the awaited
  model-message/result barriers belong to NH05.
- The current UI can request cancellation and clear its busy state before the task settles.
  Confirmed termination, durable barriers, queues and late-event fencing belong to NH05.
- Legacy Codable Date fields use Foundation seconds since 2001. Preserve that codec while
  reading old data. Contract v1/pi timestamps below are different fields and units.

## Native identities and time

Session, entry, run, model-request attempt, tool-call invocation, artifact revision and
effect receipt identities are distinct. IDs are opaque nonempty strings, at most 128 UTF-8
bytes. Existing UUID text can be retained without replacement. Never deduplicate by text
equality, tool arguments or array position. A retry is a new request attempt; it does not
change the identity of an already committed effect.

Entries have a session-wide monotonic append ordinal and a nullable parent entry ID. The
selected leaf is separate from the newest append. Events have a run-scoped sequence starting
at one; event sequence is neither an entry ID nor append ordinal.

| Field | Encoding |
| --- | --- |
| Message timestamp | Signed Int64 Unix milliseconds, preserved exactly |
| Entry creation time | ISO 8601 UTC with explicit timezone |
| Duration | Nonnegative monotonic milliseconds |
| Legacy Date | Existing Foundation codec, decoded only through the legacy boundary |

For example, `1700000000125` message milliseconds and
`2023-11-14T22:13:20.125Z` entry time describe the same instant. Do not encode the
millisecond integer as Foundation Date seconds or infer missing historical timestamps.

## Target message and request contract — NH02

Canonical messages, transient model events, persisted entries and visual turns are four
different representations. Each provider request is a disposable projection of canonical
data; normalization must not mutate saved signatures, raw arguments or message identity.

Messages carry stable ID, role, timestamp and ordered content blocks. Assistant finals also
carry provider/model/API identity, request-attempt ID, normalized stop reason, reported usage,
and opaque provider replay data. Preserve response model/ID, raw stop reason, diagnostics and
thinking-level metadata when supplied. Missing optional values stay absent.

| Block | Required semantics |
| --- | --- |
| text | Text plus optional opaque signature |
| thinking | Visible/redacted state, optional text and opaque signature; never public diagnostics |
| toolCall | Invocation ID/name, raw argument text, parsed arguments or validation error, optional namespace and opaque replay data |
| image | Explicit MIME type and bounded data/reference; unsupported adapters use an omission marker in the request copy |

Final stop reasons distinguish stop, tool use, output length, error, abort and deferred.
Pending is transient and cannot be committed as a final response. Deferred is unsupported
until a provider implements its explicit recovery capability; no universal polling.

The authoritative final message replaces reconstructed deltas. Text/thinking/tool blocks
retain order and stable block identity through fragmentation/interleaving. An incomplete
tool call, raw parse error or output-length response cannot execute a tool, even if salvaged
JSON happens to validate. Record one synthetic error result per blocked invocation in the
canonical transcript. Keep the original raw arguments in protected canonical data.

Provider preparation/authentication/transport failures must produce a terminal protocol
outcome, including failure before any start event. UI text is a projection and cannot be
used to reconstruct canonical tool calls or decide whether a mutation committed.

## Target events, accounting and barriers — NH02/NH05/NH07

The native event envelope has `contractVersion`, session/run IDs, sequence, optional
request/call IDs and a typed event payload. It is an in-process contract, not a gateway.
Unsupported versions/required discriminants fail explicitly; never silently drop an entry.
Unknown data in a declared opaque metadata field is retained without interpretation.

Lifecycle distinguishes preparing, streaming, executing tools, waiting for user, compacting,
retry wait, cancelling, interrupted and idle. Each accepted request gets exactly one terminal
outcome. `runEnded` closes low-level execution; `sessionSettled` follows recovery and all
required writes. Cancellation is a request followed by confirmation, not an immediate settle.

Persistence/policy barriers are awaited. Final assistant data commits before tool effects;
tool results commit before the next request. A UI subscriber receives bounded/coalesced
snapshots and cannot block canonical progress indefinitely. Bound stream buffers, terminate
explicitly on overflow and ignore late progress/events from a terminated generation.

Usage belongs to request identity. Reported cumulative usage replaces partial usage; it does
not add the same request twice. Missing usage/cost is unknown, not zero. Reasoning is an output
component and is not added again to output. Summary/retry/failed-attempt usage is retained
when reported. Run totals are not current context occupancy. A cost guard needs explicit
pricing or a documented token/request fallback; it is not a provider billing guarantee.

## Target store, source projection and effects — NH03/NH04/NH06

The entry envelope has contract version, session/entry/parent IDs, append ordinal, entry
creation time and a typed payload. Indexed SwiftData entries become canonical only after a
validated per-session migration. Retain original turnsData until the migration commits;
interruption is resumable and never performs a model request or tool mutation. Extend backup,
salvage, erasure and real on-disk migration tests together. Corruption is not empty history.

Projection follows active ancestors and source segments, applies system sections/context
edits and replays saved compaction checkpoints. Tool calls/results remain paired. Record the
authorized source snapshot and selected parts at the request boundary. Narrowing sources has
an explicit memory policy; strict mode filters old excerpts, summaries and artifact metadata
before sending a request. Never substitute today's scope for recorded historical evidence.

Document effects use invocation/receipt identity and per-artifact serialization. Validate and
authorize before execution, durably commit a revision/receipt before reporting success, then
persist the result. Known committed effects are not repeated on retry/relaunch. An unknown
effect outcome is surfaced for reconciliation. A saved library document remains independent
of future chat branches; create/update/delete/re-save keep explicit provenance.

## Validation and activation

`python3 Tools/check_native_harness_contracts.py` checks complete A/C coverage, bounded
profile scope, evidence links/test symbols, fixture versions, baselines and checksums. CI
runs it with static policy. Tests decode real fixture bytes through current package/app
readers; no provider keys or paid calls are needed.

NH01 completion means the baseline and target are reviewable and traceable. Target evidence
now identifies the exercised NH02 behavior; session-dependent criteria remain open. NH03
activates store codecs/migration only after validation. NH00's real-corpus/device qualification and
authenticated provider smoke tests remain separately open.

## NH02 implementation boundary

`AgentContentMessage` is the checked v1 user/assistant content envelope. It retains an
opaque message ID, exact Int64 Unix milliseconds (absent when historically unknown), ordered
stable block IDs, response/request identities, optional model/API, raw stop reason, reported
usage and opaque replay fields. `AgentMessage.content` and `.tool(AgentToolResultMessage)`
carry native messages alongside the frozen legacy input cases. Live user/assistant/results
are native; `legacyProjection` is a read-only compatibility view. Results contain bounded
text/image blocks, optional private details, an error flag and a typed synthetic block reason.
Thinking/tool-call blocks cannot be decoded as tool results. The native golden is separate
from NH01's immutable legacy fixtures and does not claim their baseline commit.

The owner assigns a request ID before preparation and a logical invocation ID before tool
execution; both remain distinct from provider response/call IDs. New retries, summaries and
wrap-ups receive new request IDs. Reused provider call IDs cannot link a result to a different
request. Session/run/request/invocation IDs travel in typed events and content-free diagnostic
steps. New/reloaded conversations use their actual ChatSession UUID, with a new run UUID each
time. Control characters are escaped in log IDs. Historical identities are never fabricated.

Stream failures create native terminal audit messages even before the first block. Partial
raw calls stay in the failure snapshot and get synthetic interrupted results without running
tools. Detailed live protocol audit remains in memory until the NH05 owner writes it;
NH03 persists the existing presentation/diagnostic projection as canonical entries.
NH01 fixture bytes stay unchanged. The V5 graph is frozen and V6 adds entry/revision storage;
effect receipts and awaited persistence barriers remain NH04/NH05.

`AgentMessageReducer` orders interleaved blocks, bounds retained content to 4,096 blocks /
8 MiB, rejects invalid transitions and replaces all accumulated blocks/usage with the final
message. Thinking/redacted data never becomes visible text. Wire errors are sticky; malformed
payloads, unknown required block types, incomplete tool calls, missing terminal events and
explicit buffer overflow cannot be salvaged into executable calls. Anthropic requires both
`content_block_stop` for a tool and `message_stop` for the response. Responses final output
replaces stale/removed/reordered items, preserving known item identities. Chat Completions
orders tool fragments by provider index. Trailing cumulative usage replaces earlier counts;
Gemini reasoning is an output component, counted once.

Every production AgentModel implementation uses `AgentModelBoundary`, covering credential/URL
preparation and transport. It emits exactly one typed final/failure event. The harness fences
late callbacks and prevents a failed stream from returning executable calls. Deferred outcomes
are explicit and unsupported; no polling is introduced. Awaitable session barriers and event
sequence envelopes remain NH05 work.

Provider requests are disposable `AgentReplayProjection` copies. Error/aborted/deferred
messages and their paired native results are omitted with `omittedMessages` diagnostics.
Optional namespaces survive reduction/audit; unsupported namespaced calls produce explicit
errors instead of dispatching an unqualified builtin. Namespace loss in wire replay is counted.
Supplied declared diagnostics/thinking/reasoning protocol facts remain private metadata and
are never blindly forwarded. IDs are normalized/relinked
without touching canonical IDs. Invalid/incomplete arguments become `{}` only in a replay copy
paired with their error result. Unsupported images/thinking use explicit omission markers;
signed thinking and Gemini signatures are replayed only to the compatible API/model. Aliases
without a qualified identity mapping remain conservative. No new image picker or model-level
image/thinking capability claim is introduced; provider capability qualification is NH07.

`replayPrepared` persists numeric omission/normalization/sanitization counts. Request completion
adds native/thinking block counts, invalid/incomplete call counts and a normalized stop code
(0 stop, 1 tools, 2 length, 3 error, 4 abort, 5 deferred, 6 other). Request/summary failure adds
`protocolFailure` (1 preparation, 2 transport, 3 invalid stream, 4 cancellation, 5 deferred;
0 if no typed failure was observed). No content, signatures or raw errors enter these records.
All returned disabled/length-limited calls receive synthetic tool-error audit results and
`toolRequested`/`toolSkipped`/`toolFinished` diagnostics without invoking confirmation or tools.


## NH03 activation boundary

`AgentSessionEntry` checks native payloads, opaque host metadata, explicit UTC entry time,
IDs and monotonic append ordinals. `AgentEntryGraph` validates every sibling and selects
an active ancestor path independently of append order. The MainActor SwiftData adapter
exchanges Sendable snapshots/commits through `AgentSessionStore`; expected revisions reject
stale writes. Row indices are checked against checksummed payload envelopes.

V5 models are frozen independently of live V6 classes. Conversion is a single atomic,
resumable session unit, with a completion version, original turns/scope/artifact bytes and
no model/tool callbacks. Missing historical timestamps, response identity and stop reasons
stay absent. Only known artifact versions are migrated. Duplicate IDs, malformed content,
unsupported versions and mismatched indices fail explicitly.

The app compatibility writer records presentation messages/host metadata and selected
scope/artifact revision references as append-only entries. A changed/deleted suffix selects
a new branch; retained siblings stay available. Checked loads derive from the active path,
not `turnsData`/`scopeData`/`artifactsData` caches. This is the sole production presentation
writer. Detailed live model/tool messages remain in the runtime until the NH05 owner writes
them behind awaited barriers. Current model replay remains plain history; NH06 adds the
qualified source-aware canonical projection.

Recovery records persist versioned run/queue/draft/effect metadata only. Their presence
never resumes work or consumes a prompt. Generic effect metadata alone does not prove
a commit; the validated NH04 local receipt profile below does. NH05/NH08 define session/queue behavior.

The graph is shared by production, tests and whole-store protected backups. Markdown
salvage includes conversations, retained native messages/artifact revisions, recovery metadata
and independent library documents, while leaving live bytes unchanged. Library erasure
removes all three new entities, including orphans, and per-session deletion cascades.


## NH02 review corrections — PRs #337/#338

The wire finish reason closes content, not transport validation. Until SSE EOF, explicit
provider errors (including Responses typed failure events) invalidate the entire response.
Failures are sticky and cannot be cleared by later usage updates. Malformed/oversized
trailers fail explicitly; valid cumulative usage remains accepted and late content stays
fenced. Tools cannot execute from a response invalidated after its finish reason.

Diagnostic request correlation is scoped to the active model attempt. Request/summary
terminal events retain that attempt's ID, then close it on success, failure or cancellation.
Context checks, compaction decisions, retry decisions and run terminals outside requests
carry session/run identity with no stale request ID. Summary requests get their own scope.
Tool diagnostics explicitly reference their invocation's originating request without changing
the ambient model scope; ending an invocation cannot leak its request into the next check.
Existing persisted traces are retained as recorded rather than retrospectively relabeled.


## NH04 activation boundary

`AgentToolRegistry` accepts only the tools bundled by the host, with unique ASCII identifier
names (1–64 bytes). Schemas are bounded to depth 32 and 4096 nodes. The non-coercing subset
supports object/properties/required/boolean additionalProperties, homogeneous arrays/items,
string Unicode-scalar length and UUID format, finite number/integer bounds, boolean, null,
description and enum. Object roots and explicit properties/additionalProperties are required.
Unknown keywords, references, combinators, patterns and other formats fail registration.
Bundled source/document schemas use additionalProperties=false. Semantic authorization,
empty text, size, identity and paging checks remain in the host tools.

Every invocation is schema-checked before policy and rechecked after an allowed argument
transformation. Denial, confirmation refusal, unknown tools, invalid arguments, errors and
abort all close the tool lifecycle. Generic diagnostics contain numeric facts and opaque
IDs, never raw arguments or exception descriptions. Progress phases are 0=validation,
1=authorization, 2=execution, 3=commit, 4=committed, 5=recovered committed receipt. A shared
terminal fence rejects late callbacks. The UI trace retains progress plus content-free
validation/policy/abort/registration diagnostics. No after-result replacement hook or
termination policy is exposed (A23/A24 remain conditional).

Independent read batches use at most four workers (configurable bounded 1–16). Mixed batches
containing any sequential/unknown tool run sequentially. All started workers settle before
failure escapes. Progress/end events follow completion; native result messages append in
original assistant call order. Document mutations are always sequential. Before extending a soft tool limit, the
scheduler settles the currently authorized capacity so completed parallel reads contribute
to progress. Repeated/stale reads cannot earn more budget, and the hard limit stays logged. Model-visible
content, host details and structuredContent are separate native output fields; every wire
adapter projects only explicit content. The existing Unicode-safe pagination remains.

The app captures source metadata, selected parts, passage/attachment bodies, semantic
candidates and SHA-256 content revisions before model IO. Later selection/content changes
cannot expand that snapshot; source deletion and attachment deletion fail explicitly. The
snapshot is per task; persisting authorization entries for later replay is NH05/NH06.

The synchronous MainActor effect transaction reads the current checked session, plans a
pure domain edit, then saves its immutable artifact revision, selected presentation state,
artifact reference/provenance and effect receipt together. The receipt identifies the logical
invocation/request/provider call, arguments digest, exact decimal artifact version and original result. The structured output also carries
its version as decimal text, avoiding the Double precision limit of JSONValue numbers.
A matching receipt returns that original result while retaining the latest workspace state;
changed arguments/identity or a corrupt receipt fail without mutation. Receipts are immutable.
A shared local mutation lease spans the save and workspace publication, including actor
suspension and overlapping executors. Compatibility UI saves preserve newer committed
artifacts/references/provenance during cancellation; explicit branch writes remain separate. A failed save
restores only staged entries/revisions/receipt. A cancellation arriving after a successful
save cannot erase the receipt or change the known committed result into a tool failure.

New sessions are still lazy. Before the first document effect of each task, the accepted
user presentation is saved for both new and existing conversations. Preparation runs only
once per task, so a later mutation cannot rewind earlier committed artifacts. Other accepted input/message/result barriers, one owner per
session, crash recovery scheduling and settle semantics remain NH05. Native tool messages
are still in-memory until that owner persists them; reopen does not automatically execute
anything. Canonical provider replay and persistent compaction remain NH06. Local durable
receipt replay is qualified; no remote/unknown-outcome side-effect mechanism is introduced.


## Initial NH05 package ownership boundary

`NativeHarness.persistingMessages` and `persistingUsage` install awaited commits before
model/tool dependencies advance. Failure audit and synthetic results use the same message
barrier. `start` returns a producer handle: its bounded events are disposable observations,
while `result()` waits for the producer itself and `cancel()` requests termination.
The compatibility `run` API retains its original observation/cancellation contract.

`AgentSession` owns an accepted run across store awaits, explicit cancellation and terminal
writes. It writes `agent.run-start.v1`, `agent.usage.v1` and `agent.run-end.v1` custom entries
alongside native messages, correlated by run ID. A failed terminal write blocks new work;
`retrySettlement` retries the saved terminal entry without inference or effects, recognizing
an identical entry when a commit acknowledgement was lost. `waitUntilSettled` returns the
captured run state, including explicit persistence failure; it does not claim successful
durability when a write failed. Message/usage failures require host recovery. Opening a new
owner executes nothing. One owner per session is a host responsibility.

This is package infrastructure with tests, not app activation or completion of session
acceptance criteria. UI/coordinator lifetime, canonical replay/provenance, crash/effect
recovery, durable command deduplication and complete phase projection remain open in NH05;
compaction/projection and queues retain their later roadmap boundaries.
