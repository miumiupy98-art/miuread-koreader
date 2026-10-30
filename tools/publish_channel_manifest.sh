#!/usr/bin/env bash
# Final and only mutable OTA step. The promotion guard has already passed.
set -euo pipefail
: "${GH_TOKEN:?}" "${CHANNEL_TAG:?}" "${MANIFEST_NAME:?}" "${RUNNER_TEMP:?}"
CHECK_DIR="$RUNNER_TEMP/miuread-release-checks"
mkdir -p "$CHECK_DIR"
current="$CHECK_DIR/$MANIFEST_NAME"
proposed="dist/$MANIFEST_NAME"
if [ -f "$current" ] && cmp -s "$current" "$proposed"; then
  echo "OTA already points to identical, verified manifest; no replacement needed."
  exit 0
fi
restore() {
  if [ -f "$current" ]; then
    echo "::warning::OTA replacement failed; trying to restore previous channel asset" >&2
    gh release upload "$CHANNEL_TAG" "$current" --clobber || true
  fi
}
if ! gh release upload "$CHANNEL_TAG" "$proposed" --clobber; then
  restore
  exit 1
fi
verified="$CHECK_DIR/verified-$MANIFEST_NAME"
rm -f "$verified"
mkdir -p "$CHECK_DIR/verified"
# Download from the GitHub Release API and compare bytes to the staged file.
if ! gh release download "$CHANNEL_TAG" --pattern "$MANIFEST_NAME" --dir "$CHECK_DIR/verified" --clobber || \
   ! cmp -s "$proposed" "$CHECK_DIR/verified/$MANIFEST_NAME"; then
  restore
  echo "::error::OTA manifest failed GitHub API readback" >&2
  exit 1
fi
echo "PASS: channel manifest verified against GitHub API download"
