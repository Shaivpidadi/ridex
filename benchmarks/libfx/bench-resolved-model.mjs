#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { execFile, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { appendFile, mkdir, readFile, readdir, stat, writeFile } from "node:fs/promises";
import { arch, cpus, platform, release } from "node:os";
import { isAbsolute, resolve } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath, pathToFileURL } from "node:url";
import { parseArgs, promisify } from "node:util";

const script = fileURLToPath(import.meta.url);
const run = promisify(execFile);
const prompt = "Reply with exactly OK.";
const catalogUrl = "https://ai-gateway.vercel.sh/coding-agent/v1/models";
const chatUrl = "https://ai-gateway.vercel.sh/v4/ai/language-model";
const fakeKey = "resolved-model-benchmark-fixture-key";
const warmups = 3;
const timeoutMs = 120_000;
const outputLimit = 64 * 1024;
const metrics = [
  "launch_to_first_text_ms", "module_import_ms", "create_to_post_ms",
  "prompt_to_post_ms", "post_to_first_text_ms", "create_to_first_text_ms",
];
const frames = [
  { type: "text-delta", id: "answer", delta: "O" },
  { type: "text-delta", id: "answer", delta: "K" },
  { type: "finish", finishReason: { unified: "stop", raw: "stop" },
    usage: { inputTokens: { total: 3 }, outputTokens: { total: 2 } } },
].map(frame => `data: ${JSON.stringify(frame)}\n\n`).concat("data: [DONE]\n\n");
let interrupted = false;

const hash = value => createHash("sha256").update(value).digest("hex");
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
  }
  return value;
}
const jsonHash = value => hash(JSON.stringify(canonical(value)));
function plainModel(descriptor) {
  const { metadata, ...model } = descriptor;
  return model;
}
function apiKey(live) {
  if (!live) return fakeKey;
  const key = process.env.AI_GATEWAY_API_KEY;
  const testKey = process.env.AI_GATEWAY_TEST_API_KEY;
  if (!key?.trim() || !testKey?.trim() || key !== testKey) {
    throw new Error("Live runs require matching nonempty AI_GATEWAY_API_KEY and AI_GATEWAY_TEST_API_KEY; invoke through aig test");
  }
  return key;
}
function safeError(error) {
  let message = String(error?.message ?? "Unknown benchmark error");
  for (const secret of [process.env.AI_GATEWAY_API_KEY, process.env.AI_GATEWAY_TEST_API_KEY, fakeKey, prompt]) {
    if (secret) message = message.split(secret).join("[redacted]");
  }
  return {
    name: /^[A-Za-z]+$/.test(error?.name) ? error.name : "Error",
    code: /^[A-Za-z0-9_]+$/.test(error?.code) ? error.code : null,
    message: message.slice(0, 2048),
  };
}
function keyFree(value) {
  const text = JSON.stringify(value);
  for (const secret of [process.env.AI_GATEWAY_API_KEY, process.env.AI_GATEWAY_TEST_API_KEY, fakeKey]) {
    assert.ok(!secret || !text.includes(secret), "Artifact contains a credential");
  }
  return text;
}
const saveJson = (path, value) => writeFile(path, `${keyFree(value)}\n`, { mode: 0o600 });

function argumentsForRun() {
  const { values } = parseArgs({ options: {
    baseline: { type: "string" }, candidate: { type: "string" },
    backend: { type: "string" }, samples: { type: "string" },
    live: { type: "boolean", default: false }, model: { type: "string" },
    output: { type: "string" }, effort: { type: "string" }, fast: { type: "boolean" },
    "catalog-delay-ms": { type: "string", default: "0" },
    worker: { type: "boolean", default: false }, repo: { type: "string" }, mode: { type: "string" },
  } });
  assert.ok(["native", "wasm"].includes(values.backend), "--backend native|wasm is required");
  const delay = Number(values["catalog-delay-ms"]);
  assert.ok(Number.isSafeInteger(delay) && delay >= 0 && delay <= 30_000, "--catalog-delay-ms must be 0..30000");
  assert.ok(!values.live || delay === 0, "--catalog-delay-ms is a synthetic fixture option only");
  apiKey(values.live);
  if (values.worker) {
    assert.ok(values.repo && ["baseline", "resolved", "checkpoint"].includes(values.mode), "Worker requires --repo and --mode baseline|resolved|checkpoint");
    assert.ok(values.mode !== "checkpoint" || !values.live, "Checkpoint preparation must be synthetic");
    return { ...values, repo: resolve(values.repo), delay };
  }
  assert.ok(values.baseline && values.candidate && values.model, "--baseline, --candidate, and --model are required");
  assert.ok(values.output && isAbsolute(values.output), "--output must be an absolute directory");
  assert.ok(!values.live || values.samples !== undefined, "Live runs require explicit --samples (30 or more)");
  const samples = Number(values.samples ?? 50);
  assert.ok(Number.isSafeInteger(samples) && samples >= 30 && samples <= 1000, "--samples must be 30..1000 for p50/p95");
  const model = { id: values.model, ...(values.effort === undefined ? {} : { effort: values.effort }),
    ...(values.fast === undefined ? {} : { fast: values.fast }) };
  keyFree(model);
  return { ...values, baseline: resolve(values.baseline), candidate: resolve(values.candidate),
    output: resolve(values.output), samples, delay, model };
}

function syntheticCatalog(model) {
  return { object: "list", data: [{
    id: model.id, type: "language", tags: ["reasoning", "tool-use"],
    context_window: 131_072, max_tokens: 1234,
    reasoning_options: [{ type: "effort", values: [...new Set(["low", "medium", "high", "max", model.effort].filter(Boolean))] }],
    fast_options: [{ type: "toggle" }],
  }] };
}
function backendOptions(repo, backend) {
  return backend === "native"
    ? { backend, nativeAddon: resolve(repo, "zig-out/lib/libfx.node") }
    : { backend, wasm: resolve(repo, "zig-out/bin/fx-core.wasm") };
}
function requestInfo(input, init) {
  const url = String(input?.url ?? input);
  const method = String(init.method ?? input?.method ?? "GET").toUpperCase();
  return { url, method };
}
function gateway({ live, model, catalog, delay, userTurns }, state) {
  const nativeFetch = globalThis.fetch.bind(globalThis);
  const key = apiKey(live);
  return async (input, init = {}) => {
    const started = performance.now();
    const { url, method } = requestInfo(input, init);
    const headers = new Headers(init.headers ?? input?.headers);
    assert.ok(headers.get("authorization") === `Bearer ${key}`, "Unexpected Gateway credential");
    if (method === "GET") {
      const row = { endpoint: url, method, duration_ms: null, status: null };
      state.gets.push(row);
      assert.equal(url, catalogUrl, "Unexpected catalog endpoint");
      try {
        if (!live && delay) await new Promise(done => setTimeout(done, delay));
        const response = live ? await nativeFetch(input, init) : Response.json(catalog);
        row.status = response.status;
        return response;
      } finally { row.duration_ms = performance.now() - started; }
    }
    // Keep every attempted POST, including retries or requests rejected by the oracle.
    state.postAt ??= started;
    const row = { endpoint: url, method, status: null };
    state.posts.push(row);
    assert.equal(method, "POST", "Unexpected Gateway method");
    assert.equal(url, chatUrl, "Unexpected chat endpoint");
    const text = typeof init.body === "string" ? init.body : new TextDecoder().decode(init.body);
    const body = JSON.parse(text);
    const users = body.prompt?.filter(message => message.role === "user") ?? [];
    const lastUser = users.at(-1)?.content;
    const userText = typeof lastUser === "string" ? lastUser : lastUser?.map(part => part.text ?? "").join("");
    assert.equal(userText, prompt, "Request omitted the benchmark prompt");
    if (userTurns !== undefined) assert.equal(users.length, userTurns, "Checkpoint history was not restored exactly once");
    assert.ok(!body.tools?.length, "Benchmark must not advertise tools");
    assert.equal(headers.get("ai-language-model-id"), model.id, "Request selected a different model");
    assert.equal(headers.get("ai-language-model-streaming"), "true", "Expected a streaming POST");
    assert.ok(!text.includes(key), "Request body contains a credential");
    Object.assign(row, {
      model: headers.get("ai-language-model-id"),
      specification: headers.get("ai-language-model-specification-version"),
      streaming: headers.get("ai-language-model-streaming"),
      protocol: headers.get("ai-gateway-protocol-version"),
      content_type: headers.get("content-type"),
      body_sha256: jsonHash(body), request_bytes: Buffer.byteLength(text),
      max_output_tokens: body.maxOutputTokens ?? null, reasoning: body.reasoning ?? null,
      fast: body.providerOptions?.gateway?.speed ?? null,
      user_turns: users.length,
    });
    let response;
    if (live) response = await nativeFetch(input, init);
    else {
      let frame = 0;
      response = new Response(new ReadableStream({
        pull(controller) {
          if (frame === frames.length) return controller.close();
          controller.enqueue(new TextEncoder().encode(frames[frame++]));
        },
      }), { headers: { "content-type": "text/event-stream" } });
    }
    row.status = response.status;
    return response;
  };
}
function timings(state) {
  const between = (end, start) => end === null || start === null ? null : end - start;
  return {
    module_import_ms: state.importMs,
    create_to_post_ms: between(state.postAt, state.createAt),
    prompt_to_post_ms: between(state.postAt, state.promptAt),
    post_to_first_text_ms: between(state.firstTextAt, state.postAt),
    create_to_first_text_ms: between(state.firstTextAt, state.createAt),
  };
}
function transport(state) {
  return { get_count: state.gets.length, get_duration_ms: state.gets.reduce((n, get) => n + (get.duration_ms ?? 0), 0),
    gets: state.gets, post_count: state.posts.length, posts: state.posts };
}
function tokenUsage(usage) {
  return Object.fromEntries(Object.entries(usage ?? {}).filter(([, value]) => Number.isFinite(value)));
}

async function worker(options) {
  const state = { importMs: null, createAt: null, promptAt: null, postAt: null, firstTextAt: null, gets: [], posts: [] };
  let agent;
  let reply = "";
  let result;
  let checkpoint;
  let error;
  let stage = "stdin";
  try {
    let bytes = 0;
    const chunks = [];
    for await (const chunk of process.stdin) {
      bytes += chunk.length;
      assert.ok(bytes <= 8 * 1024 * 1024, "Worker fixture exceeds 8 MiB");
      chunks.push(chunk);
    }
    const fixture = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    const descriptor = fixture.descriptor;
    const model = options.mode === "resolved" ? descriptor : plainModel(descriptor);
    const catalog = fixture.catalog ?? syntheticCatalog(model);
    stage = "module-import";
    const importedAt = performance.now();
    const sdk = await import(pathToFileURL(resolve(options.repo, "sdk/node.js")).href);
    state.importMs = performance.now() - importedAt;
    const fetch = gateway({ live: options.live, model, catalog, delay: options.delay,
      userTurns: fixture.checkpoint ? 2 : 1 }, state);
    if (!options.live) globalThis.fetch = async () => { throw new Error("Uninjected synthetic fetch"); };
    const agentOptions = {
      ...backendOptions(options.repo, options.backend), apiKey: apiKey(options.live), model,
      gatewayChatUrl: chatUrl, fetch, instructions: prompt, tools: [],
      ...(fixture.checkpoint ? { checkpoint: Buffer.from(fixture.checkpoint, "base64") } : {}),
    };
    stage = "create";
    state.createAt = performance.now();
    agent = await sdk.createFxAgent(agentOptions);
    stage = "prompt";
    state.promptAt = performance.now();
    const turn = agent.prompt(prompt);
    for await (const event of turn) {
      assert.ok(!event.type.startsWith("tool_"), "Benchmark attempted tool execution");
      if (event.type !== "text_delta" || !event.delta) continue;
      if (state.firstTextAt === null) {
        state.firstTextAt = performance.now();
        // The parent timestamps this line as it arrives, not when the child exits.
        process.stdout.write(`${keyFree({ type: "first-text", timings_ms: timings(state), ...transport(state) })}\n`);
      }
      reply += event.delta;
      assert.ok(Buffer.byteLength(reply) <= outputLimit, "Reply exceeds benchmark limit");
    }
    result = await turn.result;
    assert.ok(reply.trim(), "Empty reply");
    assert.equal(result.stopReason, "end_turn", "Refused or incomplete result");
    assert.equal(state.posts.length, 1, "Expected exactly one chat POST");
    if (options.mode === "resolved") assert.equal(state.gets.length, 0, "Resolved model performed a catalog GET");
    if (!options.live) assert.equal(reply, "OK", "Synthetic text sentinel was lost");
    if (options.mode === "checkpoint") {
      stage = "checkpoint";
      if (typeof agent.checkpoint === "function") {
        const bytes = Buffer.from(await agent.checkpoint());
        assert.equal(bytes.subarray(0, 4).toString(), "FXCP", "Invalid checkpoint fixture");
        for (const secret of [fakeKey, process.env.AI_GATEWAY_API_KEY, process.env.AI_GATEWAY_TEST_API_KEY]) {
          assert.ok(!secret || !bytes.includes(Buffer.from(secret)), "Checkpoint contains a credential");
        }
        checkpoint = bytes.toString("base64");
      }
    }
    stage = "close";
  } catch (caught) { error = safeError(caught); }
  finally {
    try { await agent?.close(); }
    catch (caught) { error ??= safeError(caught); stage = "close"; }
  }
  const row = {
    type: "result", status: error ? "error" : "ok", stage, error: error ?? null,
    timings_ms: timings(state), ...transport(state),
    stop_reason: result?.stopReason ?? null, usage: tokenUsage(result?.usage), reply_bytes: Buffer.byteLength(reply),
    ...(options.mode === "checkpoint" ? { checkpoint: checkpoint ?? null } : {}),
  };
  process.stdout.write(`${keyFree(row)}\n`);
  process.exitCode = error ? 1 : 0;
}

async function execute(options, repo, mode, fixture) {
  const input = keyFree(fixture);
  const args = [...(options.backend === "wasm" ? ["--experimental-wasm-jspi"] : []), script,
    "--worker", "--repo", repo, "--mode", mode, "--backend", options.backend,
    "--catalog-delay-ms", String(mode === "checkpoint" ? 0 : options.delay),
    ...(options.live && mode !== "checkpoint" ? ["--live"] : [])];
  const launchedAt = performance.now();
  const child = spawn(process.execPath, args, { cwd: repo, env: process.env, stdio: ["pipe", "pipe", "pipe"] });
  let firstText;
  let received;
  let markerAt = null;
  let fault;
  let timedOut = false;
  let stdoutBytes = 0;
  let stderrBytes = 0;
  let killTimer;
  const terminate = () => {
    child.kill("SIGTERM");
    killTimer ??= setTimeout(() => child.kill("SIGKILL"), 1000);
  };
  const signal = () => { interrupted = true; terminate(); };
  process.once("SIGINT", signal);
  process.once("SIGTERM", signal);
  const timer = setTimeout(() => { timedOut = true; terminate(); }, timeoutMs);
  const lines = createInterface({ input: child.stdout });
  lines.on("line", line => {
    const observedAt = performance.now();
    try {
      const message = JSON.parse(line);
      if (message.type === "first-text") {
        assert.equal(markerAt, null, "Duplicate first-text marker");
        markerAt = observedAt;
        firstText = message;
      } else if (message.type === "result") {
        assert.equal(received, undefined, "Duplicate worker result");
        received = message;
      } else throw new Error("Unexpected worker stdout");
    } catch (error) { fault ??= safeError(error); terminate(); }
  });
  child.stdout.on("data", chunk => {
    stdoutBytes += chunk.length;
    if (stdoutBytes > outputLimit) { fault ??= safeError(new Error("Worker stdout exceeds limit")); terminate(); }
  });
  // Drain diagnostics without storing raw stderr, which can contain provider text.
  child.stderr.on("data", chunk => {
    stderrBytes += chunk.length;
    if (stderrBytes > outputLimit) { fault ??= safeError(new Error("Worker stderr exceeds limit")); terminate(); }
  });
  child.stdin.on("error", error => { fault ??= safeError(error); });
  child.stdin.end(input);
  const exit = await new Promise(done => {
    child.once("error", error => { fault ??= safeError(error); });
    child.once("close", (code, signal) => done({ code, signal }));
  });
  clearTimeout(timer);
  clearTimeout(killTimer);
  process.removeListener("SIGINT", signal);
  process.removeListener("SIGTERM", signal);
  lines.close();
  const row = received ?? firstText ?? { timings_ms: {}, get_count: 0, post_count: 0, gets: [], posts: [] };
  const { type, ...data } = row;
  const error = fault ?? received?.error ?? (timedOut ? safeError(new Error("Worker timed out")) :
    exit.code !== 0 || !received ? safeError(new Error("Worker exited without a successful result")) :
    markerAt === null || stderrBytes ? safeError(new Error("Missing first-text marker or unexpected stderr")) : null);
  return { ...data, mode, repo, status: timedOut ? "timeout" : error ? "error" : data.status,
    error, exit_code: exit.code, signal: exit.signal, stdout_bytes: stdoutBytes, stderr_bytes: stderrBytes,
    timings_ms: { ...data.timings_ms, launch_to_first_text_ms: markerAt === null ? null : markerAt - launchedAt } };
}

async function repoEvidence(repo, backend) {
  const git = async args => (await run("git", ["-C", repo, ...args], { encoding: "buffer", maxBuffer: 64 * 1024 * 1024 })).stdout;
  const sha = (await git(["rev-parse", "HEAD"])).toString().trim();
  const status = (await git(["status", "--porcelain=v1", "-z"])).toString().split("\0").filter(Boolean);
  const dirty = createHash("sha256").update(await git(["diff", "--binary", "HEAD", "--", "."]));
  const untracked = (await git(["ls-files", "--others", "--exclude-standard", "-z"])).toString().split("\0").filter(Boolean).sort();
  for (const path of untracked) dirty.update(path).update("\0").update(await readFile(resolve(repo, path)));
  const assetPath = backend === "native" ? "zig-out/lib/libfx.node" : "zig-out/bin/fx-core.wasm";
  const asset = await readFile(resolve(repo, assetPath));
  const assetStat = await stat(resolve(repo, assetPath));
  const build = await readFile(resolve(repo, "build.zig"), "utf8");
  const owner = build.split(backend === "native" ? "fn addNapiArtifact(" : "fn addWasmArtifact(")[1]?.split("\nfn ")[0];
  const mode = owner?.match(/\.optimize\s*=\s*\.(\w+)/)?.[1];
  assert.equal(mode, backend === "native" ? "ReleaseSafe" : "ReleaseSmall", "Unexpected backend build mode");
  return {
    repo, target_sha: sha, dirty_status: status, dirty_diff_sha256: dirty.digest("hex"),
    build_mode: mode, build_mode_evidence: "Hardcoded build.zig backend definition; caller must freshly build artifacts",
    build_zig_sha256: hash(build), asset: { path: assetPath, bytes: asset.length, sha256: hash(asset), modified_at: assetStat.mtime.toISOString() },
    sdk: Object.fromEntries(await Promise.all(["sdk/node.js", "sdk/fx-sdk.js"].map(async path => [path, hash(await readFile(resolve(repo, path)))]))),
  };
}
function distribution(values) {
  const sorted = values.filter(Number.isFinite).sort((a, b) => a - b);
  if (!sorted.length) return { count: 0 };
  const percentile = fraction => sorted[Math.ceil(sorted.length * fraction) - 1];
  return { count: sorted.length, p50: percentile(0.5), p95: percentile(0.95),
    ...(sorted.length >= 100 ? { p99: percentile(0.99) } : {}), min: sorted[0], max: sorted.at(-1) };
}
function countHistogram(values) {
  const counts = {};
  for (const value of values) counts[value ?? "missing"] = (counts[value ?? "missing"] ?? 0) + 1;
  return counts;
}
function summary(rows, samples) {
  const measured = rows.filter(row => row.phase === "measured");
  const modes = Object.fromEntries(["baseline", "resolved"].map(mode => {
    const attempts = measured.filter(row => row.mode === mode);
    return [mode, {
      planned: samples, attempted: attempts.length, ok: attempts.filter(row => row.status === "ok").length,
      errors: attempts.filter(row => row.status === "error").length, timeouts: attempts.filter(row => row.status === "timeout").length,
      timings_ms: Object.fromEntries(metrics.map(metric => [metric, {
        ...distribution(attempts.map(row => row.timings_ms?.[metric])),
        missing: attempts.filter(row => !Number.isFinite(row.timings_ms?.[metric])).length,
        failed_with_value: attempts.filter(row => row.status !== "ok" && Number.isFinite(row.timings_ms?.[metric])).length,
      }])),
      get_counts: countHistogram(attempts.map(row => row.get_count)), post_counts: countHistogram(attempts.map(row => row.post_count)),
      get_duration_ms: distribution(attempts.map(row => row.get_duration_ms)),
    }];
  }));
  const pairs = Array.from({ length: samples }, (_, pair) => measured.filter(row => row.pair === pair));
  const valid = pairs.filter(pair => pair.length === 2 && pair.every(row => row.status === "ok"));
  return {
    modes, paired_valid: valid.length, paired_missing_or_failed: samples - valid.length,
    paired_delta_ms_candidate_minus_baseline: Object.fromEntries(metrics.map(metric => [metric, distribution(valid.map(pair =>
      pair.find(row => row.mode === "resolved").timings_ms[metric] - pair.find(row => row.mode === "baseline").timings_ms[metric]))])),
    warmup_attempts: rows.filter(row => row.phase === "warmup").length,
    warmup_failures: rows.filter(row => row.phase === "warmup" && row.status !== "ok").length,
    statistics: "Nearest-rank percentiles; p99 only at count >= 100. All available failed-attempt timings are included and counted; missing values remain explicit. Paired deltas use successful equivalent pairs only.",
  };
}
function assertPair(pair) {
  if (pair.length !== 2 || pair.some(row => row.status !== "ok")) return;
  try {
    const signature = row => row.posts.map(({ status, ...request }) => request);
    assert.deepEqual(signature(pair[0]), signature(pair[1]), "Baseline and candidate POST endpoint/method/body/options differ");
    for (const row of pair) for (const metric of metrics) {
      assert.ok(Number.isFinite(row.timings_ms[metric]) && row.timings_ms[metric] >= 0, `Missing or invalid ${metric}`);
    }
  } catch (error) {
    for (const row of pair) { row.status = "error"; row.error = safeError(error); }
  }
}

async function driver(options) {
  await mkdir(options.output, { recursive: true, mode: 0o700 });
  // Refuse accidental artifact reuse instead of overwriting an earlier experiment.
  assert.equal((await readdir(options.output)).length, 0, "--output must be a new or empty directory");
  await writeFile(resolve(options.output, "rows.jsonl"), "", { flag: "wx", mode: 0o600 });
  const manifestPath = resolve(options.output, "manifest.json");
  const rows = [];
  const manifest = {
    format_version: 1, status: "preparing", started_at: new Date().toISOString(),
    evidence_scope: "Local serial fresh Node processes, not deployed functions; warmups warm OS caches, not a shared runtime",
    command: [process.execPath, script, ...process.argv.slice(2)],
    backend: options.backend, live: options.live, samples_per_mode: options.samples, warmups_per_mode: warmups,
    order: "Paired alternating: baseline/resolved on even pairs, resolved/baseline on odd pairs",
    timeout_ms: timeoutMs, concurrency: 1,
    host: { os: platform(), release: release(), architecture: arch(), cpu: cpus()[0]?.model, node: process.version },
    credential_source: options.live ? "Inherited matching AI_GATEWAY_API_KEY and AI_GATEWAY_TEST_API_KEY via aig test" : "Synthetic literal; no network",
    boundaries: { launch_to_first_text_ms: "Parent spawn invocation to receipt of child first-text stdout marker (includes startup and pipe observation)",
      create_to_post_ms: "createFxAgent call to first POST fetch entry, including checkpoint restore",
      prompt_to_post_ms: "agent.prompt call to first POST fetch entry",
      post_to_first_text_ms: "First POST fetch entry to first nonempty text_delta",
      create_to_first_text_ms: "createFxAgent call to first nonempty text_delta",
      module_import_ms: "Dynamic import of sdk/node.js in each child",
      get_duration_ms: "Sum of GET fetch entry to response headers, including synthetic catalog delay, not JSON parsing/body consumption" },
    artifacts: ["manifest.json", "descriptor.json", "fixture.json", "rows.jsonl", "summary.json"],
  };
  let error;
  try {
    await saveJson(manifestPath, manifest);
    try { manifest.host.zig = (await run("zig", ["version"])).stdout.trim(); }
    catch { manifest.host.zig = "unavailable"; }
    manifest.targets = {
      baseline: await repoEvidence(options.baseline, options.backend),
      candidate: await repoEvidence(options.candidate, options.backend),
    };
    assert.notEqual(options.baseline, options.candidate, "Baseline and candidate must be different worktrees");
    assert.equal(manifest.targets.baseline.dirty_status.length, 0, "Baseline must be untouched (clean git status)");
    const catalog = syntheticCatalog(options.model);
    const discovery = { gets: [], posts: [], postAt: null };
    const fetch = gateway({ live: options.live, model: options.model, catalog, delay: options.delay }, discovery);
    const importAt = performance.now();
    const sdk = await import(pathToFileURL(resolve(options.candidate, "sdk/node.js")).href);
    manifest.preparation = { module_import_ms: performance.now() - importAt };
    assert.equal(typeof sdk.resolveModel, "function", "Candidate SDK is missing resolveModel()");
    const resolveAt = performance.now();
    const descriptor = JSON.parse(JSON.stringify(await sdk.resolveModel({ apiKey: apiKey(options.live), model: options.model, fetch })));
    assert.equal(descriptor.metadata?.version, 1, "Expected version 1 serializable model metadata");
    assert.deepEqual(plainModel(descriptor), options.model, "resolveModel changed requested model options");
    Object.assign(manifest.preparation, { resolve_ms: performance.now() - resolveAt, ...transport(discovery) });
    assert.equal(discovery.posts.length, 0, "Discovery must not send a chat POST");
    await saveJson(resolve(options.output, "descriptor.json"), descriptor);
    // Checkpoint construction always uses the fake key and fake stream, even in live mode.
    const prepared = await execute(options, options.candidate, "checkpoint", { descriptor: plainModel(descriptor), catalog });
    let checkpoint = prepared.status === "ok" ? prepared.checkpoint : null;
    manifest.checkpoint = checkpoint ? { kind: "restored", bytes: Buffer.from(checkpoint, "base64").length,
      sha256: hash(Buffer.from(checkpoint, "base64")), preparation: "One synthetic candidate turn, no live model call" } :
      { kind: "first-turn", reason: prepared.error ?? "Checkpoint API unavailable" };
    if (checkpoint) {
      await writeFile(resolve(options.output, "checkpoint.bin"), Buffer.from(checkpoint, "base64"), { mode: 0o600 });
      manifest.artifacts.push("checkpoint.bin");
    }
    const fixture = { descriptor, checkpoint, catalog };
    const fixtureEvidence = {
      model: plainModel(descriptor), descriptor_sha256: jsonHash(descriptor),
      prompt_sha256: hash(prompt), prompt_bytes: Buffer.byteLength(prompt), instructions_sha256: hash(prompt), tools: [],
      catalog: options.live ? { source: "Live Gateway", selected_sha256: jsonHash(descriptor.metadata.data) } :
        { source: "Synthetic", sha256: jsonHash(catalog), data: catalog, delay_ms: options.delay },
      synthetic_stream_sha256: hash(frames.join("")), checkpoint: manifest.checkpoint,
    };
    manifest.fixture_sha256 = jsonHash(fixtureEvidence);
    await saveJson(resolve(options.output, "fixture.json"), fixtureEvidence);
    manifest.status = "running";
    await saveJson(manifestPath, manifest);
    for (const phase of ["warmup", "measured"]) {
      for (let pair = 0; pair < (phase === "warmup" ? warmups : options.samples); pair++) {
        const order = pair % 2 === 0 ? ["baseline", "resolved"] : ["resolved", "baseline"];
        const completed = [];
        for (const mode of order) {
          if (interrupted) break;
          const repo = mode === "baseline" ? options.baseline : options.candidate;
          completed.push({ ...await execute(options, repo, mode, fixture), phase, pair, order });
        }
        assertPair(completed);
        for (const row of completed) {
          if (phase === "warmup") row.timings_ms = null;
          rows.push(row);
          await appendFile(resolve(options.output, "rows.jsonl"), `${keyFree(row)}\n`);
        }
        assert.ok(!interrupted, "Benchmark interrupted; retained attempted rows");
      }
    }
    manifest.targets_after = {
      baseline: await repoEvidence(options.baseline, options.backend),
      candidate: await repoEvidence(options.candidate, options.backend),
    };
    assert.deepEqual(manifest.targets_after, manifest.targets, "Repository or assets changed during measurement");
    manifest.status = rows.every(row => row.status === "ok") ? "ok" : "error";
  } catch (caught) {
    error = safeError(caught);
    manifest.status = "error";
    manifest.error = error;
  }
  manifest.finished_at = new Date().toISOString();
  const report = { format_version: 1, status: manifest.status, evidence_scope: manifest.evidence_scope,
    backend: options.backend, live: options.live, error: error ?? null, ...summary(rows, options.samples) };
  await saveJson(manifestPath, manifest);
  await saveJson(resolve(options.output, "summary.json"), report);
  process.stdout.write(`${keyFree(report)}\n`);
  process.exitCode = manifest.status === "ok" ? 0 : 1;
}

try {
  const options = argumentsForRun();
  if (options.worker) await worker(options);
  else await driver(options);
} catch (error) {
  process.stderr.write(`${keyFree({ status: "error", error: safeError(error) })}\n`);
  process.exitCode = 1;
}
