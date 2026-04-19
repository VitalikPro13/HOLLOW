use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::SystemTime;

use serde::Deserialize;
use tokio::sync::RwLock;

#[derive(Deserialize)]
struct LicenseFile {
    #[serde(default)]
    enabled: bool,
    #[serde(default)]
    keys: Vec<String>,
}

struct LicenseConfig {
    enabled: bool,
    keys: HashSet<String>,
}

pub struct LicenseState {
    config: RwLock<LicenseConfig>,
    /// Maps license_key → peer_id for active connections.
    active_keys: RwLock<HashMap<String, String>>,
    file_path: PathBuf,
    last_mtime: RwLock<Option<SystemTime>>,
}

pub type SharedLicenseState = Arc<LicenseState>;

pub enum LicenseResult {
    Ok,
    NotRequired,
    InvalidKey,
    KeyInUse,
    KeyRequired,
}

impl LicenseState {
    pub fn load_from_file(path: &Path) -> Result<Self, String> {
        let content = std::fs::read_to_string(path)
            .map_err(|e| format!("Failed to read {}: {e}", path.display()))?;
        let file: LicenseFile = serde_json::from_str(&content)
            .map_err(|e| format!("Failed to parse {}: {e}", path.display()))?;

        let mtime = std::fs::metadata(path).ok().and_then(|m| m.modified().ok());

        let key_count = file.keys.len();
        tracing::info!(
            "Loaded {} license key(s), enabled={}",
            key_count,
            file.enabled
        );

        Ok(Self {
            config: RwLock::new(LicenseConfig {
                enabled: file.enabled,
                keys: file.keys.into_iter().collect(),
            }),
            active_keys: RwLock::new(HashMap::new()),
            file_path: path.to_path_buf(),
            last_mtime: RwLock::new(mtime),
        })
    }

    pub fn disabled() -> Self {
        Self {
            config: RwLock::new(LicenseConfig {
                enabled: false,
                keys: HashSet::new(),
            }),
            active_keys: RwLock::new(HashMap::new()),
            file_path: PathBuf::new(),
            last_mtime: RwLock::new(None),
        }
    }

    pub async fn is_enabled(&self) -> bool {
        self.config.read().await.enabled
    }

    pub async fn validate_key(
        &self,
        key: Option<&str>,
        peer_id: &str,
    ) -> LicenseResult {
        let config = self.config.read().await;
        if !config.enabled {
            return LicenseResult::NotRequired;
        }

        let key = match key {
            Some(k) if !k.is_empty() => k,
            _ => return LicenseResult::KeyRequired,
        };

        if !config.keys.contains(key) {
            return LicenseResult::InvalidKey;
        }
        drop(config);

        let mut active = self.active_keys.write().await;
        if let Some(existing_peer) = active.get(key) {
            if existing_peer != peer_id {
                return LicenseResult::KeyInUse;
            }
        }
        active.insert(key.to_string(), peer_id.to_string());
        LicenseResult::Ok
    }

    pub async fn release_key(&self, peer_id: &str) {
        let mut active = self.active_keys.write().await;
        active.retain(|_, v| v != peer_id);
    }

    pub fn spawn_reload_task(
        self: Arc<Self>,
        ws_state: crate::ws_router::SharedWsState,
    ) {
        if self.file_path.as_os_str().is_empty() {
            return;
        }
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(std::time::Duration::from_secs(30));
            loop {
                interval.tick().await;
                self.try_reload(&ws_state).await;
            }
        });
    }

    async fn try_reload(&self, ws_state: &crate::ws_router::SharedWsState) {
        let current_mtime = match tokio::fs::metadata(&self.file_path).await {
            Ok(m) => m.modified().ok(),
            Err(_) => return,
        };

        let last = *self.last_mtime.read().await;
        if current_mtime == last {
            return;
        }

        let content = match tokio::fs::read_to_string(&self.file_path).await {
            Ok(c) => c,
            Err(e) => {
                tracing::warn!("Failed to re-read keys file: {e}");
                return;
            }
        };

        let file: LicenseFile = match serde_json::from_str(&content) {
            Ok(f) => f,
            Err(e) => {
                tracing::warn!("Failed to parse keys file on reload: {e}");
                return;
            }
        };

        let key_count = file.keys.len();
        let new_keys: HashSet<String> = file.keys.into_iter().collect();

        // Detect revoked keys — active connections using removed keys get kicked.
        let peers_to_kick = {
            let active = self.active_keys.read().await;
            let mut kicked = Vec::new();
            for (key, peer_id) in active.iter() {
                if !new_keys.contains(key) {
                    kicked.push(peer_id.clone());
                    tracing::info!("License key revoked for peer {peer_id}");
                }
            }
            kicked
        };

        {
            let mut config = self.config.write().await;
            config.enabled = file.enabled;
            config.keys = new_keys;
        }
        *self.last_mtime.write().await = current_mtime;

        // Remove revoked keys from active tracking.
        if !peers_to_kick.is_empty() {
            let mut active = self.active_keys.write().await;
            active.retain(|_, pid| !peers_to_kick.contains(pid));
        }

        tracing::info!(
            "Reloaded license keys: {} key(s), enabled={}",
            key_count,
            self.config.read().await.enabled
        );

        // Kick peers with revoked keys.
        if !peers_to_kick.is_empty() {
            ws_state.kick_peers(&peers_to_kick).await;
        }
    }
}
