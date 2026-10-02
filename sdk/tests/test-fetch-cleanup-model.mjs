import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { fetchCleanupAction } from "../fetch-cleanup.js";

const directory = new URL("./formal/native-fetch-cleanup/", import.meta.url);
const fixture = JSON.parse(await readFile(new URL("policy-cases.json", directory), "utf8"));
const model = await readFile(new URL("FetchCleanup.tla", directory));
assert.equal(createHash("sha256").update(model).digest("hex"), fixture.modelSha256,
  "TLA model changed: regenerate TLC policy cases, do not hand-edit the oracle");
assert.ok(fixture.cases.length >= 100);
for (const { state, expected } of fixture.cases) {
  assert.equal(fetchCleanupAction(state, fixture.maxAge, fixture.maxBytes), expected, JSON.stringify(state));
}
// TLC's legacy counterexample reaches this state after model completion, before HTTP EOF.
const completed = { alive: true, active: false, consumed: true, eof: false, closing: false,
  canceled: false, failed: false, age: 0, discarded: 0 };
assert.equal(fetchCleanupAction(completed, 2, 2), "drain");
assert.equal(fetchCleanupAction({ ...completed, canceled: true }, 2, 2), "abort");
assert.equal(fetchCleanupAction({ ...completed, age: 2 }, 2, 2), "abort");
assert.equal(fetchCleanupAction({ ...completed, discarded: 2 }, 2, 2), "abort");
assert.equal(fetchCleanupAction({ ...completed, eof: true }, 2, 2), "done");
assert.equal(fetchCleanupAction({ ...completed, consumed: false }, 2, 2), "abort");
const observationFixture = JSON.parse(await readFile(new URL("observation-cases.json", directory), "utf8"));
for (const [name, hash] of [["FetchObservation.tla", observationFixture.modelSha256],
  ["ObservationExport.cfg", observationFixture.configSha256]]) {
  assert.equal(createHash("sha256").update(await readFile(new URL(name, directory))).digest("hex"), hash,
    `${name} changed: regenerate TLC observation cases, do not hand-edit the oracle`);
}
assert.ok(observationFixture.cases.length > 0);
const methods = new Set();
const dispositions = new Set();
for (const { method, priorConsumed, read, state, expected } of observationFixture.cases) {
  methods.add(method);
  // This checks the declared sampler contract, not the SDK adapter's execution.
  const consumed = priorConsumed || (method === "coherent" ? read.disposition === 2 :
    method === "split" && read.consumed);
  const active = method === "coherent" ? read.disposition === 1 : read.active;
  assert.equal(state.consumed, consumed);
  assert.equal(state.active, active);
  if (method === "coherent") {
    dispositions.add(read.disposition);
    assert.equal(read.consumed, read.disposition === 2);
    assert.equal(read.active, read.disposition === 1);
  }
  if (method === "fallback") assert.equal(consumed, false, "fallback must not invent success");
  assert.equal(fetchCleanupAction(state, observationFixture.maxAge, observationFixture.maxBytes), expected,
    JSON.stringify({ method, priorConsumed, read, state }));
}
assert.deepEqual([...methods].sort(), ["coherent", "fallback", "split"]);
assert.deepEqual([...dispositions].sort(), [0, 1, 2]);
const witnesses = observationFixture.witnesses;
assert.deepEqual(Object.keys(witnesses).sort(), ["consumedWhileActive", "consumedAfterClose",
  "consumedBeforePublication", "consumedBeforeDelivery", "publicationBeforeConsume", "deliveryBeforeConsume",
  "retirementBeforePublication", "retirementBeforeDelivery", "foreignHandle", "cachedAfterCancel",
  "fallbackNoSuccess", "splitReadRace"].sort());
for (const witness of Object.values(witnesses)) {
  assert.equal(fetchCleanupAction(witness.state, 2, 2), witness.expected, JSON.stringify(witness));
}
for (const name of ["consumedWhileActive", "consumedAfterClose"]) {
  const witness = witnesses[name];
  assert.equal(witness.event, "read_disposition");
  assert.equal(witness.read.disposition, 2, "matching consumed marker wins over native active/close");
  assert.equal(witness.expected, "drain");
}
assert.equal(witnesses.consumedWhileActive.native.active, true);
assert.equal(witnesses.consumedAfterClose.native.closed, true);
for (const name of ["consumedBeforePublication", "retirementBeforePublication"]) {
  assert.equal(witnesses[name].native.consumed, true);
  assert.equal(witnesses[name].host.textPublished, false);
  assert.equal(witnesses[name].host.resultPublished, false);
}
for (const name of ["consumedBeforeDelivery", "retirementBeforeDelivery"]) {
  assert.equal(witnesses[name].native.consumed, true);
  assert.equal(witnesses[name].host.textPublished, true);
  assert.equal(witnesses[name].host.resultPublished, true);
  assert.equal(witnesses[name].host.textDelivered, false);
  assert.equal(witnesses[name].host.resultDelivered, false);
}
for (const name of ["retirementBeforePublication", "retirementBeforeDelivery"]) {
  assert.equal(witnesses[name].native.active, false);
}
for (const name of ["publicationBeforeConsume", "deliveryBeforeConsume"]) {
  assert.equal(witnesses[name].native.consumed, false);
  assert.equal(witnesses[name].host.textPublished, true);
  assert.equal(witnesses[name].host.resultPublished, true);
}
assert.equal(witnesses.deliveryBeforeConsume.host.textDelivered, true);
assert.equal(witnesses.deliveryBeforeConsume.host.resultDelivered, true);
assert.equal(witnesses.foreignHandle.read.disposition, 0);
assert.equal(witnesses.foreignHandle.expected, "abort");
assert.equal(witnesses.cachedAfterCancel.state.consumed, true, "JS caches consumed monotonically");
assert.equal(witnesses.cachedAfterCancel.expected, "abort", "cancellation still wins");
assert.equal(witnesses.fallbackNoSuccess.state.consumed, false);
assert.equal(witnesses.fallbackNoSuccess.expected, "abort", "delivered result is not a native success marker");
const race = witnesses.splitReadRace;
assert.equal(race.native.consumed, true);
assert.equal(race.state.consumed, false);
assert.equal(race.state.active, false);
assert.equal(race.expected, "abort", "production policy reproduces the torn-observation abort");
const repaired = observationFixture.cases.find(c => c.method === "coherent" && c.handle === race.handle &&
  c.read.disposition === 2 && Object.entries(race.state).every(([key, value]) =>
    c.state[key] === (key === "consumed" ? true : value)));
assert.ok(repaired, "TLC must reach the corresponding coherent consumed observation");
assert.equal(repaired.expected, "drain");
assert.equal(fetchCleanupAction(repaired.state, 2, 2), repaired.expected,
  "the coherent matching disposition repairs the observation, not the policy");
console.log(`fetch cleanup policy matches ${fixture.cases.length} lifecycle and ${observationFixture.cases.length} ` +
  `observation TLC-derived cases (${observationFixture.reachableObservations} reachable observations, ` +
  `${Object.keys(witnesses).length} ordering witnesses); split-read abort reproduced, coherent observation qualified`);
