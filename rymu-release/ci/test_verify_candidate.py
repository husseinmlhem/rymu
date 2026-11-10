"""Test the integrity boundary between original archive and reviewed source deltas."""
import copy
import unittest
from verify_candidate import reviewed_expectations


class OverlayTests(unittest.TestCase):
    def setUp(self):
        self.name = 'flutter/windows/runner/Runner.rc'
        self.patch = 'rymu-release/ci/patches/publisher.patch'
        self.manifest = {
            'files': {self.name: 'a' * 64},
            'ciInputs': {self.patch: 'b' * 64},
            'lineEndingNormalizedSha256': {self.name: 'c' * 64},
            'reviewedSourceChanges': {self.name: {
                'beforeSha256': 'a' * 64, 'beforeLineEndingNormalizedSha256': 'c' * 64,
                'afterSha256': 'd' * 64, 'afterLineEndingNormalizedSha256': 'e' * 64,
                'patch': self.patch, 'patchSha256': 'b' * 64,
                'baseCommit': 'f' * 40, 'reason': 'Reviewed publisher attribution only',
            }},
        }

    def test_valid_overlay_preserves_original_mapping(self):
        before = copy.deepcopy(self.manifest)
        checks, normalized = reviewed_expectations(self.manifest)
        self.assertEqual(checks[self.name], 'd' * 64)
        self.assertEqual(normalized[self.name], 'e' * 64)
        self.assertEqual(self.manifest, before)

    def test_no_overlay_uses_original(self):
        self.manifest.pop('reviewedSourceChanges')
        checks, _ = reviewed_expectations(self.manifest)
        self.assertEqual(checks[self.name], 'a' * 64)

    def test_original_hash_mismatch_rejected(self):
        self.manifest['reviewedSourceChanges'][self.name]['beforeSha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'original source hash'):
            reviewed_expectations(self.manifest)

    def test_unreviewed_patch_rejected(self):
        self.manifest['ciInputs'].clear()
        with self.assertRaisesRegex(ValueError, 'not a reviewed CI input'):
            reviewed_expectations(self.manifest)

    def test_unknown_source_path_rejected(self):
        self.manifest['files'].clear()
        with self.assertRaisesRegex(ValueError, 'original source hash'):
            reviewed_expectations(self.manifest)

    def test_missing_new_hash_rejected(self):
        self.manifest['reviewedSourceChanges'][self.name].pop('afterSha256')
        with self.assertRaisesRegex(ValueError, 'hash is missing'):
            reviewed_expectations(self.manifest)


if __name__ == '__main__':
    unittest.main()
