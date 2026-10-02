#!/usr/bin/env node
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { extname, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const root = resolve(scriptDir, "../..");
const chromeCandidates = [
  process.env.CHROME_PATH,
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
  "/Applications/Chromium.app/Contents/MacOS/Chromium",
  "google-chrome",
  "chromium",
].filter(Boolean);
const chromeStartTimeoutMs = 15_000;

async function stopChrome(process) {
  if (process.exitCode !== null || process.signalCode !== null) return;
  process.kill();
  await new Promise((resolveExit) => process.once("exit", resolveExit));
}

const contentTypes = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".wasm": "application/wasm",
};
const server = createServer(async (request, response) => {
  try {
    const pathname = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
    const path = resolve(root, `.${pathname}`);
    if (path !== root && !path.startsWith(`${root}${sep}`)) throw new Error("path escapes root");
    const info = await stat(path);
    if (!info.isFile()) throw new Error("not a file");
    response.writeHead(200, { "content-type": contentTypes[extname(path)] || "application/octet-stream" });
    response.end(await readFile(path));
  } catch {
    response.writeHead(404).end("not found");
  }
});
await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
const { port } = server.address();

let chrome;
let chromeLaunchError;
for (const candidate of chromeCandidates) {
  try {
    const args = [
      "--headless=new",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-background-networking",
      "--disable-component-update",
      "--remote-debugging-port=0",
      "about:blank",
    ];
    if (process.platform === "linux") args.unshift("--no-sandbox", "--disable-dev-shm-usage");
    chrome = spawn(candidate, args, { stdio: ["ignore", "ignore", "pipe"] });
    await new Promise((resolveStart, reject) => {
      let stderr = "";
      const fail = (error) => {
        clearTimeout(timeout);
        reject(error);
      };
      const timeout = setTimeout(() => fail(new Error(
        `timed out starting ${candidate}${stderr.trim() ? `: ${stderr.trim()}` : ""}`,
      )), chromeStartTimeoutMs);
      chrome.once("error", fail);
      chrome.once("exit", (code, signal) => fail(new Error(
        `${candidate} exited before DevTools started (${signal || code})${stderr.trim() ? `: ${stderr.trim()}` : ""}`,
      )));
      chrome.stderr.on("data", (chunk) => {
        stderr += String(chunk);
        const match = stderr.match(/DevTools listening on (ws:\/\/[^\s]+)/);
        if (!match) return;
        clearTimeout(timeout);
        chrome.off("error", fail);
        chrome.debugUrl = match[1];
        resolveStart();
      });
    });
    break;
  } catch (error) {
    chromeLaunchError = error;
    if (chrome) await stopChrome(chrome);
    chrome = null;
  }
}
if (!chrome) {
  server.close();
  console.error(`Chrome could not be started: ${chromeLaunchError?.message || "no executable found"}`);
  process.exit(2);
}

let nextId = 1;
const pending = new Map();
const events = new Map();
const socket = new WebSocket(chrome.debugUrl);
await new Promise((resolveOpen, reject) => {
  socket.addEventListener("open", resolveOpen, { once: true });
  socket.addEventListener("error", reject, { once: true });
});
socket.addEventListener("message", ({ data }) => {
  const message = JSON.parse(data);
  if (message.id) {
    const waiter = pending.get(message.id);
    if (!waiter) return;
    pending.delete(message.id);
    if (message.error) waiter.reject(new Error(message.error.message));
    else waiter.resolve(message.result);
    return;
  }
  for (const listener of events.get(message.method) || []) listener(message.params);
});
function command(method, params = {}, sessionId) {
  const id = nextId++;
  socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
  return new Promise((resolveCommand, reject) => pending.set(id, { resolve: resolveCommand, reject }));
}
async function waitFor(expression, sessionId, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const result = await command("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true }, sessionId);
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.text);
    if (result.result.value) return result.result.value;
    await new Promise((resolveWait) => setTimeout(resolveWait, 25));
  }
  let diagnostic;
  try {
    diagnostic = await command("Runtime.evaluate", {
      expression: "window.__fxCoreTest || window.__fxBrowserTerminalTest || null",
      returnByValue: true,
    }, sessionId);
  } catch {}
  throw new Error(`timed out waiting for ${expression}; last value=${JSON.stringify(diagnostic?.result?.value)}`);
}
async function runCase(name, query, verify) {
  const { targetId } = await command("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await command("Target.attachToTarget", { targetId, flatten: true });
  await command("Runtime.enable", {}, sessionId);
  await command("Page.enable", {}, sessionId);
  const exceptions = [];
  const listener = (params) => {
    if (params.targetId === targetId || !params.targetId) exceptions.push(params.exceptionDetails?.text || "browser exception");
  };
  const list = events.get("Runtime.exceptionThrown") || [];
  list.push(listener);
  events.set("Runtime.exceptionThrown", list);
  try {
    await command("Page.navigate", { url: `http://127.0.0.1:${port}/sdk/index.html?${query}` }, sessionId);
    const result = await waitFor("window.__fxCoreTest && ['completed', 'failed', 'unsupported'].includes(window.__fxCoreTest.state) && window.__fxCoreTest", sessionId);
    if (exceptions.length) throw new Error(exceptions.join("; "));
    verify(result);
    console.log(`browser core ${name} passed`);
  } finally {
    events.set("Runtime.exceptionThrown", list.filter((entry) => entry !== listener));
    await command("Target.closeTarget", { targetId });
  }
}
function expect(condition, message) {
  if (!condition) throw new Error(message);
}
function withTimeout(promise, message, timeoutMs) {
  let timer;
  return Promise.race([
    promise,
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(message)), timeoutMs);
    }),
  ]).finally(() => clearTimeout(timer));
}

try {
  await runCase("incremental stream", "transport=mock&autorun=say%20hello&chunk-delay=75&model=sdk%2Fchrome-model&mode=code", (result) => {
    const modelChunks = result.chunks.filter((chunk) => !chunk.startsWith("[context]"));
    expect(result.stopReason === "end_turn", `unexpected stop reason ${result.stopReason}`);
    expect(modelChunks.join("").trimEnd() === "hello world", `unexpected chunks ${JSON.stringify(result.chunks)}`);
    expect(modelChunks.filter((chunk) => chunk.trim()).length >= 2, "browser stream was buffered");
    expect(result.fetchCalls === 1, `expected one prompt fetch, got ${result.fetchCalls}`);
    expect(result.model === "sdk/chrome-model", `unexpected model ${result.model}`);
    expect(JSON.stringify(result.api) === JSON.stringify(["checkpoint", "close", "prompt"]), `unexpected public API ${JSON.stringify(result.api)}`);
  });
  await runCase("Blob prompt", "transport=mock&autorun=describe&model=sdk%2Fchrome-model&blob-prompt=1", (result) => {
    expect(result.stopReason === "end_turn", `unexpected stop reason ${result.stopReason}`);
    expect(result.blobSent === true, "browser Blob image was not sent as a validated file part");
    expect(result.fetchCalls === 1, `expected one prompt fetch, got ${result.fetchCalls}`);
  });
  await runCase("iframe File prompt", "transport=mock&autorun=describe&model=sdk%2Fchrome-model&blob-prompt=1&blob-iframe=1", (result) => {
    expect(result.crossRealm === true, "test File was not created in another realm");
    expect(result.stopReason === "end_turn", `unexpected stop reason ${result.stopReason}`);
    expect(result.blobSent === true, "iframe File was not sent as a validated file part");
  });
  await runCase("stalled cancellation", "transport=stall&autorun=wait&cancel-after=50", (result) => {
    expect(result.stopReason === "cancelled", `unexpected stop reason ${result.stopReason}`);
    expect(result.fetchAborted, "browser fetch did not receive abort");
    expect(JSON.stringify(result.api) === JSON.stringify(["checkpoint", "close", "prompt"]), `unexpected public API ${JSON.stringify(result.api)}`);
  });
  await runCase("host tool and skill", "transport=mock&autorun=use%20the%20tool&host-tool=1&host-skill=1&model=sdk%2Fchrome-model", (result) => {
    expect(result.stopReason === "end_turn", `unexpected stop reason ${result.stopReason}`);
    expect(result.chunks.join("").trimEnd() === "tool done", `unexpected chunks ${JSON.stringify(result.chunks)}`);
    expect(result.fetchCalls === 2, `expected two prompt fetches, got ${result.fetchCalls}`);
    expect(result.toolAdvertised, "browser host tool was not advertised");
    expect(result.toolCalls === 1, `browser host tool ran ${result.toolCalls} times`);
    expect(result.toolResultSent, "browser host tool result did not reach the next model step");
    expect(result.skillSent, "browser host-provided skill instructions were omitted");
  });
  await runCase("unsupported UI", "force-unsupported=1", (result) => {
    expect(result.state === "unsupported", `unexpected state ${result.state}`);
  });

  const resolvedTarget = await command("Target.createTarget", { url: `http://127.0.0.1:${port}/sdk/index.html?force-unsupported=1` });
  const resolvedSession = await command("Target.attachToTarget", { targetId: resolvedTarget.targetId, flatten: true });
  try {
    await command("Runtime.enable", {}, resolvedSession.sessionId);
    await waitFor("location.pathname === '/sdk/index.html'", resolvedSession.sessionId);
    const evaluated = await command("Runtime.evaluate", {
      awaitPromise: true, returnByValue: true,
      expression: `(async () => {
        const {createFxAgent, resolveModel} = await import('/sdk/browser.js');
        const apiKey = 'browser-resolved-fixture';
        const id = 'browser/resolved-model';
        let gets = 0, posts = 0;
        const fetch = async (_, init) => {
          if (init.method === 'GET') {
            gets++;
            return Response.json({data:[{id,type:'language',max_tokens:2048,tags:['reasoning'],reasoning_options:[{type:'effort',values:['high']}]}]});
          }
          posts++;
          const body = JSON.parse(typeof init.body === 'string' ? init.body : new TextDecoder().decode(init.body));
          if (body.reasoning !== 'high' || body.maxOutputTokens !== 2048) throw new Error('selected capabilities missing');
          return new Response('data: {"type":"text-delta","delta":"ok"}\\n\\n' +
            'data: {"type":"finish","finishReason":{"unified":"stop","raw":"stop"}}\\n\\ndata: [DONE]\\n\\n',
            {headers:{'content-type':'text/event-stream'}});
        };
        const model = await resolveModel({apiKey, model:{id,effort:'high'}, fetch});
        let checkpoint;
        const output = [];
        for (let index = 0; index < 2; index++) {
          const agent = await createFxAgent({apiKey,model:JSON.parse(JSON.stringify(model)),fetch,
            wasm:new URL('/zig-out/bin/fx-core.wasm',location.href).href,...(checkpoint ? {checkpoint} : {})});
          try {
            const turn = agent.prompt('say ok');
            let text = '';
            for await (const event of turn) if (event.type === 'text_delta') text += event.delta;
            if ((await turn.result).stopReason !== 'end_turn') throw new Error('turn did not finish');
            output.push(text);
            checkpoint = await agent.checkpoint();
          } finally { await agent.close(); }
        }
        return {gets,posts,output,checkpointBytes:checkpoint.length};
      })()`,
    }, resolvedSession.sessionId);
    expect(!evaluated.exceptionDetails, JSON.stringify(evaluated.exceptionDetails));
    const value = evaluated.result.value;
    expect(value.gets === 1 && value.posts === 2, 'resolved browser agents fetched a catalog after explicit discovery');
    expect(value.output.join('') === 'okok' && value.checkpointBytes > 0, 'resolved browser restore or output failed');
    console.log('browser resolved model creation, prompt, and restore passed');
  } finally { await command("Target.closeTarget", { targetId: resolvedTarget.targetId }); }

  const { targetId } = await command("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await command("Target.attachToTarget", { targetId, flatten: true });
  try {
    await command("Runtime.enable", {}, sessionId);
    await command("Page.enable", {}, sessionId);
    await command("Page.navigate", { url: `http://127.0.0.1:${port}/sdk/browser-test-terminal.html` }, sessionId);
    const result = await withTimeout(
      waitFor("window.__fxBrowserTerminalTest && ['completed', 'failed'].includes(window.__fxBrowserTerminalTest.state) && window.__fxBrowserTerminalTest", sessionId),
      "browser terminal case timed out",
      15000,
    );
    expect(result.state === "completed", result.error || `unexpected terminal state ${result.state}`);
    expect(result.code === 0, `unexpected terminal exit code ${result.code}`);
    expect(result.output.includes("Run /help for commands"), "browser terminal startup output missing");
    expect(result.inputTaskRanDuringStream, "browser terminal input task was blocked until the buffered stream finished");
    expect(result.draftRenderedDuringStream, "browser terminal input rendered only after the stream source closed");
    expect(result.activeClearFetchAborted, "active /clear did not abort the browser fetch");
    expect(result.activeClearSessionRendered, "active /clear did not render a fresh browser session");
    expect(result.activeClearFollowupFresh, "browser follow-up retained cancelled session history");
    expect(result.dataListeners === 0, `browser terminal leaked ${result.dataListeners} data listener(s)`);
    expect(result.resizeListeners === 0, `browser terminal leaked ${result.resizeListeners} resize listener(s)`);
    console.log("browser terminal startup and shutdown passed");
  } finally {
    await command("Target.closeTarget", { targetId });
  }
} finally {
  socket.close();
  await stopChrome(chrome);
  server.close();
}
