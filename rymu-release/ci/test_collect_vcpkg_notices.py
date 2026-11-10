"""Fixtures only; never modifies an installed application or real vcpkg tree."""
from pathlib import Path
import hashlib
import importlib.util
import json
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('collector', Path(__file__).with_name('collect_vcpkg_notices.py'))
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class NoticeTests(unittest.TestCase):
    def setUp(self):
        scratch_root = Path(tempfile.gettempdir()).resolve()
        self.temporary = tempfile.TemporaryDirectory(prefix='notice-fixture-', dir=scratch_root)
        self.root = Path(self.temporary.name).resolve()
        assert self.root.parent == scratch_root.resolve()
        self.addCleanup(self.temporary.cleanup)
        self.installed = self.root / 'installed'
        self.runner = self.root / 'runner'
        self.runner.mkdir()
        (self.installed / 'vcpkg').mkdir(parents=True)
        self.names = sorted(collector.REQUIRED | {'vcpkg-cmake'})
        status = ''
        for name in self.names:
            status += f'Package: {name}\nVersion: 1.0\nArchitecture: {collector.TRIPLET}\nStatus: install ok installed\n\n'
            path = self.installed / collector.TRIPLET / 'share' / name / 'copyright'
            path.parent.mkdir(parents=True)
            path.write_bytes(f'Fixture notice {name}\r\n'.encode())
        self.status = self.installed / 'vcpkg/status'
        self.status.write_text(status, encoding='utf-8')

    def notice(self, name):
        return self.installed / collector.TRIPLET / 'share' / name / 'copyright'

    def test_exact_copies_hashes_and_explicit_limits(self):
        result = collector.collect(self.installed, self.runner)
        self.assertEqual(len(result['notices']), len(self.names))
        for item in result['notices']:
            original = self.notice(item['package']).read_bytes()
            self.assertEqual((self.runner / 'THIRD-PARTY-LICENSES' / item['path']).read_bytes(), original)
            self.assertEqual(item['sha256'], hashlib.sha256(original).hexdigest())
        manifest = json.loads((self.runner / 'THIRD-PARTY-LICENSES/manifest.json').read_text())
        self.assertFalse(manifest['licenseGrantReviewComplete'])
        self.assertFalse(manifest['completeDependencyCoverage'])
        self.assertNotIn(str(self.root), json.dumps(manifest))

    def test_missing_core_fails_before_output(self):
        self.notice('ffmpeg').unlink()
        with self.assertRaisesRegex(ValueError, 'Required installed library'):
            collector.collect(self.installed, self.runner)
        self.assertFalse((self.runner / 'THIRD-PARTY-LICENSES').exists())

    def test_missing_build_helper_is_reported(self):
        self.notice('vcpkg-cmake').unlink()
        result = collector.collect(self.installed, self.runner)
        self.assertEqual(result['nonRequiredPackagesWithoutCopyright'], ['vcpkg-cmake'])

    def test_output_collision_preserves_sentinel(self):
        destination = self.runner / 'THIRD-PARTY-LICENSES'
        destination.mkdir()
        (destination / 'sentinel').write_text('keep')
        with self.assertRaisesRegex(ValueError, 'Preserve'):
            collector.collect(self.installed, self.runner)
        self.assertEqual((destination / 'sentinel').read_text(), 'keep')

    def test_unsafe_package_name_fails(self):
        with self.status.open('a') as stream:
            stream.write(f'Package: ../escape\nVersion: 1\nArchitecture: {collector.TRIPLET}\nStatus: install ok installed\n')
        with self.assertRaisesRegex(ValueError, 'Unsafe'):
            collector.collect(self.installed, self.runner)

    def test_non_file_notice_fails(self):
        path = self.notice('aom')
        path.unlink()
        path.mkdir()
        with self.assertRaisesRegex(ValueError, 'Unexpected notice input type'):
            collector.collect(self.installed, self.runner)

    def test_missing_installed_core_record_fails(self):
        self.status.write_text('', encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'inventory is incomplete'):
            collector.collect(self.installed, self.runner)


if __name__ == '__main__':
    unittest.main()
