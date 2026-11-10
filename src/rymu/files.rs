use hbb_common::{
    anyhow::{bail, Context},
    ResultType,
};
use std::path::{Path, PathBuf};

#[cfg(target_os = "windows")]
mod windows;

#[cfg(target_os = "windows")]
pub(crate) use windows::{ensure_user_access, read_directory, transfer_path, transfer_write_path};

pub(crate) const LOCATIONS_QUERY: &str = "rymu:windows-locations:v1";

pub(crate) fn safe_file_name(name: &str) -> bool {
    if name.is_empty()
        || name == "."
        || name == ".."
        || name.ends_with(['.', ' '])
        || name.encode_utf16().count() > 255
        || name
            .chars()
            .any(|c| c.is_control() || "<>:\"/\\|?*".contains(c))
    {
        return false;
    }
    let stem = name
        .split('.')
        .next()
        .unwrap_or_default()
        .trim_end()
        .to_uppercase();
    !matches!(
        stem.as_str(),
        "CON" | "NUL" | "AUX" | "PRN" | "CONIN$" | "CONOUT$"
    ) && !["COM", "LPT"].iter().any(|prefix| {
        stem.strip_prefix(*prefix)
            .is_some_and(|suffix| suffix.chars().count() == 1 && "0123456789¹²³".contains(suffix))
    })
}

#[cfg(not(target_os = "windows"))]
pub(crate) fn transfer_path(_: &str, _: bool) -> ResultType<PathBuf> {
    bail!("Rymu file hosting requires Windows");
}

#[cfg(not(target_os = "windows"))]
pub(crate) fn transfer_write_path(path: &str) -> ResultType<PathBuf> {
    transfer_path(path, false)
}

pub(crate) fn transfer_child(parent: &Path, name: &str) -> ResultType<PathBuf> {
    let parts: Vec<_> = name.split(['/', '\\']).collect();
    if parts.len() > 32 || !parts.iter().all(|part| safe_file_name(part)) {
        bail!("Invalid transfer name");
    }
    let mut path = parent.to_path_buf();
    for part in parts {
        path.push(part);
    }
    transfer_write_path(path.to_str().context("Invalid transfer path")?)
}

pub(crate) fn upload_destination<'a>(
    input: &str,
    names: impl ExactSizeIterator<Item = &'a str>,
) -> ResultType<PathBuf> {
    let count = names.len();
    if !(1..=4096).contains(&count) {
        bail!("Invalid transfer file count");
    }
    let path = transfer_write_path(input)?;
    let mut targets = std::collections::HashSet::new();
    for name in names {
        let resolved = if name.is_empty() && count == 1 {
            path.clone()
        } else {
            transfer_child(&path, name)?
        };
        let target = resolved.to_str().context("Invalid transfer path")?;
        let missing = |path: &Path| matches!(std::fs::symlink_metadata(path), Err(error) if error.kind() == std::io::ErrorKind::NotFound);
        if !missing(&resolved) || !targets.insert(target.to_lowercase()) {
            bail!("Choose a new file name for this upload");
        }
        for suffix in [".download", ".digest"] {
            let helper = transfer_write_path(&format!("{target}{suffix}"))?;
            if !missing(&helper) || !targets.insert(helper.to_string_lossy().to_lowercase()) {
                bail!("The upload destination is already in use");
            }
        }
    }
    Ok(path)
}

pub(crate) fn validate_read_tree(path: &Path) -> ResultType<()> {
    let mut pending = vec![path.to_path_buf()];
    let mut inspected = 0;
    while let Some(node) = pending.pop() {
        if inspected == 4096 {
            bail!("Transfer selection contains too many entries");
        }
        inspected += 1;
        transfer_path(node.to_str().context("Invalid transfer path")?, false)?;
        if std::fs::symlink_metadata(&node)?.is_dir() {
            for entry in std::fs::read_dir(&node)? {
                pending.push(entry?.path());
                if pending.len() + inspected > 4096 {
                    bail!("Transfer selection contains too many entries");
                }
            }
        }
    }
    Ok(())
}
