#!/usr/bin/env python3
"""Shared, dependency-free release identity, asset and OTA promotion checks.

Run BEFORE modifying a fixed update-channel asset. A successful build or tag
alone is not proof that the public device update endpoint is safe.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys


def parse_version(version, channel):
    pat = r"(\d+)\.(\d+)\.(\d+)-beta\.(\d+)" if channel == "beta" else r"(\d+)\.(\d+)\.(\d+)"
    match = re.fullmatch(pat, str(version))
    if not match:
        raise ValueError("Invalid %s version: %r" % (channel, version))
    return tuple(map(int, match.groups()))


def check_manifest(manifest, channel):
    if not isinstance(manifest, dict) or manifest.get("channel") != channel:
        raise ValueError("Manifest has wrong channel")
    parse_version(manifest.get("version"), channel)
    digest = str(manifest.get("sha256") or "")
    if re.fullmatch(r"[0-9a-fA-F]{64}", digest) is None:
        raise ValueError("Manifest has no valid SHA-256")
    if not isinstance(manifest.get("size"), int) or manifest["size"] <= 0:
        raise ValueError("Manifest has no valid package size")
    if not isinstance(manifest.get("package_url"), str) or not manifest["package_url"].endswith(
        "/v%s/miuread-v%s-full.zip" % (manifest["version"], manifest["version"])):
        raise ValueError("Manifest URL does not match the immutable release identity")
    return manifest


def promotion(current, proposed, channel):
    check_manifest(proposed, channel)
    if current is None:
        return "first_publication"
    check_manifest(current, channel)
    older = parse_version(current["version"], channel)
    newer = parse_version(proposed["version"], channel)
    if newer < older:
        raise ValueError("Refusing OTA rollback: %s -> %s" % (current["version"], proposed["version"]))
    if newer == older:
        for key in ("sha256", "size", "package_url"):
            if current[key] != proposed[key]:
                raise ValueError("Immutable release %s differs (%s)" % (proposed["version"], key))
        return "already_published"
    return "advance"


def same_asset(existing, proposed):
    a = Path(existing).read_bytes()
    b = Path(proposed).read_bytes()
    if hashlib.sha256(a).digest() != hashlib.sha256(b).digest():
        raise ValueError("An existing release ZIP differs; never replace fixed-version assets")
    return True


def main():
    p = argparse.ArgumentParser()
    p.add_argument("action", choices=("promote", "same-asset", "package"))
    p.add_argument("--channel", choices=("beta", "stable"))
    p.add_argument("--current", type=Path)
    p.add_argument("--proposed", type=Path, required=True)
    p.add_argument("--package", type=Path)
    args = p.parse_args()
    try:
        if args.action == "same-asset":
            if not args.current:
                raise ValueError("--current is required")
            same_asset(args.current, args.proposed)
            print("PASS: immutable release asset is byte-identical")
        elif args.action == "promote":
            if not args.channel:
                raise ValueError("--channel is required")
            desired = json.loads(args.proposed.read_text(encoding="utf-8"))
            previous = json.loads(args.current.read_text(encoding="utf-8")) if args.current else None
            print("PASS: OTA promotion:", promotion(previous, desired, args.channel))
        else:
            if not args.channel or not args.package:
                raise ValueError("--channel and --package are required")
            desired = check_manifest(json.loads(args.proposed.read_text(encoding="utf-8")), args.channel)
            blob = args.package.read_bytes()
            if len(blob) != desired["size"] or hashlib.sha256(blob).hexdigest() != desired["sha256"]:
                raise ValueError("ZIP size or SHA-256 differs from release manifest")
            print("PASS: ZIP bytes match manifest")
    except (ValueError, OSError, json.JSONDecodeError) as exc:
        print("ERROR:", exc, file=sys.stderr)
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
