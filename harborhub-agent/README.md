# FX patch recovery Harbor Hub agent

This source package lets Harbor Hub stage the exact Linux binary for the X11
patch recovery experiment. It preserves the benchmarked
`fx ask --yolo --json` execution path; ACP is only the hosted transport
envelope.

- FX experiment source commit: `30bc05e2188d162f896bad9407ed0d1f45d24ab1`
- Binary SHA-256: `b9807ac081c3b6e102cf7f7e71641250fb9d2171c1e36f8d35be4b8317af2a32`
- Binary target: `x86_64-linux-musl`
- Optimization profile: `ReleaseSafe`
- Model: `vercel_ai_gateway/openai/gpt-5.6-sol`
- Effort: `xhigh`
- Logs: `/logs/agent/fx.json`, `/logs/agent/fx-stderr.log`, and
  `/logs/agent/fx-trace.log`

Use Harbor's direct credential mode with `AI_GATEWAY_API_KEY` and
`HOSTED_INFERENCE_URL=https://ai-gateway.vercel.sh`. Set
`FX_EXPERIMENT_X9_EDITOR=patch_v3` and
`FX_EXPERIMENT_X9_PROVIDER_RETRY=control` to match the prior Patch v3 run.

This build keeps `edit_file` available alongside transactional multi-file and
multi-hunk `apply_patch`. It adds deterministic missing, ambiguous, and no-op
outcomes; skips context-only hunks; and prevents queued fallback mutations from
running behind an unobserved failed mutation. Reads remain available so the
model can inspect current state before retrying.
