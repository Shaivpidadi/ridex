import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { access, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir, homedir } from "node:os";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const directory = fileURLToPath(new URL(".", import.meta.url));
let java = process.env.JAVA ?? "java";
if (!process.env.JAVA) {
  try { await access("/opt/homebrew/opt/openjdk/bin/java"); java = "/opt/homebrew/opt/openjdk/bin/java"; } catch {}
}
const jar = process.env.TLA2TOOLS_JAR ?? resolve(homedir(), ".local/share/tla/tla2tools.jar");
await access(jar);
const artifacts = await mkdtemp(resolve(tmpdir(), "libfx-tlc-"));
console.log(`TLC logs: ${artifacts}`);
const expected = [["Legacy", 12, "NoPrematureAbort"], ["Fixed", 0, "No error has been found"],
  ["NoTimer", 13, "Temporal properties were violated"], ["UnsafeCallbacks", 12, "NoForeignHandleMutation"],
  ["Export", 0, "No error has been found"],
  ["SplitRead", 12, "NoPrematureAbort", "FetchObservation"],
  ["ObservationFixed", 0, "No error has been found", "FetchObservation"],
  ["ObservationFallback", 0, "No error has been found", "FetchObservation"],
  ["ObservationExport", 0, "No error has been found", "FetchObservation"]];
const outputs = new Map();
for (const [config, exit, message, module = "FetchCleanup"] of expected) {
  const result = spawnSync(java, ["-XX:+UseParallelGC", "-Xmx2g", "-cp", jar, "tlc2.TLC", "-workers", "1",
    "-metadir", resolve(artifacts, config), "-config", resolve(directory, `${config}.cfg`),
    resolve(directory, `${module}.tla`)], { cwd: directory, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  if (result.error) throw result.error;
  const output = result.stdout + result.stderr;
  await writeFile(resolve(artifacts, `${config}.log`), output);
  assert.equal(result.status, exit, `${config}: unexpected TLC result; see ${artifacts}`);
  assert.ok(output.includes(message), `${config}: missing expected checker result; see ${artifacts}`);
  outputs.set(config, output);
  const counts = output.match(/([\d,]+) states generated, ([\d,]+) distinct states found/);
  assert.ok(counts, `${config}: missing TLC counts; see ${artifacts}`);
  console.log(`${config}: expected TLC exit ${exit} observed; ${counts[1]} generated, ${counts[2]} distinct`);
}
const splitTrace = outputs.get("SplitRead");
for (const event of ["read_consumed", "native_consume", "read_active", "decide"]) {
  assert.ok(splitTrace.includes(`event = "${event}"`), `SplitRead: missing ${event} in counterexample`);
}
assert.match(splitTrace, /event = "native_(retire|close)"/);
const parseTuple = line => JSON.parse(`[${line.slice(2, -2).replaceAll("TRUE", "true").replaceAll("FALSE", "false")}]`);
const cases = new Map();
for (const line of outputs.get("Export").split("\n")) {
  if (!line.startsWith('<<"POLICY",')) continue;
  const values = parseTuple(line);
  const [, alive, active, consumed, http, closing, canceled, failed, age, discarded, expected] = values;
  const state = { alive, active, consumed, eof: http !== "open", closing, canceled, failed, age, discarded };
  cases.set(JSON.stringify(state), { state, expected });
}
const model = await readFile(resolve(directory, "FetchCleanup.tla"));
const fixture = { origin: "TLC Export.cfg reachable states; not a JS-derived oracle",
  modelSha256: createHash("sha256").update(model).digest("hex"), maxAge: 2, maxBytes: 2,
  cases: [...cases.values()].sort((a, b) => JSON.stringify(a.state).localeCompare(JSON.stringify(b.state))) };
async function recordOrVerify(name, value) {
  const path = resolve(directory, name);
  if (process.argv.includes("--update")) {
    await writeFile(path, JSON.stringify(value, null, 2) + "\n");
  } else {
    assert.deepEqual(JSON.parse(await readFile(path, "utf8")), value,
      `${name} differs from TLC; run check.mjs --update, never hand-edit it`);
  }
}
const observations = new Map();
// TLC pretty-prints long tuples across lines; accept both compact and wrapped output.
for (const [line] of outputs.get("ObservationExport").matchAll(/<<\s*"OBSERVATION",[\s\S]*?>>/g)) {
  const [, method, handle, nativeActive, nativeConsumed, nativeClosed, semanticComplete,
    textPublished, resultPublished, textDelivered, resultDelivered, canceled, failed, http,
    priorConsumed, seenConsumed, seenActive, disposition, consumed, event, expected] = parseTuple(line);
  const observation = { method, handle, priorConsumed,
    read: { consumed: seenConsumed, active: seenActive, disposition },
    state: { alive: true, active: seenActive, consumed, eof: http !== "open", closing: false,
      canceled, failed, age: 0, discarded: 0 }, expected,
    native: { active: nativeActive, consumed: nativeConsumed, closed: nativeClosed },
    host: { semanticComplete, textPublished, resultPublished, textDelivered, resultDelivered }, event };
  observations.set(JSON.stringify(observation), observation);
}
const sortedObservations = [...observations.values()].sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
const observationCases = new Map();
for (const { native, host, event, ...policyCase } of sortedObservations) {
  observationCases.set(JSON.stringify(policyCase), policyCase);
}
// Select reachable ordering witnesses, never manufacture states or policy results.
const matchingSuccess = o => o.method === "coherent" && o.handle === 1 &&
  o.native.consumed && !o.state.canceled && !o.state.failed && !o.state.eof;
const sampledSuccess = o => matchingSuccess(o) && o.event === "read_disposition";
const witnesses = Object.fromEntries(Object.entries({
  consumedWhileActive: o => sampledSuccess(o) && o.native.active,
  consumedAfterClose: o => sampledSuccess(o) && o.native.closed,
  consumedBeforePublication: o => matchingSuccess(o) && !o.host.textPublished && !o.host.resultPublished,
  consumedBeforeDelivery: o => matchingSuccess(o) && o.host.textPublished && o.host.resultPublished &&
    !o.host.textDelivered && !o.host.resultDelivered,
  publicationBeforeConsume: o => o.method === "coherent" && o.handle === 1 &&
    o.event === "read_disposition" && o.host.textPublished && o.host.resultPublished && !o.native.consumed,
  deliveryBeforeConsume: o => o.method === "coherent" && o.handle === 1 &&
    o.event === "read_disposition" && o.host.textDelivered && o.host.resultDelivered && !o.native.consumed,
  retirementBeforePublication: o => matchingSuccess(o) && !o.native.active &&
    !o.host.textPublished && !o.host.resultPublished,
  retirementBeforeDelivery: o => matchingSuccess(o) && !o.native.active &&
    o.host.textPublished && o.host.resultPublished && !o.host.textDelivered && !o.host.resultDelivered,
  foreignHandle: o => o.method === "coherent" && o.handle === 2 && o.native.consumed &&
    o.event === "read_disposition" && !o.state.eof && !o.state.canceled && !o.state.failed,
  cachedAfterCancel: o => o.method === "coherent" && o.priorConsumed && o.state.canceled &&
    !o.native.consumed && o.event === "read_disposition" && !o.state.eof,
  fallbackNoSuccess: o => o.method === "fallback" && o.handle === 1 && o.native.consumed &&
    !o.native.active && o.host.resultDelivered && !o.state.eof && !o.state.canceled && !o.state.failed,
  splitReadRace: o => o.method === "split" && o.handle === 1 && o.native.consumed &&
    !o.native.active && !o.priorConsumed && !o.read.consumed && !o.read.active &&
    !o.state.eof && !o.state.canceled && !o.state.failed,
}).map(([name, predicate]) => {
  const witness = sortedObservations.find(predicate);
  assert.ok(witness, `TLC did not reach ${name}`);
  return [name, witness];
}));
const sha256 = bytes => createHash("sha256").update(bytes).digest("hex");
const observationFixture = { origin: "TLC ObservationExport.cfg reachable observations; not a JS-derived oracle",
  modelSha256: sha256(await readFile(resolve(directory, "FetchObservation.tla"))),
  configSha256: sha256(await readFile(resolve(directory, "ObservationExport.cfg"))),
  maxAge: 2, maxBytes: 2, reachableObservations: observations.size,
  cases: [...observationCases.values()].sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b))), witnesses };
await recordOrVerify("policy-cases.json", fixture);
await recordOrVerify("observation-cases.json", observationFixture);
const policy = spawnSync(process.execPath, [resolve(directory, "../../test-fetch-cleanup-model.mjs")],
  { encoding: "utf8" });
assert.equal(policy.status, 0, policy.stderr || policy.stdout);
console.log(policy.stdout.trim());
console.log(`TLC logs: ${artifacts}`);
