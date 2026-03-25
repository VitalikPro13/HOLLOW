use std::fs;
use std::path::PathBuf;

use bip39::Mnemonic;
use libp2p::identity;

/// The result of identity generation/loading.
pub(crate) struct IdentityData {
    pub keypair: identity::Keypair,
    pub peer_id: String,
    pub mnemonic: Option<String>,
}

/// Get the Hollow data directory.
/// Checks HOLLOW_DATA_DIR env var first (for multi-instance testing),
/// then falls back to %APPDATA%/hollow on Windows.
pub fn data_dir() -> Result<PathBuf, String> {
    let dir = if let Ok(custom) = std::env::var("HOLLOW_DATA_DIR") {
        PathBuf::from(custom)
    } else {
        let base = dirs::data_dir().ok_or("Could not find app data directory")?;
        base.join("hollow")
    };
    fs::create_dir_all(&dir).map_err(|e| format!("Failed to create data dir: {e}"))?;
    Ok(dir)
}

/// Path to the stored identity keypair file.
fn keypair_path() -> Result<PathBuf, String> {
    Ok(data_dir()?.join("identity.key"))
}

/// Generate a brand new identity from a fresh BIP-39 mnemonic.
pub(crate) fn generate_new_identity() -> Result<IdentityData, String> {
    // Generate 24-word mnemonic (256 bits of entropy).
    let mut entropy = [0u8; 32];
    getrandom::fill(&mut entropy).map_err(|e| format!("RNG failed: {e}"))?;
    let mnemonic = Mnemonic::from_entropy(&entropy)
        .map_err(|e| format!("Mnemonic generation failed: {e}"))?;
    let mnemonic_phrase = mnemonic.to_string();

    let keypair = keypair_from_mnemonic(&mnemonic)?;
    let peer_id = keypair.public().to_peer_id().to_string();

    // Save the keypair to disk.
    save_keypair(&keypair)?;

    Ok(IdentityData {
        keypair,
        peer_id,
        mnemonic: Some(mnemonic_phrase),
    })
}

/// Restore an identity from an existing mnemonic phrase.
pub(crate) fn restore_identity_from_mnemonic(phrase: &str) -> Result<IdentityData, String> {
    let mnemonic: Mnemonic = phrase
        .parse()
        .map_err(|e| format!("Invalid mnemonic: {e}"))?;

    let keypair = keypair_from_mnemonic(&mnemonic)?;
    let peer_id = keypair.public().to_peer_id().to_string();

    // Save the restored keypair to disk.
    save_keypair(&keypair)?;

    Ok(IdentityData {
        keypair,
        peer_id,
        mnemonic: Some(mnemonic.to_string()),
    })
}

/// Load existing identity from disk, or create a new one if none exists.
pub(crate) fn load_or_create_identity() -> Result<IdentityData, String> {
    let path = keypair_path()?;

    if path.exists() {
        // Load existing keypair.
        let bytes = fs::read(&path).map_err(|e| format!("Failed to read identity file: {e}"))?;
        let keypair = identity::Keypair::from_protobuf_encoding(&bytes)
            .map_err(|e| format!("Failed to decode identity: {e}"))?;
        let peer_id = keypair.public().to_peer_id().to_string();

        Ok(IdentityData {
            keypair,
            peer_id,
            mnemonic: None, // Don't return mnemonic on load — it's a one-time backup thing.
        })
    } else {
        // No identity yet — generate a fresh one.
        generate_new_identity()
    }
}

/// Derive an Ed25519 keypair from a BIP-39 mnemonic.
fn keypair_from_mnemonic(mnemonic: &Mnemonic) -> Result<identity::Keypair, String> {
    // BIP-39 seed: PBKDF2-HMAC-SHA512, 2048 rounds, no passphrase.
    let seed = mnemonic.to_seed("");

    // Take first 32 bytes of the 64-byte seed as the Ed25519 secret key.
    let mut secret_bytes = [0u8; 32];
    secret_bytes.copy_from_slice(&seed[..32]);

    // Build the libp2p Ed25519 keypair from the secret key bytes.
    // SecretKey::try_from_bytes takes 32-byte secret, then we derive the full keypair.
    let secret = identity::ed25519::SecretKey::try_from_bytes(&mut secret_bytes)
        .map_err(|e| format!("Invalid Ed25519 secret key: {e}"))?;
    let ed25519_keypair = identity::ed25519::Keypair::from(secret);
    Ok(identity::Keypair::from(ed25519_keypair))
}

/// Save a keypair to disk in protobuf encoding.
fn save_keypair(keypair: &identity::Keypair) -> Result<(), String> {
    let path = keypair_path()?;
    let bytes = keypair
        .to_protobuf_encoding()
        .map_err(|e| format!("Failed to encode keypair: {e}"))?;
    fs::write(&path, bytes).map_err(|e| format!("Failed to write identity file: {e}"))?;
    Ok(())
}
