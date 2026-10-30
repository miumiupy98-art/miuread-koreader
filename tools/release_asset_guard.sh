#!/usr/bin/env bash
# Called from both release workflows AFTER the complete source, ZIP and manifest pass.
set -euo pipefail
: "${RELEASE_TAG:?}" "${PACKAGE_NAME:?}" "${CHANNEL_TAG:?}" "${MANIFEST_NAME:?}" "${RELEASE_CHANNEL:?}"
: "${GH_TOKEN:?}" "${RUNNER_TEMP:?}"
mkdir -p "$RUNNER_TEMP/miuread-release-checks"
CHECK_DIR="$RUNNER_TEMP/miuread-release-checks"
# Existing immutable versioned asset: compare instead of uploading with --clobber.
EXISTS="$(gh release view "$RELEASE_TAG" --json assets --jq ".assets[] | select(.name==\"$PACKAGE_NAME\") | .name" || true)"
if [ -n "$EXISTS" ]; then
  gh release download "$RELEASE_TAG" --pattern "$PACKAGE_NAME" --dir "$CHECK_DIR" --clobber
  python3 tools/release_integrity.py same-asset \
    --current "$CHECK_DIR/$PACKAGE_NAME" --proposed "dist/$PACKAGE_NAME"
  echo "Immutable release asset verified: $RELEASE_TAG/$PACKAGE_NAME"
else
  gh release upload "$RELEASE_TAG" "dist/$PACKAGE_NAME"
fi
# GitHub API, independent of the possibly stale public CDN, must return the
# exact bytes. Do not promote the device update channel if this check fails.
rm -f "$CHECK_DIR/$PACKAGE_NAME"
gh release download "$RELEASE_TAG" --pattern "$PACKAGE_NAME" --dir "$CHECK_DIR"
python3 tools/release_integrity.py same-asset \
  --current "$CHECK_DIR/$PACKAGE_NAME" --proposed "dist/$PACKAGE_NAME"

# Check the current channel's version before any channel-asset replacement.
# A missing channel release means this is its first publication.
if gh release view "$CHANNEL_TAG" >/dev/null 2>&1; then
  existing="$(gh release view "$CHANNEL_TAG" --json assets --jq ".assets[] | select(.name==\"$MANIFEST_NAME\") | .name")"
  if [ -n "$existing" ]; then
    gh release download "$CHANNEL_TAG" --pattern "$MANIFEST_NAME" --dir "$CHECK_DIR" --clobber
    python3 tools/release_integrity.py promote --channel "$RELEASE_CHANNEL" \
      --current "$CHECK_DIR/$MANIFEST_NAME" --proposed "dist/$MANIFEST_NAME"
  else
    python3 tools/release_integrity.py promote --channel "$RELEASE_CHANNEL" \
      --proposed "dist/$MANIFEST_NAME"
  fi
else
  python3 tools/release_integrity.py promote --channel "$RELEASE_CHANNEL" \
    --proposed "dist/$MANIFEST_NAME"
fi
