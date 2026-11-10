"""Verify the final release APK against the isolated, already exercised QA AVD."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import subprocess
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SERIAL = 'emulator-5582'
PACKAGE = 'app.rymu.controller'


def adb(*args):
    return subprocess.check_output(['adb', '-s', SERIAL, *args], text=True, encoding='utf-8').strip()


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    assert adb('emu', 'avd', 'name').splitlines()[0] == 'Rymu_PublicRelease_API35'
    apk = ROOT / 'artifacts/android/Rymu-Android-arm64-1.5.1-2077.apk'
    installed = ROOT / '.local/android-public-avd/installed-2077.apk'
    assert sha(apk) == sha(installed)
    package = adb('shell', 'dumpsys', 'package', PACKAGE)
    assert 'versionCode=2077 minSdk=23 targetSdk=36' in package
    assert 'versionName=1.5.1' in package
    flags = next(line.strip() for line in package.splitlines() if 'pkgFlags=' in line)
    assert 'DEBUGGABLE' not in flags
    app_pid = adb('shell', 'pidof', PACKAGE)
    assert app_pid.isdigit()
    errors = adb('shell', 'logcat', '-d', f'--pid={app_pid}', '-s', 'AndroidRuntime:E', 'flutter:E')
    assert not errors, errors
    screen = ROOT / 'artifacts/screenshots/android-public-2077-persisted-folder-ar.xml'
    labels = '\n'.join(node.attrib.get('content-desc', '') for node in ET.parse(screen).iter('node'))
    for expected in ['Rymu-QA-Inbox', 'مجلد الاستلام', 'العربية', 'حسين ملحم', 'www.husseinmlhem.com', 'h-m.agency']:
        assert expected in labels, expected
    grants = adb('shell', 'dumpsys', 'activity', 'permissions')
    start = grants.index('content://com.android.externalstorage.documents/tree/primary%3ADocuments%2FRymu-QA-Inbox')
    grant = '\n'.join(grants[start:].splitlines()[:3])
    assert 'targetPkg=app.rymu.controller' in grant and 'persisted=0x3' in grant
    signing_log = (ROOT / 'artifacts/logs/android-public-2077-signing.log').read_text()
    for scheme in ['v1 scheme (JAR signing)', 'v2 scheme (APK Signature Scheme v2)', 'v3 scheme (APK Signature Scheme v3)']:
        assert f'Verified using {scheme}: true' in signing_log
    with zipfile.ZipFile(apk) as archive:
        native = archive.read('lib/arm64-v8a/librustdesk.so')
        aot = archive.read('lib/arm64-v8a/libapp.so')
    report = {
        'recorded_at': datetime.now(timezone.utc).isoformat(), 'status': 'passed',
        'artifact': {'path': apk.relative_to(ROOT).as_posix(), 'bytes': apk.stat().st_size, 'sha256': sha(apk)},
        'version': '1.5.1', 'version_code': 2077, 'min_sdk': 23, 'target_sdk': 36, 'debuggable': False,
        'signing': {'schemes_verified': ['v1', 'v2', 'v3'], 'certificate_sha256': '183c4a28f21b457d3790c79c2c2cb8d82a74fd298acd1a8a832c68910094bbe2'},
        'native_sha256': hashlib.sha256(native).hexdigest(), 'aot_sha256': hashlib.sha256(aot).hexdigest(),
        'emulator': {'name': 'Rymu_PublicRelease_API35', 'serial': SERIAL, 'sdk': adb('shell', 'getprop', 'ro.build.version.sdk'),
                     'abis': adb('shell', 'getprop', 'ro.product.cpu.abilist'), 'fresh_data': True, 'installed_apk_sha256': sha(installed)},
        'observed_ui': ['English launch and settings', 'Android Documents picker created and selected empty Rymu-QA-Inbox',
                        'OS folder permission granted once in isolated QA AVD', 'Force-stop/relaunch retained Arabic and receiving-folder choice',
                        'Persisted read/write document-tree grant verified after relaunch', 'Arabic attribution and both links visible',
                        '900x1600 and 1600x900 settings screenshots inspected; no overlap observed'],
        'current_process_error_log': 'empty', 'physical_device': False,
        'not_run': ['Authenticated multi-monitor remote session', 'File transfer to/from a real peer', 'Physical phone input and performance',
                    'Old debug APK upgrade with a different signing certificate'],
        'evidence': ['artifacts/logs/android-public-2077-signing.log', 'artifacts/screenshots/android-public-2077-launch.png',
                     'artifacts/screenshots/android-public-2077-settings-ar.png', 'artifacts/screenshots/android-public-2077-wide.png'],
    }
    path = ROOT / 'artifacts/android/public-2077-verification.json'
    path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    print(json.dumps({'status': report['status'], 'artifact': report['artifact'], 'report': path.relative_to(ROOT).as_posix()}, indent=2))


if __name__ == '__main__':
    main()
