# GitHub Pull Request — MiuRead v6.5.0-beta.28

## Title
fix(ci): release beta.28 with corrected local EPUB regression fixture and full comment tests

## Summary
- Advance the beta version to **6.5.0-beta.28**, with a changelog entry covering the CI correction and completed local EPUB community comment integration carried forward from beta.27.
- Include the corrected `tools/test_reader_local_book_isolation.lua` from the beta.27 CI fix. The test now loads the actual `_local_comment_enabled` method from `main.lua` and simulates bound/unbound local EPUBs, instead of failing because its reduced test plugin lacks that method.
- Extend the existing **Verify Lua syntax and scoped regressions before publishing** step to execute the beta.27 feature regressions (`test_local_comments_beta27.lua`, `test_imported_public_comments.lua`, and the integration-contract Python suite).
- Generalize the integration-contract version assertion to check that the manifest-facing `_meta.lua` and `config.lua` versions match; rename it to `test_local_comments_integration_contract.py` to avoid baking beta.27 into future releases.
- Preserve the existing manual and auto-Tag release paths, package naming, full archive manifest, release issue handling, OTA beta-channel, and existing KOReader plugin runtime behavior.

## Changed files relative to the corrected beta.27 source
- `miuread.koplugin/_meta.lua`: version only.
- `miuread.koplugin/miuread/config.lua`: version only.
- `.github/workflows/release-beta.yml`: run the three local-comments regression suites before packaging.
- `tools/test_local_comments_integration_contract.py`: rename and generalize previous beta.27 integration contract; verify CI includes all three tests.
- `tools/test_beta27_integration_contract.py`: removed after rename.
- `CHANGELOG.md`, `README.md`, `PR_SUMMARY.md`: release metadata and documentation.

## Tests and validation
- Existing fixture fix for `tools/test_reader_local_book_isolation.lua` is present in the release base.
- Local plugin Lua syntax and executable mock tests must pass on GitHub Actions' **LuaJIT** runner before the full ZIP is published.
- Python contract and release issue automation tests should pass without network calls.
- A local package ZIP and SHA-256 digest are generated from the same `tools/build_package.py` used by the release workflow.
- Actual WeRead network responses and Kindle/KOReader gestures remain unverified until device testing.

## Release steps
1. Merge the complete beta.28 source into the **beta** branch.
2. Run **Release beta full package** with `workflow_dispatch` on branch `beta` and version `6.5.0-beta.28` (or push a new, immutable `v6.5.0-beta.28` tag pointing at the same commit).
3. Confirm the Verify Lua step succeeds before expecting the full package or beta-channel manifest to be published.
4. Do not rerun an older beta.27 failed workflow and expect it to pick up these changes.

## Scope
No changes to book downloading, reading-time reporting, position sync, comment protocol, SQLite schema (136), or device UI beyond what is already in beta.27.
