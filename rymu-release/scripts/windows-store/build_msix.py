"""Build and inspect an unsigned Rymu MSIX without installing or activating it.

The local-test identity is deliberately unusable as Rymu's Store identity.
Real identity values must be copied from the reserved Partner Center product.
"""
from __future__ import annotations

import argparse
import ctypes
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SDK = Path('C:/Program Files (x86)/Windows Kits/10/bin/10.0.26100.0/x64')
NS = {
    '': 'http://schemas.microsoft.com/appx/manifest/foundation/windows10',
    'uap': 'http://schemas.microsoft.com/appx/manifest/uap/windows10',
    'uap10': 'http://schemas.microsoft.com/appx/manifest/uap/windows10/10',
    'desktop': 'http://schemas.microsoft.com/appx/manifest/desktop/windows10',
    'rescap': 'http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities',
}
LOCAL_IDENTITY = {
    'identityName': 'Rymu.LocalQualification',
    'publisher': 'CN=Rymu Local Qualification',
    'publisherDisplayName': 'Local qualification only',
    'displayName': 'Rymu Local Qualification',
    'source': 'local-qualification-only',
}
REQUIRED_RUNTIME = (
    'Rymu.exe', 'librustdesk.dll', 'flutter_windows.dll',
    'data/app.so', 'data/icudtl.dat', 'data/flutter_assets/AssetManifest.bin',
    'data/flutter_assets/NOTICES.Z', 'RUSTDESK-AGPL.txt',
)


def sha256(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def family_name(name: str, publisher: str) -> str:
    """Use Windows' identity API, not a home-grown publisher hash."""
    class PackageId(ctypes.Structure):
        _fields_ = [
            ('reserved', ctypes.c_uint32), ('processorArchitecture', ctypes.c_uint32),
            ('version', ctypes.c_uint64), ('name', ctypes.c_wchar_p),
            ('publisher', ctypes.c_wchar_p), ('resourceId', ctypes.c_wchar_p),
            ('publisherId', ctypes.c_wchar_p),
        ]
    identity = PackageId(name=name, publisher=publisher)
    api = ctypes.WinDLL('kernel32', use_last_error=True).PackageFamilyNameFromId
    api.argtypes = [ctypes.POINTER(PackageId), ctypes.POINTER(ctypes.c_uint32), ctypes.c_wchar_p]
    api.restype = ctypes.c_long
    size = ctypes.c_uint32(128)
    output = ctypes.create_unicode_buffer(size.value)
    result = api(ctypes.byref(identity), ctypes.byref(size), output)
    if result:
        raise ValueError(f'Windows rejected package identity, Win32 error {result}')
    return output.value


def validate_identity(identity: dict, local_test: bool) -> dict:
    fields = ('identityName', 'publisher', 'publisherDisplayName', 'displayName', 'source')
    for field in fields:
        value = identity.get(field)
        if not isinstance(value, str) or value != value.strip() or not value:
            raise ValueError(f'Identity field {field} must be a nonempty, trimmed string')
        if any(ord(char) < 32 for char in value):
            raise ValueError(f'Identity field {field} contains control characters')
    if not re.fullmatch(r'[A-Za-z0-9.-]{3,50}', identity['identityName']):
        raise ValueError('identityName must be the 3–50 character Partner Center package name')
    if len(identity['publisher']) > 8192 or not identity['publisher'].startswith('CN='):
        raise ValueError('publisher must be the exact Partner Center X.509 CN= identity')
    if any(len(identity[field]) > 256 for field in ('displayName', 'publisherDisplayName')):
        raise ValueError('Display names exceed the manifest limit')
    if local_test:
        if identity != LOCAL_IDENTITY:
            raise ValueError('Local qualification identity is fixed and cannot impersonate a publisher')
    else:
        if identity['source'] != 'partner-center-product-identity':
            raise ValueError('Store identity source must be partner-center-product-identity')
        combined = ' '.join(identity[field] for field in fields).lower()
        if any(marker in combined for marker in ('placeholder', 'replace_me', 'localqualification', 'local qualification', '<', '>')):
            raise ValueError('Placeholder/local identity cannot be used for a Store candidate')
        if not isinstance(identity.get('packageFamilyName'), str):
            raise ValueError('Copy packageFamilyName from the same Partner Center product identity page')
    derived = family_name(identity['identityName'], identity['publisher'])
    if not local_test and derived.casefold() != identity['packageFamilyName'].casefold():
        raise ValueError('Package family name does not match identityName and publisher')
    return {**identity, 'packageFamilyName': derived, 'applicationUserModelId': derived + '!Rymu'}


def validate_version(version: str, local_test: bool = False) -> str:
    parts = version.split('.')
    if len(parts) != 4 or any(not re.fullmatch(r'0|[1-9][0-9]*', p) or int(p) > 65535 for p in parts):
        raise ValueError('Version must contain four integer components from 0 to 65535')
    if parts[-1] != '0':
        raise ValueError('Microsoft Store reserves the fourth version component; use 0')
    if parts[0] == '0' and not local_test:
        raise ValueError('Microsoft Store requires a nonzero major package version; use a version such as 1.0.14.0')
    return version


def manifest(identity: dict, version: str) -> bytes:
    for prefix, uri in NS.items():
        ET.register_namespace(prefix, uri)
    tag = lambda name: '{' + NS[''] + '}' + name
    package = ET.Element(tag('Package'), {'IgnorableNamespaces': 'uap uap10 desktop rescap'})
    ET.SubElement(package, tag('Identity'), {
        'Name': identity['identityName'], 'Publisher': identity['publisher'],
        'Version': version, 'ProcessorArchitecture': 'x64',
    })
    properties = ET.SubElement(package, tag('Properties'))
    for key, value in [('DisplayName', identity['displayName']),
                       ('PublisherDisplayName', identity['publisherDisplayName']),
                       ('Description', 'Secure remote access to your own Windows computer.'),
                       ('Logo', 'Assets\\StoreLogo.png')]:
        ET.SubElement(properties, tag(key)).text = value
    dependencies = ET.SubElement(package, tag('Dependencies'))
    ET.SubElement(dependencies, tag('TargetDeviceFamily'), {
        'Name': 'Windows.Desktop', 'MinVersion': '10.0.22000.0', 'MaxVersionTested': '10.0.26100.0',
    })
    resources = ET.SubElement(package, tag('Resources'))
    for language in ('en-US', 'ar-SA'):
        ET.SubElement(resources, tag('Resource'), {'Language': language})
    applications = ET.SubElement(package, tag('Applications'))
    application = ET.SubElement(applications, tag('Application'), {
        'Id': 'Rymu', 'Executable': 'Rymu.exe',
        '{' + NS['uap10'] + '}RuntimeBehavior': 'packagedClassicApp',
        '{' + NS['uap10'] + '}TrustLevel': 'mediumIL',
    })
    ET.SubElement(application, '{' + NS['uap'] + '}VisualElements', {
        'DisplayName': identity['displayName'], 'Description': 'Remote access to your own computer',
        'BackgroundColor': 'transparent',
        'Square150x150Logo': 'Assets\\Square150x150Logo.png',
        'Square44x44Logo': 'Assets\\Square44x44Logo.png',
    })
    extensions = ET.SubElement(application, tag('Extensions'))
    extension = ET.SubElement(extensions, '{' + NS['desktop'] + '}Extension', {
        'Category': 'windows.startupTask', 'Executable': 'Rymu.exe', 'EntryPoint': 'Windows.FullTrustApplication',
    })
    ET.SubElement(extension, '{' + NS['desktop'] + '}StartupTask', {
        'TaskId': 'RymuStartup', 'Enabled': 'false', 'DisplayName': identity['displayName'],
    })
    capabilities = ET.SubElement(package, tag('Capabilities'))
    ET.SubElement(capabilities, '{' + NS['rescap'] + '}Capability', {'Name': 'runFullTrust'})
    ET.indent(package, space='  ')
    return ET.tostring(package, encoding='utf-8', xml_declaration=True) + b'\n'


def generate_assets(destination: Path) -> dict:
    from PIL import Image, __version__ as pillow_version
    source = ROOT / 'design/assets/rymu-windows.ico'
    with Image.open(source) as icon:
        original = icon.convert('RGBA')
    destination.mkdir()
    sizes = {'StoreLogo.png': 50, 'Square150x150Logo.png': 150, 'Square44x44Logo.png': 44}
    for size in (24, 32, 48, 256):
        sizes[f'Square44x44Logo.targetsize-{size}_altform-unplated.png'] = size
    for name, size in sizes.items():
        original.resize((size, size), Image.Resampling.LANCZOS).save(destination / name)
    return {'approvedSource': str(source.relative_to(ROOT)), 'sourceSha256': sha256(source),
            'pillowVersion': pillow_version, 'dimensions': sizes}


def command(args: list[str], log: Path, commands: list) -> str:
    result = subprocess.run(args, capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=300)
    output = result.stdout + result.stderr
    log.write_text(output, encoding='utf-8')
    commands.append({'argv': args, 'exitCode': result.returncode, 'log': str(log)})
    if result.returncode:
        raise RuntimeError(f'{Path(args[0]).name} failed ({result.returncode}); see {log}')
    return output


def inspect_pe_files(folder: Path, evidence_dir: Path, commands: list) -> dict:
    vc = Path('C:/Program Files (x86)/Microsoft Visual Studio/18/BuildTools/VC/Tools/MSVC')
    candidates = sorted(vc.glob('*/bin/Hostx64/x64/dumpbin.exe'))
    if not candidates:
        raise RuntimeError('Visual Studio x64 dumpbin is required for dependency audit')
    dumpbin = candidates[-1]
    # This layout's DLLs are beside Rymu.exe. An unrelated file with the same
    # basename buried in Flutter assets must not satisfy an import check.
    bundled = {p.name.upper() for p in folder.iterdir() if p.is_file()}
    system = Path(os.environ['SystemRoot']) / 'System32'
    result = []
    for item in sorted(folder.rglob('*')):
        if not item.is_file():
            continue
        with item.open('rb') as stream:
            header = stream.read(4096)
        if header[:2] != b'MZ':
            continue
        offset = struct.unpack_from('<I', header, 0x3c)[0]
        if header[offset:offset + 4] != b'PE\0\0':
            raise ValueError(f'Invalid PE signature: {item}')
        machine = struct.unpack_from('<H', header, offset + 4)[0]
        if machine != 0x8664:
            raise ValueError(f'Non-x64 PE payload: {item}')
        flags = struct.unpack_from('<H', header, offset + 24 + 70)[0]
        rel = item.relative_to(folder).as_posix()
        text = command([str(dumpbin), '/nologo', '/dependents', str(item)],
                       evidence_dir / (rel.replace('/', '_') + '.imports.log'), commands)
        imports = sorted({s.upper() for s in re.findall(r'^\s+([\w.-]+\.dll)\s*$', text, re.I | re.M)})
        unresolved = [s for s in imports if s not in bundled and not (system / s).is_file()
                      and not s.startswith(('API-MS-WIN-', 'EXT-MS-WIN-'))]
        # A redistributable installed on this developer machine is not proof
        # it exists on a customer's clean PC. No framework dependency is
        # declared by this manifest, so VC runtime DLLs must be bundled.
        missing_vc_runtime = [s for s in imports if s.startswith(('MSVCP', 'VCRUNTIME', 'CONCRT')) and s not in bundled]
        result.append({'path': rel, 'sha256': sha256(item), 'machine': 'AMD64',
                       'aslr': bool(flags & 0x40), 'nxCompatible': bool(flags & 0x100),
                       'imports': imports, 'unresolvedStaticImports': unresolved,
                       'missingBundledVCRuntime': missing_vc_runtime})
        if unresolved:
            raise ValueError(f'Unresolved static dependencies in {rel}: {unresolved}')
        if missing_vc_runtime:
            raise ValueError(f'Unbundled Microsoft VC runtime dependency in {rel}: {missing_vc_runtime}')
    return {'files': result, 'tool': str(dumpbin),
            'scope': 'Static normal/delay import audit; System32 resolution is this build machine only. Dynamic LoadLibrary and runtime behavior remain untested.'}


def build(args: argparse.Namespace) -> Path:
    if os.name != 'nt':
        raise RuntimeError('Build on Windows with the Windows SDK')
    identity = validate_identity(LOCAL_IDENTITY.copy() if args.local_test_identity else
                                 json.loads(args.identity.read_text(encoding='utf-8-sig')), args.local_test_identity)
    version = validate_version(args.version, args.local_test_identity)
    runner = args.runner.resolve(strict=True)
    output = args.output.resolve()
    if output.suffix.lower() != '.msix':
        raise ValueError('Output must have .msix extension')
    if args.local_test_identity and 'localqualification' not in output.name.casefold():
        raise ValueError('Local identity output filename must include LocalQualification')
    evidence_dir = output.with_suffix('.evidence')
    if output.exists() or evidence_dir.exists():
        raise ValueError('Refusing to replace an existing package/evidence directory')
    if output.is_relative_to(runner) or runner.is_relative_to(output.parent):
        raise ValueError('Keep input runner and output artifact directories separate')
    makeappx = args.sdk.resolve(strict=True) / 'MakeAppx.exe'
    if not makeappx.is_file():
        raise ValueError('MakeAppx.exe is missing')
    for relative in REQUIRED_RUNTIME:
        if not (runner / relative).is_file():
            raise ValueError(f'Incomplete release runner: missing {relative}')
    files = sorted(p for p in runner.rglob('*') if p.is_file())
    for path in runner.rglob('*'):
        if path.is_symlink() or path.is_junction():
            raise ValueError(f'Reparse point is not permitted in release input: {path}')
        relative = path.relative_to(runner)
        if any(part.casefold() in {'.git', '.local', '.wrangler', '.ssh'} for part in relative.parts):
            raise ValueError(f'Private working directory is not permitted in runtime input: {path}')
        if path.is_file() and (path.suffix.lower() in {'.pdb', '.pfx', '.pem', '.key', '.env', '.msi', '.msix', '.log'}
                               or path.name.casefold().startswith('.env')
                               or path.name.casefold() in {'appxmanifest.xml', 'appxsignature.p7x', 'appxblockmap.xml',
                                                           '[content_types].xml', 'account.dat', 'id_rsa'}):
            raise ValueError(f'Unexpected debug/private/installer file in runtime input: {path}')
    output.parent.mkdir(parents=True, exist_ok=True)
    evidence_dir.mkdir()
    scratch = Path(tempfile.mkdtemp(prefix='rymu-msix-', dir=ROOT / '.local'))
    stage, unpacked = scratch / 'stage', scratch / 'unpacked'
    commands: list = []
    report = {
        'createdAt': dt.datetime.now(dt.timezone.utc).isoformat(),
        'status': 'in-progress', 'storeReady': False, 'submitted': False,
        'signed': False, 'installed': False, 'activated': False,
        'identityMode': 'local-qualification-only' if args.local_test_identity else 'partner-center-candidate',
        'identity': identity, 'version': version, 'runner': str(runner),
        'packagingScriptSha256': sha256(Path(__file__)), 'makeappxSha256': sha256(makeappx),
        'scratchDirectory': str(scratch), 'commands': commands,
        'limitations': [
            'Unsigned package; no install, startup consent, reboot, authenticated remote session, or WACK execution in this audit.',
            'Partner Center acceptance, restricted runFullTrust approval and certification are not established by MakeAppx.',
            'Existing MSI and package share a window class and loopback port; simultaneous execution is not qualified.',
            'AppData/registry virtualization, saved login, uninstall data handling, and old-MSI migration require clean-machine runtime validation.',
        ],
    }
    try:
        stage.mkdir()
        before = {p.relative_to(runner).as_posix(): sha256(p) for p in files}
        for item in files:
            target = stage / item.relative_to(runner)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(item, target)
        report['branding'] = generate_assets(stage / 'Assets')
        manifest_bytes = manifest(identity, version)
        (stage / 'AppxManifest.xml').write_bytes(manifest_bytes)
        (evidence_dir / 'AppxManifest.xml').write_bytes(manifest_bytes)
        report['peAudit'] = inspect_pe_files(stage, evidence_dir, commands)
        command([str(makeappx), 'pack', '/d', str(stage), '/p', str(output), '/no', '/h', 'SHA256'],
                evidence_dir / 'makeappx-pack.log', commands)
        command([str(makeappx), 'unpack', '/p', str(output), '/d', str(unpacked), '/no'],
                evidence_dir / 'makeappx-unpack.log', commands)
        staged_hashes = {p.relative_to(stage).as_posix(): sha256(p) for p in stage.rglob('*') if p.is_file()}
        for relative, expected in staged_hashes.items():
            if sha256(unpacked / relative) != expected:
                raise ValueError(f'Unpacked payload changed: {relative}')
        after = {p.relative_to(runner).as_posix(): sha256(p) for p in runner.rglob('*') if p.is_file()}
        if before != after or any(staged_hashes[relative] != expected for relative, expected in before.items()):
            raise ValueError('Release runner changed during packaging; rebuild from a stable snapshot')
        with zipfile.ZipFile(output) as archive:
            archive_names = {s.replace('\\', '/') for s in archive.namelist()}
            if 'AppxSignature.p7x' in archive_names:
                raise ValueError('Expected an unsigned candidate, found package signature')
            required = {'AppxManifest.xml', 'AppxBlockMap.xml', '[Content_Types].xml'}
            if not required.issubset(archive_names):
                raise ValueError('MSIX container metadata is incomplete')
        report.update(status='static-package-validation-passed', artifact=str(output),
                      bytes=output.stat().st_size, sha256=sha256(output),
                      runtimeFileCount=len(before), payloadFileCount=len(staged_hashes),
                      payloadSha256=staged_hashes, roundTripHashesMatched=True,
                      inputUnchanged=True, makeappxSemanticValidation=True)
        return output
    except Exception as exc:
        report.update(status='failed', error=str(exc))
        raise
    finally:
        (evidence_dir / 'report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    identity = parser.add_mutually_exclusive_group(required=True)
    identity.add_argument('--identity', type=Path, help='Actual Partner Center product identity JSON')
    identity.add_argument('--local-test-identity', action='store_true', help='Synthetic identity: never submit to Store')
    parser.add_argument('--runner', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--sdk', type=Path, default=SDK)
    return parser.parse_args()


if __name__ == '__main__':
    try:
        artifact = build(parse_args())
        print(f'Unsigned package created and statically verified: {artifact}')
        print('NOT INSTALLED. NOT CERTIFIED. NOT STORE-READY. Read the adjacent evidence/report.json.')
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))
