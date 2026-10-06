# 5.9.0-beta.19 Verification

- `tools/test_beta19_robust_mapping.lua`: locks multi-anchor capture, source-only normalization, coordinate-conflict fail-closed behavior, beta.18 fresh-context retention, and quiet text-anchor UI semantics.
- `tools/verify_590_beta19.py`: release/static verifier for version identity and beta.19 invariants.
- Existing position resolution, open-sync, cloud mirror/freshness, terminal guard, finished resolution, Store repair, beta.17 lifecycle and beta.18 fresh-context protections remain regression-tested.
- Release workflow runs Lua syntax checks and beta.19 verification before tag creation.
