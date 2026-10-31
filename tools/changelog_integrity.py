#!/usr/bin/env python3
"""Non-destructive integrity check for MiuRead's release changelog.

Identical duplicate release entries (including legacy `v` headings) are
collapsed. Different bodies for one version are rejected with line numbers;
no historic changelog text is silently discarded.
"""
import re

VERSION_ENTRY = re.compile(r"^## (?P<legacy>v?)(?P<version>\d+\.\d+\.\d+-beta\.\d+)(?:$| (?:-|—) .*)$")


def normalize_changelog(text):
    lines = text.splitlines(keepends=True)
    boundaries = [i for i, line in enumerate(lines)
                  if line.strip().lower() == '# changelog' or line.startswith('## ')]
    if not boundaries:
        return text
    chunks = [lines[:boundaries[0]]]
    seen_versions = {}
    first_header = None
    for offset, start in enumerate(boundaries):
        end = boundaries[offset+1] if offset+1 < len(boundaries) else len(lines)
        chunk = lines[start:end]
        heading = chunk[0].strip()
        if heading.lower() == '# changelog':
            if first_header is None:
                first_header = start+1
                chunks.append(chunk)
            else:
                # A repeated document heading can be removed only if its
                # section contains no additional prose or unrelated content.
                if any(line.strip() for line in chunk[1:]):
                    raise ValueError(f'Duplicate # Changelog at line {start+1} includes content; original at {first_header}')
            continue
        match = VERSION_ENTRY.fullmatch(heading)
        if match:
            version = match.group('version')
            title = heading.replace('## v'+version, '## '+version, 1)
            body = '\n'.join(line.rstrip() for line in chunk[1:]).strip()
            value = (title, body)
            prior = seen_versions.get(version)
            if prior:
                original_line, original_content = prior
                if original_content != value:
                    raise ValueError(f'Conflicting changelog sections for {version}: lines {original_line} and {start+1}; refusing to discard differing notes')
                # Duplicate of exactly the same entry, safe to omit.
                continue
            seen_versions[version] = (start+1, value)
        chunks.append(chunk)
    return ''.join(''.join(chunk) for chunk in chunks)
