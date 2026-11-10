"""Check the source snapshot and reviewed CI input hashes without running a build."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys
import os
import subprocess


def main() -> None:
    root = Path(__file__).resolve().parents[2]
    manifest = json.loads((root / 'rymu-release/ci/source-baseline.json').read_text(encoding='utf-8'))
    checks = manifest['files'] | manifest['ciInputs']
    failures = []
    line_ending_matches = 0
    for name, expected in checks.items():
        path = root / name
        if not path.resolve().is_relative_to(root) or path.is_symlink() or not path.is_file():
            failures.append(name)
            continue
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() == expected:
            continue
        normalized = manifest.get('lineEndingNormalizedSha256', {}).get(name)
        if normalized and b'\0' not in data:
            if hashlib.sha256(data.replace(b'\r\n', b'\n')).hexdigest() == normalized:
                line_ending_matches += 1
                continue
        failures.append(name)
    active = {path.name for path in (root / '.github/workflows').glob('*') if path.is_file()}
    if active != {'rymu-windows-ci.yml'}:
        failures.append('unexpected active workflows')
    git_index_verified = False
    if (root / '.git').exists():
        try:
            rows = subprocess.check_output(['git', 'ls-files', '--stage', '-z'], cwd=root).split(b'\0')
            index = {}
            for row in rows:
                if row:
                    metadata, name = row.split(b'\t', 1)
                    index[name.decode()] = metadata.decode().split()
            expected_paths = {name for name in checks if not name.startswith('libs/hbb_common/')}
            expected_paths |= {'libs/hbb_common', 'rymu-release/ci/source-baseline.json'}
            if set(index) != expected_paths:
                failures.append('tracked file allowlist mismatch')
            if index.get('libs/hbb_common') != ['160000', manifest['hbbCommonCommit'], '0']:
                failures.append('hbb_common gitlink mismatch')
            actual_common = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root / 'libs/hbb_common', text=True).strip()
            if actual_common != manifest['hbbCommonCommit']:
                failures.append('hbb_common checkout mismatch')
            git_index_verified = not failures
        except (OSError, subprocess.CalledProcessError):
            failures.append('Git provenance could not be verified')
    elif os.environ.get('GITHUB_ACTIONS') == 'true':
        failures.append('CI checkout Git metadata missing')
    if failures:
        print(json.dumps({'status': 'failed', 'paths': failures}, indent=2))
        raise SystemExit(1)
    result = {'status': 'source-and-ci-inputs-verified', 'sourceFiles': len(manifest['files']),
              'ciInputs': len(manifest['ciInputs']), 'upstreamWorkflowsQuarantined': True,
              'gitLineEndingMatches': line_ending_matches,
              'gitTrackedAllowlistAndSubmoduleVerified': git_index_verified,
              'sourceArchiveSha256': manifest['sourceArchiveSha256'], 'buildExecuted': False}
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
