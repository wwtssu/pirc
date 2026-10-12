use std::{fs, io};
use uuid::Uuid;

pub fn load() -> io::Result<String> {
    load_at(&crate::state::directory()?.join("server-id"))
}
fn load_at(path: &std::path::Path) -> io::Result<String> {
    use io::Write;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    match fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
    {
        Ok(mut file) => {
            let id = Uuid::new_v4().to_string();
            file.write_all(id.as_bytes())?;
            file.sync_all()?;
            Ok(id)
        }
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
            let id = fs::read_to_string(path)?.trim().to_owned();
            Uuid::parse_str(&id).map_err(|_| io::Error::other("Invalid server identity file"))?;
            Ok(id)
        }
        Err(e) => Err(e),
    }
}
#[cfg(test)]
mod tests {
    #[test]
    fn identity_survives_restarts_and_invalid_identity_is_not_replaced() {
        let path = std::env::temp_dir().join(format!("pirc-id-{}", uuid::Uuid::new_v4()));
        let id = super::load_at(&path).unwrap();
        assert_eq!(super::load_at(&path).unwrap(), id);
        std::fs::write(&path, "broken").unwrap();
        assert!(super::load_at(&path).is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "broken");
        std::fs::remove_file(path).unwrap();
    }
}
