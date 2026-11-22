use std::{
    collections::HashSet,
    env, fs,
    io::{self, Write},
    os::unix::{ffi::OsStrExt, fs::MetadataExt},
    path::{Path, PathBuf},
};

fn measure(path: &Path, device: u64) -> (u64, bool) {
    let mut pending = vec![path.to_owned()];
    let mut seen = HashSet::new();
    let mut bytes = 0;
    let mut partial = false;
    while let Some(item) = pending.pop() {
        let Ok(meta) = fs::symlink_metadata(&item) else {
            partial = true;
            continue;
        };
        if meta.dev() != device {
            partial = true;
            continue;
        }
        if meta.nlink() > 1 && !seen.insert(meta.ino()) {
            continue;
        }
        bytes += meta.blocks() * 512;
        if meta.is_dir() {
            match fs::read_dir(item) {
                Ok(entries) => {
                    for entry in entries {
                        match entry {
                            Ok(child) => pending.push(child.path()),
                            Err(_) => partial = true,
                        }
                    }
                }
                Err(_) => partial = true,
            }
        }
    }
    (bytes, partial)
}

fn installer(path: &Path) -> bool {
    path.extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| {
            ["dmg", "pkg", "mpkg", "xip", "iso"]
                .iter()
                .any(|kind| ext.eq_ignore_ascii_case(kind))
        })
}

fn related_paths(library: &Path, id: &str) -> io::Result<Vec<PathBuf>> {
    if !id.contains('.')
        || !id.split('.').all(|part| {
            !part.is_empty() && part.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
        })
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Invalid bundle identifier",
        ));
    }
    let mut paths = Vec::new();
    if fs::symlink_metadata(library)?.is_symlink() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Library is a symbolic link",
        ));
    }
    for dir in ["Caches", "Logs", "Preferences"] {
        let parent = library.join(dir);
        let path = parent.join(if dir == "Preferences" {
            format!("{id}.plist")
        } else {
            id.to_owned()
        });
        for candidate in [&parent, &path] {
            match fs::symlink_metadata(candidate) {
                Ok(meta) if meta.is_symlink() => break,
                Ok(_) if candidate == &path => paths.push(path.clone()),
                Ok(_) => (),
                Err(err) if err.kind() == io::ErrorKind::NotFound => break,
                Err(err) => return Err(err),
            }
        }
    }
    Ok(paths)
}

fn record(out: &mut impl Write, path: &Path, label: &Path, device: u64) -> io::Result<()> {
    let (bytes, partial) = measure(path, device);
    write!(out, "{}\t{}\t", bytes, u8::from(partial))?;
    out.write_all(label.as_os_str().as_bytes())?;
    out.write_all(&[0])
}

fn main() -> io::Result<()> {
    let mut args = env::args_os().skip(1);
    let root = PathBuf::from(args.next().ok_or(io::ErrorKind::InvalidInput)?);
    let mode = args.next();
    let device = fs::metadata(&root)?.dev();
    let mut out = io::BufWriter::new(io::stdout().lock());
    match mode.as_deref().and_then(|v| v.to_str()) {
        Some("uninstall") => {
            let id = args
                .next()
                .and_then(|v| v.into_string().ok())
                .ok_or(io::ErrorKind::InvalidInput)?;
            if root
                .extension()
                .is_none_or(|ext| !ext.eq_ignore_ascii_case("app"))
                || !fs::symlink_metadata(&root)?.is_dir()
            {
                return Err(io::ErrorKind::InvalidInput.into());
            }
            let library =
                PathBuf::from(env::var_os("HOME").ok_or(io::ErrorKind::NotFound)?).join("Library");
            for path in related_paths(&library, &id)?.into_iter().chain([root]) {
                record(&mut out, &path, &path, fs::symlink_metadata(&path)?.dev())?;
            }
        }
        None | Some("installers") => {
            for entry in fs::read_dir(root)? {
                let entry = entry?;
                let path = entry.path();
                if mode.is_some() && !(installer(&path) && entry.file_type()?.is_file()) {
                    continue;
                }
                record(&mut out, &path, Path::new(&entry.file_name()), device)?;
            }
        }
        _ => return Err(io::ErrorKind::InvalidInput.into()),
    }
    out.flush()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    #[test]
    fn installer_extensions_and_exact_app_matches() -> io::Result<()> {
        assert!(installer(Path::new("Image.DMG")));
        assert!(!installer(Path::new("backup.zip")));
        let lib = env::temp_dir().join(format!("siftmark-library-{}", std::process::id()));
        fs::create_dir_all(lib.join("Logs/com.example.App"))?;
        fs::create_dir_all(lib.join("Logs/com.example.AppBeta"))?;
        symlink(lib.join("Logs"), lib.join("Caches"))?;
        assert!(related_paths(&lib, "../escape").is_err());
        assert_eq!(
            related_paths(&lib, "com.example.App")?,
            vec![lib.join("Logs/com.example.App")]
        );
        fs::remove_dir_all(lib)
    }

    #[test]
    fn counts_allocated_blocks_once_and_does_not_follow_links() -> io::Result<()> {
        let dir = env::temp_dir().join(format!("siftmark-test-{}", std::process::id()));
        fs::create_dir(&dir)?;
        let file = dir.join("data");
        fs::write(&file, vec![7; 65536])?;
        fs::hard_link(&file, dir.join("copy"))?;
        let link = dir.join("loop");
        symlink(&dir, &link)?;
        let meta = fs::metadata(&dir)?;
        let expected = [
            meta.blocks(),
            fs::metadata(file)?.blocks(),
            fs::symlink_metadata(link)?.blocks(),
        ]
        .iter()
        .sum::<u64>()
            * 512;
        assert_eq!(measure(&dir, meta.dev()), (expected, false));
        fs::remove_dir_all(dir)
    }
}
