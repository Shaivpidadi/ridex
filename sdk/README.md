# libfx

`libfx` is the small fx agent kernel for JavaScript hosts. One agent is one
in-memory conversation with three operations: `prompt`, `checkpoint`, and
`close`.

```sh
npm install libfx
```

Node.js uses the native addon when available and falls back to WebAssembly.
Browsers use WebAssembly with JSPI. The default package has no runtime
dependencies and performs no MCP connection, skill scan, process spawn, or
filesystem read when imported.

## Agent

```js
import { createFxAgent } from "libfx";

const agent = await createFxAgent({
  env: { AI_GATEWAY_API_KEY: process.env.AI_GATEWAY_API_KEY },
});

const turn = agent.prompt("Explain this project.");

for await (const event of turn) {
  if (event.type === "text_delta") process.stdout.write(event.delta);
}

console.log(await turn.result); // { stopReason, usage }
const checkpoint = await agent.checkpoint();
await agent.close();
```

`prompt(input, { signal? })` accepts a string or text/resource blocks. It
returns an async iterable of normalized events:

- `text_delta`
- `reasoning_delta` when supplied by the provider
- `tool_start`
- `tool_end`

Only one prompt may run at a time. `checkpoint()` is idle-only and returns
opaque, bounded, versioned bytes. Restore them only when creating a fresh
agent:

```js
const restored = await createFxAgent({ checkpoint, env });
```

The checkpoint contains conversation history and usage only. The host owns
durable storage and must resupply models, credentials, instructions, tools,
MCP clients, and skill records.

## JavaScript tools and instructions

```js
const agent = await createFxAgent({
  instructions: "Keep answers concise.",
  tools: [{
    name: "lookup",
    description: "Look up a value.",
    inputSchema: {
      type: "object",
      properties: { key: { type: "string" } },
      required: ["key"],
    },
    async execute(input, { signal }) {
      return database.get(input.key, { signal });
    },
  }],
  env,
});
```

The JavaScript host is the authority for tool effects. The same descriptors,
schemas, cancellation, results, and events are used by N-API and WebAssembly.

## MCP

`libfx/mcp` accepts a host-owned MCP client. Transport, authentication,
elicitation, and cleanup remain outside the kernel.

```js
import { createMcpAdapter } from "libfx/mcp";

const mcp = await createMcpAdapter(client, {
  prefix: "github_",
  resources: ["repo://instructions"],
  prompts: ["review"],
});

const agent = await createFxAgent({
  tools: mcp.tools,
  instructions: mcp.instructions,
  env,
});

// ...
await agent.close();
await mcp.close();
```

## Skills

Use `libfx/skills` for already-loaded records or `libfx/skills/node` to load a
`SKILL.md` explicitly in Node or Bun.

```js
import { loadSkillFile } from "libfx/skills/node";
import { createSkillsAdapter } from "libfx/skills";

const record = await loadSkillFile("./skills/review/SKILL.md");
const skills = createSkillsAdapter([record]);
const agent = await createFxAgent({ ...skills, env });
```

## Backends

```js
await createFxAgent({ backend: "auto" });   // native, then Wasm fallback
await createFxAgent({ backend: "native" }); // require N-API
await createFxAgent({ backend: "wasm" });   // require Wasm + JSPI
```

Node.js 20+ is supported. Browser WebAssembly requires a JSPI-capable browser.
Some Node versions require `--experimental-wasm-jspi`.

## Interactive terminal

`createFxTerminal()` remains a separate terminal harness API. In browsers,
connect it to xterm.js with `xtermAdapter()`:

```js
import { createFxTerminal, xtermAdapter } from "libfx/browser";

const runtime = await createFxTerminal({
  terminal: xtermAdapter(term),
  env: { AI_GATEWAY_API_KEY: "<short-lived credential>" },
});

await runtime.interactive;
```

The terminal runtime exposes `interactive`, `exited`, `write`, `resize`, and
`abort`. Terminal session, config, OAuth, prompt-history, URL, and workspace
stores remain terminal-only host integrations.

## Security

Treat `nativeAddon` and `env.FX_GATEWAY_CHAT_URL` as trusted host
configuration. Do not embed long-lived credentials in public browser code.
Host tool functions, MCP clients, and skill loaders retain their own authority;
libfx validates and sequences them but does not grant operating-system access.
