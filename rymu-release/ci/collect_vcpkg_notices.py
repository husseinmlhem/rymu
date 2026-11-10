"""Copy actual installed vcpkg notices into a runner; this is not a license audit."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import stat


TRIPLET = 'x64-windows-static'
REQUIRED = frozenset({'aom', 'amd-amf', 'ffmpeg', 'ffnvcodec', 'libjpeg-turbo',
                      'libvpx', 'libyuv', 'mfx-dispatch', 'opus'})
README = (
    'These files are exact copies of copyright notices installed by vcpkg for '
    'this Windows build. The manifest identifies their paths, versions and hashes.\n'
    'Collection does not establish a selected license grant, complete source-to-binary '
    'provenance or complete coverage of Cargo, Flutter and other dependencies. '
    'Separate license/provenance review remains required. No license text was invented.\n'
).encode('utf-8')


def checked_path(path: Path, root: Path, *, directory: bool = False) -> Path:
    """Reject links/reparse points and unexpected types before reading/copying."""
    if not path.resolve().is_relative_to(root):
        raise ValueError(f'Path escapes the declared input: {path.name}')
    for item in (path, *path.parents):
        if not item.is_relative_to(root):
            break
        info = item.lstat()
        if stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT:
            raise ValueError(f'Links/reparse points are not notice inputs: {item.name}')
    if not (path.is_dir() if directory else path.is_file()):
        raise ValueError(f'Unexpected notice input type: {path.name}')
    return path


def read_packages(raw: bytes) -> dict[str, dict]:
    packages: dict[str, dict] = {}
    paragraphs = re.split(r'\r?\n\s*\r?\n', raw.decode('utf-8').strip())
    for paragraph in paragraphs:
        fields = {}
        current = None
        for line in paragraph.splitlines():
            if line[:1].isspace() and current:
                fields[current] += '\n' + line.strip()
            elif ': ' in line:
                current, value = line.split(': ', 1)
                fields[current] = value
        if fields.get('Architecture') != TRIPLET or fields.get('Status') != 'install ok installed':
            continue
        name = fields.get('Package', '')
        if not re.fullmatch(r'[a-z0-9][a-z0-9-]*', name):
            raise ValueError('Unsafe or missing package name in vcpkg status')
        entry = packages.setdefault(name, {'name': name, 'features': []})
        if 'Feature' in fields:
            entry['features'].append(fields['Feature'])
        else:
            if 'version' in entry or not fields.get('Version'):
                raise ValueError(f'Missing or duplicate package version: {name}')
            entry['version'] = fields['Version']
            entry['portVersion'] = fields.get('Port-Version', '0')
    if not REQUIRED.issubset(packages) or any('version' not in value for value in packages.values()):
        raise ValueError('Installed core package/version inventory is incomplete')
    for entry in packages.values():
        entry['features'] = sorted(set(entry['features']))
    return packages


def collect(installed_root: Path, runner: Path) -> dict:
    installed_root = installed_root.absolute()
    runner = runner.absolute()
    checked_path(installed_root, installed_root, directory=True)
    checked_path(runner, runner, directory=True)
    installed_root, runner = installed_root.resolve(), runner.resolve()
    destination = runner / 'THIRD-PARTY-LICENSES'
    if destination.exists() or destination.is_symlink():
        raise ValueError('Preserve the existing notice directory; do not overwrite it')
    status_path = checked_path(installed_root / 'vcpkg/status', installed_root)
    status = status_path.read_bytes()
    packages = read_packages(status)
    pending = []
    missing = []
    # Validate the entire input before creating any output.
    for name in sorted(packages):
        source = installed_root / TRIPLET / 'share' / name / 'copyright'
        if not source.exists() and not source.is_symlink():
            if name in REQUIRED:
                raise ValueError(f'Required installed library copyright is absent: {name}')
            missing.append(name)
            continue
        data = checked_path(source, installed_root).read_bytes()
        if not data.strip():
            raise ValueError(f'Installed copyright is empty: {name}')
        pending.append((name, source.relative_to(installed_root).as_posix(), data))
    notices = []
    for name, source, data in pending:
        relative = f'vcpkg/{name}/copyright'
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open('xb') as stream:
            stream.write(data)
        notices.append({'package': name, 'source': source, 'path': relative,
                        'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)})
    record = {
        'schema': 1, 'status': 'installed-notices-collected', 'triplet': TRIPLET,
        'source': 'vcpkg installed tree from this build',
        'vcpkgStatusSha256': hashlib.sha256(status).hexdigest(),
        'requiredLibraryPackages': sorted(REQUIRED), 'packages': [packages[name] for name in sorted(packages)],
        'notices': notices, 'nonRequiredPackagesWithoutCopyright': missing,
        'licenseGrantReviewComplete': False, 'completeDependencyCoverage': False,
        'limitations': [
            'Exact installed notices are copied; no SPDX identifier or legal grant is inferred.',
            'Cargo, Flutter, plugin and binary-engine provenance need separate review.',
            'This does not resolve an upstream placeholder license or prove source-to-binary identity.',
        ],
    }
    (destination / 'README.txt').write_bytes(README)
    (destination / 'manifest.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
    return record


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--installed-root', required=True, type=Path)
    parser.add_argument('--runner', required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(collect(args.installed_root, args.runner), indent=2))


if __name__ == '__main__':
    main()
