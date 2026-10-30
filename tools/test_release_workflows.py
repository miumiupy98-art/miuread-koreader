import unittest
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
BETA=(ROOT/'.github/workflows/release-beta.yml').read_text(encoding='utf-8')
STABLE=(ROOT/'.github/workflows/release.yml').read_text(encoding='utf-8')
PREFLIGHT=(ROOT/'.github/workflows/release-check.yml').read_text(encoding='utf-8')

class ReleaseWorkflows(unittest.TestCase):
    def test_versions_built_from_shared_packager(self):
        self.assertIn('tools/build_package.py --channel beta', BETA)
        self.assertIn('tools/build_package.py --channel stable', STABLE)
    def test_beta_build_precedes_immutable_tag(self):
        self.assertLess(BETA.index('name: Verify beta package and manifest'),
                        BETA.index('name: Ensure release tag'))
        self.assertIn('python3 tools/check_beta_release_identity.py --version "$VERSION"', BETA)
        self.assertNotIn('python3 tools/ensure_beta_tag_changelog.py', BETA)
    def test_no_force_move_of_versioned_assets(self):
        for workflow in (BETA, STABLE):
            self.assertIn('bash tools/release_asset_guard.sh', workflow)
            self.assertIn('bash tools/publish_channel_manifest.sh', workflow)
            self.assertNotIn('gh release upload "$RELEASE_TAG" "$FILE" --clobber', workflow)
            self.assertNotIn('git push --force', workflow)
    def test_identity_and_package_are_checked_before_publish(self):
        for workflow in (BETA, STABLE):
            self.assertLess(workflow.index('release_integrity.py package'),
                            workflow.index('release_asset_guard.sh'))
    def test_preflight_only_checks_no_mutations(self):
        self.assertIn('bash tools/release_preflight.sh', PREFLIGHT)
        self.assertIn('lua5.1 luajit', PREFLIGHT)
        self.assertNotIn('gh release create', PREFLIGHT)
        self.assertNotIn('git push', PREFLIGHT)
        self.assertNotIn('channel manifest', PREFLIGHT)
    def test_stable_latest_after_successful_ota_promotion(self):
        self.assertLess(STABLE.index('bash tools/publish_channel_manifest.sh'),
                        STABLE.index('gh release edit "$RELEASE_TAG" --latest'))
        self.assertIn('--latest=false',STABLE)
    def test_stable_behavior_coverage(self):
        self.assertIn('tools/test_shelf_progress.lua', STABLE)
        self.assertIn('tools/test_641_progress_recovery_behavior.lua', STABLE)
        self.assertIn('tools/test_offline_readtime.py', STABLE)
        self.assertIn('tools/test_eink_download.py', STABLE)

if __name__=='__main__':unittest.main()
