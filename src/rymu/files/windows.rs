use super::{safe_file_name, LOCATIONS_QUERY};
use ::windows::{
    core::GUID,
    Win32::{
        Foundation::{HANDLE, RPC_E_CHANGED_MODE},
        Storage::FileSystem::{
            FileAttributeTagInfo, GetFileInformationByHandleEx, FILE_ATTRIBUTE_TAG_INFO,
        },
        System::Com::{CoInitializeEx, CoTaskMemFree, CoUninitialize, COINIT_MULTITHREADED},
        UI::Shell::{
            FOLDERID_CommonStartup, FOLDERID_Desktop, FOLDERID_Documents, FOLDERID_Downloads,
            FOLDERID_LocalAppData, FOLDERID_Music, FOLDERID_Pictures, FOLDERID_Profile,
            FOLDERID_ProgramData, FOLDERID_ProgramFiles, FOLDERID_ProgramFilesX86,
            FOLDERID_Startup, FOLDERID_Videos, FOLDERID_Windows, SHGetKnownFolderPath,
            KF_FLAG_DONT_VERIFY,
        },
    },
};
use base::message_proto::{FileDirectory, FileEntry, FileType};
use hbb_common::{
    anyhow::{bail, Context},
    config::Config,
    ResultType,
};
use serde::Serialize;
use std::{
    collections::BTreeMap,
    fs::{self, Metadata, OpenOptions},
    io::ErrorKind,
    os::windows::{
        fs::{MetadataExt, OpenOptionsExt},
        io::AsRawHandle,
    },
    path::{Component, Path, PathBuf, Prefix},
    ptr,
    sync::{Mutex, OnceLock},
    time::UNIX_EPOCH,
};
use winapi::{
    shared::winerror::NO_ERROR,
    um::{
        fileapi::{
            GetDriveTypeW, GetFileInformationByHandle, GetLogicalDrives, BY_HANDLE_FILE_INFORMATION,
        },
        winbase::{
            DRIVE_CDROM, DRIVE_FIXED, DRIVE_RAMDISK, DRIVE_REMOTE, DRIVE_REMOVABLE,
            FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
        },
        winnetwk::{
            WNetCloseEnum, WNetEnumResourceW, WNetGetConnectionW, WNetOpenEnumW, NETRESOURCEW,
            RESOURCETYPE_DISK, RESOURCE_REMEMBERED,
        },
        winnt::{
            FILE_ATTRIBUTE_HIDDEN, FILE_ATTRIBUTE_REPARSE_POINT, FILE_READ_ATTRIBUTES,
            IO_REPARSE_TAG_CLOUD,
        },
    },
};

const KNOWN: [(&str, GUID); 7] = [
    ("desktop", FOLDERID_Desktop),
    ("downloads", FOLDERID_Downloads),
    ("documents", FOLDERID_Documents),
    ("pictures", FOLDERID_Pictures),
    ("videos", FOLDERID_Videos),
    ("music", FOLDERID_Music),
    ("profile", FOLDERID_Profile),
];
const PROTECTED_WRITES: [GUID; 6] = [
    FOLDERID_Windows,
    FOLDERID_ProgramFiles,
    FOLDERID_ProgramFilesX86,
    FOLDERID_ProgramData,
    FOLDERID_Startup,
    FOLDERID_CommonStartup,
];

static SEEN_DRIVES: OnceLock<Mutex<BTreeMap<u8, &'static str>>> = OnceLock::new();
static USER_ACCESS: OnceLock<bool> = OnceLock::new();

#[derive(Serialize)]
struct Location {
    kind: &'static str,
    path: Option<String>,
    available: bool,
}

struct ComScope(bool);

impl ComScope {
    fn enter() -> ResultType<Self> {
        let status = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
        if status != RPC_E_CHANGED_MODE {
            status.ok()?;
        }
        Ok(Self(status.is_ok()))
    }
}

impl Drop for ComScope {
    fn drop(&mut self) {
        if self.0 {
            unsafe { CoUninitialize() };
        }
    }
}

fn known_folder(id: &GUID) -> Option<PathBuf> {
    let _com = ComScope::enter().ok()?;
    let value = unsafe { SHGetKnownFolderPath(id, KF_FLAG_DONT_VERIFY, None) }.ok()?;
    let path = unsafe { value.to_string() };
    unsafe { CoTaskMemFree(Some(value.0.cast())) };
    path.ok().map(PathBuf::from)
}

fn exchange_path() -> ResultType<PathBuf> {
    Ok(known_folder(&FOLDERID_LocalAppData)
        .context("No Windows user profile")?
        .join("Rymu")
        .join("Files"))
}

pub(crate) fn ensure_user_access() -> ResultType<()> {
    if !USER_ACCESS.get_or_init(|| {
        !crate::platform::is_root()
            && crate::platform::is_elevated(None).is_ok_and(|elevated| !elevated)
    }) {
        bail!("Open Rymu normally on the Windows host to use file transfer");
    }
    Ok(())
}

fn comparable(path: &Path) -> String {
    let value = path.to_string_lossy().replace('/', "\\");
    let normal = match value.strip_prefix(r"\\?\UNC\") {
        Some(unc) => format!(r"\\{unc}"),
        None => value.strip_prefix(r"\\?\").unwrap_or(&value).to_owned(),
    };
    normal.trim_end_matches('\\').to_lowercase()
}

fn within(root: &Path, path: &Path) -> bool {
    let root = comparable(root);
    let path = comparable(path);
    path == root
        || path
            .strip_prefix(&root)
            .is_some_and(|tail| tail.starts_with('\\'))
}

fn private_location(
    path: &Path,
    actual: &Path,
    config: &Path,
    actual_config: &Path,
    exchange: Option<&Path>,
) -> bool {
    [path, actual].into_iter().any(|candidate| {
        within(config, candidate)
            || within(actual_config, candidate)
            || exchange.is_some_and(|exchange| {
                exchange.parent().is_some_and(|app| within(app, candidate))
                    && !within(exchange, candidate)
            })
    })
}

fn drive_bit(letter: u8) -> u32 {
    1 << (letter.to_ascii_uppercase() - b'A')
}

fn parse_path(
    input: &str,
    logical_drives: u32,
    known_roots: impl FnOnce(&Path) -> bool,
) -> ResultType<PathBuf> {
    if input.len() > 4096
        || input
            .split(['/', '\\'])
            .any(|part| matches!(part, "." | ".."))
    {
        bail!("Invalid Rymu file path");
    }
    let path = Path::new(input);
    let mut components = path.components();
    let prefix = match components.next() {
        Some(Component::Prefix(prefix)) => prefix.kind(),
        _ => bail!("Choose an absolute Windows path"),
    };
    match prefix {
        Prefix::Disk(letter) if letter.is_ascii_alphabetic() => {
            if logical_drives & drive_bit(letter) == 0 {
                bail!("The Windows drive is unavailable");
            }
            if components.next() != Some(Component::RootDir) {
                bail!("Choose an absolute Windows path");
            }
        }
        Prefix::UNC(server, share)
            if server.to_str().is_some_and(safe_file_name)
                && share.to_str().is_some_and(safe_file_name)
                && known_roots(path) =>
        {
            if components.next() != Some(Component::RootDir) {
                bail!("Choose an absolute Windows path");
            }
        }
        _ => bail!("This location is outside the Rymu file scope"),
    }
    if !components.all(
        |part| matches!(part, Component::Normal(name) if name.to_str().is_some_and(safe_file_name)),
    ) {
        bail!("Invalid Rymu file path");
    }
    Ok(path.to_path_buf())
}

fn known_redirected_root(path: &Path) -> bool {
    KNOWN
        .iter()
        .any(|(_, id)| known_folder(id).is_some_and(|root| path.starts_with(root)))
        || exchange_path().is_ok_and(|root| path.starts_with(root))
}

fn cloud_tag(tag: u32) -> bool {
    // Windows Cloud Files tags 0 through F are data placeholders. Their name
    // surrogate bit is clear, unlike a junction, mount point or symbolic link.
    tag & !0x0000_f000 == IO_REPARSE_TAG_CLOUD
}

fn validate_metadata(path: &Path, metadata: &Metadata, check_hard_links: bool) -> ResultType<()> {
    let reparse = metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0;
    if !reparse && !(check_hard_links && metadata.is_file()) {
        return Ok(());
    }
    let file = OpenOptions::new()
        .access_mode(FILE_READ_ATTRIBUTES)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS)
        .open(path)?;
    let mut tag: FILE_ATTRIBUTE_TAG_INFO = unsafe { std::mem::zeroed() };
    if unsafe {
        GetFileInformationByHandleEx(
            HANDLE(file.as_raw_handle()),
            FileAttributeTagInfo,
            (&mut tag as *mut FILE_ATTRIBUTE_TAG_INFO).cast(),
            std::mem::size_of_val(&tag) as u32,
        )
    }
    .is_err()
        || (tag.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 && !cloud_tag(tag.ReparseTag))
    {
        bail!("Rymu cannot follow links or junctions");
    }
    if check_hard_links && metadata.is_file() {
        let mut info: BY_HANDLE_FILE_INFORMATION = unsafe { std::mem::zeroed() };
        if unsafe { GetFileInformationByHandle(file.as_raw_handle() as _, &mut info) } == 0
            || info.nNumberOfLinks != 1
        {
            bail!("Rymu cannot transfer linked files");
        }
    }
    Ok(())
}

fn validate_ancestors(path: &Path) -> ResultType<()> {
    let ancestors: Vec<_> = path.ancestors().filter(|node| node.has_root()).collect();
    // Inspect parents before any child, so even validation never looks through
    // an untrusted directory reparse point.
    for (index, node) in ancestors.into_iter().rev().enumerate() {
        match fs::symlink_metadata(node) {
            Ok(meta) => {
                validate_metadata(node, &meta, true)?;
                if node != path && !meta.is_dir() {
                    bail!("A parent of the Windows file is unavailable");
                }
            }
            Err(err) if index > 0 && err.kind() == ErrorKind::NotFound => break,
            Err(err) => return Err(err.into()),
        }
    }
    Ok(())
}

fn checked_path(input: &str) -> ResultType<PathBuf> {
    let path = parse_path(input, unsafe { GetLogicalDrives() }, known_redirected_root)?;
    let config = Config::path("");
    if !config.is_absolute() {
        bail!("Could not resolve the native Windows configuration");
    }
    validate_ancestors(&path)?;
    let actual = canonical_parent(&path)?;
    let actual_config = canonical_parent(&config)?;
    let exchange = exchange_path().ok();
    if private_location(&path, &actual, &config, &actual_config, exchange.as_deref()) {
        bail!("Rymu's account and native configuration data are private");
    }
    Ok(path)
}

fn exchange_folder() -> ResultType<PathBuf> {
    let root = exchange_path()?;
    let root = checked_path(root.to_str().context("Invalid exchange folder")?)?;
    fs::create_dir_all(&root)?;
    Ok(root)
}

pub(crate) fn transfer_path(input: &str, empty_is_root: bool) -> ResultType<PathBuf> {
    if input.is_empty() && empty_is_root {
        return exchange_folder().or_else(|_| {
            let profile = known_folder(&FOLDERID_Profile).context("No Windows user profile")?;
            checked_path(profile.to_str().context("Invalid Windows user profile")?)
        });
    }
    checked_path(input)
}

fn canonical_parent(path: &Path) -> ResultType<PathBuf> {
    for parent in path.ancestors().filter(|parent| parent.has_root()) {
        match fs::canonicalize(parent) {
            Ok(actual) => {
                return Ok(actual.join(path.strip_prefix(parent)?));
            }
            Err(err) if err.kind() == ErrorKind::NotFound => {}
            Err(err) => return Err(err.into()),
        }
    }
    bail!("The Windows drive is unavailable")
}

pub(crate) fn transfer_write_path(input: &str) -> ResultType<PathBuf> {
    let path = checked_path(input)?;
    if path.parent().is_none() {
        bail!("Choose a file or folder on the drive");
    }
    let canonical = canonical_parent(&path)?;
    let protected = PROTECTED_WRITES.iter().filter_map(known_folder);
    for root in protected.chain(
        std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(Path::to_owned)),
    ) {
        if within(&root, &path) || within(&root, &canonical) {
            bail!("Rymu cannot write to system, program or startup folders");
        }
    }
    Ok(path)
}

fn remembered_drive_letters() -> u32 {
    let mut handle = ptr::null_mut();
    if unsafe {
        WNetOpenEnumW(
            RESOURCE_REMEMBERED,
            RESOURCETYPE_DISK,
            0,
            ptr::null_mut(),
            &mut handle,
        )
    } != NO_ERROR
    {
        return 0;
    }
    let mut mask = 0;
    // NETRESOURCEW structures require pointer alignment. 26 local drive
    // letters bound the useful result and the loop remains bounded on errors.
    let mut storage = vec![0usize; 8192];
    for _ in 0..26 {
        let mut count = u32::MAX;
        let mut bytes = (storage.len() * std::mem::size_of::<usize>()) as u32;
        let status = unsafe {
            WNetEnumResourceW(handle, &mut count, storage.as_mut_ptr().cast(), &mut bytes)
        };
        if status != NO_ERROR
            || count as usize
                > storage.len() * std::mem::size_of::<usize>() / std::mem::size_of::<NETRESOURCEW>()
        {
            break;
        }
        let records = unsafe {
            std::slice::from_raw_parts(storage.as_ptr().cast::<NETRESOURCEW>(), count as usize)
        };
        for resource in records {
            if resource.lpLocalName.is_null() {
                continue;
            }
            let first = unsafe { *resource.lpLocalName };
            if first <= u8::MAX as u16 && (first as u8).is_ascii_alphabetic() {
                let suffix = unsafe { *resource.lpLocalName.add(1) };
                if suffix == u16::from(b':') {
                    mask |= drive_bit(first as u8);
                }
            }
        }
    }
    unsafe { WNetCloseEnum(handle) };
    mask
}

fn drive_kind(letter: u8) -> &'static str {
    let root = [u16::from(letter), u16::from(b':'), u16::from(b'\\'), 0];
    match unsafe { GetDriveTypeW(root.as_ptr()) } {
        DRIVE_REMOVABLE => "removable",
        DRIVE_FIXED => "local",
        DRIVE_REMOTE => "network",
        DRIVE_CDROM => "optical",
        DRIVE_RAMDISK => "ram",
        _ => "drive",
    }
}

fn mapped_drive_connected(letter: u8) -> bool {
    let drive = [u16::from(letter), u16::from(b':'), 0];
    let mut target = vec![0u16; 4096];
    let mut size = target.len() as u32;
    unsafe { WNetGetConnectionW(drive.as_ptr(), target.as_mut_ptr(), &mut size) == NO_ERROR }
}

fn drives() -> Vec<Location> {
    let logical = unsafe { GetLogicalDrives() };
    let remembered = remembered_drive_letters();
    let mut current = BTreeMap::new();
    for letter in b'A'..=b'Z' {
        let bit = drive_bit(letter);
        if (logical | remembered) & bit != 0 {
            let reported = if logical & bit != 0 {
                drive_kind(letter)
            } else {
                "drive"
            };
            let kind = if reported == "drive" && remembered & bit != 0 {
                "network"
            } else {
                reported
            };
            current.insert(letter, kind);
        }
    }
    let seen = {
        let mut seen = SEEN_DRIVES.get_or_init(Mutex::default).lock().unwrap();
        seen.extend(current);
        seen.clone()
    };
    seen.into_iter()
        .map(|(letter, kind)| {
            let path = format!("{}:\\", char::from(letter));
            let available = logical & drive_bit(letter) != 0
                && (kind != "network" || mapped_drive_connected(letter))
                && fs::read_dir(&path).is_ok();
            Location {
                kind,
                path: Some(path),
                available,
            }
        })
        .collect()
}

fn available_folder(kind: &'static str, path: Option<PathBuf>) -> Location {
    let path = path.and_then(|path| path.into_os_string().into_string().ok());
    let available = path.as_deref().is_some_and(|path| {
        checked_path(path).is_ok_and(|resolved| fs::read_dir(resolved).is_ok())
    });
    Location {
        kind,
        path,
        available,
    }
}

pub(crate) fn read_directory(input: &str, include_hidden: bool) -> ResultType<FileDirectory> {
    ensure_user_access()?;
    if matches!(input, LOCATIONS_QUERY | "/") {
        let drives = drives();
        let entries = if input == LOCATIONS_QUERY {
            let mut locations: Vec<_> = KNOWN
                .iter()
                .map(|(key, id)| available_folder(key, known_folder(id)))
                .collect();
            locations.push(available_folder(
                "exchange",
                exchange_folder().ok().or_else(|| exchange_path().ok()),
            ));
            locations.extend(drives);
            vec![FileEntry {
                name: serde_json::to_string(&locations)?,
                ..Default::default()
            }]
        } else {
            drives
                .into_iter()
                .filter(|drive| drive.available)
                .filter_map(|drive| drive.path)
                .map(|path| FileEntry {
                    name: path.trim_end_matches('\\').to_owned(),
                    entry_type: FileType::DirDrive.into(),
                    ..Default::default()
                })
                .collect()
        };
        return Ok(FileDirectory {
            path: input.to_owned(),
            entries,
            ..Default::default()
        });
    }
    let path = transfer_path(input, true)?;
    let mut entries = Vec::new();
    for entry in fs::read_dir(&path)? {
        let entry = entry?;
        let Ok(name) = entry.file_name().into_string() else {
            continue;
        };
        if !safe_file_name(&name) {
            continue;
        }
        let Ok(meta) = fs::symlink_metadata(entry.path()) else {
            continue;
        };
        let is_hidden = meta.file_attributes() & FILE_ATTRIBUTE_HIDDEN != 0;
        if (is_hidden && !include_hidden) || validate_metadata(&entry.path(), &meta, false).is_err()
        {
            continue;
        }
        if entries.len() == 20_000 {
            bail!("This Windows folder has too many entries to list");
        }
        let is_dir = meta.is_dir();
        entries.push(FileEntry {
            name,
            entry_type: if is_dir {
                FileType::Dir
            } else {
                FileType::File
            }
            .into(),
            is_hidden,
            size: if is_dir { 0 } else { meta.len() },
            modified_time: meta
                .modified()
                .ok()
                .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
                .map_or(0, |duration| duration.as_secs()),
            ..Default::default()
        });
    }
    // Preserve the requested path for the controller's pending-read key. An
    // empty initial request returns the concrete exchange or profile path.
    let path = path
        .into_os_string()
        .into_string()
        .ok()
        .context("Invalid Rymu file path")?;
    Ok(FileDirectory {
        path,
        entries,
        ..Default::default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_scope_accepts_real_drive_roots_and_rejects_aliases() {
        let mask = drive_bit(b'C') | drive_bit(b'E');
        for allowed in [r"C:\", r"e:\Documents\تقرير.pdf", "C:/Users/me/Downloads"] {
            assert!(parse_path(allowed, mask, |_| false).is_ok(), "{allowed}");
        }
        for rejected in [
            "",
            "/",
            LOCATIONS_QUERY,
            r"C:file",
            r"D:\",
            r"C:\one\..\two",
            r"C:\one\.\two",
            r"C:\Users\NUL.txt",
            r"C:\file:stream",
            r"\\?\C:\Users",
            r"\\.\C:\Users",
            r"\\unknown\share\file",
        ] {
            assert!(parse_path(rejected, mask, |_| false).is_err(), "{rejected}");
        }
    }

    #[test]
    fn file_scope_accepts_only_known_unc_folder_descendants() {
        let root = Path::new(r"\\domain\share\My Desktop");
        let known = |candidate: &Path| candidate.starts_with(root);
        assert!(parse_path(r"\\domain\share\My Desktop\file.txt", 0, known).is_ok());
        assert!(parse_path(r"\\domain\share\My Desktop copy\file.txt", 0, known).is_err());
        assert!(parse_path(r"\\domain\share\My Desktop\..\file.txt", 0, known).is_err());
    }

    #[test]
    fn file_scope_protects_native_config_root_and_aliases_without_closing_exchange() {
        let config = Path::new(r"C:\Users\Test User\AppData\Roaming\Rymu\config");
        let canonical_config = Path::new(r"\\?\C:\Users\Test User\AppData\Roaming\Rymu\config");
        let exchange = Path::new(r"C:\Users\Test User\AppData\Local\Rymu\Files");
        let hidden = |path: &Path, actual: &Path| {
            private_location(path, actual, config, canonical_config, Some(exchange))
        };
        assert!(hidden(config, canonical_config));
        let identity = config.join("Rymu.toml");
        assert!(hidden(&identity, &canonical_config.join("Rymu.toml")));
        let transport = config.join("Rymu2.toml");
        assert!(hidden(&transport, &canonical_config.join("Rymu2.toml")));
        let short_alias = Path::new(r"C:\Users\TESTUS~1\AppData\Roaming\Rymu\config\Rymu.toml");
        assert!(hidden(short_alias, &canonical_config.join("Rymu.toml")));
        let vault = exchange.parent().unwrap().join(r"Control\account.dat");
        assert!(hidden(&vault, &vault));
        let shared = exchange.join("example.txt");
        assert!(!hidden(&shared, &shared));
        let adjacent = config.with_file_name("config-backup");
        assert!(!hidden(&adjacent, &adjacent));
        assert!(parse_path(
            r"C:\Users\Test User\AppData\Roaming\Rymu\config\..\config\Rymu.toml",
            drive_bit(b'C'),
            |_| false,
        )
        .is_err());
    }

    #[test]
    fn cloud_placeholders_do_not_admit_surrogate_reparse_tags() {
        assert!(cloud_tag(IO_REPARSE_TAG_CLOUD));
        assert!(cloud_tag(0x9000_f01a));
        for tag in [0xA000_0003, 0xA000_000C, 0x8000_0021, 0x0000_001a] {
            assert!(!cloud_tag(tag));
        }
    }
}
