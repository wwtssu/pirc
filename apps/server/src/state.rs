use std::{io, path::PathBuf};

pub fn directory() -> io::Result<PathBuf> {
    let home = std::env::var_os("HOME").ok_or_else(|| io::Error::other("HOME is missing"))?;
    Ok(PathBuf::from(home).join(".pirc"))
}
