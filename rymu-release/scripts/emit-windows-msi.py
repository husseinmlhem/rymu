"""Author a per-user MSI with two explicit, installed-file Finish actions."""
from __future__ import annotations

import argparse
import hashlib
import re
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path

WIX = "http://schemas.microsoft.com/wix/2006/wi"
UPGRADE = uuid.UUID("e20d6245-06d5-4909-9a0e-055dbdf88df5")
ET.register_namespace("", WIX)


def element(parent: ET.Element, tag: str, **attrs: str) -> ET.Element:
    return ET.SubElement(parent, f"{{{WIX}}}{tag}", attrs)


def identity(prefix: str, relative: str) -> str:
    return prefix + hashlib.sha256(relative.casefold().encode()).hexdigest()[:22]


def main() -> None:
    cli = argparse.ArgumentParser()
    cli.add_argument("runner", type=Path)
    cli.add_argument("out", type=Path)
    cli.add_argument("--version", default="0.1.0", help="MSI product version (major.minor.build)")
    cli.add_argument("--public-release", action="store_true", help="Use the public Rymu product and shortcut names; does not sign the MSI")
    args = cli.parse_args()
    version = re.fullmatch(r"([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,5})", args.version)
    if not version or any(int(part) > maximum for part, maximum in zip(version.groups(), (255, 255, 65535))):
        cli.error("Use a three-part MSI version in the range 0.0.0 to 255.255.65535")
    runner = args.runner.resolve(strict=True)
    exe = runner / "Rymu.exe"
    if not exe.is_file() or exe.open("rb").read(2) != b"MZ":
        cli.error("Build the genuine Rymu.exe Windows runner first")
    if not (runner / "librustdesk.dll").is_file() or not (runner / "data").is_dir():
        cli.error("A full native runner bundle is required")

    root = ET.Element(f"{{{WIX}}}Wix")
    display_name = "Rymu" if args.public_release else "Rymu (Development)"
    product = element(root, "Product", Id="*", Name=display_name,
                      Language="1033", Version=args.version, Manufacturer="Hussein Mlhem" if args.public_release else "Rymu",
                      UpgradeCode=str(UPGRADE).upper())
    element(product, "Package", InstallerVersion="500", Compressed="yes",
            InstallScope="perUser", InstallPrivileges="limited", Platform="x64")
    element(product, "MajorUpgrade", DowngradeErrorMessage="A newer Rymu version is installed.")
    element(product, "MediaTemplate", EmbedCab="yes", CompressionLevel="high")
    build = element(product, "Property", Id="RYMU_NT_BUILD", Secure="yes")
    element(build, "RegistrySearch", Id="RymuWindowsBuild", Root="HKLM",
            Key=r"SOFTWARE\Microsoft\Windows NT\CurrentVersion", Name="CurrentBuildNumber",
            Type="raw", Win64="yes")
    # VersionNT64 may expose a compatibility version. Check architecture with
    # that property and the OS minimum with the native registry build number.
    element(product, "Condition", Message="Rymu requires 64-bit Windows 11 (build 22000 or newer).").text = (
        "Installed OR (VersionNT64 AND RYMU_NT_BUILD >= 22000)"
    )
    element(product, "Property", Id="ARPNOMODIFY", Value="1")
    installer_assets = Path(__file__).resolve().parent.parent / "design" / "installer"
    icon = installer_assets.parent / "assets" / "rymu-windows.ico"
    for asset in (installer_assets / "dialog.bmp", installer_assets / "banner.bmp", icon):
        if not asset.is_file():
            cli.error(f"Missing installer artwork: {asset}")
    element(product, "Icon", Id="RymuAppIcon", SourceFile=str(icon))
    element(product, "Property", Id="ARPPRODUCTICON", Value="RymuAppIcon")
    element(product, "Property", Id="ARPHELPLINK", Value="https://rymu.iptvora-server.workers.dev/help")
    if args.public_release:
        element(product, "Property", Id="ARPURLINFOABOUT", Value="https://www.husseinmlhem.com")
    element(product, "WixVariable", Id="WixUIBannerBmp", Value=str(installer_assets / "banner.bmp"))
    element(product, "WixVariable", Id="WixUIDialogBmp", Value=str(installer_assets / "dialog.bmp"))
    for page in ("welcome", "finish", "progress", "remove"):
        asset = installer_assets / f"{page}.bmp"
        if not asset.is_file():
            cli.error(f"Missing installer artwork: {asset}")
        element(product, "Binary", Id=f"Rymu_{page}", SourceFile=str(asset))
    element(product, "CustomAction", Id="RymuApplyStartup", FileKey="RymuExe",
            ExeCommand="--rymu-installer-startup [RYMU_STARTUP_ARG]", Return="check", Execute="immediate")
    element(product, "CustomAction", Id="RymuLaunchNow", FileKey="RymuExe",
            ExeCommand="", Return="asyncNoWait", Execute="immediate")
    product.append(ET.ProcessingInstruction("include", f'"{installer_assets / "rymu-ui.wxi"}"'))
    feature = element(product, "Feature", Id="RymuFeature", Title="Rymu", Level="1")
    target = element(product, "Directory", Id="TARGETDIR", Name="SourceDir")
    local = element(target, "Directory", Id="LocalAppDataFolder")
    programs = element(local, "Directory", Id="LocalPrograms", Name="Programs")
    install = element(programs, "Directory", Id="INSTALLFOLDER", Name="Rymu")
    folders = {".": install}
    expected = set()
    for file in sorted(runner.rglob("*")):
        if file.is_symlink():
            cli.error("The runner contains a link; package a regular file tree")
        if not file.is_file() or file.suffix.lower() in {".pdb", ".exp", ".lib"}:
            continue
        relative = file.relative_to(runner)
        if relative.as_posix().casefold() in expected:
            cli.error("Two runner files differ only by case")
        expected.add(relative.as_posix().casefold())
        path = Path(".")
        for part in relative.parts[:-1]:
            folder = folders[path.as_posix()]
            path /= part
            key = path.as_posix()
            if key not in folders:
                folders[key] = element(folder, "Directory", Id=identity("D", key), Name=part)
        key = relative.as_posix()
        comp_id = identity("C", key)
        comp = element(folders[path.as_posix()], "Component", Id=comp_id,
                       Guid=str(uuid.uuid5(UPGRADE, key.casefold())).upper(), Win64="yes")
        element(comp, "File", Id="RymuExe" if key == "Rymu.exe" else identity("F", key),
                Source=str(file), Name=file.name)
        element(comp, "RegistryValue", Root="HKCU", Key=r"Software\Rymu\Installer\Components",
                Name=comp_id, Value="1", Type="integer", KeyPath="yes")
        element(feature, "ComponentRef", Id=comp_id)

    start = element(target, "Directory", Id="ProgramMenuFolder")
    menu = element(start, "Directory", Id="RymuPrograms", Name="Rymu")
    shortcut = element(menu, "Component", Id="RymuShortcut",
                       Guid=str(uuid.uuid5(UPGRADE, "start-menu")).upper(), Win64="yes")
    element(shortcut, "Shortcut", Id="StartRymu", Name=display_name,
            Target="[#RymuExe]", WorkingDirectory="INSTALLFOLDER")
    element(shortcut, "RemoveFolder", Id="RemoveRymuPrograms", On="uninstall")
    # Windows Installer removes these directories only when empty. Listing them
    # explicitly handles per-user cleanup and satisfies ICE64 for nested assets.
    for relative, folder in reversed(list(folders.items())):
        element(shortcut, "RemoveFolder", Id=identity("RemoveDir", relative),
                Directory=folder.attrib["Id"], On="uninstall")
    element(shortcut, "RemoveFolder", Id="RemoveLocalProgramsIfEmpty",
            Directory="LocalPrograms", On="uninstall")
    element(shortcut, "RegistryValue", Root="HKCU", Key=r"Software\Rymu\Installer",
            Name="StartMenu", Type="integer", Value="1", KeyPath="yes")
    element(feature, "ComponentRef", Id="RymuShortcut")
    ET.indent(root)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(root).write(args.out, encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    main()
