#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { createServer } from "node:http";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { setImmediate as nextLoop } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { createFxAgent, resolveModel } from "../node.js";

// Legacy.cfg counterexample rows, with their FetchCleanup.tla source owners:
// 1 Init (13), 2 Open (20), 3 WireText (29), 4 Deliver (35),
// 5 Complete (41), 6 Observe (80) -> prematureAbort / NoPrematureAbort.
// HTTP EOF is deliberately withheld through rows 4 and 5. Normal completion
// must drain, not abort, even when a fresh agent closes before HTTP EOF.
const apiKey = "http-cleanup-fixture-key";
const modelId = "native/http-cleanup-model";
const addon = resolve(process.argv[2] || fileURLToPath(new URL("../../zig-out/lib/libfx.node", import.meta.url)));
const native = createRequire(import.meta.url)(addon);
assert.equal(typeof native.coreFetchDisposition, "function", "rebuild libfx.node with coreFetchDisposition before running this suite");
const eofDelayMs = 30;
const cleanupBoundMs = 500; // 100 ms policy budget plus scheduling allowance.
const realFetch = globalThis.fetch; // No dispatcher override: all agents share Node's default TCP pool.
const sse = (value) => `data: ${typeof value === "string" ? value : JSON.stringify(value)}\n\n`;
const textFrame = (delta) => sse({ type: "text-delta", delta });
const finishFrame = (reason) => sse({ type: "finish", finishReason: { unified: reason, raw: reason } });
const successFrames = textFrame("OK") + finishFrame("stop") + sse("[DONE]");

function deferred() {
  let resolve, reject;
  const promise = new Promise((done, fail) => { resolve = done; reject = fail; });
  void promise.catch(() => {});
  return { promise, resolve, reject };
}
const serverFailure = deferred();
async function bounded(promise, label, ms = 2000) {
  let timer;
  try {
    return await Promise.race([
      promise,
      serverFailure.promise,
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`${label}: exceeded ${ms} ms`)), ms); }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

const requests = [];
let clientPosts = 0;
let serverPosts = 0;
let nextSocketId = 0;
const socketIds = new WeakMap();
function plan(mode, input) {
  const record = {
    id: requests.length + 1, mode, input, text: "", aborts: 0,
    posted: deferred(), firstText: deferred(), aborted: deferred(), closed: deferred(),
  };
  requests.push(record);
  return record;
}
function check(record, expectation) {
  return `request ${record.id} (${record.mode}): ${expectation}`;
}
function endAfterDelay(record, tail = "") {
  assert.ok(record.response, check(record, "server must have accepted the POST"));
  assert.equal(record.response.writableEnded, false, check(record, "HTTP EOF must still be withheld"));
  record.endTimer = setTimeout(() => {
    record.endAt = performance.now();
    record.response.end(tail);
  }, eofDelayMs);
}

const server = createServer((request, response) => {
  void serve(request, response).catch((error) => {
    serverFailure.reject(error);
    response.destroy();
  });
});
server.on("connection", (socket) => { socketIds.set(socket, ++nextSocketId); });
async function serve(request, response) {
  assert.equal(request.method, "POST", "resolved models must eliminate HTTP catalog GETs");
  assert.equal(request.url, "/chat");
  const record = requests[serverPosts++];
  assert.ok(record, "unexpected HTTP POST");
  record.socketId = socketIds.get(request.socket);
  record.response = response;
  response.once("close", () => {
    clearTimeout(record.endTimer);
    record.closedAt = performance.now();
    record.closed.resolve();
  });
  let body = "";
  for await (const chunk of request) body += chunk.toString("utf8");
  assert.ok(!body.includes(apiKey), check(record, "credentials must not appear in model payloads"));
  const payload = JSON.parse(body);
  if (record.mode === "tool-step") {
    assert.ok(payload.tools?.some((tool) => tool.name === "lookup"), "lookup must be advertised");
  } else if (record.mode === "tool-result") {
    assert.ok(body.includes("value:alpha"), "the second POST must include the tool result");
  } else {
    assert.ok(payload.tools == null || payload.tools.length === 0, "no native tools must be advertised");
  }
  response.writeHead(200, { "content-type": "text/event-stream" });
  record.wireAt = performance.now();
  const frames = record.mode === "active"
    ? textFrame("PARTIAL")
    : record.mode === "tool-step"
      ? sse({ type: "tool-call", toolCallId: "cleanup_lookup", toolName: "lookup", input: { key: "alpha" } })
        + finishFrame("tool-calls") + sse("[DONE]")
      : successFrames;
  record.frames = frames;
  response.write(frames);
  record.posted.resolve();
}

await new Promise((done, fail) => { server.once("error", fail); server.listen(0, "127.0.0.1", done); });
const gatewayChatUrl = `http://127.0.0.1:${server.address().port}/chat`;
const agents = new Set();
const results = [];
let currentCase;
let model;
let catalogCalls = 0;

async function newAgent(extra = {}) {
  const agent = await bounded(createFxAgent({
    backend: "native", nativeAddon: addon, apiKey, model, gatewayChatUrl,
    fetch(input, init) {
      // Observe the SDK's own signal, then return the real Response unchanged.
      assert.equal(String(input), gatewayChatUrl, "no external request is allowed");
      assert.equal(init.method, "POST", "descriptor consumption must not discover models");
      const record = requests[clientPosts++];
      assert.ok(record, "unexpected client POST");
      record.signal = init.signal;
      assert.equal(init.signal.aborted, false, check(record, "POST must start with a live signal"));
      init.signal.addEventListener("abort", () => {
        record.aborts++;
        record.abortAt = performance.now();
        record.aborted.resolve();
      }, { once: true });
      return realFetch(input, init);
    },
    ...extra,
  }), "fresh native agent initialization");
  agents.add(agent);
  return agent;
}
function readTurn(turn, record) {
  const task = (async () => {
    for await (const update of turn) {
      if (update.type !== "text_delta") continue;
      record.text += update.delta;
      if (record.firstTextAt === undefined) {
        record.firstTextAt = performance.now();
        assert.equal(record.response?.writableEnded, false,
          check(record, "legacy row 4 Deliver: first text must arrive before HTTP EOF"));
        record.firstText.resolve();
      }
    }
  })();
  void task.catch((error) => record.firstText.reject(error));
  return task;
}
async function completedTurn(turn, record, reading) {
  record.result = await bounded(turn.result, check(record, "legacy row 5 Complete: model result before HTTP EOF"));
  record.resultAt = performance.now();
  await bounded(reading, check(record, "event iterator must finish before HTTP EOF"));
  assert.equal(record.result.stopReason, "end_turn", check(record, "model must succeed"));
  assert.equal(record.text, "OK", check(record, "exact streamed model text"));
  assert.equal(record.response.writableEnded, false, check(record, "model completion must not depend on HTTP EOF"));
  assert.equal(record.aborts, 0, check(record, "legacy row 6 Observe: no premature successful signal abort"));
}
async function closedAgent(agent, closing = agent.close()) {
  assert.equal(await bounded(closing, "native agent.close cleanup", cleanupBoundMs), undefined);
  agents.delete(agent);
  // Give the shared default fetch pool its ordinary idle/reuse turn.
  await nextLoop();
}
function passed(name, details) {
  results.push({ name, ...details });
  console.log(`PASS ${name}: ${JSON.stringify(details)}`);
}

try {
  model = await resolveModel({
    apiKey, model: modelId, gatewayChatUrl,
    fetch(_input, init) {
      assert.equal(init.method, "GET");
      catalogCalls++;
      return Promise.resolve(Response.json({ object: "list", data: [{ id: modelId, type: "language", tags: ["tool-use"] }] }));
    },
  });

  currentCase = "coherent disposition across native completion between legacy reads";
  {
    const record = plan("split-read", currentCase);
    const wire = Buffer.from(successFrames);
    const textBytes = Buffer.byteLength(textFrame("OK"));
    const sleeper = new Int32Array(new SharedArrayBuffer(4));
    // Hold only finish frames at the addon boundary. This guarantees the old
    // getter reads false after text delivery, regardless of worker scheduling.
    const held = [];
    let pushedBytes = 0;
    let released = false;
    let handle;
    const observations = record.interleaving = { dispositionReads: 0, consumedReads: 0, activeReads: 0, forcedSplitReads: 0, destroyed: 0 };
    function releaseFinish(core, fetchHandle) {
      assert.equal(fetchHandle, handle, "the completion gate must target the exact pushed handle");
      assert.equal(native.pushCoreFetchResponse(core, fetchHandle, Buffer.concat(held)), 1);
      released = true;
      held.length = 0;
      // Only the native worker runs here. JS cannot deliver EOF or process the
      // completion wake until the getter returns, so retirement is the barrier.
      const deadline = performance.now() + cleanupBoundMs;
      while (native.coreFetchActive(core, fetchHandle)) {
        assert.ok(performance.now() < deadline, "native completion must retire the handle within the bounded getter wait");
        Atomics.wait(sleeper, 0, 0, 1);
      }
      assert.equal(native.coreFetchDisposition(core, fetchHandle), 2, "normal retirement must retain consumed disposition");
    }
    const wrapped = Object.assign(Object.create(native), {
      pushCoreFetchResponse(core, fetchHandle, bytes) {
        handle ??= fetchHandle;
        assert.equal(fetchHandle, handle);
        assert.equal(native.coreFetchDisposition(core, fetchHandle), 1, "withheld finish must keep this fetch active");
        assert.deepEqual(bytes, wire.subarray(pushedBytes, pushedBytes + bytes.length), "forward only the real loopback response bytes");
        const prefixLength = Math.min(bytes.length, Math.max(0, textBytes - pushedBytes));
        if (prefixLength) assert.equal(native.pushCoreFetchResponse(core, fetchHandle, bytes.subarray(0, prefixLength)), 1);
        if (prefixLength < bytes.length) held.push(Buffer.from(bytes.subarray(prefixLength)));
        pushedBytes += bytes.length;
        return 1;
      },
      coreFetchConsumed(core, fetchHandle) {
        observations.consumedReads++;
        const prior = native.coreFetchDisposition(core, fetchHandle) === 2;
        if (!prior && !released && pushedBytes === wire.length) {
          // Old refreshFetch reads false after text was pushed. Complete and
          // retire on the native thread before returning that same false, so
          // its separate coreFetchActive read sees false and aborts success.
          observations.forcedSplitReads++;
          releaseFinish(core, fetchHandle);
        }
        return prior;
      },
      coreFetchActive(core, fetchHandle) {
        observations.activeReads++;
        return native.coreFetchActive(core, fetchHandle);
      },
      coreFetchDisposition(core, fetchHandle) {
        observations.dispositionReads++;
        if (!released && pushedBytes === wire.length) releaseFinish(core, fetchHandle);
        return native.coreFetchDisposition(core, fetchHandle);
      },
      destroyCore(core) {
        observations.destroyed++;
        return native.destroyCore(core);
      },
    });
    const agent = await newAgent({ nativeAddon: wrapped });
    const turn = agent.prompt(record.input);
    await completedTurn(turn, record, readTurn(turn, record));
    assert.equal(released, true, "the real finish frames must cross the native completion gate");
    assert.equal(pushedBytes, wire.length);
    assert.ok(observations.dispositionReads > 0, "the SDK must use the coherent native disposition getter");
    assert.equal(observations.consumedReads, 0, "the new SDK path must never call the obsolete consumed getter");
    assert.equal(observations.activeReads, 0, "refreshFetch must not split a coherent observation into an active read");
    assert.equal(observations.forcedSplitReads, 0, "only the old split-read implementation enters the interleaving trap");
    const closing = agent.close();
    endAfterDelay(record);
    await closedAgent(agent, closing);
    await bounded(record.closed.promise, check(record, "successful drain must reach real HTTP EOF"), cleanupBoundMs);
    assert.equal(record.aborts, 0, "coherent consumed state must drain without any successful signal abort");
    assert.equal(record.signal.aborted, false);
    assert.equal(record.response.writableEnded, true);
    assert.equal(observations.consumedReads, 0, "normal close must not consult the obsolete consumed getter");
    assert.equal(observations.activeReads, 0, "normal close must also use the coherent disposition getter");
    assert.equal(observations.destroyed, 1, "closing must release the wrapped native core exactly once");
    passed("coherent disposition interleaving", { posts: 1, ...observations, signalAborts: record.aborts });
  }

  currentCase = "legacy rows 1-6: fresh agents, delayed EOF, shared TCP pool";
  let sharedSocketId;
  let maxCloseMs = 0;
  for (let index = 0; index < 30; index++) {
    const record = plan("success", `cleanup success ${index + 1}`);
    const agent = await newAgent();
    const turn = agent.prompt(record.input);
    const reading = readTurn(turn, record);
    await bounded(record.firstText.promise, check(record, "first streamed text before EOF"));
    await completedTurn(turn, record, reading);
    // Start close with the real body still open; EOF follows 30 ms later.
    const closeAt = performance.now();
    const closing = agent.close();
    endAfterDelay(record);
    await closedAgent(agent, closing);
    maxCloseMs = Math.max(maxCloseMs, performance.now() - closeAt);
    assert.equal(record.aborts, 0, check(record, "NoPrematureAbort: successful close must never abort its fetch signal"));
    assert.equal(record.signal.aborted, false);
    assert.equal(record.response.writableEnded, true, check(record, "normal HTTP EOF must be reached"));
    sharedSocketId ??= record.socketId;
    assert.equal(record.socketId, sharedSocketId, check(record, "all 30 fresh agents must reuse the same request.socket"));
  }
  passed("delayed EOF socket reuse", { requests: 30, socketId: sharedSocketId, signalAborts: 0, maxCloseMs });

  // FetchCleanup.tla Cancel (53): a real unfinished body must abort immediately,
  // not enter the successful-consumption drain path.
  for (const operation of ["turn.cancel", "agent.close"]) {
    currentCase = `${operation} while a live POST is unfinished`;
    const record = plan("active", currentCase);
    const agent = await newAgent();
    const turn = agent.prompt(record.input);
    const reading = readTurn(turn, record);
    await bounded(record.firstText.promise, check(record, "unfinished response text"));
    const cancelAt = performance.now();
    let closing;
    if (operation === "turn.cancel") turn.cancel();
    else closing = agent.close(); // FetchCleanup.tla Close (65).
    assert.equal(record.signal.aborted, true, check(record, `${operation} must synchronously abort the client signal`));
    assert.equal(record.aborts, 1, check(record, "exactly one abort event"));
    record.result = await bounded(turn.result, check(record, "cancelled turn result"), cleanupBoundMs);
    await bounded(reading, check(record, "cancelled event iterator"), cleanupBoundMs);
    assert.equal(record.result.stopReason, "cancelled");
    assert.equal(record.text, "PARTIAL");
    await closedAgent(agent, closing);
    await bounded(record.closed.promise, check(record, "server must observe the aborted response"), cleanupBoundMs);
    assert.equal(record.response.writableEnded, false, "cancellation must not wait for server EOF");
    passed(operation, { signalAborts: record.aborts, abortMs: record.abortAt - cancelAt });
  }

  // FetchCleanup.tla Tick (91): no more data or readiness events arrive.
  currentCase = "successful model, HTTP tail never reaches EOF";
  {
    const record = plan("stalled-tail", currentCase);
    const agent = await newAgent();
    const turn = agent.prompt(record.input);
    await completedTurn(turn, record, readTurn(turn, record));
    const closeAt = performance.now();
    await closedAgent(agent);
    assert.equal(record.aborts, 1, check(record, "the 100 ms cleanup timer must abort a never-ending tail"));
    assert.ok(record.abortAt - record.resultAt >= 50, check(record, "successful consumption must drain, not abort immediately"));
    assert.equal(record.response.writableEnded, false);
    await bounded(record.closed.promise, check(record, "timer abort must close the server response"), cleanupBoundMs);
    passed("never-EOF cleanup", { signalAborts: record.aborts, closeMs: performance.now() - closeAt, abortAfterResultMs: record.abortAt - record.resultAt });
  }

  // FetchCleanup.tla Tail (97): >64 KiB after explicit model consumption.
  // EOF is offered after 30 ms so a timer-only implementation cannot pass by
  // aborting a stalled response after 100 ms instead of enforcing the byte cap.
  currentCase = "consumed HTTP tail exceeds 64 KiB";
  {
    const record = plan("capped-tail", currentCase);
    const agent = await newAgent();
    const turn = agent.prompt(record.input);
    await completedTurn(turn, record, readTurn(turn, record));
    const tail = `: ${"x".repeat(96 * 1024)}\n\n`;
    record.tailBytes = Buffer.byteLength(tail);
    record.tailAt = performance.now();
    record.response.write(tail);
    endAfterDelay(record);
    const closing = agent.close();
    await bounded(record.aborted.promise, check(record, ">64 KiB tail must abort before the offered 30 ms EOF"), cleanupBoundMs);
    assert.equal(record.response.writableEnded, false, check(record, "byte-limit abort must precede HTTP EOF"));
    assert.equal(record.aborts, 1);
    await closedAgent(agent, closing);
    await bounded(record.closed.promise, check(record, "byte-limit abort must close the server response"), cleanupBoundMs);
    passed("tail byte cap", { tailBytes: record.tailBytes, signalAborts: record.aborts, abortMs: record.abortAt - record.tailAt });
  }

  // FetchCleanup.tla Open (20) / LateCallback (109): one tool step changes the
  // native fetch handle. Broader tool semantics remain in test-host-tools.mjs;
  // this fixture only checks delayed cleanup cannot pollute the next POST.
  currentCase = "tool-step completion drains before the next POST";
  {
    const first = plan("tool-step", currentCase);
    const second = plan("tool-result", currentCase);
    const toolStarted = deferred();
    let toolCalls = 0;
    const agent = await newAgent({
      tools: [{
        name: "lookup", description: "Look up a fixture value.",
        inputSchema: { type: "object", properties: { key: { type: "string" } }, required: ["key"], additionalProperties: false },
        execute(input, { signal }) {
          assert.equal(signal.aborted, false);
          assert.deepEqual(input, { key: "alpha" });
          toolCalls++;
          toolStarted.resolve();
          return "value:alpha";
        },
      }],
    });
    const turn = agent.prompt(currentCase);
    const reading = readTurn(turn, second);
    await bounded(toolStarted.promise, "host tool after finish(tool-calls)");
    assert.equal(first.aborts, 0, "tool completion is successful consumption, not cancellation");
    // Bytes after finish must be discarded, never become text on the next handle.
    endAfterDelay(first, textFrame("STALE-FIRST-RESPONSE"));
    await bounded(second.posted.promise, "next POST after successful tool-step cleanup");
    assert.ok(first.endAt <= second.wireAt, "next POST must not overtake the first body's EOF");
    await completedTurn(turn, second, reading);
    const closing = agent.close();
    endAfterDelay(second);
    await closedAgent(agent, closing);
    assert.equal(toolCalls, 1);
    assert.equal(first.aborts, 0);
    assert.equal(second.aborts, 0);
    assert.equal(second.text, "OK", "late first-response text must not reach the next model step");
    passed("tool-step cleanup isolation", { posts: 2, toolCalls, signalAborts: 0 });
  }

  currentCase = "older addon without a consumed disposition keeps conservative abort";
  {
    const record = plan("legacy-addon", currentCase);
    let activeReads = 0;
    const wrapped = Object.assign(Object.create(native), {
      coreFetchDisposition: undefined,
      coreFetchConsumed() { throw new Error("an older addon must not compose a split observation"); },
      coreFetchActive(core, handle) {
        activeReads++;
        return native.coreFetchActive(core, handle);
      },
    });
    const agent = await newAgent({ nativeAddon: wrapped });
    const turn = agent.prompt(record.input);
    const reading = readTurn(turn, record);
    record.result = await bounded(turn.result, "legacy addon successful model result");
    await bounded(reading, "legacy addon event iterator");
    await bounded(record.aborted.promise, "legacy addon conservative fetch abort");
    assert.equal(record.result.stopReason, "end_turn");
    assert.equal(record.text, "OK");
    assert.ok(activeReads > 0, "missing disposition must use the existing active-only query");
    assert.equal(record.aborts, 1, "without an authoritative consumed query the old addon must abort, not infer success");
    assert.equal(record.response.writableEnded, false);
    await closedAgent(agent);
    await bounded(record.closed.promise, "legacy addon response release", cleanupBoundMs);
    passed("legacy addon fallback", { posts: 1, activeReads, signalAborts: record.aborts });
  }

  assert.equal(catalogCalls, 1, "one fake discovery must serve every fresh agent");
  assert.equal(clientPosts, 38);
  assert.equal(serverPosts, clientPosts);
  console.log(`native core real HTTP cleanup passed: ${results.length} cases, ${serverPosts} POSTs, fake credentials only`);
} catch (error) {
  // Preserve the first failing fixture input, wire frames and result without
  // headers, credentials, or a replacement oracle. Do not retry a failure.
  console.error("FIRST HTTP CLEANUP FAILURE", JSON.stringify({
    case: currentCase,
    expectation: error.message,
    passed: results,
    clientPosts, serverPosts,
    requests: requests.map((record) => ({
      id: record.id, mode: record.mode, input: record.input, socketId: record.socketId,
      frames: record.frames, text: record.text, result: record.result, aborts: record.aborts,
      signalAborted: record.signal?.aborted, httpEnded: record.response?.writableEnded,
      wireAt: record.wireAt, firstTextAt: record.firstTextAt, resultAt: record.resultAt,
      endAt: record.endAt, abortAt: record.abortAt, tailBytes: record.tailBytes, interleaving: record.interleaving,
    })),
  }));
  throw error;
} finally {
  for (const record of requests) clearTimeout(record.endTimer);
  // Release real server bodies first so failure cleanup cannot hang on a read.
  server.closeAllConnections();
  for (const agent of agents) await bounded(agent.close().catch(() => {}), "failure teardown", cleanupBoundMs).catch(() => {});
  await new Promise((done) => server.close(done));
}
