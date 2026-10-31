# 6.5.0-beta.17 — Third-party metadata 429 isolation

The HTTP layer already supports per-scope persisted cooldown files. Google Books and Open Library previously omitted the scope, allowing third-party 429s to create `/weread-rate-limit.json` under the legacy global budget shared with WeRead progress APIs.

This patch explicitly uses distinct `metadata-google` and `metadata-openlibrary` scopes on all three third-party requests. Both paths fail fast on their **own** cooldown, without retrying 429 in the same call (`rate_limit_retries=0`); `NetworkMetadata.fetch()` already catches a failure from Google Books and tries Open Library if the book has an ISBN. Metadata lookups remain on the existing home background worker. The HTTP global implementation is deliberately untouched; its WeRead rate-limit and readtime/progress safety remain unchanged.

A legacy global cooldown created by an older installed build is not erased and expires normally. The patch neither guarantees a successful metadata response nor removes Web/E-Ink coordinate mismatch issues.
