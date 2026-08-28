# FX hardened apply_patch Harbor Hub agent

This source package lets Harbor Hub stage the exact Linux binary for the
hardened Patch v3 follow-up. It preserves the benchmarked `fx ask --yolo --json`
execution path; ACP is only the hosted transport envelope.

- FX experiment source commit: `d335962babe9dcbbdd839cd63279e9e4bbcc18b0`
- Binary SHA-256: `f7728ec1bbbeb8dd0fef4f6fd8c900d25628bfd18f5494e9653ada173d8059b9`
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

This build keeps `edit_file` available while adding the transactional
multi-file/multi-hunk `apply_patch` tool. The hardening adds bounded context
recovery for whitespace drift while retaining ambiguity and transaction-safety
checks.
