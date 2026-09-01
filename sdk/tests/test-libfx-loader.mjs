#!/usr/bin/env node
import { strict as assert } from "node:assert";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  createFxAgent,
  createFxTerminal,
  fxSdkApiVersion,
  libfxApiVersion,
} from "../node.js";
import * as browser from "../browser.js";

assert.equal(libfxApiVersion, 2);
assert.equal(fxSdkApiVersion, 2);
assert.equal(browser.libfxApiVersion, 2);
assert.equal(typeof browser.createFxAgent, "function");
assert.equal(typeof browser.createFxTerminal, "function");

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const realNativeAddon = resolve(scriptDir, "../../zig-out/lib/libfx.node");
const dir = await mkdtemp(resolve(tmpdir(), "libfx-loader-"));
const nativePath = resolve(dir, "native.mjs");
await writeFile(nativePath, `
  export async function createFxAgent(options) { return { backend: "native-agent", options }; }
  export async function createFxTerminal(options) { return { backend: "native-terminal", options }; }
`);
const nativeUrl = pathToFileURL(nativePath);

for (const gatewayChatUrl of [
  "http://attacker.example/chat",
  "https://[redacted]@example.com/chat",
  "https://example.com/chat",
  "file:///tmp/socket",
]) {
  await assert.rejects(
    createFxAgent({ nativeAddon: nativeUrl, env: { FX_GATEWAY_CHAT_URL: gatewayChatUrl } }),
    TypeError,
  );
}

const agent = await createFxAgent({ nativeAddon: nativeUrl, marker: 1 });
assert.equal(agent.backend, "native-agent");
assert.equal(agent.options.marker, 1);
assert.equal("nativeAddon" in agent.options, false);
assert.equal("backend" in agent.options, false);

const terminal = await createFxTerminal({ nativeAddon: nativeUrl, marker: 2 });
assert.equal(terminal.backend, "native-terminal");
assert.equal(terminal.options.marker, 2);

const savedSuspending = WebAssembly.Suspending;
const savedPromising = WebAssembly.promising;
try {
  Object.defineProperty(WebAssembly, "Suspending", { configurable: true, value: undefined });
  Object.defineProperty(WebAssembly, "promising", { configurable: true, value: undefined });
  await assert.rejects(
    createFxAgent({ nativeAddon: nativeUrl, backend: "wasm" }),
    (error) => error?.code === "LIBFX_JSPI_REQUIRED" &&
      error.message.includes("--experimental-wasm-jspi"),
  );
  await assert.rejects(
    createFxAgent({ nativeAddon: realNativeAddon, instructions: "x".repeat(65_537) }),
    (error) => error instanceof RangeError && error.message.includes("65536"),
  );
  await assert.rejects(
    createFxAgent({
      nativeAddon: realNativeAddon,
      checkpoint: new Uint8Array([1, 2, 3]),
      env: { AI_GATEWAY_API_KEY: "loader-checkpoint-key" },
    }),
    (error) => error.message.includes("Invalid or non-fresh libfx checkpoint"),
  );
} finally {
  Object.defineProperty(WebAssembly, "Suspending", { configurable: true, value: savedSuspending });
  Object.defineProperty(WebAssembly, "promising", { configurable: true, value: savedPromising });
}

const coreOnlyPath = resolve(dir, "core-only.mjs");
await writeFile(coreOnlyPath, `
  export const libfxApiVersion = 2;
  export async function createFxAgent() { return { backend: "core-only" }; }
`);
await assert.rejects(
  createFxTerminal({ nativeAddon: pathToFileURL(coreOnlyPath), backend: "native" }),
  (error) => error?.code === "LIBFX_NATIVE_UNAVAILABLE" &&
    error.message.includes("createFxTerminal"),
);

const incompatiblePath = resolve(dir, "incompatible.mjs");
await writeFile(incompatiblePath, `
  export const libfxApiVersion = 3;
  export async function createFxAgent() {}
`);
await assert.rejects(
  createFxAgent({ nativeAddon: pathToFileURL(incompatiblePath), backend: "native" }),
  (error) => error?.code === "LIBFX_NATIVE_UNAVAILABLE" &&
    error.message.includes("incompatible"),
);

for (const [name, source] of [
  ["missing-version", `
    export function createCore() { throw new Error("missing-version createCore invoked"); }
  `],
  ["unequal-version", `
    export const libfxApiVersion = 3;
    export function createCore() { throw new Error("unequal-version createCore invoked"); }
  `],
]) {
  const modulePath = resolve(dir, `${name}.mjs`);
  await writeFile(modulePath, source);
  await assert.rejects(
    createFxAgent({ nativeAddon: pathToFileURL(modulePath), backend: "native" }),
    (error) => error?.code === "LIBFX_NATIVE_UNAVAILABLE" &&
      error.message.includes("incompatible") &&
      !String(error.cause).includes("createCore invoked"),
    `${name} low-level addon must fail before createCore invocation`,
  );
}

const matchingVersionPath = resolve(dir, "matching-version.mjs");
await writeFile(matchingVersionPath, `
  export const libfxApiVersion = 2;
  export function createCore() {
    const error = new Error("matching-version createCore invoked");
    error.code = "MATCHING_VERSION_INVOKED";
    throw error;
  }
`);
await assert.rejects(
  createFxAgent({ nativeAddon: pathToFileURL(matchingVersionPath), backend: "native" }),
  (error) => error?.code === "MATCHING_VERSION_INVOKED",
  "matching v2 low-level addon must reach createCore",
);

console.log("libfx loader passed: browser exports, native preference, fallback diagnostics, semantic errors, and strict low-level API validation");
