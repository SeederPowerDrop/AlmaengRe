use crate::{Asset, Result};
use std::{
    collections::HashSet,
    fs::{self, File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::{Component, Path},
};
const MAX_ENTRIES: usize = 10_000;
const MAX_ENTRY_BYTES: u64 = 256 * 1024 * 1024;
const MAX_TOTAL_BYTES: u64 = 1024 * 1024 * 1024;
const MAX_RATIO: u64 = 1000;
fn safe_path(name: &str) -> bool {
    !name.is_empty()
        && !name.contains('\\')
        && !name.contains('\0')
        && !name.contains(':')
        && !Path::new(name).is_absolute()
        && Path::new(name)
            .components()
            .all(|c| matches!(c, Component::Normal(_)))
}
fn validate_size(size: u64, compressed: u64, total: u64) -> Result<u64> {
    let next = total.checked_add(size).ok_or("ZIP size overflow")?;
    if size > MAX_ENTRY_BYTES
        || next > MAX_TOTAL_BYTES
        || size > compressed.saturating_mul(MAX_RATIO).max(1024 * 1024)
    {
        return Err("ZIP decompression limit exceeded".into());
    }
    Ok(next)
}
// Inspect the bounded end records before the ZIP dependency allocates its directory.
// The entry-count limit must be enforced before ZipArchive::new, not only afterwards.
fn preflight(file: &mut File) -> Result<()> {
    let length = file.metadata().map_err(|e| e.to_string())?.len();
    if length > 2 * MAX_TOTAL_BYTES || length < 22 {
        return Err("ZIP file size exceeds safe limits".into());
    }
    let tail_size = length.min(65_557) as usize;
    file.seek(SeekFrom::End(-(tail_size as i64)))
        .map_err(|e| e.to_string())?;
    let mut tail = vec![0; tail_size];
    file.read_exact(&mut tail).map_err(|e| e.to_string())?;
    let offset = (0..=tail.len() - 22)
        .rev()
        .find(|&i| {
            tail[i..i + 4] == [0x50, 0x4b, 0x05, 0x06]
                && i + 22 + u16::from_le_bytes([tail[i + 20], tail[i + 21]]) as usize == tail.len()
        })
        .ok_or("Missing ZIP end record")?;
    let read16 = |i| u16::from_le_bytes([tail[offset + i], tail[offset + i + 1]]) as u64;
    let read32 =
        |i| u32::from_le_bytes(tail[offset + i..offset + i + 4].try_into().unwrap()) as u64;
    if read16(4) != 0 || read16(6) != 0 {
        return Err("Multi-disk ZIP is unsupported".into());
    }
    let mut count = read16(10);
    let mut directory_size = read32(12);
    let mut directory_offset = read32(16);
    let eocd_position = length - tail_size as u64 + offset as u64;
    let mut locator = [0; 20];
    if eocd_position >= 20 {
        file.seek(SeekFrom::Start(eocd_position - 20))
            .map_err(|e| e.to_string())?;
        file.read_exact(&mut locator).map_err(|e| e.to_string())?;
    }
    let has_zip64 = locator[..4] == [0x50, 0x4b, 0x06, 0x07];
    if !has_zip64
        && (count == 0xffff || directory_size == 0xffff_ffff || directory_offset == 0xffff_ffff)
    {
        return Err("Missing ZIP64 locator".into());
    }
    if has_zip64 {
        let position = u64::from_le_bytes(locator[8..16].try_into().unwrap());
        if position
            .checked_add(56)
            .is_none_or(|end| end > eocd_position)
        {
            return Err("Invalid ZIP64 offset".into());
        }
        file.seek(SeekFrom::Start(position))
            .map_err(|e| e.to_string())?;
        let mut record = [0; 56];
        file.read_exact(&mut record).map_err(|e| e.to_string())?;
        if record[..4] != [0x50, 0x4b, 0x06, 0x06] || record[16..24] != [0; 8] {
            return Err("Invalid ZIP64 end record".into());
        }
        count = u64::from_le_bytes(record[32..40].try_into().unwrap());
        directory_size = u64::from_le_bytes(record[40..48].try_into().unwrap());
        directory_offset = u64::from_le_bytes(record[48..56].try_into().unwrap());
    }
    if count > MAX_ENTRIES as u64
        || directory_size > 16 * 1024 * 1024
        || directory_offset
            .checked_add(directory_size)
            .is_none_or(|end| end > length)
    {
        return Err("ZIP directory exceeds safe limits".into());
    }
    file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
    Ok(())
}
pub fn extract(path: &str, destination: &str, extensions: &HashSet<String>) -> Result<Vec<Asset>> {
    let dest = Path::new(destination);
    if !dest.is_dir()
        || dest
            .symlink_metadata()
            .map_err(|e| e.to_string())?
            .file_type()
            .is_symlink()
        || fs::read_dir(dest)
            .map_err(|e| e.to_string())?
            .next()
            .is_some()
    {
        return Err("ZIP destination must be an empty private directory".into());
    }
    let mut file = File::open(path).map_err(|e| e.to_string())?;
    preflight(&mut file)?;
    let mut archive = zip::ZipArchive::new(file).map_err(|e| format!("Invalid ZIP: {e}"))?;
    if archive.len() > MAX_ENTRIES {
        return Err("ZIP contains too many entries".into());
    }
    let mut total = 0;
    let mut names = HashSet::new();
    let mut selected = Vec::new();
    // Validate every member before creating any file. Never trust a path from the archive.
    for i in 0..archive.len() {
        let entry = archive.by_index(i).map_err(|e| e.to_string())?;
        let name = entry.name().trim_end_matches('/');
        if !safe_path(name) || entry.enclosed_name().is_none() {
            return Err("Unsafe ZIP entry path".into());
        }
        if entry.unix_mode().is_some_and(|m| m & 0o170000 == 0o120000) {
            return Err("ZIP symbolic links are unsupported".into());
        }
        if !names.insert(name.to_owned()) {
            return Err("Duplicate ZIP entry path".into());
        }
        total = validate_size(entry.size(), entry.compressed_size(), total)?;
        if entry.is_dir()
            || name
                .split('/')
                .any(|p| p.starts_with('.') || p == "__MACOSX")
        {
            continue;
        }
        let ext = Path::new(name)
            .extension()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        if extensions.contains(&ext) {
            selected.push((i, name.to_owned(), ext));
        }
    }
    let mut assets = Vec::new();
    for (i, name, ext) in selected {
        let mut entry = archive.by_index(i).map_err(|e| e.to_string())?;
        let target = dest.join(format!("{i:08}.{ext}"));
        let mut output = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&target)
            .map_err(|e| e.to_string())?;
        let size = entry.size();
        let mut bytes = 0;
        let mut buffer = [0u8; 64 * 1024];
        loop {
            let n = entry.read(&mut buffer).map_err(|e| e.to_string())?;
            if n == 0 {
                break;
            }
            bytes += n as u64;
            if bytes > size || bytes > MAX_ENTRY_BYTES {
                return Err("ZIP expanded beyond declared size".into());
            }
            output.write_all(&buffer[..n]).map_err(|e| e.to_string())?;
        }
        if bytes != size {
            return Err("Truncated ZIP entry".into());
        }
        assets.push(Asset {
            path: target.to_string_lossy().into_owned(),
            name: Path::new(&name)
                .file_name()
                .unwrap()
                .to_string_lossy()
                .into_owned(),
            size: Some(size),
            modified: None,
            created: None,
            latitude: None,
            longitude: None,
            entry_path: Some(name),
            ..Default::default()
        });
    }
    assets.sort_by(|a, b| super::name_order(a, b));
    Ok(assets)
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;
    use zip::write::SimpleFileOptions;
    #[test]
    fn traversal_rejected() {
        for p in [
            "../x.jpg",
            "/x.jpg",
            "a/../../b.jpg",
            "C:/x.jpg",
            "a\\b.jpg",
        ] {
            assert!(!safe_path(p), "{p}");
        }
        assert!(safe_path("한글/사진.jpg"));
    }
    #[test]
    fn expansion_limits() {
        assert!(validate_size(MAX_ENTRY_BYTES + 1, MAX_ENTRY_BYTES, 0).is_err());
        assert!(validate_size(2 * 1024 * 1024, 1, 0).is_err());
        assert!(validate_size(1, 1, MAX_TOTAL_BYTES).is_err());
    }
    fn temp() -> std::path::PathBuf {
        let p = std::env::temp_dir().join(format!(
            "almeng-zip-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir(&p).unwrap();
        p
    }
    #[test]
    fn valid_zip_and_corruption() {
        let dir = temp();
        let dest = dir.join("out");
        fs::create_dir(&dest).unwrap();
        let input = dir.join("test.zip");
        let mut z = zip::ZipWriter::new(Cursor::new(Vec::new()));
        z.start_file("album/test.jpg", SimpleFileOptions::default())
            .unwrap();
        z.write_all(b"picture").unwrap();
        fs::write(&input, z.finish().unwrap().into_inner()).unwrap();
        let r = extract(
            input.to_str().unwrap(),
            dest.to_str().unwrap(),
            &HashSet::from(["jpg".into()]),
        )
        .unwrap();
        assert_eq!(r[0].entry_path.as_deref(), Some("album/test.jpg"));
        assert_eq!(fs::read(&r[0].path).unwrap(), b"picture");
        fs::remove_dir_all(&dest).unwrap();
        fs::create_dir(&dest).unwrap();
        fs::write(&input, b"bad zip").unwrap();
        assert!(
            extract(
                input.to_str().unwrap(),
                dest.to_str().unwrap(),
                &HashSet::new()
            )
            .is_err()
        );
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn central_directory_allocation_is_bounded() {
        let dir = temp();
        let path = dir.join("bomb.zip");
        let mut bytes = vec![0u8; 22];
        bytes[..4].copy_from_slice(&[0x50, 0x4b, 0x05, 0x06]);
        bytes[10..12].copy_from_slice(&10_001u16.to_le_bytes());
        fs::write(&path, bytes).unwrap();
        assert!(preflight(&mut File::open(&path).unwrap()).is_err());
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn malicious_zip_cannot_escape() {
        let dir = temp();
        let dest = dir.join("out");
        fs::create_dir(&dest).unwrap();
        let input = dir.join("test.zip");
        let mut z = zip::ZipWriter::new(Cursor::new(Vec::new()));
        z.start_file("../escape.jpg", SimpleFileOptions::default())
            .unwrap();
        z.write_all(b"bad").unwrap();
        fs::write(&input, z.finish().unwrap().into_inner()).unwrap();
        assert!(
            extract(
                input.to_str().unwrap(),
                dest.to_str().unwrap(),
                &HashSet::from(["jpg".into()])
            )
            .is_err()
        );
        assert!(!dir.join("escape.jpg").exists());
        fs::remove_dir_all(dir).unwrap();
    }
}
