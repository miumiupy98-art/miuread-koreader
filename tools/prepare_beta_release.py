#!/usr/bin/env python3
"""Prepare a MiuRead beta release from one version and one set of notes.

Called for workflow_dispatch. The release workflow prepares version files,
runs tests, commits metadata and creates an immutable tag. Direct tag pushes
are supported by the workflow and use a separate workspace-only preparation path.
"""

import argparse
import re
import subprocess
from pathlib import Path
from changelog_integrity import canonicalize_changelog

VERSION_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)-beta\.(\d+)$")
CONFIG_RE = re.compile(r'(?m)^(\s*VERSION\s*=\s*["\'])([^"\']+)(["\'],?\s*)$')
META_RE = re.compile(r'(?m)^(\s*version\s*=\s*["\'])([^"\']+)(["\'],?\s*)$')


def version_key(version):
    match = VERSION_RE.fullmatch(version)
    if not match:
        raise ValueError(f"无效的 Beta 版本：{version!r}，应为 6.0.1-beta.2 这样的格式")
    return tuple(int(part) for part in match.groups())


def parse_notes(notes):
    if not isinstance(notes, str):
        raise ValueError("更新说明必须是字符串")
    if not notes.strip():
        notes = "版本更新与维护"
    if len(notes) > 4000:
        raise ValueError("更新说明超过 4000 个字符")
    # GitHub workflow_dispatch uses a text input. Separate multiple points
    # with ' | ', or pass actual newlines when invoking through the CLI.
    lines = notes.replace(" | ", "\n").splitlines()
    bullets = []
    for line in lines:
        line = line.strip()
        if line.startswith(("- ", "* ", "• ")):
            line = line[2:].strip()
        if not line:
            continue
        if line.startswith("#"):
            raise ValueError("更新说明不要包含 Markdown 标题；只填写改动内容")
        bullets.append(line)
    if not bullets or len(bullets) > 20:
        raise ValueError("更新说明需要 1–20 条有效内容")
    return bullets



def generated_notes_from_commits(root):
    """Use recent user-facing source changes when optional notes are empty.

    Never invent detailed fixes from a generic CI or release commit.
    When no suitable history exists, parse_notes retains its honest generic fallback.
    """
    try:
        result=subprocess.run(
            ["git", "-C", str(root), "log", "-25", "--no-merges", "--pretty=format:%s", "--", "miuread.koplugin"],
            text=True, capture_output=True, check=False, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    if result.returncode != 0:
        return ""
    notes=[]
    for line in result.stdout.splitlines():
        line=" ".join(line.strip().split())
        if not line or len(line)>200 or re.search(r"(?i)^(?:chore\(release\)|chore:|sync beta|merge )",line):
            continue
        if line not in notes:
            notes.append(line)
        if len(notes)>=5:
            break
    return " | ".join(notes)


def find_version(contents, pattern, filename):
    matches = list(pattern.finditer(contents))
    if len(matches) != 1:
        raise ValueError(f"{filename} 应有且只有一个版本字段，实际为 {len(matches)} 个")
    version_key(matches[0].group(2))
    return matches[0].group(2)


def replace_version(contents, pattern, new_version):
    return pattern.sub(lambda match: match.group(1) + new_version + match.group(3), contents, count=1)


def extract_existing_notes(changelog, version):
    lines = changelog.splitlines()
    for index, line in enumerate(lines):
        if line == f"## {version}" or line.startswith((f"## {version} - ", f"## {version} — ")):
            next_heading = next(
                (i for i in range(index + 1, len(lines)) if lines[i].startswith("## ")),
                len(lines),
            )
            return [
                item[2:].strip()
                for item in lines[index + 1:next_heading]
                if item.startswith("- ") and item[2:].strip()
            ]
    return None


def prepare(root, version, notes):
    version_target = version_key(version)
    root = Path(root)
    if not notes.strip():
        notes = generated_notes_from_commits(root)
    bullets = parse_notes(notes)
    config_path = root / "miuread.koplugin/miuread/config.lua"
    meta_path = root / "miuread.koplugin/_meta.lua"
    changelog_path = root / "CHANGELOG.md"
    config = config_path.read_text(encoding="utf-8")
    meta = meta_path.read_text(encoding="utf-8")
    original_changelog = changelog_path.read_text(encoding="utf-8")
    changelog = canonicalize_changelog(original_changelog)

    config_version = find_version(config, CONFIG_RE, "config.lua")
    meta_version = find_version(meta, META_RE, "_meta.lua")
    if config_version != meta_version:
        raise ValueError(f"源码版本已不一致：config={config_version}, meta={meta_version}")
    if version_target < version_key(config_version):
        raise ValueError(f"禁止版本回退：当前 {config_version}，目标 {version}")

    previous_notes = extract_existing_notes(changelog, version)
    if version == config_version and previous_notes is None:
        raise ValueError(f"源码已经是 {version}，但 CHANGELOG 缺少对应版本条目")
    if version != config_version and previous_notes is not None:
        raise ValueError(f"CHANGELOG.md 已存在 {version} 的条目，但源码仍为旧版本；请人工检查")

    if previous_notes is not None:
        # The target section may be buried underneath older entries. Remove
        # just that section, then recreate it at the beginning.
        lines = changelog.splitlines(keepends=True)
        starts = [i for i, line in enumerate(lines) if
                  line.rstrip("\r\n") == f"## {version}" or
                  line.rstrip("\r\n").startswith((f"## {version} - ", f"## {version} — "))]
        if len(starts) != 1:
            raise ValueError(f"CHANGELOG.md 中 {version} 记录不唯一")
        start = starts[0]
        end = next((i for i in range(start + 1, len(lines))
                    if lines[i].startswith("## ")), len(lines))
        changelog = "".join(lines[:start] + lines[end:])

    # A genuine document header is always kept at the top, not in the
    # middle of historic release sections.
    prefix_match = re.match(r"(?i)^# Changelog[ \t]*\n+", changelog)
    prefix = "# Changelog\n\n" if prefix_match else ""
    history = changelog[prefix_match.end():] if prefix_match else changelog
    new_entry = f"## {version} - Beta Update\n\n" + "\n".join(
        f"- {bullet}" for bullet in bullets) + "\n\n"
    new_changelog = prefix + new_entry + history.lstrip("\r\n")
    new_config = replace_version(config, CONFIG_RE, version)
    new_meta = replace_version(meta, META_RE, version)
    # All checks above complete before writing anything.
    changed = (new_config != config or new_meta != meta or
               new_changelog != original_changelog)
    if not changed:
        print(f"Already prepared: {version} (no changes)")
        return False
    config_path.write_text(new_config, encoding="utf-8")
    meta_path.write_text(new_meta, encoding="utf-8")
    changelog_path.write_text(new_changelog, encoding="utf-8")
    print(f"Prepared {version}: version metadata and latest changelog header")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".")
    parser.add_argument("--version", required=True)
    parser.add_argument("--notes", required=True)
    args = parser.parse_args()
    try:
        prepare(args.root, args.version, args.notes)
    except (OSError, ValueError) as exc:
        parser.error(str(exc))


if __name__ == "__main__":
    main()
