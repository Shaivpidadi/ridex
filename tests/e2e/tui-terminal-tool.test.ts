import { afterEach, expect, test } from "bun:test";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { FX_BIN } from "../evals/eval-helpers";
import {
  FAKE_GATEWAY_MODEL,
  fakeGatewayFinalText,
  fakeGatewayToolCall,
  startFakeGateway,
  terminalFixtureShell,
  TmuxSession,
  tmuxAvailable,
} from "./tmux-helpers";

const TIMEOUT = 30_000;
const sessions: TmuxSession[] = [];
const roots: string[] = [];
const homes: string[] = [];
const gateways: Array<ReturnType<typeof startFakeGateway>> = [];

afterEach(async () => {
  for (const session of sessions.splice(0)) await session.kill();
  for (const home of homes.splice(0)) await cleanupTerminalHost(home);
  for (const gateway of gateways.splice(0)) gateway.stop();
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function createFixture(prefix: string) {
  const root = realpathSync(mkdtempSync(join("/tmp", prefix)));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const tracePath = join(root, "trace.log");
  const stderrPath = join(root, "stderr.log");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace);
  writeFileSync(
    join(home, ".fx", "settings.json"),
    JSON.stringify({
      permission_mode: "yolo",
      sandbox: "os",
      yolo_acknowledged: true,
      permission: {},
    }) + "\n",
  );
  writeFileSync(tracePath, "");
  writeFileSync(stderrPath, "");
  roots.push(root);
  homes.push(home);
  return {
    root,
    home,
    workspace: realpathSync(workspace),
    tracePath,
    stderrPath,
  };
}

async function launch(
  fixture: ReturnType<typeof createFixture>,
  gateway: ReturnType<typeof startFakeGateway>,
) {
  const session = await TmuxSession.create({
    isolated: true,
    cmd: FX_BIN,
    cwd: fixture.workspace,
    env: {
      HOME: fixture.home,
      SHELL: terminalFixtureShell(),
      AI_GATEWAY_API_KEY: "fake-shell-tool-key",
      VERCEL_OIDC_TOKEN: undefined,
      FX_AUTO_UPGRADE: "0",
      FX_PERMISSION_MODE: "yolo",
      FX_MODEL: FAKE_GATEWAY_MODEL,
      FX_GATEWAY_BASE_URL: gateway.baseUrl,
      FX_GATEWAY_CHAT_URL: gateway.chatUrl,
      FX_TRACE_LOG: fixture.tracePath,
      FX_TRACE_SCOPES: "shell,terminal,terminal_client,terminal_host,tool,agent",
      FX_TERMINAL_HOST_IDLE_MS: "500",
    },
    width: 120,
    height: 32,
    stderrPath: fixture.stderrPath,
  });
  sessions.push(session);
  await session.waitForComposer(TIMEOUT);
  return session;
}

function findSessionId(value: unknown): string | null {
  if (typeof value === "string") {
    if (!value.includes("session_id")) return null;
    try {
      return findSessionId(JSON.parse(value));
    } catch {
      return null;
    }
  }
  if (Array.isArray(value)) {
    for (let index = value.length - 1; index >= 0; index -= 1) {
      const found = findSessionId(value[index]);
      if (found) return found;
    }
    return null;
  }
  if (value && typeof value === "object") {
    const object = value as Record<string, unknown>;
    if (typeof object.session_id === "string" && object.session_id.length > 0) {
      return object.session_id;
    }
    return findSessionId(Object.values(object));
  }
  return null;
}

function toolResultEnvelope(body: string, toolCallId: string): string {
  const matches: string[] = [];
  const visit = (value: unknown): void => {
    if (Array.isArray(value)) {
      for (const item of value) visit(item);
      return;
    }
    if (!value || typeof value !== "object") return;
    const object = value as Record<string, unknown>;
    const id = object.toolCallId ?? object.tool_call_id;
    if (id === toolCallId) matches.push(JSON.stringify(object));
    for (const child of Object.values(object)) visit(child);
  };
  visit(JSON.parse(body));
  return matches.join("\n");
}

function schemaFromRequest(body: string): Record<string, unknown> {
  const parsed = JSON.parse(body) as Record<string, unknown>;
  const tools = parsed.tools as Array<Record<string, unknown>>;
  const shell = tools.find((tool) => tool.name === "shell");
  if (!shell) throw new Error("missing shell schema");
  return shell.inputSchema as Record<string, unknown>;
}

function terminalRecords(home: string): Array<Record<string, unknown>> {
  const sessionsRoot = join(home, ".fx", "sessions");
  if (!existsSync(sessionsRoot)) return [];
  return readdirSync(sessionsRoot).flatMap((sessionId) => {
    const terminalRoot = join(sessionsRoot, sessionId, "terminal", "state");
    if (!existsSync(terminalRoot)) return [];
    return readdirSync(terminalRoot).flatMap((name) =>
      name.startsWith("record-") && name.endsWith(".json")
        ? [JSON.parse(readFileSync(join(terminalRoot, name), "utf8"))]
        : []
    );
  });
}

async function cleanupTerminalHost(home: string): Promise<void> {
  const identityPath = join(home, ".fx", "terminal-host-v6", "host.json");
  const deadline = Date.now() + 3_000;
  while (Date.now() < deadline) {
    if (!existsSync(identityPath)) return;
    await Bun.sleep(25);
  }
  try {
    const identity = JSON.parse(readFileSync(identityPath, "utf8"));
    const pid = Number(identity.pid);
    if (Number.isSafeInteger(pid) && pid > 0) process.kill(pid, "SIGTERM");
  } catch {
    return;
  }
}

test.skipIf(!tmuxAvailable())(
  "shell captured execution yields one handle and waits without respawn",
  async () => {
    const fixture = createFixture("fx-shell-captured-");
    let sessionId = "";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("shell_run", "shell", {
        request: {
          action: "run",
          command: "printf CAPTURED_READY; sleep 0.2; printf CAPTURED_DONE",
          profile: "clean",
          yield_time_ms: 0,
        },
      }),
      (body) => {
        sessionId = findSessionId(JSON.parse(body)) ?? "";
        if (!sessionId) return new Response("missing session id", { status: 500 });
        return fakeGatewayToolCall("shell_wait", "shell", {
          request: {
            action: "wait",
            session_id: sessionId,
            wait_ceiling_ms: 5_000,
          },
        });
      },
      fakeGatewayFinalText("SHELL_CAPTURED_OK"),
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);
    await active.sendText("Run the captured managed shell flow.");
    await active.sendKeys("Enter");
    await active.waitForText("SHELL_CAPTURED_OK", TIMEOUT);

    expect(sessionId.length).toBeGreaterThan(0);
    expect(gateway.requests).toHaveLength(3);
    const schema = schemaFromRequest(gateway.requests[0]!.body);
    const request = (schema.properties as Record<string, any>).request;
    const actions = request.oneOf.map(
      (branch: any) => branch.properties.action.enum[0],
    );
    expect(actions).toEqual(["run", "wait", "write", "stop", "list"]);
    expect(gateway.requests[0]!.body).not.toContain('"name":"terminal"');
    const runResult = toolResultEnvelope(
      gateway.requests[1]!.body,
      "shell_run",
    );
    expect(runResult).toContain('\\"next_action\\":{\\"action\\":\\"wait\\"');
    expect(runResult).toContain(`\\"session_id\\":\\"${sessionId}\\"`);
    const scrollback = await active.captureFullScrollback();
    expect(scrollback).toContain("Ran printf CAPTURED_READY");
    expect(scrollback).toContain("Finished waiting for session shell_run");
    expect(scrollback).not.toContain("Using terminal");
    expect(scrollback).not.toContain("Used terminal");
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "overlapping captured shell handles keep lifecycle output isolated",
  async () => {
    const fixture = createFixture("fx-shell-overlap-");
    let firstSessionId = "";
    let secondSessionId = "";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("shell_overlap_first", "shell", {
        request: {
          action: "run",
          command: "sleep 0.4; printf FIRST_OVERLAP",
          profile: "clean",
          yield_time_ms: 0,
        },
      }),
      (body) => {
        firstSessionId = findSessionId(JSON.parse(body)) ?? "";
        return fakeGatewayToolCall("shell_overlap_second", "shell", {
          request: {
            action: "run",
            command: "sleep 0.2; printf SECOND_OVERLAP",
            profile: "clean",
            yield_time_ms: 0,
          },
        });
      },
      (body) => {
        secondSessionId = findSessionId(JSON.parse(body)) ?? "";
        return fakeGatewayToolCall("shell_overlap_wait_first", "shell", {
          request: {
            action: "wait",
            session_id: firstSessionId,
            wait_ceiling_ms: 5_000,
          },
        });
      },
      () => fakeGatewayToolCall("shell_overlap_wait_second", "shell", {
        request: {
          action: "wait",
          session_id: secondSessionId,
          wait_ceiling_ms: 5_000,
        },
      }),
      fakeGatewayFinalText("SHELL_OVERLAP_OK"),
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);
    await active.sendText("Run both overlapping managed shell commands.");
    await active.sendKeys("Enter");
    await active.waitForText("SHELL_OVERLAP_OK", TIMEOUT);

    expect(firstSessionId.length).toBeGreaterThan(0);
    expect(secondSessionId.length).toBeGreaterThan(0);
    expect(secondSessionId).not.toBe(firstSessionId);
    const firstResult = toolResultEnvelope(
      gateway.requests[3]!.body,
      "shell_overlap_wait_first",
    );
    const secondResult = toolResultEnvelope(
      gateway.requests[4]!.body,
      "shell_overlap_wait_second",
    );
    expect(firstResult).toContain("FIRST_OVERLAP");
    expect(firstResult).not.toContain("SECOND_OVERLAP");
    expect(secondResult).toContain("SECOND_OVERLAP");
    expect(secondResult).not.toContain("FIRST_OVERLAP");
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "shell TTY execution writes atomically drains final output and closes host state",
  async () => {
    const fixture = createFixture("fx-shell-tty-");
    let sessionId = "";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("shell_tty_run", "shell", {
        request: {
          action: "run",
          command:
            "printf 'TTY_READY\\n'; IFS= read -r line; printf 'TTY_ECHO:%s\\n' \"$line\"",
          profile: "clean",
          tty: true,
          yield_time_ms: 0,
        },
      }),
      (body) => {
        sessionId = findSessionId(JSON.parse(body)) ?? "";
        if (!sessionId) return new Response("missing session id", { status: 500 });
        return fakeGatewayToolCall("shell_tty_write", "shell", {
          request: {
            action: "write",
            session_id: sessionId,
            input: { kind: "text", text: "violet comet\n" },
          },
        });
      },
      fakeGatewayFinalText("SHELL_TTY_OK"),
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);
    await active.sendText("Run the interactive managed shell flow.");
    await active.sendKeys("Enter");
    await active.waitForText("SHELL_TTY_OK", TIMEOUT);

    const writeResult = toolResultEnvelope(
      gateway.requests[2]!.body,
      "shell_tty_write",
    );
    expect(writeResult).toContain("TTY_ECHO:violet comet");
    expect(writeResult).toContain('\\"state\\":\\"completed\\"');
    expect(writeResult).toContain('\\"exit_code\\":0');
    const records = terminalRecords(fixture.home);
    expect(records.some((record) =>
      record.session_id === sessionId && record.lifecycle === "closed"
    )).toBe(true);
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "shell TTY writes advance one runtime-owned cursor without duplicate output",
  async () => {
    const fixture = createFixture("fx-shell-tty-cursor-");
    let sessionId = "";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("shell_tty_cursor_run", "shell", {
        request: {
          action: "run",
          command:
            "printf 'CURSOR_READY\\n'; IFS= read -r _; printf 'CURSOR_FIRST\\n'; IFS= read -r _; printf 'CURSOR_SECOND\\n'",
          profile: "clean",
          tty: true,
          yield_time_ms: 0,
        },
      }),
      (body) => {
        sessionId = findSessionId(JSON.parse(body)) ?? "";
        if (!sessionId) return new Response("missing session id", { status: 500 });
        return fakeGatewayToolCall("shell_tty_cursor_write", "shell", {
          request: {
            action: "write",
            session_id: sessionId,
            input: { kind: "text", text: "continue\n" },
          },
        });
      },
      () => fakeGatewayToolCall("shell_tty_cursor_write_two", "shell", {
        request: {
          action: "write",
          session_id: sessionId,
          input: { kind: "text", text: "next\n" },
        },
      }),
      fakeGatewayFinalText("SHELL_TTY_CURSOR_OK"),
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);
    await active.sendText("Run the TTY cursor flow.");
    await active.sendKeys("Enter");
    await active.waitForText("SHELL_TTY_CURSOR_OK", TIMEOUT);

    const first = toolResultEnvelope(
      gateway.requests[2]!.body,
      "shell_tty_cursor_write",
    );
    const second = toolResultEnvelope(
      gateway.requests[3]!.body,
      "shell_tty_cursor_write_two",
    );
    expect(first).toContain("CURSOR_FIRST");
    expect(first).not.toContain("CURSOR_SECOND");
    expect(second).toContain("CURSOR_SECOND");
    expect(second).not.toContain("CURSOR_FIRST");
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "Ctrl-X keeps captured managed work across clear without making it attachable",
  async () => {
    const fixture = createFixture("fx-shell-manager-");
    let sessionId = "";
    const gateway = startFakeGateway([
      fakeGatewayToolCall("shell_manager_run", "shell", {
        request: {
          action: "run",
          command: "trap 'exit 0' TERM; while :; do sleep 1; done",
          profile: "clean",
          yield_time_ms: 0,
        },
      }),
      (body) => {
        sessionId = findSessionId(JSON.parse(body)) ?? "";
        return fakeGatewayFinalText("HANDLE_RUNNING");
      },
      () => fakeGatewayToolCall("shell_manager_stop", "shell", {
        request: {
          action: "stop",
          session_id: sessionId,
          force: false,
        },
      }),
      fakeGatewayFinalText("HANDLE_STOPPED"),
    ]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);
    await active.sendText("Start the managed watcher.");
    await active.sendKeys("Enter");
    await active.waitForText("HANDLE_RUNNING", TIMEOUT);

    await active.sendKeys("C-x");
    await active.waitForPane(
      (pane) => pane.includes("Background processes") && pane.includes("trap 'exit 0' TERM"),
      TIMEOUT,
    );
    await active.sendKeys("Enter");
    expect(await active.capturePane()).toContain("Background processes");
    await active.sendKeys("C-x");
    await active.waitForComposer(TIMEOUT);
    await active.sendText("/clear");
    await active.sendKeys("Enter");
    await active.waitForComposer(TIMEOUT);
    await active.sendKeys("C-x");
    await active.waitForPane(
      (pane) => pane.includes("Background processes") && pane.includes("trap 'exit 0' TERM"),
      TIMEOUT,
    );
    await active.sendKeys("C-x");
    await active.waitForComposer(TIMEOUT);
    await active.sendText("Stop the existing managed watcher.");
    await active.sendKeys("Enter");
    await active.waitForText("HANDLE_STOPPED", TIMEOUT);
    await active.sendKeys("C-x");
    await active.waitForPane(
      (pane) => pane.includes("No background processes"),
      TIMEOUT,
    );
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "direct human command registers in the same Ctrl-X managed process catalog",
  async () => {
    const fixture = createFixture("fx-shell-direct-");
    const gateway = startFakeGateway([]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);

    await active.sendText("!printf 'DIRECT_READY\\n'; sleep 30");
    await active.sendKeys("Enter");
    await active.waitForText("Running", TIMEOUT);
    await active.sendKeys("C-x");
    await active.waitForText("printf 'DIRECT_READY", TIMEOUT);

    const scrollback = await active.captureFullScrollback();
    expect(scrollback).toContain("Agents & processes");
    expect(scrollback).toContain("printf 'DIRECT_READY");
    expect(terminalRecords(fixture.home).some((record) =>
      record.lifecycle === "running" &&
      String(record.command).includes("DIRECT_READY")
    )).toBe(true);
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);

test.skipIf(!tmuxAvailable())(
  "Ctrl-X refresh removes a naturally completed direct human command",
  async () => {
    const fixture = createFixture("fx-shell-direct-complete-");
    const gateway = startFakeGateway([]);
    gateways.push(gateway);
    const active = await launch(fixture, gateway);

    await active.sendText("!printf 'DIRECT_SHORT_DONE\\n'; sleep 0.1");
    await active.sendKeys("Enter");
    await active.waitForText("Running", TIMEOUT);
    await Bun.sleep(300);
    await active.sendKeys("C-x");
    await active.waitForPane(
      (pane) => pane.includes("No background processes"),
      TIMEOUT,
    );

    expect(terminalRecords(fixture.home).some((record) =>
      String(record.command).includes("DIRECT_SHORT_DONE") &&
      record.lifecycle === "exited"
    )).toBe(true);
    expect(readFileSync(fixture.stderrPath, "utf8")).toBe("");
  },
  TIMEOUT,
);
