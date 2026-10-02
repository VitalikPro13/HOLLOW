//! A guest's view of servers it is not in: the rooms it browses for their public
//! channels, and the store those channels' posts live in while it does (D6). The store
//! is memory only, so nothing a guest is shown reaches its database, and leaving a room
//! forgets that room's posts.

use std::collections::HashSet;

use crate::storage::MessageStore;

pub(crate) struct GuestView {
    rooms: HashSet<String>,
    store_path: String,
    /// The connection that keeps the store alive while any room is browsed. Behind a
    /// lock only so the event loop's future stays `Send`.
    keeper: std::sync::Mutex<Option<MessageStore>>,
}

impl GuestView {
    pub(crate) fn new() -> Self {
        let mut name = [0u8; 8];
        let _ = getrandom::fill(&mut name);
        Self {
            rooms: HashSet::new(),
            store_path: crate::storage::messages::guest_store_path(&hex::encode(name)),
            keeper: std::sync::Mutex::new(None),
        }
    }

    pub(crate) fn contains(&self, server_id: &str) -> bool {
        self.rooms.contains(server_id)
    }

    pub(crate) fn rooms(&self) -> impl Iterator<Item = &String> {
        self.rooms.iter()
    }

    /// Start browsing `server_id`. The store is memory only, so opening it here touches
    /// no disk.
    pub(crate) fn enter(&mut self, server_id: &str, db_passphrase: &str) {
        self.rooms.insert(server_id.to_string());
        let keeper = self.keeper.get_mut().unwrap_or_else(|e| e.into_inner());
        if keeper.is_none() {
            *keeper = MessageStore::open(&self.store_path, db_passphrase).ok();
        }
    }

    /// Stop browsing `server_id` and forget its posts; the store goes with the last room.
    pub(crate) fn leave(&mut self, server_id: &str) {
        self.rooms.remove(server_id);
        let keeper = self.keeper.get_mut().unwrap_or_else(|e| e.into_inner());
        if self.rooms.is_empty() {
            *keeper = None;
        } else if let Some(store) = keeper {
            let _ = store.prune_channel_messages_in_range(server_id, i64::MIN, i64::MAX);
        }
    }

    /// The store a frame for a server reads and writes: our own for a server we are in,
    /// else the guest store.
    pub(crate) fn store_for<'a>(&'a self, member: bool, db_path: &'a str) -> &'a str {
        if member { db_path } else { &self.store_path }
    }
}
