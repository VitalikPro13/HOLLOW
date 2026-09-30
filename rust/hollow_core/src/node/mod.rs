pub(crate) mod assets;
pub(crate) mod at_rest;
pub(crate) mod at_rest_server;
pub(crate) mod blocklist;
pub(crate) mod conference;
pub(crate) mod crdt_store;
pub(crate) mod crypto_handler;
pub(crate) mod destroy;
pub(crate) mod dm_room;
/// Embedded peer-forwarder bridge: the swarm to `forwarder::engine` seam for
/// viewer-peer forwarders. Desktop-only, the same gate as the forwarder module.
#[cfg(all(feature = "forwarder", not(any(target_os = "android", target_os = "ios"))))]
pub(crate) mod embedded_forwarder;
pub(crate) mod emotes;
pub(crate) mod fetch;
pub(crate) mod frame_auth;
pub(crate) mod file_asks;
pub(crate) mod file_commit;
pub(crate) mod file_handler;
pub(crate) mod file_transfer;
pub(crate) mod forwarder_client;
pub(crate) mod gossip;
pub(crate) mod gossip_relay;
pub(crate) mod image_convert;
pub(crate) mod join_lane;
pub(crate) mod join_lock;
pub(crate) mod lock_keeper;
pub(crate) mod link_handler;
pub(crate) mod link_preview;
pub(crate) mod message_ops;
pub(crate) mod nick_claim;
pub(crate) mod olm_lane;
pub(crate) mod mls_authority;
pub(crate) mod profile_card;
pub(crate) mod recovery_pool;
pub(crate) mod resolver;
pub(crate) mod ring_auth;
pub(crate) mod sealed_box;
pub(crate) mod security_alerts;
pub(crate) mod share_handler;
pub(crate) mod social;
pub(crate) mod support_creds;
pub(crate) mod support_rsa;
pub(crate) mod sync_handler;
pub(crate) mod twitch;
pub(crate) mod types;
pub(crate) mod vault_ops;
pub(crate) mod voice_handler;
pub(crate) mod ws_stream_transfer;
mod swarm;
pub(crate) mod ws_client;
pub(crate) mod webp_anim;

#[cfg(test)]
mod test_harness;

pub(crate) use crdt_store::CrdtStore;
pub(crate) use types::{new_channel_id, LinkPreviewRef, NetworkEvent, NodeCommand, PersonalEmoteEntry, RichCard, SendFilePayload, ShareRef, SignedDeviceList, VaultUploadFilePayload, VideoThumbRef};
pub(crate) use crypto_handler::verify_message_signature;
pub(crate) use swarm::spawn_node;
