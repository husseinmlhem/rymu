"""Record actual CI outputs; never label an unsigned qualification build as a release."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import zipfile


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--version', required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    out = root / 'rymu-release/out'
    runner = root / 'flutter/build/windows/x64/runner/Release'
    if os.environ.get('GITHUB_ACTIONS') != 'true' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted':
        raise SystemExit('Evidence generation requires the actual hosted CI build.')
    baseline = json.loads((root / 'rymu-release/ci/source-baseline.json').read_text(encoding='utf-8'))
    payload = {}
    archive = out / f'Rymu-Windows-x64-{args.version}-CI-Unsigned.zip'
    with zipfile.ZipFile(archive, 'x', compression=zipfile.ZIP_DEFLATED) as target:
        for path in sorted(runner.rglob('*')):
            if path.is_symlink():
                raise SystemExit('Unexpected link in the compiled runner.')
            if path.is_file() and path.suffix.lower() not in {'.pdb', '.lib', '.exp'}:
                name = path.relative_to(runner).as_posix()
                payload[name] = hashlib.sha256(path.read_bytes()).hexdigest()
                target.write(path, name)
    artifacts = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in out.iterdir() if p.suffix in {'.zip', '.msi'}}
    record = {
        'recordedAt': datetime.now(timezone.utc).isoformat(),
        'status': 'unsigned-ci-qualification-build',
        'repository': os.environ['GITHUB_REPOSITORY'],
        'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
        'runUrl': f"{os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}",
        'runAttempt': os.environ['GITHUB_RUN_ATTEMPT'],
        'runnerImage': {key: os.environ.get(key) for key in ['ImageOS', 'ImageVersion', 'RUNNER_OS', 'RUNNER_ARCH']},
        'version': args.version,
        'sourceArchiveSha256': baseline['sourceArchiveSha256'],
        'reviewedSourceChanges': baseline.get('reviewedSourceChanges', {}),
        'originalArchiveHashMappingPreserved': True,
        'sourceBaselineSha256': hashlib.sha256((root / 'rymu-release/ci/source-baseline.json').read_bytes()).hexdigest(),
        'toolchainLock': json.loads((root / 'rymu-release/ci/toolchain-lock.json').read_text(encoding='utf-8')),
        'cargoLockSha256': hashlib.sha256((root / 'Cargo.lock').read_bytes()).hexdigest(),
        'pubspecLockSha256': hashlib.sha256((root / 'flutter/pubspec.lock').read_bytes()).hexdigest(),
        'payloadSha256': payload,
        'installedVcpkgNoticesManifestSha256': hashlib.sha256((runner / 'THIRD-PARTY-LICENSES/manifest.json').read_bytes()).hexdigest(),
        'licenseGrantReviewComplete': False,
        'artifactsSha256': artifacts,
        'signed': False, 'published': False, 'wackPassed': False,
        'limitations': ['No GUI install/reboot/remote peer qualification is inferred.', 'No SignPath acceptance or signing request is inferred.', 'Hash-pinned binary tools are not a claim of verified upstream source-to-binary provenance.', 'Timestamped PE/MSI/ZIP outputs are not claimed bit-for-bit reproducible.'],
    }
    (out / 'build-evidence.json').write_text(json.dumps(record, indent=2) + '\n', encoding='utf-8')
    public_record = dict(record)
    public_record['payloadFiles'] = len(payload)
    rendered = json.dumps(public_record, indent=2)
    if len(rendered) > 120_000:
        public_record['payloadSha256ManifestHash'] = hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()
        del public_record['payloadSha256']
        rendered = json.dumps(public_record, indent=2)
    print(rendered)
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a', encoding='utf-8') as stream:
            stream.write('## Unsigned Windows qualification evidence\n\n```json\n' + rendered + '\n```\n')


if __name__ == '__main__':
    main()
