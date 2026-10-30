#!/usr/bin/env python3
"""Check beta release identity after preparation, before any tag or upload."""
import argparse
import re
from pathlib import Path

def check(root, version):
    root = Path(root)
    paths = [root / "miuread.koplugin/miuread/config.lua",
             root / "miuread.koplugin/_meta.lua"]
    patterns = [r"(?m)^\s*VERSION\s*=\s*\"([^\"]+)\"",
                r"(?m)^\s*version\s*=\s*\"([^\"]+)\""]
    for path, pattern in zip(paths, patterns):
        matches = re.findall(pattern, path.read_text(encoding="utf-8"))
        if matches != [version]:
            raise ValueError(f"{path.name}: 实际版本 {matches}，目标 {version}")
    text = (root / "CHANGELOG.md").read_text(encoding="utf-8")
    headings = re.findall(r'(?m)^## ([0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+)(?:\s+-\s+.*|\s+—\s+.*)?$', text)
    if not headings or headings[0] != version:
        raise ValueError(f"CHANGELOG 最新 Beta {headings[0] if headings else '无'}，目标 {version}")
    if headings.count(version) != 1:
        raise ValueError(f"CHANGELOG 中 {version} 版本记录数量不等于 1")
    return True

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".")
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    try:
        check(args.root, args.version)
    except (ValueError, OSError) as exc:
        parser.error(str(exc))
    print(f"PASS: Beta 版本文件及 CHANGELOG 最新记录一致：{args.version}")
