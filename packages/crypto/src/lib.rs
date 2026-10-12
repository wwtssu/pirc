//! Versioned Noise channel. No application data is sent before peer-key trust.
use sha2::{Digest, Sha256};
use snow::{Builder, HandshakeState, TransportState};
use zeroize::Zeroizing;

pub const SUBPROTOCOL: &str = "pirc.noise.v1";
const PATTERN: &str = "Noise_XX_25519_ChaChaPoly_SHA256";
const PROLOGUE: &[u8] = b"Pirc encrypted control channel v1";
pub const MAX_RECORD: usize = 1024 * 1024;
const CHUNK: usize = 60000;

pub fn generate_key() -> Result<String, String> {
    let key = Builder::new(PATTERN.parse().unwrap())
        .generate_keypair()
        .map_err(|_| "Unable to generate encryption keys")?;
    let secret = Zeroizing::new(key.private);
    Ok(hex::encode(&*secret))
}
pub fn public_key(secret: &str) -> Result<String, String> {
    let secret = decode_key(secret)?;
    let secret = x25519_dalek::StaticSecret::from(*secret);
    Ok(hex::encode(
        x25519_dalek::PublicKey::from(&secret).as_bytes(),
    ))
}
fn decode_key(encoded: &str) -> Result<Zeroizing<[u8; 32]>, String> {
    let mut bytes = Zeroizing::new([0u8; 32]);
    hex::decode_to_slice(encoded, &mut *bytes).map_err(|_| "Invalid encryption key")?;
    Ok(bytes)
}
pub fn fingerprint(public: &str) -> Result<String, String> {
    let bytes = decode_key(public)?;
    let digest = hex::encode(Sha256::digest(*bytes)).to_uppercase();
    Ok(digest
        .as_bytes()
        .chunks(8)
        .map(|c| std::str::from_utf8(c).unwrap())
        .collect::<Vec<_>>()
        .join(" "))
}
/// Short authentication string bound to both identities and this fresh handshake.
pub fn pairing_code(handshake_hash: &[u8]) -> String {
    const ALPHABET: &[u8; 32] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let mut hash = Sha256::new();
    hash.update(b"PiRC server approval v1\0");
    hash.update(handshake_hash);
    let digest = hash.finalize();
    let mut bits = 0u64;
    for byte in &digest[..5] {
        bits = (bits << 8) | u64::from(*byte);
    }
    let code: String = (0..8)
        .rev()
        .map(|i| ALPHABET[((bits >> (i * 5)) & 31) as usize] as char)
        .collect();
    format!("{}-{}", &code[..4], &code[4..])
}
pub fn handshake(secret: &str, initiator: bool) -> Result<HandshakeState, String> {
    let secret = decode_key(secret)?;
    let builder = Builder::new(PATTERN.parse().unwrap())
        .prologue(PROLOGUE)
        .map_err(|_| "Unable to initialize the encrypted handshake")?
        .local_private_key(&*secret)
        .map_err(|_| "Invalid encryption key")?;
    if initiator {
        builder.build_initiator()
    } else {
        builder.build_responder()
    }
    .map_err(|_| "Unable to initialize the encrypted handshake".into())
}
pub struct Channel(TransportState);
impl Channel {
    pub fn new(handshake: HandshakeState) -> Result<Self, String> {
        handshake
            .into_transport_mode()
            .map(Self)
            .map_err(|_| "Encrypted handshake is incomplete".into())
    }
    pub fn encrypt(&mut self, text: &str) -> Result<Vec<u8>, String> {
        if text.len() > MAX_RECORD {
            return Err("Message is too large".into());
        }
        let mut plain = Vec::with_capacity(text.len() + 4);
        plain.extend_from_slice(&(text.len() as u32).to_be_bytes());
        plain.extend_from_slice(text.as_bytes());
        let mut record = Vec::new();
        for chunk in plain.chunks(CHUNK) {
            let mut encrypted = vec![0; chunk.len() + 16];
            let n = self
                .0
                .write_message(chunk, &mut encrypted)
                .map_err(|_| "Unable to encrypt message")?;
            record.extend_from_slice(&(n as u16).to_be_bytes());
            record.extend_from_slice(&encrypted[..n]);
        }
        Ok(record)
    }
    pub fn decrypt(&mut self, mut record: &[u8]) -> Result<String, String> {
        if record.len() > MAX_RECORD + 1024 {
            return Err("Encrypted message is too large".into());
        }
        let mut plain = Vec::new();
        while !record.is_empty() {
            if record.len() < 2 {
                return Err("Encrypted message is incomplete".into());
            }
            let n = u16::from_be_bytes([record[0], record[1]]) as usize;
            record = &record[2..];
            if !(16..=CHUNK + 16).contains(&n) || n > record.len() {
                return Err("Invalid encrypted message".into());
            }
            let mut chunk = vec![0; n];
            let size = self
                .0
                .read_message(&record[..n], &mut chunk)
                .map_err(|_| "Encryption verification failed. Connection stopped.".to_string())?;
            plain.extend_from_slice(&chunk[..size]);
            if plain.len() > MAX_RECORD + 4 {
                return Err("Encrypted message is too large".into());
            }
            record = &record[n..];
        }
        if plain.len() < 4
            || u32::from_be_bytes(plain[..4].try_into().unwrap()) as usize != plain.len() - 4
        {
            return Err("Encrypted message is incomplete".into());
        }
        String::from_utf8(plain.split_off(4))
            .map_err(|_| "Invalid encrypted message encoding".into())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn channels() -> (Channel, Channel) {
        let a = generate_key().unwrap();
        let b = generate_key().unwrap();
        let mut a = handshake(&a, true).unwrap();
        let mut b = handshake(&b, false).unwrap();
        let mut wire = vec![0; 65535];
        let mut out = vec![0; 65535];
        let n = a.write_message(&[], &mut wire).unwrap();
        b.read_message(&wire[..n], &mut out).unwrap();
        let n = b.write_message(b"server-id", &mut wire).unwrap();
        a.read_message(&wire[..n], &mut out).unwrap();
        let n = a.write_message(&[], &mut wire).unwrap();
        b.read_message(&wire[..n], &mut out).unwrap();
        (Channel::new(a).unwrap(), Channel::new(b).unwrap())
    }
    #[test]
    fn large_records_are_confidential_and_bidirectional() {
        let (mut a, mut b) = channels();
        let text = "Unicode streaming reply".repeat(40000);
        let encrypted = a.encrypt(&text).unwrap();
        assert!(!encrypted.windows(6).any(|w| w == "Unicode".as_bytes()));
        assert_eq!(b.decrypt(&encrypted).unwrap(), text);
        assert_eq!(a.decrypt(&b.encrypt("answer").unwrap()).unwrap(), "answer");
    }
    #[test]
    fn tamper_replay_truncation_and_wrong_session_are_rejected() {
        let (mut a, mut b) = channels();
        let wire = a.encrypt("secret").unwrap();
        assert_eq!(b.decrypt(&wire).unwrap(), "secret");
        assert!(b.decrypt(&wire).is_err());
        let (mut a, mut b) = channels();
        let mut wire = a.encrypt("secret").unwrap();
        wire[3] ^= 1;
        assert!(b.decrypt(&wire).is_err());
        let (mut a, mut b) = channels();
        let mut wire = a.encrypt(&"x".repeat(100000)).unwrap();
        wire.truncate(60018);
        assert!(b.decrypt(&wire).is_err());
        let (_, mut other) = channels();
        assert!(other.decrypt(&a.encrypt("secret").unwrap()).is_err());
    }
}
