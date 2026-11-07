#!/usr/bin/env python3
"""Link explicitly selected issues to a release, then close after verified OTA.

No issues are discovered automatically. Repeat runs do not duplicate comments.
Issue #135 additionally requires an explicit verified real-device test for manual
Beta releases. Tag-triggered releases keep it open until verified separately.
"""
import argparse
import hashlib
import json
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / ".github/release-issues.json"
TAG_RE = re.compile(r"^v\d+\.\d+\.\d+(?:-beta\.\d+)?$")
REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


def entries(tag):
    if not TAG_RE.fullmatch(tag):
        raise ValueError(f"Invalid release tag: {tag!r}")
    data = json.loads(CONFIG.read_text(encoding="utf-8"))
    found = data.get(tag, [])
    if not isinstance(found, list):
        raise ValueError(f"Issue mapping for {tag} must be a list")
    seen = set()
    for entry in found:
        if not isinstance(entry, dict) or type(entry.get("number")) is not int:
            raise ValueError(f"Invalid issue entry for {tag}: {entry!r}")
        number = entry["number"]
        if number < 1 or number in seen:
            raise ValueError(f"Duplicate/invalid issue number: {number}")
        if set(entry) - {"number", "requires_device_verification"}:
            raise ValueError(f"Unexpected issue entry keys for #{number}")
        if entry.get("requires_device_verification", False) not in (True, False):
            raise ValueError(f"Invalid verification setting for #{number}")
        seen.add(number)
    return found


def prepare(tag, path):
    items = entries(tag)
    if not items:
        return 0
    text = path.read_text(encoding="utf-8").rstrip() + "\n"
    section = "\n### 关联 Issues\n\n"
    for entry in items:
        number = entry["number"]
        suffix = "（需完成真机目录验证后关闭）" if entry.get("requires_device_verification") else "（发布成功后自动关闭）"
        section += f"- #{number} {suffix}\n"
    if "\n### 关联 Issues\n" not in text:
        path.write_text(text + section, encoding="utf-8")
    return len(items)


def gh(*args):
    completed = subprocess.run(("gh", *map(str, args)), check=True, text=True, capture_output=True)
    return completed.stdout


def gh_json(*args):
    return json.loads(gh(*args))


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_published_assets(tag, repo, package_path, manifest_path, channel_tag):
    """Compare the installed release ZIP AND fixed-channel manifest byte-for-byte.

    A merely-created Release object is not proof the OTA update channel points
    at the right binary. Never close issues until both assets are confirmed.
    """
    tag_info = gh_json("release", "view", tag, "--json", "assets,url")
    channel_info = gh_json("release", "view", channel_tag, "--json", "assets")
    package_name = package_path.name
    manifest_name = manifest_path.name
    if sum(a.get("name") == package_name for a in tag_info.get("assets", [])) != 1:
        raise RuntimeError("Release installation ZIP is missing or duplicated")
    if sum(a.get("name") == manifest_name for a in channel_info.get("assets", [])) != 1:
        raise RuntimeError("OTA manifest asset is missing or duplicated")
    with tempfile.TemporaryDirectory(prefix="miuread-verify-release-") as folder:
        folder = Path(folder)
        (folder / "package").mkdir()
        (folder / "manifest").mkdir()
        gh("release", "download", tag, "--pattern", package_name,
           "--dir", str(folder / "package"), "--clobber")
        gh("release", "download", channel_tag, "--pattern", manifest_name,
           "--dir", str(folder / "manifest"), "--clobber")
        package_actual = folder / "package" / package_name
        manifest_actual = folder / "manifest" / manifest_name
        if sha256(package_actual) != sha256(package_path):
            raise RuntimeError("Published installation ZIP hash differs from local build")
        if sha256(manifest_actual) != sha256(manifest_path):
            raise RuntimeError("Published OTA manifest differs from local build")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    expected_url = f"https://github.com/{repo}/releases/download/{tag}/{package_name}"
    if (manifest.get("version") != tag[1:] or manifest.get("package_url") != expected_url
            or manifest.get("sha256") != sha256(package_path)
            or manifest.get("size") != package_path.stat().st_size):
        raise RuntimeError("OTA manifest identity, size, or SHA-256 is not valid")
    return tag_info.get("url") or f"https://github.com/{repo}/releases/tag/{tag}"


def existing_comment(repo, number, marker):
    pages = gh_json("api", "--paginate", "--slurp",
                    f"repos/{repo}/issues/{number}/comments?per_page=100")
    if not isinstance(pages, list):
        raise RuntimeError("Unexpected issue comment API response")
    for page in pages:
        if isinstance(page, list):
            for comment in page:
                if isinstance(comment, dict) and marker in str(comment.get("body", "")):
                    return True
    return False


def close(tag, repo, package, manifest, channel_tag, verified_issue135=False):
    if not REPO_RE.fullmatch(repo):
        raise ValueError(f"Invalid repository name: {repo!r}")
    items = entries(tag)
    if not items:
        print(f"No issues configured for {tag}; nothing to close")
        return 0
    package, manifest = Path(package), Path(manifest)
    release_url = validate_published_assets(tag, repo, package, manifest, channel_tag)
    closed_count = 0
    for entry in items:
        number = entry["number"]
        if entry.get("requires_device_verification") and not verified_issue135:
            print(f"Issue #{number} remains open: real-device verification not confirmed")
            continue
        issue = gh_json("api", f"repos/{repo}/issues/{number}")
        if issue.get("pull_request"):
            raise RuntimeError(f"Refusing to close PR #{number} as an issue")
        marker = f"<!-- miuread-release-issue:{tag} -->"
        message = (f"已纳入 [觅阅 {tag}]({release_url}) 发布版本；"
                   "安装包和 OTA 更新清单均已核验。\n\n" + marker)
        if not existing_comment(repo, number, marker):
            gh("api", f"repos/{repo}/issues/{number}/comments", "--method", "POST", "-f", f"body={message}")
        if issue.get("state") == "open":
            gh("api", f"repos/{repo}/issues/{number}", "--method", "PATCH",
               "-f", "state=closed", "-f", "state_reason=completed")
            closed_count += 1
        else:
            print(f"Issue #{number} is already closed")
    return closed_count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="mode", required=True)
    a = commands.add_parser("prepare", help="append release issue references to notes")
    a.add_argument("--tag", required=True)
    a.add_argument("--notes", required=True, type=Path)
    b = commands.add_parser("close", help="close after both published assets are verified")
    b.add_argument("--tag", required=True)
    b.add_argument("--repo", required=True)
    b.add_argument("--package", required=True, type=Path)
    b.add_argument("--manifest", required=True, type=Path)
    b.add_argument("--channel-tag", required=True)
    b.add_argument("--device-verified", action="store_true")
    args = parser.parse_args()
    if args.mode == "prepare":
        print(f"Release notes linked to {prepare(args.tag, args.notes)} configured issues")
    else:
        count = close(args.tag, args.repo, args.package,
                      args.manifest, args.channel_tag, args.device_verified)
        print(f"Issues newly closed: {count}")


if __name__ == "__main__":
    main()
