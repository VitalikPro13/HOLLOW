use std::sync::Mutex;
use std::sync::OnceLock;

use aes_gcm::aead::Aead;
use aes_gcm::{Aes256Gcm, KeyInit, Nonce};

const MAGIC: &[u8; 6] = b"HKEYV1";
const PROTOBUF_HEADER: [u8; 4] = [0x08, 0x01, 0x12, 0x40];

const FLAG_PASSWORD: u8 = 0x01;
const FLAG_OS_KEYCHAIN: u8 = 0x02;

static SESSION_KEY: OnceLock<Mutex<Option<[u8; 32]>>> = OnceLock::new();

fn session_key_lock() -> &'static Mutex<Option<[u8; 32]>> {
    SESSION_KEY.get_or_init(|| Mutex::new(None))
}

pub(crate) fn set_session_key(key: [u8; 32]) {
    let lock = session_key_lock();
    let mut guard = lock.lock().unwrap();
    *guard = Some(key);
}

pub(crate) fn get_session_key() -> Option<[u8; 32]> {
    let lock = session_key_lock();
    let guard = lock.lock().unwrap();
    *guard
}

pub(crate) fn clear_session_key() {
    let lock = session_key_lock();
    let mut guard = lock.lock().unwrap();
    if let Some(ref mut key) = *guard {
        key.fill(0);
    }
    *guard = None;
}

#[derive(Debug, PartialEq)]
pub(crate) enum IdentityFormat {
    Plaintext,
    Encrypted {
        flags: u8,
        salt: [u8; 16],
        nonce: [u8; 12],
        ciphertext: Vec<u8>,
    },
}

pub(crate) fn detect_format(bytes: &[u8]) -> Result<IdentityFormat, String> {
    if bytes.len() >= 68 && bytes[..4] == PROTOBUF_HEADER {
        return Ok(IdentityFormat::Plaintext);
    }

    if bytes.len() >= 6 && bytes[..6] == *MAGIC {
        if bytes.len() < 6 + 1 + 16 + 12 + 16 {
            return Err("Encrypted identity file is too short".into());
        }
        let flags = bytes[6];
        let mut salt = [0u8; 16];
        salt.copy_from_slice(&bytes[7..23]);
        let mut nonce = [0u8; 12];
        nonce.copy_from_slice(&bytes[23..35]);
        let ciphertext = bytes[35..].to_vec();
        return Ok(IdentityFormat::Encrypted {
            flags,
            salt,
            nonce,
            ciphertext,
        });
    }

    Err("Unrecognized identity file format".into())
}

pub(crate) fn flags_has_password(flags: u8) -> bool {
    flags & FLAG_PASSWORD != 0
}

pub(crate) fn flags_has_os_keychain(flags: u8) -> bool {
    flags & FLAG_OS_KEYCHAIN != 0
}

/// Argon2id derivations run since the counter was last read. The duress design
/// stands on "both slots, every time", and that is a property of the COUNT, not of
/// any output a test could inspect.
#[cfg(test)]
static DERIVE_COUNT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

#[cfg(test)]
pub(crate) fn take_derive_count() -> u32 {
    DERIVE_COUNT.swap(0, std::sync::atomic::Ordering::SeqCst)
}

pub(crate) fn derive_wrapping_key_from_password(
    password: &str,
    salt: &[u8; 16],
) -> Result<[u8; 32], String> {
    #[cfg(test)]
    DERIVE_COUNT.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    let params = argon2::Params::new(65536, 3, 1, Some(32))
        .map_err(|e| format!("Argon2 params error: {e}"))?;
    let argon = argon2::Argon2::new(argon2::Algorithm::Argon2id, argon2::Version::V0x13, params);
    let mut key = [0u8; 32];
    argon
        .hash_password_into(password.as_bytes(), salt, &mut key)
        .map_err(|e| format!("Argon2 hash error: {e}"))?;
    Ok(key)
}

pub(crate) fn encrypt_identity(
    plaintext: &[u8],
    wrapping_key: &[u8; 32],
    salt: &[u8; 16],
    password_used: bool,
    os_keychain_used: bool,
) -> Result<Vec<u8>, String> {
    let mut flags: u8 = 0;
    if password_used {
        flags |= FLAG_PASSWORD;
    }
    if os_keychain_used {
        flags |= FLAG_OS_KEYCHAIN;
    }

    let mut nonce_bytes = [0u8; 12];
    getrandom::fill(&mut nonce_bytes).map_err(|e| format!("RNG error: {e}"))?;

    let cipher =
        Aes256Gcm::new_from_slice(wrapping_key).map_err(|e| format!("Cipher init error: {e}"))?;
    let nonce = Nonce::from_slice(&nonce_bytes);
    let ciphertext = cipher
        .encrypt(nonce, plaintext)
        .map_err(|_| "Identity encryption failed".to_string())?;

    let mut output = Vec::with_capacity(6 + 1 + 16 + 12 + ciphertext.len());
    output.extend_from_slice(MAGIC);
    output.push(flags);
    output.extend_from_slice(salt);
    output.extend_from_slice(&nonce_bytes);
    output.extend_from_slice(&ciphertext);
    Ok(output)
}

/// Open an HKEYV1 blob WITHOUT the keypair-shape check. The duress slot's
/// plaintext is a tagged marker, not a keypair, and it shares this layout so the
/// two files are indistinguishable on disk.
pub(crate) fn decrypt_blob(
    encrypted: &[u8],
    wrapping_key: &[u8; 32],
) -> Result<Vec<u8>, String> {
    let format = detect_format(encrypted)?;
    let (nonce_bytes, ciphertext) = match format {
        IdentityFormat::Encrypted {
            nonce, ciphertext, ..
        } => (nonce, ciphertext),
        IdentityFormat::Plaintext => {
            return Err("File is not encrypted".into());
        }
    };

    let cipher =
        Aes256Gcm::new_from_slice(wrapping_key).map_err(|e| format!("Cipher init error: {e}"))?;
    let nonce = Nonce::from_slice(&nonce_bytes);
    cipher
        .decrypt(nonce, ciphertext.as_slice())
        .map_err(|_| "Wrong password or corrupted identity file".to_string())
}

pub(crate) fn decrypt_identity(
    encrypted: &[u8],
    wrapping_key: &[u8; 32],
) -> Result<Vec<u8>, String> {
    let plaintext = decrypt_blob(encrypted, wrapping_key)?;

    if plaintext.len() < 68 || plaintext[..4] != PROTOBUF_HEADER {
        return Err("Decrypted data is not a valid identity keypair".into());
    }

    Ok(plaintext)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dummy_keypair() -> Vec<u8> {
        let mut buf = vec![0x08, 0x01, 0x12, 0x40];
        buf.extend_from_slice(&[0xAA; 32]); // fake secret
        buf.extend_from_slice(&[0xBB; 32]); // fake public
        buf
    }

    #[test]
    fn detect_plaintext() {
        let kp = dummy_keypair();
        assert_eq!(detect_format(&kp).unwrap(), IdentityFormat::Plaintext);
    }

    #[test]
    fn round_trip_encrypt_decrypt() {
        let kp = dummy_keypair();
        let key = [0x42u8; 32];
        let salt = [0x01u8; 16];
        let encrypted = encrypt_identity(&kp, &key, &salt, true, false).unwrap();

        let format = detect_format(&encrypted).unwrap();
        assert!(matches!(format, IdentityFormat::Encrypted { flags, .. } if flags == FLAG_PASSWORD));

        let decrypted = decrypt_identity(&encrypted, &key).unwrap();
        assert_eq!(decrypted, kp);
    }

    #[test]
    fn wrong_key_fails() {
        let kp = dummy_keypair();
        let key = [0x42u8; 32];
        let wrong_key = [0x99u8; 32];
        let salt = [0x01u8; 16];
        let encrypted = encrypt_identity(&kp, &key, &salt, true, false).unwrap();
        assert!(decrypt_identity(&encrypted, &wrong_key).is_err());
    }

    #[test]
    fn flags_both() {
        let kp = dummy_keypair();
        let key = [0x42u8; 32];
        let salt = [0x01u8; 16];
        let encrypted = encrypt_identity(&kp, &key, &salt, true, true).unwrap();
        let format = detect_format(&encrypted).unwrap();
        match format {
            IdentityFormat::Encrypted { flags, .. } => {
                assert!(flags_has_password(flags));
                assert!(flags_has_os_keychain(flags));
            }
            _ => panic!("Expected encrypted"),
        }
    }

    #[test]
    fn session_key_lifecycle() {
        clear_session_key();
        assert!(get_session_key().is_none());
        set_session_key([0x42; 32]);
        assert_eq!(get_session_key().unwrap(), [0x42; 32]);
        clear_session_key();
        assert!(get_session_key().is_none());
    }

    #[test]
    fn corrupt_file_rejected() {
        assert!(detect_format(b"garbage").is_err());
        assert!(detect_format(&[]).is_err());
    }

    #[test]
    fn truncated_encrypted_rejected() {
        let mut buf = Vec::new();
        buf.extend_from_slice(MAGIC);
        buf.push(0x01);
        assert!(detect_format(&buf).is_err());
    }

    #[test]
    fn argon2_key_derivation_deterministic() {
        let salt = [0x55u8; 16];
        let k1 = derive_wrapping_key_from_password("test123", &salt).unwrap();
        let k2 = derive_wrapping_key_from_password("test123", &salt).unwrap();
        assert_eq!(k1, k2);

        let k3 = derive_wrapping_key_from_password("different", &salt).unwrap();
        assert_ne!(k1, k3);
    }
}
