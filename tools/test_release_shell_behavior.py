"""Exercise release shell code against a hermetic GitHub Release fake.
Does not contact GitHub or mutate real tags/releases.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
FAKE_GH='#!/usr/bin/env bash\nset -euo pipefail\nROOT="$FAKE_RELEASES"\ncase "$1 $2" in\n  \'release view\')\n    TAG="$3"; test -d "$ROOT/$TAG" || exit 1\n    if [[ " $* " == *\' --json assets \'* ]]; then\n      query="${*: -1}"\n      NAME="$(printf \'%s\' "$query" | sed -n \'s/.*name=="\\([^"]*\\)".*/\\1/p\')"\n      if [[ -n "$NAME" && -f "$ROOT/$TAG/$NAME" ]]; then printf \'%s\\n\' "$NAME"; fi\n    fi ;;\n  \'release upload\')\n    TAG="$3"; SOURCE="$4"; test -d "$ROOT/$TAG"\n    DEST="$ROOT/$TAG/$(basename "$SOURCE")"\n    if [[ -e "$DEST" && " $* " != *\' --clobber\'* ]]; then exit 1; fi\n    cp "$SOURCE" "$DEST" ;;\n  \'release download\')\n    TAG="$3"; test -d "$ROOT/$TAG"\n    shift 3; NAME=\'\'; DIR=\'\'; CLOBBER=0\n    while [ "$#" -gt 0 ]; do\n      case "$1" in\n        --pattern) NAME="$2"; shift 2 ;;\n        --dir) DIR="$2"; shift 2 ;;\n        --clobber) CLOBBER=1; shift ;;\n        *) echo "fake gh: invalid option $1" >&2; exit 2 ;;\n      esac\n    done\n    test -f "$ROOT/$TAG/$NAME"; mkdir -p "$DIR"\n    if [[ -e "$DIR/$NAME" && "$CLOBBER" -eq 0 ]]; then exit 1; fi\n    cp "$ROOT/$TAG/$NAME" "$DIR/$NAME" ;;\n  *) echo "fake gh: unsupported call $*" >&2; exit 2 ;;\nesac\n'

class ReleaseShell(unittest.TestCase):
    def test_publish_retry_and_immutable_assets(self):
        with tempfile.TemporaryDirectory() as tmp:
            d=Path(tmp);(d/'bin').mkdir();(d/'dist').mkdir()
            exe=d/'bin/gh';exe.write_text(FAKE_GH);exe.chmod(0o755)
            releases=d/'releases';(releases/'v6.3.5-beta.2').mkdir(parents=True)
            (releases/'beta-channel').mkdir()
            name='miuread-v6.3.5-beta.2-full.zip'
            payload=b'valid test archive bytes'
            (d/'dist'/name).write_bytes(payload)
            manifest={'channel':'beta','version':'6.3.5-beta.2','size':len(payload),
                      'sha256':hashlib.sha256(payload).hexdigest(),
                      'package_url':'https://github.com/test/repo/releases/download/v6.3.5-beta.2/'+name}
            (d/'dist/update-beta.json').write_text(json.dumps(manifest))
            env=dict(os.environ,PATH=str(d/'bin')+os.pathsep+os.environ.get('PATH',''),
                 FAKE_RELEASES=str(releases),GH_TOKEN='fake',RUNNER_TEMP=str(d/'runtime'),
                 RELEASE_TAG='v6.3.5-beta.2',PACKAGE_NAME=name,CHANNEL_TAG='beta-channel',
                 MANIFEST_NAME='update-beta.json',RELEASE_CHANNEL='beta')
            def run(script):
                return subprocess.run(['bash',str(ROOT/'tools'/script)],cwd=d,env=env,
                                      capture_output=True,text=True,timeout=25)
            # Commands need the real shared integrity checker in cwd.
            (d/'tools').mkdir()
            (d/'tools/release_integrity.py').write_bytes((ROOT/'tools/release_integrity.py').read_bytes())
            for script in ('release_asset_guard.sh','publish_channel_manifest.sh'):
                r=run(script);self.assertEqual(r.returncode,0,r.stderr+'\n'+r.stdout)
            # A repeated publication of identical bytes is safe and idempotent.
            for script in ('release_asset_guard.sh','publish_channel_manifest.sh'):
                r=run(script);self.assertEqual(r.returncode,0,r.stderr+'\n'+r.stdout)
            current=(releases/'beta-channel/update-beta.json').read_bytes()
            # Same immutable tag with different bytes must refuse overwrite.
            (d/'dist'/name).write_bytes(payload+b'different')
            r=run('release_asset_guard.sh')
            self.assertNotEqual(r.returncode,0)
            self.assertEqual((releases/'v6.3.5-beta.2'/name).read_bytes(),payload)
            self.assertEqual((releases/'beta-channel/update-beta.json').read_bytes(),current)
            # With a fresh tag but an older version, OTA promotion must fail.
            oldname='miuread-v6.3.5-beta.1-full.zip'
            (releases/'v6.3.5-beta.1').mkdir()
            (d/'dist'/oldname).write_bytes(payload)
            old=dict(manifest,version='6.3.5-beta.1',
                     package_url='https://github.com/test/repo/releases/download/v6.3.5-beta.1/'+oldname)
            (d/'dist/update-beta.json').write_text(json.dumps(old))
            env['RELEASE_TAG']='v6.3.5-beta.1';env['PACKAGE_NAME']=oldname
            r=run('release_asset_guard.sh')
            self.assertNotEqual(r.returncode,0)
            self.assertIn('rollback',r.stderr.lower())
            self.assertEqual((releases/'beta-channel/update-beta.json').read_bytes(),current)

if __name__=='__main__':unittest.main()
