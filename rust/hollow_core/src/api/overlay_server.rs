//! The OBS overlay server (#97): desktop only, loopback only, one per profile.

use flutter_rust_bridge::frb;

use crate::node::overlay_server as server;

pub struct OverlayServerStatusFfi {
    /// "Run the overlay for OBS", saved for this profile.
    pub enabled: bool,
    pub running: bool,
    /// The running port, else the saved one, else 0.
    pub port: u16,
    /// The saved port was busy at start; cleared by a link reset or turning it off.
    pub port_changed: bool,
    pub open_streams: u32,
}

pub struct OverlayLinksFfi {
    pub room: String,
    pub me: String,
    /// A person's link is this plus their slot number.
    pub person_base: String,
}

impl From<server::Status> for OverlayServerStatusFfi {
    fn from(s: server::Status) -> Self {
        Self {
            enabled: s.enabled,
            running: s.running,
            port: s.port,
            port_changed: s.port_changed,
            open_streams: s.open_streams,
        }
    }
}

impl From<server::Links> for OverlayLinksFfi {
    fn from(l: server::Links) -> Self {
        Self { room: l.room, me: l.me, person_base: l.person_base }
    }
}

/// Starts or stops the server and saves the choice. Starting keeps the saved port
/// unless it is busy, which moves it, mints a new token and raises `OverlayPortChanged`.
/// The server starts LOCKED: pages stay blank until `overlay_server_set_locked(false)`.
#[frb]
pub fn overlay_server_set_enabled(enabled: bool) -> Result<OverlayServerStatusFfi, String> {
    server::set_enabled(enabled).map(Into::into)
}

#[frb]
pub fn overlay_server_status() -> OverlayServerStatusFfi {
    server::status().into()
}

/// Errors until the server has run once on this profile.
#[frb]
pub fn overlay_server_links() -> Result<OverlayLinksFfi, String> {
    server::links().map(Into::into)
}

/// A new token: every old link and open page stops working.
#[frb]
pub fn overlay_server_reset_link() -> Result<OverlayLinksFfi, String> {
    server::reset_link().map(Into::into)
}

/// The latest snapshot (plan 16.4). Rust validates and projects it before any page
/// sees it; an invalid body is refused whole.
#[frb]
pub fn overlay_publish(snapshot_json: String) -> Result<(), String> {
    server::publish(&snapshot_json)
}

/// The latest speaking states and levels (plan 16.4).
#[frb]
pub fn overlay_publish_live(live_json: String) -> Result<(), String> {
    server::publish_live(&live_json)
}

/// App Lock: pages go blank while locked and resume on unlock. Locked is the starting
/// state of every process, so call this with `false` once the app is unlocked.
#[frb]
pub fn overlay_server_set_locked(locked: bool) {
    server::set_locked(locked);
}
