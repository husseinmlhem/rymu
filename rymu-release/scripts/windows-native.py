"""Build the local Windows x64 DLL with the workspace's pinned C: toolchain."""
from __future__ import annotations

import argparse
from datetime import UTC, datetime
import os
from pathlib import Path
import shutil
import subprocess
import sys


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("build", "test"))
    parser.add_argument("--hosted", action="store_true",
                        help="Require HTTPS account transport in the compiled native engine.")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    if sys.platform != "win32" or root.drive.lower() != "c:":
        parser.error("Use the dedicated workspace on C: for this recovery recipe.")
    local = root / ".local"
    native = root / "apps/native"
    toolchain = local / "rustup-win/toolchains/1.75.0-x86_64-pc-windows-msvc/bin"
    target = local / "windows-ntfs-target"
    clang = local / "llvm-15-ntfs"
    vcpkg = local / "vcpkg"
    for path in (toolchain / "cargo.exe", toolchain / "rustc.exe", clang / "libclang.dll",
                 vcpkg / "installed/x64-windows-static/lib/vpx.lib", native / "src/bridge_generated.rs"):
        if not path.is_file():
            parser.error(f"Missing pinned prerequisite: {path}")
    free = shutil.disk_usage(root).free
    if free < (2.5 if target.exists() else 4) * 2**30:
        parser.error("The C: workspace needs more free space for this native build.")
    temporary = local / "windows-ntfs-temp"
    temporary.mkdir(exist_ok=True)
    env = os.environ.copy()
    env.update(CARGO_HOME=str(local / "cargo-shim"), RUSTUP_HOME=str(local / "rustup-win"),
               RUSTC=str(toolchain / "rustc.exe"), CARGO_TARGET_DIR=str(target),
               VCPKG_ROOT=str(vcpkg), VCPKG_DISABLE_METRICS="1", LIBCLANG_PATH=str(clang),
               RYMU_LOCAL_BUILD="1", TEMP=str(temporary), TMP=str(temporary),
               CARGO_INCREMENTAL="0", CARGO_TERM_COLOR="never")
    if args.hosted:
        env.pop("RYMU_LOCAL_BUILD", None)
    env["PATH"] = os.pathsep.join([str(toolchain), *(part for part in env.get("PATH", "").split(os.pathsep)
                                  if part.strip('"').lower().startswith("c:"))])
    command = [str(toolchain / "cargo.exe"), "rustc" if args.mode == "build" else "test",
               "--offline", "--locked", "--features", "hwcodec,vram,flutter", "--lib", "--release",
               "--jobs", "6", "--config", "profile.release.opt-level=1", "--config",
               "profile.release.lto=false", "--config", "profile.release.codegen-units=8"]
    command.extend(["--crate-type", "cdylib"] if args.mode == "build" else ["rymu::", "--", "--nocapture"])
    qualifier = "-hosted" if args.hosted else ""
    log = root / "artifacts/logs" / f"windows-ntfs{qualifier}-{args.mode}.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("a", encoding="utf-8") as stream:
        print(f"{datetime.now(UTC).isoformat()} {args.mode}; {free / 2**30:.2f} GiB free", file=stream, flush=True)
        print("cargo " + " ".join(command[1:]), file=stream, flush=True)
        result = subprocess.run(command, cwd=native, env=env, stdout=stream, stderr=subprocess.STDOUT)
        print(f"{datetime.now(UTC).isoformat()} exit_code={result.returncode}", file=stream)
    if result.returncode:
        raise SystemExit(f"Windows Rust {args.mode} exited {result.returncode}; see {log}")
    if args.mode == "build":
        output = native / "target/release/librustdesk.dll"
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(target / "release/librustdesk.dll", output)
        print(f"Staged {output}")
    print(f"Windows Rust {args.mode} passed; see {log}")


if __name__ == "__main__":
    main()
