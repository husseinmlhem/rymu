"""Snapshot the Windows tray owner build without changing either Git index."""
from __future__ import annotations

import hashlib
import argparse
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / 'apps/native'
UPSTREAM = '23e5bb471a040d62f0a6ad52591fb30784265b73'


def digest(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def git(*args: str, env=None, repo=NATIVE) -> bytes:
    return subprocess.check_output(['git', '-C', str(repo), *args], env=env)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--windows-version', default='0.1.12')
    parser.add_argument('--release-name', default='Tray')
    parser.add_argument('--android-build', default='2076')
    parser.add_argument('--report', default='docs/TRAY_UPDATE_2026-11-10_AR.md')
    args = parser.parse_args()
    if not re.fullmatch(r'\d+\.\d+\.\d+', args.windows_version):
        parser.error('Use a three-part Windows version.')
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9-]*', args.release_name):
        parser.error('Release name must contain letters, digits or hyphens.')
    if not re.fullmatch(r'[1-9][0-9]*', args.android_build):
        parser.error('Android build must be a positive integer.')
    report = (ROOT / args.report).resolve()
    if not report.is_relative_to(ROOT / 'docs') or not report.is_file():
        parser.error('Report must be an existing file under docs/.')
    OUTPUT = ROOT / f'artifacts/source/Rymu-Native-{args.release_name}-{args.windows_version}-{args.android_build}-Source.zip'
    if OUTPUT.exists():
        raise SystemExit('Refusing to replace an existing release source archive.')
    original_index = NATIVE / '.git/index'
    index_before = digest(original_index)
    with tempfile.TemporaryDirectory(prefix='rymu-tray-source-', dir=ROOT / '.local') as folder:
        scratch = Path(folder)
        env = {**os.environ, 'GIT_INDEX_FILE': str(scratch / 'snapshot.index')}
        git('read-tree', 'HEAD', env=env)
        git('add', '-A', env=env)
        tree = git('write-tree', env=env).decode().strip()
        patch = ROOT / 'patches/rymu-native.patch'
        patch.write_bytes(git('diff', '--binary', UPSTREAM, tree))
        verify_env = {**os.environ, 'GIT_INDEX_FILE': str(scratch / 'verify.index')}
        git('read-tree', UPSTREAM, env=verify_env)
        git('apply', '--cached', str(patch), env=verify_env)
        reconstructed = git('write-tree', env=verify_env).decode().strip()
        assert tree == reconstructed, 'Canonical patch failed exact tree reconstruction'
        git('archive', '--format=zip', f'--output={scratch / "native.zip"}', tree)
        submodule = NATIVE / 'libs/hbb_common'
        assert not git('diff', 'HEAD', '--', repo=submodule), 'Submodule has changes outside the pinned archive'
        git('archive', '--format=zip', f'--output={scratch / "common.zip"}', 'HEAD', '--',
            ':(exclude)tests/data/websocket-cert.pem', ':(exclude)tests/data/websocket-key.pem', repo=submodule)
        entries: dict[str, bytes] = {}
        for archive, prefix in [('native.zip', 'Rymu/apps/native/'),
                                ('common.zip', 'Rymu/apps/native/libs/hbb_common/')]:
            with zipfile.ZipFile(scratch / archive) as source:
                entries.update({prefix + name: source.read(name) for name in source.namelist() if not name.endswith('/')})
        bridges = ['src/bridge_generated.rs', 'src/bridge_generated.io.rs',
                   'flutter/lib/generated_bridge.dart', 'flutter/lib/generated_bridge.freezed.dart']
        for path in bridges:
            entries['Rymu/apps/native/' + path] = (NATIVE / path).read_bytes()
        support = [
            'scripts/windows-native.py', 'scripts/windows-flutter.mjs',
            'scripts/windows-plugin-registrants.dart', 'scripts/build-android.ps1',
            'scripts/_common.ps1', 'scripts/emit-windows-msi.py', 'scripts/build-windows-msi.ps1',
            'scripts/test-windows-msi.py', 'scripts/test-windows-bridge.py',
            'scripts/package-tray-source.py', 'scripts/qa/windows-tray-smoke.py',
            'scripts/qa/android-public-release-evidence.py',
            'scripts/qa/windows-startup-probe.py', 'scripts/qa/windows-startup-probe.dart',
            'scripts/qa/windows-installer-startup-probe.py', 'scripts/qa/windows-installer-startup-probe.cpp',
            'scripts/qa/privacy-capture.rs', 'scripts/qa/privacy-capture.py',
            'scripts/qa/privacy-native-tests.py', 'docs/WINDOWS.md', 'docs/ANDROID.md',
            'docs/PRIVACY_BUILD.md', 'docs/PRIVACY_VALIDATION_2026-11-06.md',
            'docs/TRAY_BUILD.md',
            'docs/TRAY_UPDATE_2026-11-10_AR.md', 'docs/TRAY_VALIDATION_2026-11-10.md',
            'docs/MICROSOFT_STORE_READINESS_2026-11-10_AR.md',
            'artifacts/native-dependency-audit.json', 'patches/rymu-native.patch',
        ]
        for path in support:
            entries['Rymu/' + path] = (ROOT / path).read_bytes()
        entries['Rymu/' + report.relative_to(ROOT).as_posix()] = report.read_bytes()
        msix_notes = ROOT / 'docs/MSIX_BUILD.md'
        if msix_notes.exists():
            entries['Rymu/docs/MSIX_BUILD.md'] = msix_notes.read_bytes()
        for name in ['WINDOWS_STORE_STARTUP.md', 'ANDROID_MONITOR_TRACKPAD_2026-11-10_AR.md',
                     'FILE_FOLDER_AND_ATTRIBUTION_2026-11-10_AR.md']:
            notes = ROOT / 'docs' / name
            if notes.exists():
                entries['Rymu/docs/' + name] = notes.read_bytes()
        for folder in ['design/installer', 'scripts/windows-installer', 'scripts/windows-store']:
            for path in (ROOT / folder).rglob('*'):
                if path.is_file() and '__pycache__' not in path.parts:
                    entries['Rymu/' + path.relative_to(ROOT).as_posix()] = path.read_bytes()
        entries['Rymu/design/assets/rymu-windows.ico'] = (ROOT / 'design/assets/rymu-windows.ico').read_bytes()
        entries['Rymu/apps/web/src/globe-fallback.webp'] = (ROOT / 'apps/web/src/globe-fallback.webp').read_bytes()
        forbidden = {'.local', '.wrangler', 'node_modules', '.dart_tool', '.dart-tool', 'target'}
        for name in entries:
            path = Path(name)
            assert not forbidden.intersection(path.parts), name
            assert path.suffix not in {'.pfx', '.p12', '.pem', '.key', '.keystore', '.jks', '.apk'}, name
        record = {
            'upstream': UPSTREAM, 'native_tree': tree,
            'submodule': git('rev-parse', 'HEAD', repo=submodule).decode().strip(),
            'canonical_patch_sha256': digest(patch),
            'files': {name: hashlib.sha256(data).hexdigest() for name, data in sorted(entries.items())},
        }
        entries['Rymu/SOURCE-RECORD.json'] = (json.dumps(record, indent=2) + '\n').encode()
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(OUTPUT, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for name, data in sorted(entries.items()):
                archive.writestr(name, data)
        with zipfile.ZipFile(OUTPUT) as archive:
            assert archive.testzip() is None
            for name, data in entries.items():
                assert archive.read(name) == data, name
        assert digest(original_index) == index_before, 'Original index changed'
        result = {
            'upstream': UPSTREAM, 'reconstructed_tree': reconstructed,
            'canonical_patch_sha256': digest(patch), 'git_index_preserved': True,
            'source_package': {'path': OUTPUT.relative_to(ROOT).as_posix(),
                               'bytes': OUTPUT.stat().st_size, 'sha256': digest(OUTPUT),
                               'native_tree': tree, 'verified_files': len(record['files'])},
            'report': report.relative_to(ROOT).as_posix(),
        }
        (ROOT / 'artifacts/native-source-verification.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
        print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
