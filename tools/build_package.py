"""Build the regular plugin archive locally or in the release workflow."""
import argparse
import sys
import hashlib
from pathlib import Path
import re
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "miuread.koplugin"
REQUIRED = {
    "_meta.lua", "main.lua", "miuread/config.lua", "LICENSE", "NOTICE", "THIRD_PARTY_NOTICES",
    "miuread/readtime_controller.lua", "miuread/readtime_outbox.lua", "miuread/readtime_stats.lua",
    "miuread/readtime_protocol.lua", "miuread/eink_readtime.lua",
    "miuread/readtime_clock.lua", "miuread/readtime_metadata.lua",
    "licenses/weread-omni-MIT.txt", "licenses/moon-GPL-3.0.txt",
}


def included(path):
    relative = path.relative_to(PLUGIN)
    return (not set(relative.parts) & {"native", "__MACOSX", "__pycache__"}
            and path.name not in {".DS_Store", "Thumbs.db", "miuread.lua", "settings.reader.lua", "NON_COMMERCIAL_NOTICE.txt"}
            and path.suffix.lower() not in {".md", ".epub", ".log", ".pyc", ".zip", ".sqlite3", ".db",
                                            ".sqlite3-wal", ".sqlite3-shm", ".db-wal", ".db-shm"})


def build(output):
    files = sorted(p for p in PLUGIN.rglob("*") if p.is_file() and included(p))
    names = {p.relative_to(PLUGIN).as_posix() for p in files}
    if missing := REQUIRED - names:
        raise ValueError(f"Missing runtime files: {sorted(missing)}")
    payloads = {p.relative_to(ROOT).as_posix(): p.read_bytes() for p in files}
    output.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(output, "w", compression=ZIP_DEFLATED, compresslevel=9) as archive:
        for path in files:
            info = ZipInfo(path.relative_to(ROOT).as_posix(), (2020, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = ZIP_DEFLATED
            archive.writestr(info, payloads[path.relative_to(ROOT).as_posix()])
    with ZipFile(output) as archive:
        if damaged := archive.testzip():
            raise ValueError(f"Damaged archive member: {damaged}")
        for path in files:
            if archive.read(path.relative_to(ROOT).as_posix()) != payloads[path.relative_to(ROOT).as_posix()]:
                raise ValueError(f"Source/archive mismatch: {path}")
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(output.suffix + ".sha256").write_text(
        f"{digest}  {output.name}\n", encoding="utf-8", newline="\n")
    print(f"{output}\nfiles={len(files)} bytes={output.stat().st_size} sha256={digest}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--channel", choices=("beta", "stable"), required=True)
    args = parser.parse_args()
    config = (PLUGIN / "miuread/config.lua").read_text(encoding="utf-8")
    version = re.search(r'VERSION\s*=\s*"([^"]+)"', config)[1]
    channel = re.search(r'UPDATE_CHANNEL\s*=\s*"([^"]+)"', config)
    expected = r"\d+\.\d+\.\d+-beta\.\d+" if args.channel == "beta" else r"\d+\.\d+\.\d+"
    if not channel or channel.group(1) != args.channel:
        parser.error(f"The source channel does not match the requested package channel: {args.channel}")
    if re.fullmatch(expected, version) is None:
        parser.error(f"The source version has the wrong channel format: {version}")
    meta = (PLUGIN / "_meta.lua").read_text(encoding="utf-8")
    meta_match = re.search(r'\bversion\s*=\s*"([^"]+)"', meta)
    if not meta_match or meta_match.group(1) != version:
        parser.error("_meta.lua and config.lua versions do not match")
    build(args.output or ROOT / "dist" / f"miuread-{version}-full.zip")
