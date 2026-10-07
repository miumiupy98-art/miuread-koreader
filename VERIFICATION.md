# 6.0.0-beta.1 Verification

- `tools/verify_600_beta1.py`: validates 6.0.0-beta.1 identity, Schema 136, inherited progress/shelf/bookstore contracts, lean-package boundaries, same-account Native shelf-auth preservation, independent shelf-auth revocation, bookstore copy polish, and StorePerf log throttling.
- Historical contract tests for beta.19 mapping and 5.9.1-beta.1 progress recovery no longer pin the current release to an old version string; they continue to validate the retained behavior.
- Release workflow still installs Lua 5.1 and LuaJIT and runs the production regression set before packaging.
