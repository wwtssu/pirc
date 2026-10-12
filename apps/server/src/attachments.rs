use base64::{engine::general_purpose::STANDARD, Engine};
use pirc_protocol::Message;
use std::{fs, io::Write, path::Path};

const LIMIT: u32 = 20 * 1024 * 1024;
const CHUNK: usize = 64 * 1024;

pub fn store(message: &Message) -> Result<Message, String> {
    store_at(
        &crate::state::directory()
            .map_err(|e| e.to_string())?
            .join("attachments"),
        message,
    )
}

fn store_at(root: &Path, message: &Message) -> Result<Message, String> {
    let Message::UploadFileChunk {
        instance_id,
        upload_id,
        name,
        offset,
        total,
        data,
        ..
    } = message
    else {
        return Err("Invalid file upload".into());
    };
    if uuid::Uuid::parse_str(instance_id).is_err()
        || uuid::Uuid::parse_str(upload_id).is_err()
        || name.is_empty()
        || name.len() > 255
        || name == "."
        || name == ".."
        || name
            .chars()
            .any(|c| c.is_control() || c == '/' || c == '\\')
        || *total > LIMIT
        || *offset > *total
        || data.len() > CHUNK
    {
        return Err("Invalid file upload".into());
    }
    let bytes = STANDARD.decode(data).map_err(|_| "Invalid file data")?;
    let end = offset
        .checked_add(bytes.len() as u32)
        .ok_or("Invalid file offset")?;
    if end > *total || (bytes.is_empty() && *total != 0) {
        return Err("Invalid file offset".into());
    }
    let directory = root.join(instance_id).join(upload_id);
    if *offset == 0 {
        fs::create_dir_all(directory.parent().unwrap()).map_err(|e| e.to_string())?;
        fs::create_dir(&directory).map_err(|e| e.to_string())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))
                .map_err(|e| e.to_string())?;
        }
        fs::write(
            directory.join("metadata.json"),
            serde_json::to_vec(&(name, total)).map_err(|e| e.to_string())?,
        )
        .map_err(|e| e.to_string())?;
    }
    let metadata: (String, u32) = serde_json::from_slice(
        &fs::read(directory.join("metadata.json")).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    if metadata != (name.clone(), *total) {
        return Err("File upload metadata changed".into());
    }
    let part = directory.join("upload.part");
    let mut options = fs::OpenOptions::new();
    options.write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    if *offset == 0 {
        options.create_new(true);
    } else {
        options.append(true);
    }
    let mut file = options.open(&part).map_err(|e| e.to_string())?;
    if file.metadata().map_err(|e| e.to_string())?.len() != u64::from(*offset) {
        return Err("File upload is out of order".into());
    }
    file.write_all(&bytes).map_err(|e| e.to_string())?;
    let path = if end == *total {
        file.sync_all().map_err(|e| e.to_string())?;
        drop(file);
        let files = directory.join("files");
        fs::create_dir(&files).map_err(|e| e.to_string())?;
        let path = files.join(name);
        fs::rename(&part, &path).map_err(|e| e.to_string())?;
        Some(path.to_string_lossy().into_owned())
    } else {
        None
    };
    Ok(Message::FileChunkStored { offset: end, path })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn chunked_upload_preserves_bytes_and_rejects_invalid_paths_and_offsets() {
        let root = std::env::temp_dir().join(format!("pirc-files-{}", uuid::Uuid::new_v4()));
        let instance_id = uuid::Uuid::new_v4().to_string();
        let upload_id = uuid::Uuid::new_v4().to_string();
        let chunk = |name: &str, offset, data: &[u8]| Message::UploadFileChunk {
            generation_id: "g".into(),
            session_id: "s".into(),
            instance_id: instance_id.clone(),
            upload_id: upload_id.clone(),
            name: name.into(),
            offset,
            total: 6,
            data: STANDARD.encode(data),
        };
        assert!(store_at(&root, &chunk("../secret", 0, b"abc")).is_err());
        assert_eq!(
            store_at(&root, &chunk("notes.txt", 0, b"abc")).unwrap(),
            Message::FileChunkStored {
                offset: 3,
                path: None
            }
        );
        assert!(store_at(&root, &chunk("notes.txt", 1, b"def")).is_err());
        assert!(store_at(&root, &chunk("other.txt", 3, b"def")).is_err());
        let Message::FileChunkStored {
            path: Some(path), ..
        } = store_at(&root, &chunk("notes.txt", 3, b"def")).unwrap()
        else {
            panic!()
        };
        assert_eq!(fs::read(path).unwrap(), b"abcdef");
        assert!(store_at(&root, &chunk("notes.txt", 0, b"abc")).is_err());
        fs::remove_dir_all(root).unwrap();
    }
}
