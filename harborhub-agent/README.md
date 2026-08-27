# FX X9 Harbor Hub factorial agent

This source package lets Harbor Hub stage one exact Linux binary for the X9
control, Patch v3, and adaptive provider-retry runs. It preserves the benchmarked
`fx ask --yolo --json` execution path; ACP is only the hosted transport envelope.

- FX experiment source commit: `efeae8be879b3d7db9e85272dd8ce1586ec8683c`
- Binary SHA-256: `ababc24f21d6376cd2e3419b24d8260d3a0f1224906f677afba0e32e7e93c169`
- Binary target: `x86_64-linux-musl`
- Model: `vercel_ai_gateway/openai/gpt-5.6-sol`
- Effort: `xhigh`
- Logs: `/logs/agent/fx.json`, `/logs/agent/fx-stderr.log`, and
  `/logs/agent/fx-trace.log`

Use Harbor's direct credential mode with `AI_GATEWAY_API_KEY` and
`HOSTED_INFERENCE_URL=https://ai-gateway.vercel.sh`. Keep the agent repository,
Git ref, source directory, manifest path, model, effort, task set, and concurrency
identical across all three jobs. Only the following non-secret environment varies:

| Run | `FX_EXPERIMENT_X9_EDITOR` | `FX_EXPERIMENT_X9_PROVIDER_RETRY` |
| --- | --- | --- |
| Control | `control` | `control` |
| Patch v3 | `patch_v3` | `control` |
| Adaptive retry | `control` | `adaptive_v1` |

Patch v3 replaces `edit_file` with the transactional multi-file/multi-hunk
`apply_patch` tool. Adaptive retry caps transient provider recovery at three
attempts with 30, 60, and 120 second response-head deadlines.
