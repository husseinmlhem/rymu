"""Test the integrity boundary between original archive and reviewed source deltas."""
import copy
import unittest
import tempfile
from pathlib import Path
from verify_candidate import reviewed_expectations, verify_rust_literal_inputs


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

    def test_literal_input_cannot_rely_on_surrounding_workspace(self):
        with tempfile.TemporaryDirectory(prefix='rymu-path-fixture-') as temporary:
            parent = Path(temporary).resolve()
            self.assertEqual(parent.parent, Path(tempfile.gettempdir()).resolve())
            root = parent / 'candidate'
            (root / 'src').mkdir(parents=True)
            (parent / 'outside.rs').write_text('// outside candidate')
            (root / 'src/test.rs').write_text('#[path = "../../outside.rs"]\nmod probe;\n')
            count, failures = verify_rust_literal_inputs(root)
            self.assertEqual(count, 1)
            self.assertEqual(len(failures), 1)

    def test_literal_input_must_exist_inside_candidate(self):
        with tempfile.TemporaryDirectory(prefix='rymu-path-fixture-') as temporary:
            root = Path(temporary).resolve()
            self.assertEqual(root.parent, Path(tempfile.gettempdir()).resolve())
            (root / 'src').mkdir()
            (root / 'src/test.rs').write_text('const DATA: &str = include_str!("fixture.json");')
            self.assertEqual(len(verify_rust_literal_inputs(root)[1]), 1)
            (root / 'src/fixture.json').write_text('{}')
            self.assertEqual(verify_rust_literal_inputs(root), (1, []))


if __name__ == '__main__':
    unittest.main()
