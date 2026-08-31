# FX patch recovery + adaptive retry Harbor Hub agent

This source package lets Harbor Hub stage the exact Linux binary for the X12
combined patch recovery and adaptive provider retry experiment. It preserves the benchmarked
`fx ask --yolo --json` execution path; ACP is only the hosted transport
envelope.

- FX experiment source commit: `d345e0fd14e2ae5bee452029604b5fe9e6ac65ce`
- Binary SHA-256: `5f4a06c51cbdbd09533ace66e95e0fe64e13af1348cb7ac361c5f41ca8a4283f`
- Binary target: `x86_64-linux-musl`
- Optimization profile: `ReleaseSafe`
- Model: `vercel_ai_gateway/openai/gpt-5.6-sol`
- Effort: `xhigh`
- Logs: `/logs/agent/fx.json`, `/logs/agent/fx-stderr.log`, and
  `/logs/agent/fx-trace.log`

Use Harbor's direct credential mode with `AI_GATEWAY_API_KEY` and
`HOSTED_INFERENCE_URL=https://ai-gateway.vercel.sh`. The wrapper pins
`FX_EXPERIMENT_X9_EDITOR=patch_v3` and
`FX_EXPERIMENT_X9_PROVIDER_RETRY=adaptive_v1` for every task.

This build keeps `edit_file` available alongside transactional multi-file and
multi-hunk `apply_patch`. It adds deterministic missing, ambiguous, and no-op
outcomes; skips context-only hunks; and prevents queued fallback mutations from
running behind an unobserved failed mutation. Missing and ambiguous failures
include bounded match evidence and emit stable trace reasons. Reads remain
available so the model can inspect current state before retrying.

Adaptive provider recovery caps a failed response sequence at three semantic
attempts and escalates response-head deadlines from 30 to 60 to 120 seconds.
