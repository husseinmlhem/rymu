"""Run explicitly opted-in desktop privacy component tests in bounded processes."""
import argparse
import ctypes as c
from ctypes import wintypes as w
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess


ROOT=Path(__file__).resolve().parents[2]
CASES=[
    'rymu::privacy::tests::privacy_physical_capture_and_restore',
    'rymu::privacy::tests::privacy_local_stop_message_restores',
    'rymu::privacy::tests::privacy_process_crash_restores',
]


def pe_code_digest(path):
    data=path.read_bytes()
    pe=struct.unpack_from('<I',data,0x3c)[0]
    assert data[pe:pe+4]==b'PE\0\0'
    count=struct.unpack_from('<H',data,pe+6)[0]
    size=struct.unpack_from('<H',data,pe+20)[0]
    for index in range(count):
        at=pe+24+size+40*index
        name=data[at:at+8].rstrip(b'\0')
        if name==b'.text':
            length,pointer=struct.unpack_from('<II',data,at+16)
            return hashlib.sha256(data[pointer:pointer+length]).hexdigest()
    raise ValueError('No native executable code section')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable',type=Path,required=True)
    parser.add_argument('--run-desktop',action='store_true',help='Briefly cover this workstation; never run implicitly.')
    parser.add_argument('--case',choices=[c.rsplit('::',1)[1] for c in CASES],action='append')
    args=parser.parse_args()
    exe=args.executable.resolve()
    expected=(ROOT/'.local/windows-ntfs-target/release/deps').resolve()
    if exe.parent!=expected or not exe.is_file() or exe.suffix.lower()!='.exe':
        parser.error('Use the exact test executable built in the workspace native release/deps cache.')
    source_exe=exe
    source_digest=hashlib.file_digest(source_exe.open('rb'),'sha256').hexdigest()
    source_code=pe_code_digest(source_exe)
    manifest=ROOT/'apps/native/flutter/windows/runner/runner.exe.manifest'
    output=ROOT/'.local/rymu-privacy-qa'
    output.mkdir(exist_ok=True)
    exe=output/'privacy-native-tests.exe'
    shutil.copy2(source_exe,exe)
    kernel=c.WinDLL('kernel32',use_last_error=True)
    kernel.BeginUpdateResourceW.argtypes=[w.LPCWSTR,w.BOOL]; kernel.BeginUpdateResourceW.restype=w.HANDLE
    kernel.UpdateResourceW.argtypes=[w.HANDLE,c.c_void_p,c.c_void_p,w.WORD,c.c_void_p,w.DWORD]
    kernel.EndUpdateResourceW.argtypes=[w.HANDLE,w.BOOL]
    handle=kernel.BeginUpdateResourceW(str(exe),False)
    if not handle: raise c.WinError(c.get_last_error())
    data=manifest.read_bytes()
    buffer=c.create_string_buffer(data)
    if not kernel.UpdateResourceW(handle,c.c_void_p(24),c.c_void_p(1),0,buffer,len(data)):
        error=c.get_last_error();kernel.EndUpdateResourceW(handle,True);raise c.WinError(error)
    if not kernel.EndUpdateResourceW(handle,False): raise c.WinError(c.get_last_error())
    assert pe_code_digest(exe)==source_code,'Manifest embedding changed native machine code'
    kernel.LoadLibraryExW.argtypes=[w.LPCWSTR,w.HANDLE,w.DWORD];kernel.LoadLibraryExW.restype=w.HANDLE
    kernel.FindResourceW.argtypes=[w.HANDLE,c.c_void_p,c.c_void_p];kernel.FindResourceW.restype=w.HANDLE
    kernel.LoadResource.argtypes=[w.HANDLE,w.HANDLE];kernel.LoadResource.restype=w.HANDLE
    kernel.LockResource.argtypes=[w.HANDLE];kernel.LockResource.restype=c.c_void_p
    kernel.SizeofResource.argtypes=[w.HANDLE,w.HANDLE];kernel.SizeofResource.restype=w.DWORD
    kernel.FreeLibrary.argtypes=[w.HANDLE]
    module=kernel.LoadLibraryExW(str(exe),None,2)
    if not module:raise c.WinError(c.get_last_error())
    try:
        resource=kernel.FindResourceW(module,c.c_void_p(1),c.c_void_p(24))
        assert resource,'Embedded manifest resource not found'
        loaded=kernel.LoadResource(module,resource)
        payload=kernel.LockResource(loaded)
        assert payload and c.string_at(payload,kernel.SizeofResource(module,resource))==data,'Manifest readback mismatch'
    finally:kernel.FreeLibrary(module)
    listing=subprocess.run([str(exe),'--list'],cwd=ROOT,capture_output=True,text=True,timeout=15,check=True)
    for case in CASES: assert case+': test' in listing.stdout,case
    if not args.run_desktop:
        print('All named tests are present. Use --run-desktop only for the explicitly authorized bounded desktop run.')
        return
    cases=CASES if not args.case else [c for c in CASES if c.rsplit('::',1)[1] in args.case]
    log=ROOT/'artifacts/logs/privacy-native-physical.log'
    report={'started_at':datetime.now(timezone.utc).isoformat(),
            'native_test_executable':str(exe.relative_to(ROOT)),
            'native_test_executable_sha256':hashlib.file_digest(exe.open('rb'),'sha256').hexdigest(),
            'unmodified_native_test_executable':str(source_exe.relative_to(ROOT)),
            'unmodified_native_test_sha256':source_digest,
            'manifest':str(manifest.relative_to(ROOT)),
            'manifest_sha256':hashlib.file_digest(manifest.open('rb'),'sha256').hexdigest(),
            'manifest_note':'Same Windows10 compatibility manifest as real Flutter runner; bare Rust test EXE lacks it.',
            'native_text_section_unchanged':True,
            'native_text_section_sha256':source_code,
            'manifest_readback_exact':True,
            'classification':'actual_host_backend_component_tests_not_remote_phone_session', 'tests':[]}
    with log.open('w',encoding='utf-8') as stream:
        for case in cases:
            command=[str(exe),'--exact',case,'--ignored','--nocapture','--test-threads=1']
            stream.write('COMMAND '+str(command)+'\n'); stream.flush()
            try:
                result=subprocess.run(command,cwd=ROOT,capture_output=True,text=True,timeout=45)
                stream.write(result.stdout+result.stderr); stream.flush()
                report['tests'].append({'name':case,'exit_code':result.returncode,
                    'passed':result.returncode==0 and '1 passed' in result.stdout})
                print(case+': '+('PASS' if report['tests'][-1]['passed'] else 'FAIL'))
            except subprocess.TimeoutExpired:
                report['tests'].append({'name':case,'passed':False,'error':'bounded_test_process_timeout'})
                stream.write('FAIL bounded test process timed out; subprocess terminated by supervisor\n'); stream.flush()
                break
            if not report['tests'][-1]['passed']: break
    report['finished_at']=datetime.now(timezone.utc).isoformat()
    report['status']='passed' if len(report['tests'])==len(cases) and all(t['passed'] for t in report['tests']) else 'failed'
    (ROOT/'artifacts/logs/privacy-native-physical.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    if report['status']!='passed': raise SystemExit(1)


if __name__=='__main__': main()
