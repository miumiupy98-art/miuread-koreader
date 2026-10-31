# Feature migration audit

| Module/behavior | Origin | beta.10 disposition |
|---|---|---|
| Progress upload/confirmation, remote read/resolve, pending recovery, reading-end sync | Uploaded beta.9 | Seven core `main.lua` functions byte-for-byte identical; checked via SHA-256 |
| Worker ownership at sleep/close, display active time channel | Uploaded beta.9 | Preserved |
| Web auth revision for Web time service | Later beta7 reference | Merged into store + specific time routes of sync |
| Stopped-reader offline outbox guard | Later beta7 reference | Targeted change in readtime_controller |
| Comment progress UI and opt-in chapter preloader | Later beta7 reference | Ported with explicit hooks and setting; defaults off |
| Home sync management shortcut | Later beta7 reference | Ported as menu |
| Full-book Web coordinate source readiness | New beta.10 | New Gate, exact cache, validation before EPUB installation |
| Late ProgressFence, replay policy, position_event | Later 6.5 series | NOT imported: they change working progress sync |
| Post-install backfill queue | Later beta7 | NOT imported: old implementation depended on missing helper and did not satisfy pre-read readiness |
| Existing old EPUBs | Uploaded beta.9 | Unchanged on upgrade |
| Existing build workflows | Uploaded beta.9 | Preserved; version updated |

**Not guaranteed**: Full feature parity with all historic 6.5 branches. Only identified and explicitly listed features were ported. The beta.9 base itself already omitted some earlier upgrades.
