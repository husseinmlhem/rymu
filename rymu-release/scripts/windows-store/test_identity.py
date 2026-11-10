"""Negative packaging-input checks; never build/install a fixture identity."""
import unittest

from build_msix import LOCAL_IDENTITY, REQUIRED_RUNTIME, SDK, build, family_name, validate_identity, validate_version


class PackageIdentityInputTests(unittest.TestCase):
    def test_local_identity_requires_explicit_local_mode(self):
        with self.assertRaises(ValueError):
            validate_identity(LOCAL_IDENTITY.copy(), False)

    def test_local_mode_cannot_accept_another_publishers_identity(self):
        modified = {**LOCAL_IDENTITY, 'publisher': 'CN=Another Publisher'}
        with self.assertRaises(ValueError):
            validate_identity(modified, True)

    def test_template_cannot_be_packaged(self):
        import json
        from pathlib import Path
        template = json.loads(Path(__file__).with_name('identity.template.json').read_text())
        with self.assertRaises(ValueError):
            validate_identity(template, False)

    def test_mismatched_family_is_rejected(self):
        fixture = {
            'identityName': 'Rymu.ValidationFixture', 'publisher': 'CN=Validation Fixture',
            'publisherDisplayName': 'Validation Fixture', 'displayName': 'Validation Fixture',
            'source': 'partner-center-product-identity',
            'packageFamilyName': 'Rymu.ValidationFixture_invalid',
        }
        with self.assertRaises(ValueError):
            validate_identity(fixture, False)

    def test_platform_derived_family_is_consistent(self):
        identity = validate_identity(LOCAL_IDENTITY.copy(), True)
        self.assertEqual(identity['packageFamilyName'], family_name(LOCAL_IDENTITY['identityName'], LOCAL_IDENTITY['publisher']))
        self.assertEqual(identity['applicationUserModelId'], identity['packageFamilyName'] + '!Rymu')

    def test_name_cannot_escape_or_inject_manifest(self):
        for name in ('../Rymu', 'Rymu<script>', 'Rymu\nInjected', 'Rymu"bad', 'a' * 51):
            with self.subTest(name=name), self.assertRaises(ValueError):
                validate_identity({**LOCAL_IDENTITY, 'identityName': name}, True)

    def test_store_reserved_revision_and_overflow_are_rejected(self):
        for version in ('0.1.13.1', '0.1.65536.0', '0.1.13', '-1.0.0.0', '01.1.13.0', '0.1.13.0\n'):
            with self.subTest(version=version), self.assertRaises(ValueError):
                validate_version(version)

    def test_target_version_is_accepted(self):
        self.assertEqual(validate_version('1.0.13.0'), '1.0.13.0')

    def test_zero_major_is_local_qualification_only(self):
        with self.assertRaises(ValueError):
            validate_version('0.1.13.0')
        self.assertEqual(validate_version('0.1.13.0', local_test=True), '0.1.13.0')

    def test_private_files_fail_before_any_package_or_evidence_is_created(self):
        import argparse
        from pathlib import Path
        import tempfile
        for private_path in ('.env', '.env.production', '.git/config', 'account.dat', 'private.pfx', 'AppxSignature.p7x'):
            with self.subTest(path=private_path), tempfile.TemporaryDirectory(prefix='rymu-msix-input-test-') as temporary:
                root = Path(temporary)
                runner = root / 'runner'
                for relative in (*REQUIRED_RUNTIME, private_path):
                    file = runner / relative
                    file.parent.mkdir(parents=True, exist_ok=True)
                    file.write_bytes(b'non-secret preflight fixture; not an executable')
                output = root / 'artifacts/Test-LocalQualification.msix'
                args = argparse.Namespace(local_test_identity=True, identity=None, version='1.0.14.0',
                                          runner=runner, output=output, sdk=SDK)
                with self.assertRaises(ValueError):
                    build(args)
                self.assertFalse(output.parent.exists(), 'Preflight must fail before artifact creation')


if __name__ == '__main__':
    unittest.main()
