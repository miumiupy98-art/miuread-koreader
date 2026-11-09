"""Offline, deterministic tests of the release issue close workflow."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

MODULE_PATH = Path(__file__).with_name("release_issue_automation.py")
spec = importlib.util.spec_from_file_location("miuread_release_issues", MODULE_PATH)
issues = importlib.util.module_from_spec(spec)
spec.loader.exec_module(issues)
TAG = "v6.5.0-beta.26"
REPO = "miumiupy98-art/miuread-koreader"


class ReleaseIssuesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="miuread-issues-test-")
        root = Path(self.tmp.name)
        self.package = root / "miuread-v6.5.0-beta.26-full.zip"
        self.package.write_bytes(b"verified complete plugin archive")
        self.manifest = root / "update-beta.json"
        self.manifest.write_text(json.dumps({
            "version": TAG[1:], "size": self.package.stat().st_size,
            "sha256": issues.sha256(self.package),
            "package_url": f"https://github.com/{REPO}/releases/download/{TAG}/{self.package.name}",
        }))
        self.saved_comments = {number: [] for number in (135,160,183,184,185)}
        self.status = {number: "open" for number in self.saved_comments}
        self.actions = []

    def tearDown(self):
        self.tmp.cleanup()

    def fake_gh(self, *args):
        self.actions.append(args)
        if args[:2] == ("release", "view"):
            if args[2] == TAG:
                return json.dumps({"url": f"https://github.com/{REPO}/releases/tag/{TAG}",
                                   "assets": [{"name": self.package.name}]})
            if args[2] == "beta-channel":
                return json.dumps({"assets": [{"name": self.manifest.name}]})
        if args[:2] == ("release", "download"):
            destination = Path(args[args.index("--dir") + 1])
            destination.mkdir(parents=True, exist_ok=True)
            if args[2] == TAG:
                (destination / self.package.name).write_bytes(self.package.read_bytes())
            else:
                (destination / self.manifest.name).write_bytes(self.manifest.read_bytes())
            return ""
        if args[0] == "api":
            if "--paginate" in args:
                number = int(args[-1].split("/issues/")[1].split("/")[0])
                return json.dumps([self.saved_comments[number]])
            path = args[1]
            number = int(path.split("/issues/")[1].split("/")[0])
            if "/comments" in path:
                body = next(x[5:] for x in args if isinstance(x,str) and x.startswith("body="))
                self.saved_comments[number].append({"body":body})
                return "{}"
            if "PATCH" in args:
                self.status[number] = "closed"
                return "{}"
            return json.dumps({"state": self.status[number], "number":number})
        raise AssertionError(f"Unexpected GitHub command: {args}")

    def test_prepare_notes_is_idempotent_and_explicit(self):
        note = Path(self.tmp.name) / "release-notes.md"
        note.write_text("修复多级目录\n")
        self.assertEqual(issues.prepare(TAG,note),5)
        text = note.read_text()
        self.assertIn("#135",text)
        self.assertIn("#185",text)
        self.assertNotIn("#165",text)
        issues.prepare(TAG,note)
        self.assertEqual(note.read_text().count("### 关联 Issues"),1)

    def test_published_assets_verified_before_issue_close(self):
        with patch.object(issues,"gh",side_effect=self.fake_gh):
            self.assertEqual(issues.close(TAG,REPO,self.package,self.manifest,"beta-channel"),4)
            self.assertEqual(self.status[135],"open")
            self.assertEqual(issues.close(TAG,REPO,self.package,self.manifest,"beta-channel"),0)
            for number in (160,183,184,185):
                self.assertEqual(self.status[number],"closed")
                self.assertEqual(len(self.saved_comments[number]),1)
            self.assertEqual(issues.close(TAG,REPO,self.package,self.manifest,
                                          "beta-channel",verified_issue135=True),1)
            self.assertEqual(self.status[135],"closed")
            self.assertEqual(len(self.saved_comments[135]),1)

    def test_invalid_manifest_fails_without_issuing_close_commands(self):
        corrupted = json.loads(self.manifest.read_text())
        corrupted["sha256"] = "not-the-actual-package"
        self.manifest.write_text(json.dumps(corrupted))
        with patch.object(issues,"gh",side_effect=self.fake_gh):
            with self.assertRaisesRegex(RuntimeError,"manifest identity"):
                issues.close(TAG,REPO,self.package,self.manifest,"beta-channel",True)
        self.assertEqual(set(self.status.values()),{"open"})
        self.assertTrue(all("issues/" not in " ".join(map(str,action)) for action in self.actions))

    def test_unlisted_release_is_noop(self):
        self.assertEqual(issues.entries("v6.5.0-beta.25"),[])
        with patch.object(issues,"gh",side_effect=self.fake_gh):
            self.assertEqual(issues.close("v6.5.0-beta.25",REPO,self.package,
                                          self.manifest,"beta-channel"),0)
        self.assertEqual(self.actions,[])


if __name__ == "__main__":
    unittest.main(verbosity=2)
