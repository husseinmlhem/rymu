"""Reconstruct the submitted 100-file payload from the immutable public MSI.

No installer is invoked. MSI database/CAB access follows the reviewed
rymu-release/scripts/test-windows-msi.py helper, which is also run unchanged
without --round-trip against the extracted runtime before Store assets are added.
The resulting envelope must never be described as the original submitted MSIX.
"""
from __future__ import annotations

import argparse
import base64
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import time
import urllib.request
from xml.etree import ElementTree

MSI_SHA256 = 'bd7a1ce138be3adf6f54fce8d9ba989f56eac8cfa5efe5f7b4e03deb15b41174'
MSI_BYTES = 36651008
MSI_URL = ('https://rymu.iptvora-server.workers.dev/api/v1/releases/windows-installer/0.1.14/'
           + MSI_SHA256 + '/Rymu-Windows-x64-0.1.14.msi')
SUBMITTED_SHA256 = 'e1eb4b89c6e9518477071ff57b703c7b8300e92316fc5cac4030fb75bc5c3ba4'


def sha256(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def expected_payload() -> dict[str, str]:
    record = json.loads(Path(__file__).with_name('store-msix-1.0.14.0-payload.json').read_text())
    payload = record['payloadSha256']
    if record['sha256'] != SUBMITTED_SHA256 or len(payload) != 100:
        raise ValueError('Unexpected original payload record')
    for name, digest in payload.items():
        path = PurePosixPath(name)
        if path.is_absolute() or '..' in path.parts or '\\' in name or ':' in name:
            raise ValueError('Unsafe payload path')
        if len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest):
            raise ValueError('Invalid recorded payload hash')
    return payload


def runtime_file_id(relative: str) -> str:
    return 'RymuExe' if relative == 'Rymu.exe' else 'F' + hashlib.sha256(relative.casefold().encode()).hexdigest()[:22]


def verify_blockmap(directory: Path) -> dict:
    expected = expected_payload()
    raw = (directory / 'AppxBlockMap.xml').read_bytes()
    if b'<!DOCTYPE' in raw.upper() or b'<!ENTITY' in raw.upper():
        raise ValueError('Unsupported block map XML declaration')
    root = ElementTree.fromstring(raw)
    namespace = '{http://schemas.microsoft.com/appx/2010/blockmap}'
    extension = '{http://schemas.microsoft.com/appx/2021/blockmap}FileHash'
    if root.tag != namespace + 'BlockMap' or root.get('HashMethod') != 'http://www.w3.org/2001/04/xmlenc#sha256':
        raise ValueError('Unexpected block map identity/hash algorithm')
    seen, blocks, full_hashes = set(), 0, 0
    for item in root:
        name = item.get('Name', '').replace('\\', '/')
        if item.tag != namespace + 'File' or name not in expected or name in seen:
            raise ValueError('Unexpected or duplicate block map file')
        seen.add(name)
        data = (directory / name).read_bytes()
        if item.get('Size') != str(len(data)) or hashlib.sha256(data).hexdigest() != expected[name]:
            raise ValueError('Block map file size/payload hash differs')
        hashes = []
        extension_count = 0
        for child in item:
            digest = base64.b64decode(child.get('Hash', ''), validate=True)
            if child.tag == namespace + 'Block':
                hashes.append(digest)
            elif child.tag == extension:
                if digest != hashlib.sha256(data).digest():
                    raise ValueError('Block map whole-file hash differs')
                extension_count += 1
            else:
                raise ValueError('Unexpected block map element')
        wanted = [hashlib.sha256(data[i:i + 65536]).digest() for i in range(0, len(data), 65536)]
        if hashes != wanted or extension_count > 1:
            raise ValueError('Block map content hashes differ')
        blocks += len(hashes)
        full_hashes += extension_count
    if seen != set(expected):
        raise ValueError('Block map does not cover exactly the 100 submitted files')
    return {'status': 'blockmap-verified', 'payloadFiles': len(seen), 'sha256Blocks': blocks, 'wholeFileHashes': full_hashes}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, newurl):
        raise ValueError('Immutable public MSI must not redirect')


def download_public(destination: Path) -> None:
    opener = urllib.request.build_opener(NoRedirect())
    request = urllib.request.Request(MSI_URL, headers={'User-Agent': 'Rymu-Store-Payload-Audit/1'})
    started = time.monotonic()
    with opener.open(request, timeout=30) as response, destination.open('xb') as output:
        if response.status != 200 or response.geturl() != MSI_URL:
            raise ValueError('Expected exact public immutable MSI response')
        if response.headers.get('Content-Length') != str(MSI_BYTES):
            raise ValueError('Public MSI length header differs')
        size = 0
        while block := response.read(65536):
            size += len(block)
            if size > MSI_BYTES or time.monotonic() - started > 180:
                raise ValueError('Public MSI transfer exceeded its bound')
            output.write(block)
    verify_msi(destination)


def verify_msi(package: Path) -> None:
    if package.is_symlink() or package.stat().st_size != MSI_BYTES or sha256(package) != MSI_SHA256:
        raise ValueError('MSI differs from the exact public 0.1.14 artifact')


def extract_runtime(package: Path, scratch: Path, runtime: dict[str, str]) -> Path:
    api = ctypes.WinDLL('msi.dll')
    uint, string = wintypes.UINT, wintypes.LPCWSTR
    api.MsiOpenDatabaseW.argtypes = (string, string, ctypes.POINTER(uint))
    api.MsiDatabaseOpenViewW.argtypes = (uint, string, ctypes.POINTER(uint))
    api.MsiViewExecute.argtypes = (uint, uint)
    api.MsiViewFetch.argtypes = (uint, ctypes.POINTER(uint))
    api.MsiRecordGetStringW.argtypes = (uint, uint, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD))
    api.MsiRecordReadStream.argtypes = (uint, uint, ctypes.c_void_p, ctypes.POINTER(wintypes.DWORD))
    api.MsiCloseHandle.argtypes = (uint,)

    def check(status: int) -> None:
        if status:
            raise OSError(f'Read-only Windows Installer API returned {status}')

    database = uint()
    check(api.MsiOpenDatabaseW(str(package), None, ctypes.byref(database)))

    def query(sql: str, fields: int) -> list[list[str]]:
        view = uint()
        check(api.MsiDatabaseOpenViewW(database, sql, ctypes.byref(view)))
        try:
            check(api.MsiViewExecute(view, 0))
            rows = []
            while True:
                record = uint()
                status = api.MsiViewFetch(view, ctypes.byref(record))
                if status == 259:
                    return rows
                check(status)
                try:
                    row = []
                    for index in range(1, fields + 1):
                        value = ctypes.create_unicode_buffer(512)
                        size = wintypes.DWORD(len(value))
                        check(api.MsiRecordGetStringW(record, index, value, ctypes.byref(size)))
                        row.append(value.value)
                    rows.append(row)
                finally:
                    api.MsiCloseHandle(record)
        finally:
            api.MsiCloseHandle(view)

    cabinet = scratch / 'payload.cab'
    try:
        properties = dict(query('SELECT `Property`, `Value` FROM `Property`', 2))
        if properties.get('ProductName') != 'Rymu' or properties.get('ProductVersion') != '0.1.14':
            raise ValueError('Unexpected MSI product')
        ids = [row[0] for row in query('SELECT `File` FROM `File`', 1)]
        wanted_ids = {runtime_file_id(name) for name in runtime}
        if len(ids) != 92 or len(wanted_ids) != 92 or set(ids) != wanted_ids:
            raise ValueError('MSI file table differs from the 92 expected runtime paths')
        media = query('SELECT `Cabinet` FROM `Media`', 1)
        if len(media) != 1 or not media[0][0].startswith('#'):
            raise ValueError('Expected exactly one embedded cabinet')
        name = media[0][0][1:]
        if not name or any(not (c.isalnum() or c in '-_.') for c in name):
            raise ValueError('Unsafe cabinet stream name')
        view, record = uint(), uint()
        check(api.MsiDatabaseOpenViewW(database, f"SELECT `Data` FROM `_Streams` WHERE `Name`='{name}'", ctypes.byref(view)))
        try:
            check(api.MsiViewExecute(view, 0))
            check(api.MsiViewFetch(view, ctypes.byref(record)))
            with cabinet.open('xb') as output:
                buffer = ctypes.create_string_buffer(65536)
                total = 0
                while True:
                    size = wintypes.DWORD(len(buffer))
                    check(api.MsiRecordReadStream(record, 1, buffer, ctypes.byref(size)))
                    if not size.value:
                        break
                    total += size.value
                    if total > MSI_BYTES:
                        raise ValueError('Cabinet exceeds the pinned MSI size')
                    output.write(buffer.raw[:size.value])
        finally:
            if record.value:
                api.MsiCloseHandle(record)
            api.MsiCloseHandle(view)
    finally:
        api.MsiCloseHandle(database)

    expanded = scratch / 'cabinet-files'
    expanded.mkdir()
    subprocess.run([str(Path(os.environ['SystemRoot']) / 'System32/expand.exe'), '-F:*', str(cabinet), str(expanded)],
                   check=True, timeout=30, stdout=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW)
    extracted = list(expanded.iterdir())
    found = {file.name.casefold(): file for file in extracted}
    if len(found) != 92 or any(not file.is_file() or file.is_symlink() for file in extracted):
        raise ValueError('Cabinet has unexpected files or directories')
    payload = scratch / 'payload'
    payload.mkdir()
    for relative, digest in runtime.items():
        source = found[runtime_file_id(relative).casefold()]
        if sha256(source) != digest:
            raise ValueError(f'Runtime content differs: {relative}')
        destination = payload / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
    return payload


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--output', type=Path, help='New isolated directory; must not already exist')
    mode.add_argument('--verify-blockmap', type=Path, help='Read-only verification of an unpacked SDK block map')
    parser.add_argument('--msi', type=Path, help='Optional exact local MSI for extraction-only verification')
    args = parser.parse_args()
    if args.verify_blockmap:
        if args.msi:
            raise ValueError('An MSI input is not used for block map verification')
        print(json.dumps(verify_blockmap(args.verify_blockmap.resolve(strict=True)), indent=2))
        return
    if sys.platform != 'win32':
        raise SystemExit('Read-only MSI database extraction requires Windows')
    expected = expected_payload()
    assets = {n: h for n, h in expected.items() if n == 'AppxManifest.xml' or n.startswith('Assets/')}
    runtime = {n: h for n, h in expected.items() if n not in assets}
    if len(runtime) != 92 or len(assets) != 8:
        raise ValueError('Unexpected runtime/Store asset partition')
    asset_root = Path(__file__).with_name('store-payload-assets')
    if {p.relative_to(asset_root).as_posix() for p in asset_root.rglob('*') if p.is_file()} != set(assets):
        raise ValueError('Unexpected Store input files')
    for name, digest in assets.items():
        if sha256(asset_root / name) != digest:
            raise ValueError('Store-only asset differs from the submitted package')
    scratch = args.output.resolve()
    scratch.mkdir()
    package = args.msi.resolve(strict=True) if args.msi else scratch / 'public-original.msi'
    if not args.msi:
        download_public(package)
    verify_msi(package)
    payload = extract_runtime(package, scratch, runtime)
    helper = Path(__file__).resolve().parents[1] / 'scripts/test-windows-msi.py'
    subprocess.run([sys.executable, str(helper), str(package), str(payload), '--log-dir', str(scratch / 'msi-audit')],
                   check=True, timeout=90, creationflags=subprocess.CREATE_NO_WINDOW)
    for name in assets:
        destination = payload / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(asset_root / name, destination)
    actual = {p.relative_to(payload).as_posix(): sha256(p) for p in payload.rglob('*') if p.is_file()}
    if actual != expected:
        raise ValueError('Reconstructed payload is not exactly the submitted 100 files')
    verify_msi(package)
    report = {'status': 'payload-identical-reconstruction-verified', 'runtimeFiles': 92, 'storeOnlyFiles': 8,
              'payloadFiles': 100, 'publicMsiSha256': MSI_SHA256, 'publicMsiBytes': MSI_BYTES,
              'publicMsiUrl': MSI_URL, 'submittedPackageSha256ForReference': SUBMITTED_SHA256,
              'exactSubmittedArchiveTested': False, 'installerExecuted': False, 'nativeAppLaunched': False}
    (scratch / 'reconstruction.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
