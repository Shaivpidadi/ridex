# Native fetch cleanup model

These TLA+ models check native SDK fetch cleanup, not model quality or provider latency. `FetchCleanup.tla` retains the lifecycle proof: two operation handles, cancellation, failure, close, late callbacks, and bounded tail cleanup. `FetchObservation.tla` adds the native observation boundary that the lifecycle model's atomic `Observe` action does not represent.

## Run

TLC and Java are development tools, not libfx runtime dependencies. Set `JAVA` and `TLA2TOOLS_JAR` if they are not in the default locations:

```sh
JAVA=/opt/homebrew/opt/openjdk/bin/java \
TLA2TOOLS_JAR="$HOME/.local/share/tla/tla2tools.jar" \
/opt/homebrew/opt/node@24/bin/node sdk/tests/formal/native-fetch-cleanup/check.mjs
```

The runner qualifies each configuration independently:

| Configuration | Module | Expected TLC exit | Check |
| --- | --- | --- | --- |
| `Legacy` | `FetchCleanup` | 12 | Premature abort before HTTP EOF |
| `Fixed` | `FetchCleanup` | 0 | Original safety and liveness invariants |
| `NoTimer` | `FetchCleanup` | 13 | Stalled-tail liveness failure |
| `UnsafeCallbacks` | `FetchCleanup` | 12 | Foreign-handle mutation |
| `Export` | `FetchCleanup` | 0 | Reachable lifecycle policy cases |
| `SplitRead` | `FetchObservation` | 12 | Torn boolean observation causes premature abort |
| `ObservationFixed` | `FetchObservation` | 0 | Coherent enum observation safety |
| `ObservationFallback` | `FetchObservation` | 0 | Active-only fallback never infers success |
| `ObservationExport` | `FetchObservation` | 0 | Reachable observations for all three methods |

Expected negative runs qualify the checker; do not weaken their invariants. The observation export deliberately includes the unsafe split-read mutation and checks premature-abort safety only for the coherent method. `SplitRead` checks that same invariant unconditionally and must fail. Logs and state counts go to a fresh temporary directory.

Use `--update` after changing a model to regenerate `policy-cases.json` and `observation-cases.json` from TLC's reachable-state output. Do not hand-edit either oracle. The observation fixture projects reachable observations to sampler inputs and policy cases, and retains ordering witnesses selected from those observations. Policy expectations come from TLA+, not JavaScript. Ordinary SDK CI needs no Java: `test-fetch-cleanup-model.mjs` checks the model hashes and observation export configuration hash, verifies the sampler projection, and compares the imported production `fetchCleanupAction` against every recorded case.

## Code correspondence

| Model action/state | Implementation owner |
| --- | --- |
| `Open` and operation identity | `src/napi_fetch_state.zig` and `FetchBridge` in `src/napi_core_main.zig` |
| Lifecycle `WireText` / `Deliver` | Native body pump and normalized SDK event delivery |
| Lifecycle `Complete`, independent of `EOF` | Coarse abstraction of provider completion, native consumption, and result publication |
| Observation `SemanticComplete` / `Consume` / `Retire` / `Close` | Separate semantic completion, exact-handle marker publication, native retirement, and native close |
| Observation `PublishText` / `PublishResult` / `DeliverText` / `DeliverResult` | Separate host output publication and JS delivery; neither supplies the native consumption marker |
| Observation `ReadDisposition` | Single lock-protected `coreFetchDisposition(core, handle)` contract: retired = 0, active = 1, consumed = 2 |
| `Observe` / `Policy` / `Decide` | `fetchCleanupAction()` in `sdk/fetch-cleanup.js`, called by the SDK reader and close path in `sdk/node.js` |
| `Tick` / `Tail` | Host cleanup timer and discarded-byte limit |
| `Cancel` / `Fail` | Existing abort controller, native abort revocation and error handling |
| `Destroy` / `LateCallback` | Deferred runtime destruction and exact-handle/settled guards |

The legacy counterexample is open, wire text, delivered text, logical completion, then abort before EOF without cancellation/failure or exceeded bounds. Inline native tests replay that release ordering. `test-native-core-http-cleanup.mjs` drives it with a real loopback HTTP server whose EOF is delayed, then checks socket reuse across fresh agents. It also exercises actual cancellation, stalled tails, the byte cap and a second model step.

## Observation race

The split-read counterexample reads consumed as false, then the native worker completes consumption and retires the handle before JS reads active as false. The production policy receives `{ consumed: false, active: false }` and returns `abort`, although the matching native marker is true and the HTTP body remains open. `SplitRead` must report `NoPrematureAbort` at exit 12. This is an observation bug, not a different cleanup policy.

The coherent query samples one native state under one lock. A matching consumed marker returns 2 even while native active is true or after native close. JS caches consumed monotonically and derives active from that same query result. A capable addon must not compose separate boolean reads. If the export is absent, the model samples only active and never infers consumed from semantic completion, published output, or delivered output; a retired operation without observed success conservatively aborts. Explicit cancellation and failure still override cached success.

The focused model starts with one open native handle and permits a matching or foreign query handle. Completion, consumption, retirement, native close, text/result publication, and JS delivery interleave independently. Result publication requires semantic completion, and delivery requires the corresponding publication. There is no assumption that JS sees text or a result before native retirement, or that host publication orders the consumption query. `observation-cases.json` includes reachable witnesses on both sides of these orderings, consumed precedence before and after close, cache retention after cancellation, the foreign handle, fallback behavior, and the torn read.

## Scope and assumptions

TLC exhaustively checks the configured finite abstractions, not arbitrary production execution. The original lifecycle invariants and three negative oracles remain unchanged. Its `Observe`, `Tick`, `Deliver`, `Complete`, and `Destroy` actions have weak fairness assumptions; a blocked event loop cannot satisfy them. The two abstract budget units do not prove a 100 ms wall-clock deadline or 64 KiB physical limit. Runtime tests check those concrete guards. Network EOF is not assumed to arrive: the timer must release a stalled drain.

The observation model checks safety without fairness assumptions, with unspent cleanup budgets. Its native actions are atomic lock-boundary transitions; the enum query must be linearizable with those transitions. Native close preserves the exact consumed marker, cancellation revokes it, and a foreign handle cannot borrow it. The JS read and decision do not yield to other JS callbacks, but native actions can run between them. A snapshot that saw active may become stale before a native push; the caller must handle a stale push and refresh before deciding cleanup. Native close is distinct from JS runtime shutdown, which the lifecycle model covers. The focused model checks one query identity per run and does not compose both modules into a single refinement proof.

The test executes the actual imported policy on TLC-derived inputs and reproduces the split-read abort. Its sampler projection checks the declared observation contract, not the execution of `refreshFetch`, the addon lock, or output delivery. This is bounded policy agreement and observation safety, not a full refinement proof of the native addon, JavaScript runtime, HTTP stack, or memory allocator. Production enum wiring, integration, cancellation, bounds, lifetime, and live connection measurements still require runtime verification.
