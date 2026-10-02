#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createFxAgent, resolveModel, supportsJspi } from "../node.js";
import { resolveModel as resolveBrowserModel } from "../browser.js";
import { createFxAgent as createSharedAgent } from "../fx-sdk.js";

const backend = process.argv[2] || "native";
if (!new Set(["native", "wasm", "discovery"]).has(backend)) {
  throw new Error("usage: test-resolved-model.mjs [native|wasm|discovery] [--cold-child]");
}
const scriptPath = fileURLToPath(import.meta.url);
const repoRoot = fileURLToPath(new URL("../..", import.meta.url));
const apiKey = "resolved-model-fixture-key";
const modelId = "sdk/resolved-model";
const plainId = "sdk/plain-model";
const catalogUrl = "https://ai-gateway.vercel.sh/coding-agent/v1/models";
const gatewayChatUrl = "http://127.0.0.1:43210/chat";
const defaultChatUrl = "https://ai-gateway.vercel.sh/v4/ai/language-model";
const pngData = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP0cAAAAASUVORK5CYII=";
const selectedRow = {
  id: modelId,
  type: "language",
  tags: ["reasoning", "tool-use", "vision", "file-input"],
  reasoning_options: [{ type: "effort", values: ["low", "high"] }],
  fast_options: [{ type: "toggle" }],
  context_window: 131_072,
  max_tokens: 1234,
};
const catalog = { object: "list", data: [
  { ...selectedRow, name: "Ignored display name" },
  { id: plainId, type: "language" },
  { id: modelId, type: "image" },
] };
const clone = (value) => JSON.parse(JSON.stringify(value));
const encoder = new TextEncoder();
const decoder = new TextDecoder();

// A missing injected fetch must fail locally, never call a real Gateway.
globalThis.fetch = async () => { throw new Error("resolved-model test attempted an uninjected fetch"); };

function mockGateway({ allowCatalog = false, data = catalog, key = apiKey, chatUrl = gatewayChatUrl } = {}) {
  const state = { get: 0, post: 0, chatBodies: [], events: [] };
  const fetch = async (input, init = {}) => {
    const url = String(input?.url ?? input);
    const method = String(init.method ?? input?.method ?? "GET").toUpperCase();
    assert.equal(new Headers(init.headers).get("authorization"), `Bearer ${key}`);
    if (method === "GET") {
      state.get += 1;
      assert.equal(url, catalogUrl);
      assert.ok(allowCatalog, "descriptor consumption must not discover models");
      return Response.json(data);
    }
    state.post += 1;
    assert.equal(method, "POST");
    assert.equal(url, chatUrl);
    state.chatBodies.push(JSON.parse(typeof init.body === "string" ? init.body : decoder.decode(init.body)));
    return new Response(encoder.encode([
      'data: {"type":"text-delta","delta":"ok"}',
      'data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"},"usage":{"inputTokens":{"total":3},"outputTokens":{"total":2}}}',
      "data: [DONE]",
      "",
    ].join("\n\n")), { headers: { "content-type": "text/event-stream" } });
  };
  return { state, fetch, onEvent: (event) => state.events.push(structuredClone(event)) };
}

function typedError(code, model = modelId, capability = "modelMetadata") {
  return (error) => {
    assert.ok(error instanceof Error);
    assert.equal(error.code, code);
    assert.equal(error.model, model);
    assert.equal(error.capability, capability);
    assert.ok(!error.message.includes(apiKey), "errors must not include the credential");
    return true;
  };
}

async function discover(resolveFn = resolveModel, model = { id: modelId, effort: "high", fast: true }, overrides = {}) {
  const gateway = mockGateway({ allowCatalog: true, ...overrides });
  const descriptor = await resolveFn({ apiKey, model, gatewayChatUrl, fetch: gateway.fetch });
  assert.equal(gateway.state.get, 1, "discovery must perform one explicit models GET");
  assert.equal(gateway.state.post, 0);
  return descriptor;
}

async function testDiscovery() {
  for (const [surface, resolveFn] of [["node", resolveModel], ["browser", resolveBrowserModel]]) {
    const before = Date.now();
    const descriptor = await discover(resolveFn);
    const after = Date.now();
    assert.equal(descriptor.id, modelId);
    assert.equal(descriptor.effort, "high");
    assert.equal(descriptor.fast, true);
    assert.equal(descriptor.metadata.version, 1);
    assert.ok(Number.isSafeInteger(descriptor.metadata.resolvedAt));
    assert.ok(descriptor.metadata.resolvedAt >= before && descriptor.metadata.resolvedAt <= after);
    assert.ok(Number.isSafeInteger(descriptor.metadata.expiresAt));
    assert.ok(descriptor.metadata.expiresAt > descriptor.metadata.resolvedAt);
    assert.match(descriptor.metadata.scope, /^[a-f0-9]{64}$/);
    assert.equal(descriptor.metadata.scope, createHash("sha256")
      .update(JSON.stringify([catalogUrl, gatewayChatUrl, apiKey])).digest("hex"));
    assert.deepEqual(descriptor.metadata.data, [selectedRow], `${surface} must retain only selected language metadata`);
    assert.deepEqual(clone(descriptor), descriptor, "descriptor must survive JSON serialization without hidden state");
    assert.ok(!JSON.stringify(descriptor).includes(apiKey));

    const stringDescriptor = await discover(resolveFn, modelId);
    assert.equal(stringDescriptor.id, modelId);
    assert.ok(!Object.hasOwn(stringDescriptor, "effort"));
    assert.ok(!Object.hasOwn(stringDescriptor, "fast"));
    assert.equal(stringDescriptor.metadata.scope, descriptor.metadata.scope);

    const defaultGateway = mockGateway({ allowCatalog: true });
    const defaultDescriptor = await resolveFn({ apiKey, model: modelId, fetch: defaultGateway.fetch });
    assert.equal(defaultGateway.state.get, 1);
    assert.equal(defaultDescriptor.metadata.scope, createHash("sha256")
      .update(JSON.stringify([catalogUrl, defaultChatUrl, apiKey])).digest("hex"));
    assert.notEqual(defaultDescriptor.metadata.scope, descriptor.metadata.scope, "chat endpoint must bind the scope");
    const otherKey = "other-resolved-model-fixture-key";
    const otherGateway = mockGateway({ allowCatalog: true, key: otherKey });
    const otherDescriptor = await resolveFn({ apiKey: otherKey, model: modelId, gatewayChatUrl, fetch: otherGateway.fetch });
    assert.notEqual(otherDescriptor.metadata.scope, descriptor.metadata.scope, "explicit credential must bind the scope");

    const invalidInputGateway = mockGateway({ allowCatalog: true });
    for (const options of [{}, { apiKey }, { apiKey, model: "" }, { apiKey, model: { id: modelId, fast: "yes" } }]) {
      await assert.rejects(resolveFn({ ...options, fetch: invalidInputGateway.fetch }), TypeError);
    }
    assert.equal(invalidInputGateway.state.get, 0, "invalid discovery inputs must have no effect");
    assert.equal(invalidInputGateway.state.post, 0);

    for (const [name, response, errorCheck] of [
      ["malformed JSON", () => new Response("{"), TypeError],
      ["missing data", () => Response.json({ object: "list" }), TypeError],
      ["empty catalog", () => Response.json({ data: [] }), typedError("LIBFX_MODEL_METADATA_INVALID")],
      ["missing selected model", () => Response.json({ data: [{ id: plainId, type: "language" }] }), typedError("LIBFX_MODEL_METADATA_INVALID")],
      ["non-language model", () => Response.json({ data: [{ id: modelId, type: "image" }] }), typedError("LIBFX_MODEL_METADATA_INVALID")],
      ["oversize catalog", () => new Response("{}", { headers: { "content-length": String(4 * 1024 * 1024 + 1) } }), RangeError],
      ["oversize selected metadata", () => Response.json({ data: [{ ...selectedRow, tags: ["x".repeat(64 * 1024)] }] }), RangeError],
    ]) {
      let gets = 0;
      await assert.rejects(resolveFn({ apiKey, model: modelId, gatewayChatUrl, fetch: async (url, init) => {
        gets += 1;
        assert.equal(String(url), catalogUrl);
        assert.equal(init.method, "GET");
        return response();
      } }), errorCheck, `${surface}: ${name}`);
      assert.equal(gets, 1);
    }
  }

  const descriptor = await discover();
  const invalid = typedError("LIBFX_MODEL_METADATA_INVALID");
  const expired = typedError("LIBFX_MODEL_METADATA_EXPIRED");
  for (const [name, change, check = invalid, overrides = {}] of [
    ["null metadata", (d) => { d.metadata = null; }],
    ["array metadata", (d) => { d.metadata = []; }],
    ["unknown version", (d) => { d.metadata.version = 2; }],
    ["invalid resolution time", (d) => { d.metadata.resolvedAt = NaN; }],
    ["future resolution time", (d) => { d.metadata.resolvedAt = Date.now() + 60_000; d.metadata.expiresAt = d.metadata.resolvedAt + 60_000; }],
    ["invalid expiry", (d) => { d.metadata.expiresAt = String(d.metadata.expiresAt); }],
    ["invalid scope", (d) => { d.metadata.scope = "not-a-sha256"; }],
    ["empty selected rows", (d) => { d.metadata.data = []; }],
    ["malformed selected row", (d) => { d.metadata.data = [null]; }],
    ["mismatched selected row", (d) => { d.metadata.data[0].id = plainId; }],
    ["mismatched configured ID", (d) => { d.id = plainId; }, typedError("LIBFX_MODEL_METADATA_INVALID", plainId)],
    ["non-language selected row", (d) => { d.metadata.data[0].type = "image"; }],
    ["too many selected rows", (d) => { d.metadata.data = Array.from({ length: 65 }, () => clone(selectedRow)); }],
    ["oversize selected rows", (d) => { d.metadata.data[0].tags = ["x".repeat(64 * 1024)]; }, RangeError],
    ["cyclic selected row", (d) => { d.metadata.data[0].tags = d.metadata.data; }],
    ["expired metadata", (d) => { d.metadata.resolvedAt = Date.now() - 2000; d.metadata.expiresAt = Date.now() - 1; }, expired],
    ["wrong credential", () => {}, invalid, { apiKey: "other-resolved-model-fixture-key" }],
    ["wrong endpoint", () => {}, invalid, { gatewayChatUrl: "http://127.0.0.1:43211/chat" }],
  ]) {
    const candidate = clone(descriptor);
    change(candidate);
    const gateway = mockGateway();
    let runtimes = 0;
    await assert.rejects(createSharedAgent({
      apiKey, model: candidate, gatewayChatUrl, fetch: gateway.fetch, onEvent: gateway.onEvent, ...overrides,
      runtimeFactory() { runtimes += 1; throw new Error("invalid descriptor started a runtime"); },
    }), check, name);
    assert.equal(runtimes, 0, `${name}: reject before runtime construction`);
    assertNoTransport(gateway);
    assert.equal(gateway.state.events.length, 0, `${name}: reject before ACP initialization`);
  }
  const oldDescriptor = clone(descriptor);
  oldDescriptor.metadata.resolvedAt = Date.now() - 2000;
  oldDescriptor.metadata.expiresAt = Date.now() - 1;
  const refreshed = await discover(resolveModel, oldDescriptor);
  assert.equal(refreshed.id, modelId);
  assert.equal(refreshed.effort, descriptor.effort);
  assert.equal(refreshed.fast, descriptor.fast);
  assert.ok(refreshed.metadata.expiresAt > oldDescriptor.metadata.expiresAt);
  let finish, handler;
  const requests = [];
  const unsupportedGateway = mockGateway();
  const oldRuntime = {
    exited: new Promise(done => { finish = done; }),
    setLineHandler(value) { handler = value; },
    write(line) {
      const message = JSON.parse(line);
      requests.push(message.method);
      queueMicrotask(() => handler({ id: message.id, result: { agentCapabilities: {} } }));
    },
    abortHostEffects() {},
    closeStdin() { finish(0); },
  };
  await assert.rejects(createSharedAgent({ apiKey, model: descriptor, gatewayChatUrl,
    fetch: unsupportedGateway.fetch, runtimeFactory: async () => oldRuntime }),
    typedError("LIBFX_MODEL_METADATA_UNSUPPORTED"));
  assert.deepEqual(requests, ["initialize"], "unsupported core must reject before session creation or POST");
  assertNoTransport(unsupportedGateway);
  console.log("Node and browser resolved-model discovery and admission passed");
}

function assertNoTransport(gateway) {
  assert.equal(gateway.state.get, 0, "descriptor consumption must issue zero models GETs");
  assert.equal(gateway.state.post, 0, "rejection must not issue a chat POST");
  assert.equal(gateway.state.events.filter((event) => event.type === "transport.start").length, 0);
}

async function backendOptions() {
  if (backend === "wasm") {
    if (!supportsJspi()) throw new Error("Node JSPI is disabled. Run with --experimental-wasm-jspi");
    return { backend, wasm: await readFile(resolve(repoRoot, "zig-out/bin/fx-core.wasm")) };
  }
  return { backend, nativeAddon: resolve(repoRoot, "zig-out/lib/libfx.node") };
}

function optionsFor(base, gateway, model, overrides = {}) {
  return { ...base, apiKey, model, gatewayChatUrl, fetch: gateway.fetch, onEvent: gateway.onEvent, ...overrides };
}

async function runPrompt(agent, input = "say ok") {
  const turn = agent.prompt(input);
  let text = "";
  for await (const event of turn) if (event.type === "text_delta") text += event.delta;
  const result = await turn.result;
  assert.equal(result.stopReason, "end_turn");
  assert.equal(text.trim(), "ok");
  return text.trim();
}

function messages(gateway, method) {
  return gateway.state.events.filter((event) => event.type === "acp.send" && event.message.method === method)
    .map((event) => event.message);
}

function assertEnvelope(envelope, descriptor) {
  assert.equal(envelope.model, descriptor.id);
  assert.equal(envelope.revision, String(descriptor.metadata.resolvedAt));
  assert.deepEqual(envelope.data, descriptor.metadata.data);
  assert.ok(envelope.validForMs > 0 && envelope.validForMs <= descriptor.metadata.expiresAt - descriptor.metadata.resolvedAt);
  assert.ok(!JSON.stringify(envelope).includes(apiKey));
}

function assertRequest(body) {
  assert.equal(body.reasoning, "high");
  assert.equal(body.providerOptions?.gateway?.speed, "fast");
  assert.equal(body.maxOutputTokens, selectedRow.max_tokens);
}

function fileParts(body) {
  return body.prompt.flatMap((message) => Array.isArray(message.content) ? message.content : [])
    .filter((part) => part.type === "file");
}

async function testRuntime() {
  const base = await backendOptions();
  const descriptor = await discover();
  const savedDescriptor = clone(descriptor);
  const gateway = mockGateway();
  let agent;
  let restored;
  try {
    agent = await createFxAgent(optionsFor(base, gateway, descriptor));
    assertNoTransport(gateway);
    const libfx = messages(gateway, "initialize")[0]?.params.clientCapabilities.libfx;
    assert.equal(libfx?.modelMetadata, true);
    assertEnvelope(libfx.initialModelMetadata, savedDescriptor);

    // Mutate every capability-bearing layer after creation; the agent owns its snapshot.
    descriptor.id = plainId;
    descriptor.effort = "low";
    descriptor.fast = false;
    descriptor.metadata.expiresAt = 0;
    descriptor.metadata.scope = "invalid";
    descriptor.metadata.data[0].id = plainId;
    descriptor.metadata.data[0].tags.length = 0;
    descriptor.metadata.data[0].reasoning_options[0].values.length = 0;
    descriptor.metadata.data[0].fast_options.length = 0;
    descriptor.metadata.data[0].max_tokens = 1;
    await runPrompt(agent, [
      { type: "text", text: "remember this image" },
      { type: "image", data: pngData, mimeType: "image/png" },
    ]);
    assert.equal(gateway.state.get, 0);
    assert.equal(gateway.state.post, 1);
    assertRequest(gateway.state.chatBodies[0]);
    assert.deepEqual(fileParts(gateway.state.chatBodies[0]), [
      { type: "file", mediaType: "image/png", data: { type: "data", data: pngData } },
    ]);
    assertEnvelope(messages(gateway, "session/prompt")[0].params.modelMetadata, savedDescriptor);

    // An unrelated discovery in the same process must not replace this agent's metadata.
    await discover(resolveModel, plainId, { data: { data: [{ id: plainId, type: "language", max_tokens: 7 }] } });
    await runPrompt(agent, "continue after unrelated discovery");
    assert.equal(gateway.state.get, 0);
    assert.equal(gateway.state.post, 2);
    assertRequest(gateway.state.chatBodies[1]);
    assertEnvelope(messages(gateway, "session/prompt")[1].params.modelMetadata, savedDescriptor);
    const checkpoint = await agent.checkpoint();
    assert.ok(checkpoint instanceof Uint8Array && checkpoint.length > 44);
    assert.equal(decoder.decode(checkpoint.subarray(0, 4)), "FXCP");
    await agent.close();
    agent = null;

    // FXCP holds history and usage, not model provenance; the new descriptor supplies capabilities.
    const restoredGateway = mockGateway();
    restored = await createFxAgent(optionsFor(base, restoredGateway, clone(savedDescriptor), { checkpoint }));
    assertNoTransport(restoredGateway);
    assert.equal(messages(restoredGateway, "libfx/restore").length, 1);
    assertEnvelope(messages(restoredGateway, "initialize")[0].params.clientCapabilities.libfx.initialModelMetadata, savedDescriptor);
    await runPrompt(restored, "continue from checkpoint");
    assert.equal(restoredGateway.state.get, 0);
    assert.equal(restoredGateway.state.post, 1);
    const body = restoredGateway.state.chatBodies[0];
    assertRequest(body);
    assert.deepEqual(fileParts(body), [{ type: "file", mediaType: "image/png", data: { type: "data", data: pngData } }]);
    const textParts = body.prompt.flatMap((message) => Array.isArray(message.content) ? message.content : [])
      .filter((part) => part.type === "text").map((part) => part.text).join("\n");
    for (const text of ["remember this image", "continue after unrelated discovery", "continue from checkpoint"]) {
      assert.equal(textParts.split(text).length - 1, 1, `restored history must include ${text} exactly once`);
    }
    assertEnvelope(messages(restoredGateway, "session/prompt")[0].params.modelMetadata, savedDescriptor);
  } finally {
    await agent?.close();
    await restored?.close();
  }

  const plainDescriptor = await discover(resolveModel, plainId);
  for (const [model, code, capability] of [
    [{ ...savedDescriptor, effort: "max" }, "LIBFX_MODEL_UNSUPPORTED_EFFORT", "effort"],
    [{ ...plainDescriptor, effort: "high" }, "LIBFX_MODEL_UNSUPPORTED_EFFORT", "effort"],
    [{ ...plainDescriptor, fast: true }, "LIBFX_MODEL_UNSUPPORTED_FAST", "fast"],
  ]) {
    const rejectedGateway = mockGateway();
    await assert.rejects(createFxAgent(optionsFor(base, rejectedGateway, clone(model))), typedError(code, model.id, capability));
    assertNoTransport(rejectedGateway);
  }

  const noVisionGateway = mockGateway();
  const noVisionAgent = await createFxAgent(optionsFor(base, noVisionGateway, plainDescriptor));
  try {
    await assert.rejects(runPrompt(noVisionAgent, [{ type: "image", data: pngData, mimeType: "image/png" }]),
      /Image prompts are unavailable for the selected model/);
    assertNoTransport(noVisionGateway);
  } finally { await noVisionAgent.close(); }

  const expiryGateway = mockGateway();
  const expiryAgent = await createFxAgent(optionsFor(base, expiryGateway, clone(savedDescriptor)));
  const realNow = Date.now;
  try {
    Date.now = () => savedDescriptor.metadata.expiresAt;
    await assert.rejects(runPrompt(expiryAgent), typedError("LIBFX_MODEL_METADATA_EXPIRED"));
    assertNoTransport(expiryGateway);
    assert.equal(messages(expiryGateway, "session/prompt").length, 0, "absolute expiry rejects before ACP prompt send");
  } finally {
    Date.now = realNow;
    await expiryAgent.close();
  }

  // Legacy string mode still discovers through the core on its first prompt.
  const legacyGateway = mockGateway({ allowCatalog: true });
  const legacyAgent = await createFxAgent(optionsFor(base, legacyGateway, modelId));
  try {
    assert.equal(legacyGateway.state.get, 0);
    await runPrompt(legacyAgent);
    assert.equal(legacyGateway.state.get, 1);
    assert.equal(legacyGateway.state.post, 1);
    assert.equal(messages(legacyGateway, "initialize")[0].params.clientCapabilities.libfx?.modelMetadata, undefined);
    assert.equal(messages(legacyGateway, "session/prompt")[0].params.modelMetadata, undefined);
  } finally { await legacyAgent.close(); }

  const coldDescriptor = await discover();
  const args = [...(backend === "wasm" ? ["--experimental-wasm-jspi"] : []), scriptPath, backend, "--cold-child"];
  const child = spawnSync(process.execPath, args, {
    cwd: repoRoot,
    input: JSON.stringify({ apiKey, model: clone(coldDescriptor), gatewayChatUrl }),
    encoding: "utf8",
    timeout: 20_000,
    env: Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith("AI_GATEWAY_") && !key.startsWith("FX_"))),
  });
  if (child.error) throw child.error;
  assert.equal(child.status, 0, `cold ${backend} process failed: ${child.stderr}`);
  assert.equal(child.signal, null);
  assert.deepEqual(JSON.parse(child.stdout), { backend, get: 0, post: 1, text: "ok" });
  console.log(`${backend} resolved-model creation, prompt, restore, and cold process passed (GET 0, POST 1, text ok)`);
}

async function coldChild() {
  const fixture = JSON.parse(readFileSync(0, "utf8"));
  assert.deepEqual(Object.keys(fixture).sort(), ["apiKey", "gatewayChatUrl", "model"]);
  assert.equal(fixture.apiKey, apiKey, "cold fixture must contain only the fake credential");
  assert.equal(fixture.gatewayChatUrl, gatewayChatUrl);
  const gateway = mockGateway();
  const agent = await createFxAgent(optionsFor(await backendOptions(), gateway, fixture.model));
  try {
    assertNoTransport(gateway);
    const text = await runPrompt(agent);
    assert.equal(gateway.state.get, 0);
    assert.equal(gateway.state.post, 1);
    assertRequest(gateway.state.chatBodies[0]);
    process.stdout.write(JSON.stringify({ backend, get: gateway.state.get, post: gateway.state.post, text }));
  } finally { await agent.close(); }
}

if (process.argv[3] === "--cold-child") {
  assert.notEqual(backend, "discovery");
  await coldChild();
} else {
  await testDiscovery();
  if (backend !== "discovery") await testRuntime();
}
