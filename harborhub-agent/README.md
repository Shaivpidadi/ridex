# FX X6 Harbor Hub agent source

This source package lets Harbor Hub stage the exact X6 Linux binary while
preserving the benchmarked `fx ask --yolo --json` execution path. ACP is used
only as the hosted transport envelope; the task itself is solved by the pinned
FX CLI binary.

- FX source commit: `dd87df1578d2390482fcb1432387c9755929fcb4`
- Binary SHA-256: `a02d34b3c34783ef0af9610bded4ac2610a695fed3ba4305cc419f39122f3b2c`
- Binary target: `x86_64-linux-musl`
- Model: `vercel_ai_gateway/openai/gpt-5.6-sol`
- Effort: `xhigh`

Harbor custom agents run in credential-proxy mode. The ACP wrapper consumes
Harbor's injected `HOSTED_INFERENCE_URL` and `HOSTED_INFERENCE_TOKEN`, then
streams FX's normal AI Gateway request through a loopback-only compatibility
proxy. The hosted provider credential is never exposed to the FX process.

The efficiency and compaction variants are selected independently with
`FX_EXPERIMENT_X6_EFFICIENCY` and `FX_EXPERIMENT_X6_COMPACTION` in the hosted
job's non-secret agent environment.
