#!/usr/bin/env python3
"""Prepare a MiuRead beta release from one version and one set of notes.

Called for workflow_dispatch. The release workflow prepares version files,
runs tests, commits metadata and creates an immutable tag. Direct tag pushes
are supported by the workflow and use a separate workspace-only preparation path.
"""

import argparse
import re
from pathlib import Path
from changelog_integrity import normalize_changelog

VERSION_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)-beta\.(\d+)$")
CONFIG_RE = re.compile(r'(?m)^(\s*VERSION\s*=\s*["\'])([^"\']+)(["\'],?\s*)$')
META_RE = re.compile(r'(?m)^(\s*version\s*=\s*["\'])([^"\']+)(["\'],?\s*)$')


def version_key(version):
    match = VERSION_RE.fullmatch(version)
    if not match:
        raise ValueError(f"无效的 Beta 版本：{version!r}，应为 6.0.1-beta.2 这样的格式")
    return tuple(int(part) for part in match.groups())


def parse_notes(notes):
    if not isinstance(notes, str) or not notes.strip():
        raise ValueError("更新说明不能为空")
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
    bullets = parse_notes(notes)
    root = Path(root)
    config_path = root / "miuread.koplugin/miuread/config.lua"
    meta_path = root / "miuread.koplugin/_meta.lua"
    changelog_path = root / "CHANGELOG.md"
    config = config_path.read_text(encoding="utf-8")
    meta = meta_path.read_text(encoding="utf-8")
    original_changelog = changelog_path.read_text(encoding="utf-8")
    changelog = normalize_changelog(original_changelog)

    config_version = find_version(config, CONFIG_RE, "config.lua")
    meta_version = find_version(meta, META_RE, "_meta.lua")
    if config_version != meta_version:
        raise ValueError(f"源码版本已不一致：config={config_version}, meta={meta_version}")
    if version_target < version_key(config_version):
        raise ValueError(f"禁止版本回退：当前 {config_version}，目标 {version}")

    previous_notes = extract_existing_notes(changelog, version)
    if version == config_version:
        if previous_notes is None:
            raise ValueError(f"源码已经是 {version}，但 CHANGELOG 缺少对应版本条目")
        if previous_notes == bullets:
            if changelog != original_changelog:
                changelog_path.write_text(changelog, encoding="utf-8")
                print(f"Normalized duplicate release notes for {version}")
                return True
            print(f"Already prepared: {version} (no changes)")
            return False
        # The workflow independently forbids changing an existing immutable tag.
        # Before tagging, the user may edit the prepared release notes explicitly.
        lines = changelog.splitlines(keepends=True)
        start = next((i for i, line in enumerate(lines)
                      if line.rstrip("\r\n") == f"## {version}"
                      or line.rstrip("\r\n").startswith((f"## {version} - ", f"## {version} — "))), None)
        if start is None:
            raise ValueError(f"CHANGELOG.md 中找不到 {version} 版本标题")
        end = next((i for i in range(start + 1, len(lines))
                    if lines[i].startswith("## ")), len(lines))
        entry = f"## {version} - Beta Update\n\n" + "\n".join(f"- {item}" for item in bullets) + "\n\n"
        updated = "".join(lines[:start]) + entry + "".join(lines[end:])
        changelog_path.write_text(updated, encoding="utf-8")
        print(f"Updated prepared release notes for {version} (version metadata unchanged)")
        return True
    if previous_notes is not None:
        raise ValueError(f"CHANGELOG.md 已存在 {version} 的条目，但源码仍为旧版本；请人工检查")

    new_config = replace_version(config, CONFIG_RE, version)
    new_meta = replace_version(meta, META_RE, version)
    new_entry = f"## {version} - Beta Update\n\n" + "\n".join(f"- {bullet}" for bullet in bullets) + "\n\n"
    # Keep an existing top-level Changelog heading if one is present.
    header = re.match(r"(# Changelog\s*\n+)", changelog, flags=re.I)
    if header:
        new_changelog = header.group(1) + new_entry + changelog[header.end():]
    else:
        new_changelog = new_entry + changelog

    # Validate all inputs before writing any files.
    config_path.write_text(new_config, encoding="utf-8")
    meta_path.write_text(new_meta, encoding="utf-8")
    changelog_path.write_text(new_changelog, encoding="utf-8")
    print(f"Prepared {version}: config.lua, _meta.lua, CHANGELOG.md")
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
