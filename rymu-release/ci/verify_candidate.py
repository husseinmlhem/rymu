"""Check the source snapshot and reviewed CI input hashes without running a build."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys


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
    if failures:
        print(json.dumps({'status': 'failed', 'paths': failures}, indent=2))
        raise SystemExit(1)
    result = {'status': 'source-and-ci-inputs-verified', 'sourceFiles': len(manifest['files']),
              'ciInputs': len(manifest['ciInputs']), 'upstreamWorkflowsQuarantined': True,
              'gitLineEndingMatches': line_ending_matches,
              'sourceArchiveSha256': manifest['sourceArchiveSha256'], 'buildExecuted': False}
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
