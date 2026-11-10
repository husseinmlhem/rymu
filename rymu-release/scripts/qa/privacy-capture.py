"""Build/run the bounded synthetic privacy proof using cached host capture libraries."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[2]
LOCAL = ROOT / '.local'
TARGET = LOCAL / 'windows-ntfs-target/release'
OUT = LOCAL / 'rymu-privacy-qa'


def latest(pattern):
    return max((TARGET / 'deps').glob(pattern), key=lambda p: p.stat().st_mtime)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--run', action='store_true')
    parser.add_argument('--capture-only', action='store_true')
    args = parser.parse_args()
    OUT.mkdir(exist_ok=True)
    toolchain = LOCAL / 'rustup-win/toolchains/1.75.0-x86_64-pc-windows-msvc/bin'
    source = ROOT / 'scripts/qa/privacy-capture.rs'
    exe = OUT / 'privacy-capture.exe'
    scrap, winapi = latest('libscrap-*.rlib'), latest('libwinapi-*.rlib')
    command = [str(toolchain/'rustc.exe'), '--edition=2021', str(source), '-o', str(exe),
               '-C', 'opt-level=1', '-C', 'target-feature=+crt-static', '-L', f'dependency={TARGET / "deps"}',
               '--extern', f'scrap={scrap}', '--extern', f'winapi={winapi}']
    link_paths = {str(LOCAL / 'vcpkg/installed/x64-windows-static/lib')}
    for output in (TARGET/'build').glob('*/output'):
        for line in output.read_text(encoding='utf-8', errors='replace').splitlines():
            if line.startswith('cargo:rustc-link-search='):
                value=line.split('=', 1)[1]
                candidate=value.split('=',1)[-1]
                if Path(candidate).is_dir(): link_paths.add(candidate)
    for path in sorted(link_paths): command += ['-L', f'native={path}']
    env=os.environ.copy()
    env['PATH']=os.pathsep.join([str(toolchain),*(p for p in env['PATH'].split(os.pathsep) if p.strip('"').lower().startswith('c:'))])
    log=ROOT/'artifacts/logs/privacy-capture-build.log'
    with log.open('w',encoding='utf-8') as stream:
        result=subprocess.run(command,env=env,cwd=ROOT,stdout=stream,stderr=subprocess.STDOUT,timeout=180)
    if result.returncode: raise SystemExit(f'Build failed ({result.returncode}); see {log}')
    record={'capture_library':str(scrap.relative_to(ROOT)), 'capture_library_sha256':hashlib.file_digest(scrap.open('rb'),'sha256').hexdigest(),
            'source_sha256':hashlib.file_digest(source.open('rb'),'sha256').hexdigest(), 'build':'passed'}
    if args.run:
        run_command=[str(exe)] + (['--capture-only'] if args.capture_only else [])
        result=subprocess.run(run_command,cwd=ROOT,env=env,capture_output=True,text=True,timeout=30)
        (ROOT/'artifacts/logs/privacy-capture-synthetic.log').write_text(result.stdout+result.stderr,encoding='utf-8')
        record['exit_code']=result.returncode
        print(result.stdout+result.stderr)
    (ROOT/'artifacts/logs/privacy-capture-build.json').write_text(json.dumps(record,indent=2)+'\n',encoding='utf-8')
    print(f'Build passed: {exe}')
    if args.run and result.returncode: raise SystemExit(result.returncode)


if __name__ == '__main__': main()
