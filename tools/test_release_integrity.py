import hashlib
import tempfile
import unittest
from pathlib import Path
from release_integrity import check_manifest, promotion, same_asset


def m(channel, version, content=b"valid-package"):
    return {"channel":channel,"version":version,"sha256":hashlib.sha256(content).hexdigest(),
            "size":len(content),"package_url":"https://github.com/example/repo/releases/download/v%s/miuread-v%s-full.zip"%(version,version)}


class ReleaseSafety(unittest.TestCase):
    def test_beta_rollback_is_rejected(self):
        with self.assertRaisesRegex(ValueError,"rollback"):
            promotion(m("beta","6.3.5-beta.2"),m("beta","6.3.5-beta.1"),"beta")
    def test_stable_rollback_is_rejected(self):
        with self.assertRaisesRegex(ValueError,"rollback"):
            promotion(m("stable","6.3.5"),m("stable","6.3.2"),"stable")
    def test_equal_versions_must_have_identical_package(self):
        self.assertEqual(promotion(m("beta","6.3.5-beta.2"),m("beta","6.3.5-beta.2"),"beta"),"already_published")
        with self.assertRaisesRegex(ValueError,"Immutable"):
            promotion(m("stable","6.3.5"),m("stable","6.3.5",b"new"),"stable")
    def test_new_version_and_first_publish(self):
        self.assertEqual(promotion(None,m("stable","6.3.5"),"stable"),"first_publication")
        self.assertEqual(promotion(m("beta","6.3.5-beta.1"),m("beta","6.3.5-beta.2"),"beta"),"advance")
    def test_cross_channel_and_bad_data_rejected(self):
        with self.assertRaises(ValueError):promotion(m("stable","6.3.5"),m("beta","6.3.5-beta.1"),"stable")
        with self.assertRaises(ValueError):check_manifest({"channel":"beta","version":"6.3.5-beta.2","sha256":"n/a","size":4},"beta")
    def test_fixed_asset_immutable(self):
        with tempfile.TemporaryDirectory() as temp:
            a=Path(temp)/"a.zip";b=Path(temp)/"b.zip"
            a.write_bytes(b"identical");b.write_bytes(b"identical")
            self.assertTrue(same_asset(a,b))
            b.write_bytes(b"different")
            with self.assertRaises(ValueError):same_asset(a,b)

if __name__ == "__main__":unittest.main()
