"""Check the source snapshot and reviewed CI input hashes without running a build."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys
import os
import subprocess
import re


def reviewed_expectations(manifest: dict) -> tuple[dict, dict]:
    """Preserve the original archive mapping and apply explicitly reviewed deltas."""
    checks = manifest['files'] | manifest['ciInputs']
    normalized = dict(manifest.get('lineEndingNormalizedSha256', {}))
    for name, change in manifest.get('reviewedSourceChanges', {}).items():
        if name not in manifest['files'] or change.get('beforeSha256') != manifest['files'][name]:
            raise ValueError(f'Overlay does not identify the original source hash: {name}')
        if change.get('beforeLineEndingNormalizedSha256') != normalized.get(name):
            raise ValueError(f'Overlay original line-ending hash differs: {name}')
        for field in ('beforeSha256', 'afterSha256', 'afterLineEndingNormalizedSha256', 'patchSha256'):
            if not re.fullmatch('[0-9a-f]{64}', change.get(field, '')):
                raise ValueError(f'Overlay hash is missing or malformed: {name}/{field}')
        patch = change.get('patch')
        if manifest['ciInputs'].get(patch) != change['patchSha256']:
            raise ValueError(f'Overlay patch is not a reviewed CI input: {name}')
        if not re.fullmatch('[0-9a-f]{40}', change.get('baseCommit', '')) or not change.get('reason'):
            raise ValueError(f'Overlay review context is incomplete: {name}')
        checks[name] = change['afterSha256']
        normalized[name] = change['afterLineEndingNormalizedSha256']
    return checks, normalized


def verify_rust_literal_inputs(root: Path) -> tuple[int, list[str]]:
    pattern = re.compile(r'#\[\s*path\s*=\s*"([^"]+)"\s*\]|include(?:_str|_bytes)?!\(\s*"([^"]+)"')
    root = root.resolve()
    checked, failures = 0, []
    for folder in ('src', 'libs'):
        for source in (root / folder).rglob('*.rs'):
            # The separate portable-wrapper executable generates data.bin and
            # app_metadata.toml in its own packaging recipe; it is not this lib.
            if source.is_relative_to(root / 'libs/portable'):
                continue
            for hit in pattern.finditer(source.read_text(encoding='utf-8', errors='replace')):
                literal = hit.group(1) or hit.group(2)
                target = (source.parent / literal).resolve()
                checked += 1
                if not target.is_relative_to(root) or not target.is_file():
                    failures.append(f'Rust literal dependency outside/missing: {source.relative_to(root).as_posix()} -> {literal}')
    return checked, failures


def main() -> None:
    root = Path(__file__).resolve().parents[2]
    manifest = json.loads((root / 'rymu-release/ci/source-baseline.json').read_text(encoding='utf-8'))
    try:
        checks, normalized_hashes = reviewed_expectations(manifest)
    except ValueError as error:
        print(json.dumps({'status': 'failed', 'reason': str(error)}, indent=2))
        raise SystemExit(1)
    failures = []
    rust_literal_count, rust_path_failures = verify_rust_literal_inputs(root)
    failures.extend(rust_path_failures)
    line_ending_matches = 0
    for name, expected in checks.items():
        path = root / name
        if not path.resolve().is_relative_to(root) or path.is_symlink() or not path.is_file():
            failures.append(name)
            continue
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() == expected:
            continue
        normalized = normalized_hashes.get(name)
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
              'reviewedSourceChanges': sorted(manifest.get('reviewedSourceChanges', {})),
              'originalArchiveHashMappingPreserved': True,
              'rustLiteralSourceInputsVerified': rust_literal_count,
              'sourceArchiveSha256': manifest['sourceArchiveSha256'], 'buildExecuted': False}
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
