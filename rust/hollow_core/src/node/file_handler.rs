use std::collections::HashMap;
use std::path::PathBuf;

use base64::Engine;
use tokio::sync::mpsc;

use crate::crdt::server_state::ServerState;
use crate::crypto::{MlsManager, OlmManager, CryptoStore};
use crate::node::file_transfer;
use crate::node::image_convert;
use super::crypto_handler::{
    peer_is_reachable, ws_room_for_peer,
    send_mls_broadcast_topic, send_encrypted_message,
    send_message_to_peer,
};
use super::gossip;
use super::types::*;
use super::ws_stream_transfer;

/// Max automatic re-requests after a failed file decrypt or assembly before
/// surfacing FileFailed to the UI. A transient truncation race clears on the first
/// or second retry; a genuinely corrupt source will not, so it is capped.
const FILE_DECRYPT_MAX_RETRIES: u32 = 3;

// ── Auto-download configuration (issue #41) ─────────────────────────────────
//
// Pushed by Dart via `set_auto_download_config` at bootstrap and on every
// settings change. `threshold_mb == 0` means auto-download is OFF. Overrides are
// keyed `dm:{master}` / `server:{server_id}`. Default-permissive when Dart never
// pushed, which matches the Dart-side default so old flows keep working.
//
// Pull paths are gated in Dart before any request is made; pushed streams are
// declined at FileHeader time. Senders also pre-negotiate via
// `HavenMessage::AutoDownloadPref`, but the receive-side gate is the enforcement.
pub(crate) struct AutoDownloadConf {
    pub threshold_mb: u32,
    pub overrides: HashMap<String, bool>,
}

const AUTO_DOWNLOAD_DEFAULT_MB: u32 = 169;

fn auto_download_conf() -> &'static std::sync::Mutex<AutoDownloadConf> {
    static CONF: std::sync::OnceLock<std::sync::Mutex<AutoDownloadConf>> =
        std::sync::OnceLock::new();
    CONF.get_or_init(|| {
        std::sync::Mutex::new(AutoDownloadConf {
            threshold_mb: AUTO_DOWNLOAD_DEFAULT_MB,
            overrides: HashMap::new(),
        })
    })
}

/// Replace the auto-download config (FFI `set_auto_download_config`).
pub(crate) fn set_auto_download_conf(threshold_mb: u32, overrides: HashMap<String, bool>) {
    if let Ok(mut conf) = auto_download_conf().lock() {
        conf.threshold_mb = threshold_mb;
        conf.overrides = overrides;
    }
}

/// The GLOBAL auto-download threshold in MB (no per-conversation override
/// applied). Advertised to our own siblings, whose mirrored pushes span every
/// conversation so no single override key applies. 0 = off.
pub(crate) fn global_auto_download_mb() -> u32 {
    auto_download_conf()
        .lock()
        .map(|c| c.threshold_mb)
        .unwrap_or(AUTO_DOWNLOAD_DEFAULT_MB)
}

/// The effective auto-download threshold in MB for a conversation
/// (`dm:{master}` / `server:{server_id}`). 0 = never auto-download.
pub(crate) fn effective_auto_download_mb(context_key: &str) -> u32 {
    let Ok(conf) = auto_download_conf().lock() else {
        return AUTO_DOWNLOAD_DEFAULT_MB;
    };
    match conf.overrides.get(context_key) {
        Some(false) => 0,
        Some(true) => {
            if conf.threshold_mb == 0 { AUTO_DOWNLOAD_DEFAULT_MB } else { conf.threshold_mb }
        }
        None => conf.threshold_mb,
    }
}

/// `true` when a filename matches a recorded voice message. The wire name is the
/// recorder temp file's basename, NOT the "Voice message.ogg" display name the UI
/// shows. A LEGACY fallback for pre-0.9.4 senders that do not set the header's
/// `voice` flag; keep the pattern in sync with the Dart twin `isVoiceMessageFile`.
pub(crate) fn is_voice_message_name(file_name: &str) -> bool {
    file_name == "Voice message.ogg"
        || (file_name.starts_with("voice_") && file_name.ends_with(".ogg"))
}

/// Ceiling on the voice-note auto-download exemption: 8 MB. A recorded note
/// is about 90 KB per 30 seconds (16 kHz mono, 24 kbps Opus), so this is well
/// over half an hour of speech and still nothing like a file push.
pub(crate) const VOICE_NOTE_MAX_BYTES: u64 = 8 * 1024 * 1024;

/// `true` = this header really is a recorded voice note, on every field at once.
///
/// SECURITY (FILE-2): the exemption used to read `voice || name`, and both are
/// strings the SENDER chooses. With no size bound and no look at the extension, a
/// 34 MB header flagged `voice: true` with `ext: "exe"` landed on disk in a
/// conversation the user had turned auto-download OFF for. Every field must agree.
pub(crate) fn is_voice_note_exempt(size: u64, file_name: &str, ext: &str, voice: bool) -> bool {
    voice
        && is_voice_message_name(file_name)
        && ext.eq_ignore_ascii_case("ogg")
        && size <= VOICE_NOTE_MAX_BYTES
}

/// `true` = a PUSHED file transfer of `size` bytes may auto-register its stream in
/// this conversation. Genuine voice notes are exempt, but only when the flag, the
/// name, the extension and the size all say so (see `is_voice_note_exempt`).
pub(crate) fn auto_download_allows(
    size: u64,
    file_name: &str,
    ext: &str,
    context_key: &str,
    voice: bool,
) -> bool {
    if is_voice_note_exempt(size, file_name, ext, voice) {
        return true;
    }
    let mb = effective_auto_download_mb(context_key) as u64;
    mb > 0 && size <= mb * 1024 * 1024
}

/// Advertise our auto-download preference to one peer DEVICE. Counterparty devices
/// get the effective threshold for the conversation with their identity; our own
/// siblings get the GLOBAL threshold, because their mirrored pushes span every
/// conversation, so no single override key applies.
pub(crate) fn advertise_auto_dl_pref_to_peer(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    local_peer_str: &str,
    peer_str: &str,
) {
    let mb = if crate::node::resolver::same_identity(peer_str, local_peer_str) {
        global_auto_download_mb()
    } else {
        let master = crate::node::resolver::resolve(peer_str);
        effective_auto_download_mb(&format!("dm:{master}"))
    };
    super::olm_lane::carry(
        ws_cmd_tx, peer_str, None,
        &HavenMessage::AutoDownloadPref { mb },
        super::olm_lane::NoSession::Queue,
    );
}

/// Re-advertise the auto-download preference to every connected DM-room peer and
/// sibling after a settings change. Best effort: a device we share only a server
/// room with never receives an advert, and its own receive gate still enforces.
pub(crate) fn advertise_auto_dl_pref_to_all(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    local_peer_str: &str,
    device_peer_id: &str,
) {
    let mut advertised: std::collections::HashSet<&String> = std::collections::HashSet::new();
    for (room, peers) in ws_room_peers {
        for peer in peers {
            if peer == device_peer_id || peer == local_peer_str || advertised.contains(peer) {
                continue;
            }
            let is_sibling = crate::node::resolver::same_identity(peer, local_peer_str);
            let is_dm_room = *room
                == crate::node::types::dm_room_code(
                    local_peer_str,
                    &crate::node::resolver::resolve(peer),
                );
            if is_sibling || is_dm_room {
                advertise_auto_dl_pref_to_peer(ws_cmd_tx, local_peer_str, peer);
                advertised.insert(peer);
            }
        }
    }
    if !advertised.is_empty() {
        hollow_log!(
            "[HOLLOW-FILE] Re-advertised auto-download pref to {} peer device(s)",
            advertised.len()
        );
    }
}

/// SECURITY (0.8.5): `true` = this REMOTE file-metadata write may proceed.
///
/// `insert_file_metadata` is an UPSERT keyed on `file_id`: it deliberately
/// overwrites name, ext, mime, size and dimensions, so a minimal placeholder row
/// written by the background-fetch node gets filled in when the real FileHeader
/// arrives. With no owner check that same overwrite was reachable by anyone on an
/// ingest path: a friend or server member could send a FileHeader carrying SOMEONE
/// ELSE'S `file_id` and relabel their attachment, and a sync responder could do it
/// through `file_meta`, whose blob the item's v2 signature does not bind.
///
/// Rule: a file card belongs to the identity that first created it. Writes pass
/// when there is no row yet, or when the incoming sender resolves to the SAME
/// master as the stored one (the device-to-master collapse is required, because
/// the fetch path stores a master while the live path stores a device).
pub(crate) fn file_meta_write_allowed(
    store: &crate::storage::MessageStore,
    file_id: &str,
    incoming_sender: &str,
) -> bool {
    let Ok(Some(existing)) = store.get_file_metadata(file_id) else {
        return true; // No row yet — nothing to overwrite.
    };
    let owner = super::resolver::resolve(&existing.sender_id);
    if owner == super::resolver::resolve(incoming_sender) {
        return true;
    }
    hollow_log!(
        "[HOLLOW-SECURITY] REJECTED file metadata write for {file_id} from {incoming_sender} — the card belongs to {owner}"
    );
    false
}

/// Why a FileHeader may not deliver anything for `fid`, `None` when it may. The ONE
/// gate every header arm runs before it consumes a receipt, registers a key or
/// writes a byte.
///
/// The owner guard protects only the card, but the key a header registers is what
/// the file's stream decrypts under and inline bytes are the file itself. So a
/// header for a file we hold a row for comes from its owner or from the holder we
/// `asked`; a channel header comes from a current member who can read the channel.
pub(crate) fn file_header_refused(
    store: &crate::storage::MessageStore,
    server_states: &HashMap<String, ServerState>,
    fid: &str,
    sid: Option<&str>,
    cid: Option<&str>,
    sender: &str,
    asked: bool,
) -> Option<&'static str> {
    let master = super::resolver::resolve(sender);
    if let Some(sid) = sid {
        let reader = cid.zip(server_states.get(sid))
            .is_some_and(|(cid, s)| s.is_member(&master) && s.can_see_channel(&master, cid));
        if !reader {
            return Some("not a member who can read the channel");
        }
    }
    match store.get_file_metadata(fid) {
        Ok(Some(row)) if !asked && super::resolver::resolve(&row.sender_id) != master => {
            Some("the file belongs to someone else")
        }
        _ => None,
    }
}

/// Whether `fid`'s bytes are already on disk. A file's content never changes once
/// written, so no header, stream or chunk may deliver it again.
pub(crate) fn file_bytes_on_disk(store: &crate::storage::MessageStore, fid: &str) -> bool {
    matches!(
        store.get_file_metadata(fid),
        Ok(Some(meta)) if meta.completed_at.is_some()
            && meta.disk_path.as_ref().is_some_and(|p| std::path::Path::new(p).exists())
    )
}

/// The file card riding a verified sync item, when it may land. The item's
/// signature binds `file_id` but not the `file_meta` blob, so the blob must
/// describe exactly that file (a committed id hashes from it with the item's `mid`
/// and verified `author`), and ownership is judged against that `author`, never the
/// blob's own `sender` field.
pub(crate) fn synced_file_meta<'a>(
    store: &crate::storage::MessageStore,
    file_meta: Option<&'a super::types::SyncFileMetaItem>,
    signed_file_id: Option<&str>,
    mid: Option<&str>,
    author: &str,
) -> Option<&'a super::types::SyncFileMetaItem> {
    let fm = file_meta?;
    if signed_file_id != Some(fm.fid.as_str()) {
        hollow_log!("[HOLLOW-SECURITY] REJECTED synced file card {} riding an item signed for {signed_file_id:?}", fm.fid);
        return None;
    }
    if let Some(reason) = synced_card_claim_refused(fm, mid, author) {
        hollow_log!("[HOLLOW-SECURITY] REJECTED synced file card {}: {reason}", fm.fid);
        return None;
    }
    file_meta_write_allowed(store, &fm.fid, author).then_some(fm)
}

/// Why a card riding a signed item (sync, a public post) may not describe its file.
pub(crate) fn synced_card_claim_refused(
    fm: &super::types::SyncFileMetaItem,
    mid: Option<&str>,
    author: &str,
) -> Option<&'static str> {
    let commit = fm.sha256.as_deref().zip(mid).map(|(sha256, mid)| super::file_commit::FileCommit {
        author, mid, size: fm.size, sha256, name: &fm.name, ext: &fm.ext, vthumb: fm.vthumb.as_ref(),
    });
    super::file_commit::claim_refused(&fm.fid, commit.as_ref())
}

/// Handle NodeCommand::SendFile.
///
/// Image conversion is CPU work that used to run inline here, and a multi-MB GIF
/// froze the ENTIRE event loop for seconds. Convertible images now hop through
/// `spawn_blocking` and re-enter via `NodeCommand::SendFileConverted`.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_send_file(
    peer_id: Option<String>,
    server_id: Option<String>,
    channel_id: Option<String>,
    file_path: String,
    message_id: String,
    message_text: String,
    vthumb: Option<VideoThumbRef>,
    override_width: Option<u32>,
    override_height: Option<u32>,
    share_ref: Option<super::types::ShareRef>,
    voice: bool,
    poster: Option<Vec<u8>>,
    album: Option<String>,
    cmd_tx: &mpsc::Sender<super::types::NodeCommand>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    server_states: &HashMap<String, ServerState>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    // THIS device's keypair — signs the Olm key exchange (Fix A/B).
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
    device_peer_id: &str,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    mls: &mut Option<MlsManager>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    webrtc_peers: &std::collections::HashSet<String>,
    pending_webrtc_sends: &mut HashMap<String, (String, ws_stream_transfer::StreamKind, String, PathBuf, u64)>,
    peer_auto_dl: &HashMap<String, u32>,
    gossip_overlays: &mut HashMap<String, gossip::GossipOverlay>,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-FILE] SendFile: {file_path} mid={message_id}");

    let path = std::path::Path::new(&file_path);
    let original_name = path.file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .to_string();
    let original_ext = path.extension()
        .unwrap_or_default()
        .to_string_lossy()
        .to_lowercase();

    // Photos the image path converts lose their metadata there; a video or a
    // HEIF photo is cleaned here, before anything (the poster, the file id,
    // the share) sees its bytes.
    let strip = !file_transfer::is_image_mime(&file_transfer::mime_from_ext(&original_ext))
        && super::media_strip::strips_on_send(&original_ext);
    let read_src = file_path.clone();
    let mut file_data = match tokio::task::spawn_blocking(move || {
        let path = std::path::Path::new(&read_src);
        if strip {
            super::media_strip::read_for_send(path)
        } else {
            crate::node::at_rest::read_all(path).map_err(|e| format!("Failed to read file: {e}"))
        }
    })
    .await
    .unwrap_or_else(|e| Err(format!("Failed to read file: {e}")))
    {
        Ok(d) => d,
        Err(e) => {
            hollow_log!("[HOLLOW-FILE] SendFile refused: {e}");
            let _ = event_tx.send(NetworkEvent::FileFailed {
                file_id: message_id.clone(),
                error: e,
            }).await;
            return;
        }
    };

    // 2b. Channel moderation gates. Posting permission was historically enforced
    // only on the text path, so file sends bypassed it; this closes that gap.
    if let Some(reason) = channel_file_send_rejection(
        server_states, &server_id, &channel_id, local_peer_str, &original_ext,
        db_path, db_passphrase,
    ).await {
        let _ = event_tx.send(NetworkEvent::FileFailed {
            file_id: message_id.clone(),
            error: reason,
        }).await;
        return;
    }

    // 3. Check size limit (34MB default, hard cap on default relay).
    let max_size = if let Some(ref sid) = server_id {
        server_states.get(sid)
            .and_then(|s| s.settings.get("max_file_size_mb"))
            .and_then(|reg| reg.read().parse::<u64>().ok())
            .unwrap_or(34) * 1024 * 1024
    } else {
        file_transfer::DEFAULT_MAX_FILE_SIZE
    };
    if share_ref.is_none() && file_data.len() as u64 > max_size {
        hollow_log!("[HOLLOW-FILE] File too large: {} > {}", file_data.len(), max_size);
        let _ = event_tx.send(NetworkEvent::FileFailed {
            file_id: message_id.clone(),
            error: format!("File too large ({}MB limit)", max_size / 1024 / 1024),
        }).await;
        return;
    }

    // 4. Convert to WebP if image, honouring the user's quality tier (read from
    // app_settings per send: one KV lookup, so the cost is negligible). GIFs become
    // animated WebP at every tier and WebP inputs pass through untouched. No
    // size-based bypass: even a 20 KB PNG drops to 2-3 KB at Q=50, and the encode
    // cost on small files is trivial.
    let mime = file_transfer::mime_from_ext(&original_ext);
    let is_image = file_transfer::is_image_mime(&mime);

    // The send stamp is taken HERE, in command order, not after the conversion
    // hop: conversions finish in any order (an animated GIF encodes slowest),
    // and an album's items must keep the order they were sent in.
    let order_us = crate::chat_clock::next_send_stamp_us();

    let needs_convert = is_image
        && (image_convert::should_convert_to_webp(&original_ext)
            || original_ext == "webp"
            || original_ext == "gif");

    if needs_convert {
        // CPU-heavy conversion: hop off the event loop and re-enter via
        // SendFileConverted, so messages, CRDT and call signaling keep flowing.
        spawn_image_conversion(
            peer_id, server_id, channel_id, message_id, message_text,
            vthumb, share_ref, original_name, is_image, voice, album, order_us,
            file_data, original_ext, override_width, override_height,
            cmd_tx.clone(), event_tx.clone(), db_path, db_passphrase,
        );
        return;
    }

    // ffmpeg's stderr probe can fail (0x0 dims) — treat zero as absent so the
    // poster-derived fallback below can take over.
    let override_width = override_width.filter(|v| *v > 0);
    let override_height = override_height.filter(|v| *v > 0);

    // Video send with a Dart-extracted poster frame: encode the wire poster off the
    // event loop, the same spawn_blocking hop the image conversion uses, then
    // resume at finish_send_file via SendFileConverted.
    if !is_image && let Some(poster_bytes) = poster.filter(|p| !p.is_empty()) {
        spawn_video_poster_encode(
            peer_id, server_id, channel_id, message_id, message_text,
            vthumb, share_ref, original_name, voice, album, order_us,
            std::mem::take(&mut file_data), original_ext,
            override_width, override_height, poster_bytes,
            cmd_tx.clone(),
        );
        return;
    }

    // Non-image files continue inline, using Dart-supplied dimensions if any (the
    // video preview path passes the source video's dimensions through here).
    let final_data = std::mem::take(&mut file_data);
    let final_ext = original_ext.clone();
    finish_send_file(
        peer_id, server_id, channel_id, message_id, message_text,
        vthumb, share_ref, original_name, is_image,
        final_data, final_ext, override_width, override_height,
        None, voice, album, order_us,
        event_tx, server_states, bundle_keypair, device_keypair, pub_key_b64, local_peer_str,
        device_peer_id, olm, crypto_store, mls,
        ws_cmd_tx, ws_room_peers, webrtc_peers, pending_webrtc_sends,
        peer_auto_dl, gossip_overlays, db_path, db_passphrase,
    ).await;
}

/// Poster-encode hop for video sends: `encode_video_poster` decodes and re-encodes
/// on the blocking pool, then re-enters the event loop with the UNCHANGED file
/// bytes plus the poster thumb and its dimension fallback.
#[allow(clippy::too_many_arguments)]
fn spawn_video_poster_encode(
    peer_id: Option<String>,
    server_id: Option<String>,
    channel_id: Option<String>,
    message_id: String,
    message_text: String,
    vthumb: Option<VideoThumbRef>,
    share_ref: Option<super::types::ShareRef>,
    original_name: String,
    voice: bool,
    album: Option<String>,
    order_us: i64,
    file_data: Vec<u8>,
    original_ext: String,
    override_width: Option<u32>,
    override_height: Option<u32>,
    poster_bytes: Vec<u8>,
    cmd_tx: mpsc::Sender<super::types::NodeCommand>,
) {
    tokio::spawn(async move {
        let encoded = tokio::task::spawn_blocking(move || encode_video_poster(&poster_bytes))
            .await
            .ok()
            .flatten();
        let (thumb, poster_w, poster_h) = match encoded {
            Some((b64, w, h)) => (Some(b64), Some(w), Some(h)),
            None => (None, None, None),
        };
        // Real source dims when the probe worked; else the poster's own
        // (scaled, aspect-true) dims so receivers still size the bubble right.
        let width = override_width.or(poster_w);
        let height = override_height.or(poster_h);
        let _ = cmd_tx
            .send(super::types::NodeCommand::SendFileConverted(Box::new(
                super::types::SendFileConvertedPayload {
                    peer_id, server_id, channel_id, message_id, message_text,
                    vthumb, share_ref, original_name, is_image: false,
                    final_data: file_data, final_ext: original_ext,
                    width, height, thumb, voice, album, order_us,
                },
            )))
            .await;
    });
}

/// Max side of the blurred-placeholder thumbnail riding an IMAGE FileHeader
/// (issue #41 carry-over). 32 px lossy WebP ≈ a few hundred bytes.
const FILE_THUMB_MAX_DIM: u32 = 32;
/// Max ENCODED size of a video poster riding the FileHeader `thumb` field (a crisp
/// frame up to 400 px). The relay's offline rings are byte-budgeted at 1 MB per
/// channel topic, so ~24 KB per video message is a comfortable share.
const VIDEO_POSTER_MAX_BYTES: usize = 24 * 1024;
/// Receive-side cap on the base64 `thumb` field — bounds both the image
/// blur thumb (a few hundred bytes) and the video poster (≤24 KB binary ≈
/// 32 KB base64). Anything larger is a malformed/hostile header.
pub(crate) const FILE_THUMB_MAX_B64_LEN: usize = 48 * 1024;

/// Longest side a header thumb may declare: blur placeholders are 32 px, video
/// posters at most 400.
const FILE_THUMB_RECV_MAX_DIM: u32 = 512;

/// Receive-side acceptance filter for the envelope-borne `thumb`: images get the
/// tiny blur placeholder, videos the poster frame, and anything else, anything
/// oversized or anything that is not a placeholder-sized WebP is dropped before it
/// reaches the DB or UI. ONE helper, so every ingest path stays in lockstep. The
/// pixels are judged where they cross to Dart (`peer_thumb_for_display`), off the
/// event loop.
pub(crate) fn accept_header_thumb(thumb: Option<String>, img: bool, mime: &str) -> Option<String> {
    thumb.filter(|t| {
        (img || mime.starts_with("video/"))
            && !t.is_empty()
            && t.len() <= FILE_THUMB_MAX_B64_LEN
            && header_thumb_is_small_webp(t)
    })
}

fn header_thumb_is_small_webp(b64: &str) -> bool {
    base64::engine::general_purpose::STANDARD
        .decode(b64)
        .ok()
        .and_then(|raw| image_convert::webp_header_dimensions(&raw))
        .is_some_and(|(w, h)| {
            (1..=FILE_THUMB_RECV_MAX_DIM).contains(&w) && (1..=FILE_THUMB_RECV_MAX_DIM).contains(&h)
        })
}

/// Encode a video poster frame into the bounded lossy WebP that rides the
/// FileHeader, stepping down through smaller max dimensions until it fits the wire
/// budget. The returned dimensions are aspect-true to the source video, so they
/// double as the header w/h fallback when the ffmpeg probe yielded none.
fn encode_video_poster(data: &[u8]) -> Option<(String, u32, u32)> {
    for max_dim in [400u32, 320, 256] {
        if let Ok((bytes, w, h)) = image_convert::convert_to_webp_preview(data, max_dim) {
            if !bytes.is_empty() && bytes.len() <= VIDEO_POSTER_MAX_BYTES {
                return Some((
                    base64::engine::general_purpose::STANDARD.encode(&bytes),
                    w,
                    h,
                ));
            }
        }
    }
    None
}

/// Tiny blurred-placeholder thumbnail from the ORIGINAL image bytes, decoded once
/// more on the blocking pool because the conversion path may produce animated WebP
/// the `image` crate cannot re-decode. None on failure: no blur preview.
fn generate_file_thumb(original_data: &[u8]) -> Option<String> {
    let (bytes, _, _) = image_convert::convert_to_webp_preview(original_data, FILE_THUMB_MAX_DIM).ok()?;
    if bytes.is_empty() || bytes.len() > FILE_THUMB_MAX_B64_LEN / 2 {
        return None;
    }
    Some(base64::engine::general_purpose::STANDARD.encode(&bytes))
}

/// A photo ready to send: its bytes, extension, width and height.
type ConvertedImage = (Vec<u8>, String, Option<u32>, Option<u32>);

/// The moved step-4 conversion block: runs on the blocking pool, never the
/// event loop. Returns the photo and its blur thumb; an Err is the reason the
/// photo was not sent.
fn convert_image_for_send(
    file_data: Vec<u8>,
    original_ext: &str,
    webp_quality: image_convert::WebpQuality,
    override_width: Option<u32>,
    override_height: Option<u32>,
) -> Result<(ConvertedImage, Option<String>), String> {
    // Placeholder thumb first, from the ORIGINAL bytes (issue #41 carry-over).
    let thumb = generate_file_thumb(&file_data);
    let converted = convert_image_data(file_data, original_ext, webp_quality, override_width, override_height)
        .map_err(|e| {
            hollow_log!("[HOLLOW-FILE] metadata strip refused a photo: {e}");
            super::media_strip::REFUSED.to_string()
        })?;
    Ok((converted, thumb))
}

/// Every arm drops the photo's metadata: a re-encode leaves it behind, and
/// the arms that send the original strip its container instead (C-FILES-03).
fn convert_image_data(
    file_data: Vec<u8>,
    original_ext: &str,
    webp_quality: image_convert::WebpQuality,
    override_width: Option<u32>,
    override_height: Option<u32>,
) -> Result<ConvertedImage, String> {
    let original = |data: Vec<u8>| -> Result<_, String> {
        let out = super::media_strip::strip_image(data)?;
        let dims = image_convert::get_image_dimensions(&out).ok();
        Ok((out, original_ext.to_string(), dims.map(|d| d.0), dims.map(|d| d.1)))
    };
    // ANIMATED sources first, decided from the BYTES. Branching on the extension is
    // what froze an APNG and flattened an animated WebP to frame 0.
    if image_convert::is_animated_image(&file_data) {
        return match image_convert::convert_animation_to_webp(&file_data, webp_quality) {
            Ok((webp_data, w, h)) => {
                hollow_log!(
                    "[HOLLOW-FILE] Converted animation to animated WebP ({:?}): {}KB -> {}KB ({}x{})",
                    webp_quality, file_data.len() / 1024, webp_data.len() / 1024, w, h
                );
                Ok((webp_data, "webp".to_string(), Some(w), Some(h)))
            }
            Err(e) => {
                // The original rather than a frozen frame.
                hollow_log!("[HOLLOW-FILE] Animation conversion failed, sending the original: {e}");
                original(file_data)
            }
        };
    }
    if image_convert::should_convert_to_webp(original_ext) {
        match image_convert::convert_to_webp_with_quality(&file_data, webp_quality) {
            Ok((webp_data, w, h)) => {
                hollow_log!("[HOLLOW-FILE] Converted to WebP ({:?}): {}KB -> {}KB ({}x{})",
                    webp_quality, file_data.len() / 1024, webp_data.len() / 1024, w, h);
                Ok((webp_data, "webp".to_string(), Some(w), Some(h)))
            }
            Err(e) => {
                hollow_log!("[HOLLOW-FILE] WebP conversion failed, sending the original: {e}");
                original(file_data)
            }
        }
    } else if original_ext == "webp" {
        match image_convert::strip_webp_metadata(&file_data) {
            Ok(stripped) => {
                let dims = image_convert::get_image_dimensions(&stripped).ok();
                Ok((stripped, original_ext.to_string(), dims.map(|d| d.0), dims.map(|d| d.1)))
            }
            Err(_) => original(file_data),
        }
    } else {
        // A `.gif` that is no GIF (every real one took the encoder above): its
        // bytes decide how it is cleaned.
        let out = super::media_strip::strip_image(file_data)?;
        Ok((out, original_ext.to_string(), override_width, override_height))
    }
}

/// Channel moderation gates for a file send (posting permission, mute, media-only,
/// slow mode). Returns Some(reason) when the send must be rejected with FileFailed.
/// Async: the slow-mode check reads the MessageStore on the blocking pool, and the
/// store lives entirely inside that closure, because a Connection is !Sync.
async fn channel_file_send_rejection(
    server_states: &HashMap<String, ServerState>,
    server_id: &Option<String>,
    channel_id: &Option<String>,
    local_peer_str: &str,
    original_ext: &str,
    db_path: &str,
    db_passphrase: &str,
) -> Option<String> {
    let (Some(sid), Some(cid)) = (server_id, channel_id) else { return None; };
    let server = server_states.get(sid)?;
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    if !server.can_post_in_channel(local_peer_str, cid) {
        return Some("You don't have permission to post in this channel".to_string());
    }
    if server.is_muted(local_peer_str, now_ms as u64) {
        return Some("You are muted on this server".to_string());
    }
    if server.is_channel_media_only(cid) {
        let mime = file_transfer::mime_from_ext(original_ext);
        let is_media = file_transfer::is_image_mime(&mime) || mime.starts_with("video/");
        if !is_media {
            return Some(
                "This is a media-only channel. Only images, GIFs, and videos can be posted"
                    .to_string(),
            );
        }
    }
    slow_mode_rejection(server, sid, cid, local_peer_str, now_ms, db_path, db_passphrase).await
}

/// Slow-mode gate for a channel file send. The Mod+ exemption short-circuits BEFORE
/// any store access; the sender's own latest channel ts is read on the blocking
/// pool via the shared message_ops helper. Store-open failure allows.
async fn slow_mode_rejection(
    server: &ServerState,
    sid: &str,
    cid: &str,
    local_peer_str: &str,
    now_ms: u128,
    db_path: &str,
    db_passphrase: &str,
) -> Option<String> {
    let slow = server.channel_slow_mode(cid);
    if slow == 0 || server.bypasses_slow_mode(local_peer_str) {
        return None;
    }
    let last_ts = super::message_ops::latest_own_channel_ts_blocking(sid, cid, db_path, db_passphrase).await?;
    let next_allowed = last_ts + (slow as i64) * 1000;
    if (now_ms as i64) < next_allowed {
        let wait_s = ((next_allowed - now_ms as i64) + 999) / 1000;
        return Some(format!("Slow mode is on. Wait {wait_s}s before sending again"));
    }
    None
}

/// The step-4 conversion dispatch: read the user's quality tier, hop the CPU-heavy
/// image conversion onto the blocking pool, and re-enter the event loop via
/// NodeCommand::SendFileConverted when done.
#[allow(clippy::too_many_arguments)]
fn spawn_image_conversion(
    peer_id: Option<String>,
    server_id: Option<String>,
    channel_id: Option<String>,
    message_id: String,
    message_text: String,
    vthumb: Option<VideoThumbRef>,
    share_ref: Option<super::types::ShareRef>,
    original_name: String,
    is_image: bool,
    voice: bool,
    album: Option<String>,
    order_us: i64,
    file_data: Vec<u8>,
    original_ext: String,
    override_width: Option<u32>,
    override_height: Option<u32>,
    cmd_tx: mpsc::Sender<super::types::NodeCommand>,
    event_tx: mpsc::Sender<NetworkEvent>,
    db_path: &str,
    db_passphrase: &str,
) {
    let webp_quality = {
        crate::storage::MessageStore::open(db_path, db_passphrase)
            .ok()
            .and_then(|s| s.load_setting("image_quality").ok().flatten())
            .map(|s| image_convert::WebpQuality::from_setting(&s))
            .unwrap_or_default()
    };
    tokio::spawn(async move {
        let converted = tokio::task::spawn_blocking(move || {
            convert_image_for_send(file_data, &original_ext, webp_quality, override_width, override_height)
        })
        .await;
        let (final_data, final_ext, width, height, thumb) = match converted {
            Ok(Ok(((data, ext, w, h), thumb))) => (data, ext, w, h, thumb),
            Ok(Err(refused)) => {
                let _ = event_tx.send(NetworkEvent::FileFailed { file_id: message_id, error: refused }).await;
                return;
            }
            Err(e) => {
                // spawn_blocking join failure (panic in codec) — surface as a
                // failed send via the resume handler's empty-data guard.
                hollow_log!("[HOLLOW-FILE] Conversion task panicked: {e}");
                (Vec::new(), String::new(), None, None, None)
            }
        };
        let _ = cmd_tx
            .send(super::types::NodeCommand::SendFileConverted(Box::new(
                super::types::SendFileConvertedPayload {
                    peer_id, server_id, channel_id, message_id, message_text,
                    vthumb, share_ref, original_name, is_image,
                    final_data, final_ext, width, height,
                    thumb, voice, album, order_us,
                },
            )))
            .await;
    });
}

/// Steps 5+ of the original SendFile flow (file id, local store, metadata,
/// signing, DM/channel fan-out, streaming). Runs on the event loop; reached
/// either inline (non-image) or via SendFileConverted (converted image).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn finish_send_file(
    peer_id: Option<String>,
    server_id: Option<String>,
    channel_id: Option<String>,
    message_id: String,
    message_text: String,
    vthumb: Option<VideoThumbRef>,
    share_ref: Option<super::types::ShareRef>,
    original_name: String,
    is_image: bool,
    final_data: Vec<u8>,
    final_ext: String,
    width: Option<u32>,
    height: Option<u32>,
    thumb: Option<String>,
    voice: bool,
    album: Option<String>,
    // Taken when the send command arrived; see handle_send_file.
    order_us: i64,
    event_tx: &mpsc::Sender<NetworkEvent>,
    server_states: &HashMap<String, ServerState>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    // THIS device's keypair — signs the Olm key exchange (Fix A/B).
    device_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
    local_peer_str: &str,
    device_peer_id: &str,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    mls: &mut Option<MlsManager>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    webrtc_peers: &std::collections::HashSet<String>,
    pending_webrtc_sends: &mut HashMap<String, (String, ws_stream_transfer::StreamKind, String, PathBuf, u64)>,
    peer_auto_dl: &HashMap<String, u32>,
    gossip_overlays: &mut HashMap<String, gossip::GossipOverlay>,
    db_path: &str,
    db_passphrase: &str,
) {
    if final_data.is_empty() && share_ref.is_none() {
        // Conversion task panicked (empty sentinel from handle_send_file).
        let _ = event_tx.send(NetworkEvent::FileFailed {
            file_id: message_id.clone(),
            error: "Image conversion failed".to_string(),
        }).await;
        return;
    }

    let file_size = final_data.len() as u64;
    let Ok((final_data, sha256)) = tokio::task::spawn_blocking(move || {
        let sha256 = super::file_commit::sha256_hex(&final_data);
        (final_data, sha256)
    })
    .await
    else {
        let _ = event_tx.send(NetworkEvent::FileFailed {
            file_id: message_id.clone(),
            error: "Failed to hash the file".to_string(),
        }).await;
        return;
    };
    let file_id = super::file_commit::file_id_for(&super::file_commit::FileCommit {
        author: local_peer_str,
        mid: &message_id,
        size: file_size,
        sha256: &sha256,
        name: &original_name,
        ext: &final_ext,
        vthumb: vthumb.as_ref(),
    });
    let total_chunks = 0u32; // 0 = streamed transfer
    let final_mime = file_transfer::mime_from_ext(&final_ext);

    // Determine if this is a vault server (6+ members).
    let member_count = if let Some(ref sid) = server_id {
        server_states.get(sid).map(|s| s.members.len()).unwrap_or(0)
    } else {
        0
    };
    // Store full file locally for DMs, <6 servers, or images (need local preview).
    let store_full_file = server_id.is_none() || member_count < 6 || is_image;

    hollow_log!("[HOLLOW-FILE] File {file_id}: {file_size} bytes (streamed={store_full_file})");

    // 6. Store file locally (skip for non-image vault files — shards handle storage).
    let final_path = file_transfer::final_file_path(&file_id, &final_ext);
    if store_full_file {
        let dest = final_path.clone();
        let bytes = final_data.clone();
        let wrote = tokio::task::spawn_blocking(move || crate::node::at_rest::write_all(&dest, &bytes))
            .await
            .unwrap_or_else(|e| Err(format!("write task failed: {e}")));
        if let Err(e) = wrote {
            hollow_log!("[HOLLOW-FILE] Failed to save local file: {e}");
        }
    }

    let local_peer = local_peer_str.to_string();
    let timestamp = order_us / 1000;

    let ctx_type;
    let ctx_id;
    if let Some(ref sid) = server_id {
        ctx_type = "channel";
        ctx_id = format!("{}:{}", sid, channel_id.as_deref().unwrap_or(""));
    } else {
        ctx_type = "dm";
        ctx_id = peer_id.clone().unwrap_or_default();
    }

    persist_sent_file_row(
        db_path, db_passphrase,
        &file_id, &original_name, &final_ext, &final_mime,
        file_size, total_chunks, is_image, width, height,
        &message_id, ctx_type, &ctx_id, &local_peer, timestamp,
        vthumb.as_ref(), thumb.as_deref(), &sha256, store_full_file, &final_path,
    );

    // Emit FileCompleted on the sender side too, so the sender's UI reloads from the
    // DB and picks up the real width/height/videoThumb Rust wrote. Without it the
    // optimistic FileAttachment, built without dimensions, keeps the wrong size.
    // Receivers already get this via the stream-receive path.
    if store_full_file {
        let _ = event_tx.send(NetworkEvent::FileCompleted {
            file_id: file_id.clone(),
            disk_path: final_path.to_string_lossy().to_string(),
        }).await;
    }

    let signing_payload_text = if message_text.is_empty() {
        format!("[file:{}]", file_id)
    } else {
        message_text.clone()
    };

    // Sign using the canonical payload format, which must match
    // verify_message_signature on the receive path.
    let (sig, pk) = sign_file_message(
        &peer_id, &server_id, &channel_id, &local_peer, timestamp,
        &signing_payload_text, &message_id, &file_id, order_us, album.as_deref(),
        bundle_keypair, pub_key_b64,
    );

    if let Some(peer_str) = peer_id {
        // DM path. The companion caption / "[file:...]" DM is a DirectMessage; a
        // sibling self-echo must carry `convo` = the recipient master so our other
        // device files it under the right thread. The text row is stored keyed by
        // that same recipient MASTER id.
        persist_sent_dm_row(
            db_path, db_passphrase, &peer_str, &signing_payload_text,
            timestamp, sig.as_deref(), pk.as_deref(), &message_id, &file_id, order_us,
            album.as_deref(),
        );

        let msg = DmFileMsg {
            signing_payload_text: &signing_payload_text,
            timestamp,
            sig: &sig,
            pk: &pk,
            message_id: &message_id,
            file_id: &file_id,
            order_us,
            album: album.as_deref(),
            final_data: &final_data,
            original_name: &original_name,
            final_ext: &final_ext,
            final_mime: &final_mime,
            file_size,
            is_image,
            width,
            height,
            vthumb: &vthumb,
            thumb: &thumb,
            voice,
            share_ref: &share_ref,
            message_text: &message_text,
            local_peer_str,
            sha256: &sha256,
            total_chunks,
            device_keypair,
            device_peer_id,
        };
        send_dm_file_fanout(
            &peer_str, &msg, device_peer_id,
            olm, crypto_store, event_tx, ws_cmd_tx, ws_room_peers,
            webrtc_peers, pending_webrtc_sends, peer_auto_dl,
        ).await;
    } else if let (Some(sid), Some(cid)) = (server_id, channel_id) {
        // Channel path — broadcast via MLS.
        send_channel_file(
            &sid, &cid, &signing_payload_text, timestamp, &sig, &pk,
            &message_id, &file_id, order_us, album.as_deref(), &final_data,
            &original_name, &final_ext, &final_mime, file_size, &sha256,
            is_image, width, height, &vthumb, &thumb, voice, &share_ref, &local_peer, device_peer_id,
            event_tx, server_states, olm, crypto_store, mls,
            ws_cmd_tx, ws_room_peers, webrtc_peers, pending_webrtc_sends,
            gossip_overlays, db_path, db_passphrase,
        ).await;
    }
}

/// Sign the file message with the canonical signing payload for its context (DM =
/// recipient, channel = "sid:cid"); no context means unsigned. The v2 signature
/// binds mid, file_id and order_us exactly as they ride the companion envelope
/// (file sends carry no reply_to and no link preview).
#[allow(clippy::too_many_arguments)]
fn sign_file_message(
    peer_id: &Option<String>,
    server_id: &Option<String>,
    channel_id: &Option<String>,
    local_peer: &str,
    timestamp: i64,
    signing_payload_text: &str,
    message_id: &str,
    file_id: &str,
    order_us: i64,
    album: Option<&str>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
) -> (Option<String>, Option<String>) {
    let extras = crate::node::crypto_handler::SignedExtras {
        mid: Some(message_id),
        reply_to: None,
        file_id: Some(file_id),
        order_us: Some(order_us),
        lp_digest: None,
        album,
    };
    if let Some(peer_str) = peer_id {
        // DM: context = recipient, sender = local
        crate::node::crypto_handler::sign_message_versioned(
            bundle_keypair, pub_key_b64, "dm", peer_str, local_peer,
            timestamp, &extras, signing_payload_text,
        )
    } else if let (Some(sid), Some(cid)) = (server_id, channel_id) {
        // Channel: context = server_id:channel_id, sender = local
        crate::node::crypto_handler::sign_message_versioned(
            bundle_keypair, pub_key_b64, "ch", &format!("{sid}:{cid}"), local_peer,
            timestamp, &extras, signing_payload_text,
        )
    } else {
        (None, None)
    }
}

/// Sync DB write for the sender's own file metadata row (+ completion when the
/// full file is stored locally). Sync on purpose — the store is never held
/// across an .await (Connection is !Sync).
#[allow(clippy::too_many_arguments)]
fn persist_sent_file_row(
    db_path: &str,
    db_passphrase: &str,
    file_id: &str,
    original_name: &str,
    final_ext: &str,
    final_mime: &str,
    file_size: u64,
    total_chunks: u32,
    is_image: bool,
    width: Option<u32>,
    height: Option<u32>,
    message_id: &str,
    ctx_type: &str,
    ctx_id: &str,
    local_peer: &str,
    timestamp: i64,
    vthumb: Option<&VideoThumbRef>,
    thumb: Option<&str>,
    sha256: &str,
    store_full_file: bool,
    final_path: &std::path::Path,
) {
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let _ = store.insert_file_metadata(
            file_id, original_name, final_ext, final_mime,
            file_size, total_chunks, is_image,
            width, height,
            Some(message_id), ctx_type, ctx_id,
            local_peer, true, timestamp,
            vthumb, thumb, Some(sha256),
        );
        if store_full_file {
            let _ = store.mark_file_complete(
                file_id,
                &final_path.to_string_lossy(),
            );
        }
    }
}

/// Sync DB write for the sender's own DM text row (caption / "[file:...]").
#[allow(clippy::too_many_arguments)]
fn persist_sent_dm_row(
    db_path: &str,
    db_passphrase: &str,
    peer_str: &str,
    text: &str,
    timestamp: i64,
    sig: Option<&str>,
    pk: Option<&str>,
    message_id: &str,
    file_id: &str,
    order_us: i64,
    album: Option<&str>,
) {
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let _ = store.insert(
            peer_str, text, true, timestamp,
            sig, pk, Some(message_id),
            None, Some(file_id), Some(order_us), album,
        );
    }
}

/// Immutable per-message data shared by every DM file fan-out target. Carries
/// NO node state and NO &mut borrows (see feedback_swarmcontext_borrow) — the
/// mutable state (olm, pending maps) is passed to each helper individually.
struct DmFileMsg<'a> {
    signing_payload_text: &'a str,
    timestamp: i64,
    sig: &'a Option<String>,
    pk: &'a Option<String>,
    message_id: &'a str,
    file_id: &'a str,
    order_us: i64,
    album: Option<&'a str>,
    final_data: &'a [u8],
    original_name: &'a str,
    final_ext: &'a str,
    final_mime: &'a str,
    file_size: u64,
    is_image: bool,
    width: Option<u32>,
    height: Option<u32>,
    vthumb: &'a Option<VideoThumbRef>,
    /// Tiny base64 WebP blurred-placeholder thumbnail (issue #41 carry-over).
    thumb: &'a Option<String>,
    /// Recorded voice message — exempt from all auto-download gating.
    voice: bool,
    /// The Hollow Share that carries a file over the direct cap: its header goes
    /// out alone, with no key and no bytes.
    share_ref: &'a Option<super::types::ShareRef>,
    message_text: &'a str,
    local_peer_str: &'a str,
    /// Plaintext SHA-256 the file id commits to.
    sha256: &'a str,
    total_chunks: u32,
    // THIS device's identity — signs the Olm KeyRequest fired when a DM file
    // targets a device we have no session with (Fix B).
    device_keypair: &'a crate::identity::native_identity::NativeKeypair,
    device_peer_id: &'a str,
}

/// Shared DM FileHeader builder — every DM header uses chunks=0 (streamed),
/// sid/cid=None, target=None; the varying fields (signature, AES material, inline
/// bytes) are parameterized per branch.
fn build_dm_file_header(
    msg: &DmFileMsg<'_>,
    sig: Option<String>,
    pk: Option<String>,
    aes_key: Option<String>,
    aes_nonce: Option<String>,
    inline_bytes: Option<String>,
) -> MessageEnvelope {
    MessageEnvelope::FileHeader {
        inner: Box::new(FileHeaderPayload {
            fid: msg.file_id.to_string(),
            name: msg.original_name.to_string(),
            ext: msg.final_ext.to_string(),
            mime: msg.final_mime.to_string(),
            size: msg.file_size,
            chunks: 0,
            img: msg.is_image,
            w: msg.width,
            h: msg.height,
            mid: Some(msg.message_id.to_string()),
            sid: None,
            cid: None,
            ts: msg.timestamp,
            sig,
            pk,
            aes_key,
            aes_nonce,
            target: None,
            vthumb: msg.vthumb.clone(),
            share_ref: msg.share_ref.clone(),
            order_us: Some(msg.order_us),
            album: msg.album.map(str::to_owned),
            inline_bytes,
            thumb: msg.thumb.clone(),
            voice: msg.voice,
            author: Some(msg.local_peer_str.to_string()),
            sha256: Some(msg.sha256.to_string()),
        }),
    }
}

/// ── Multi-device fan-out (Phase 6, Step 3) ──────────────────────
/// `peer_str` is the recipient's MASTER id. The companion DM caption, FileHeader
/// and (online) WebRTC stream all key on per-DEVICE Olm sessions and room
/// membership, so each of the recipient's devices AND our own siblings gets a
/// delivery. The DELICATE offline-image caption ratchet rule (send exactly once
/// via send_encrypted_text_to_peer, never send_encrypted_message) holds PER
/// DEVICE, since each device has its own Olm ratchet.
#[allow(clippy::too_many_arguments)]
async fn send_dm_file_fanout(
    peer_str: &str,
    msg: &DmFileMsg<'_>,
    device_peer_id: &str,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    webrtc_peers: &std::collections::HashSet<String>,
    pending_webrtc_sends: &mut HashMap<String, (String, ws_stream_transfer::StreamKind, String, PathBuf, u64)>,
    peer_auto_dl: &HashMap<String, u32>,
) {
    let recipient_master = crate::node::resolver::resolve(peer_str);
    // Self-DM ("Saved messages"): local store + FileCompleted already
    // happened above; fan-out is siblings-only (no recipient push, no
    // bare-master fallback target).
    let self_dm = crate::node::resolver::same_identity(peer_str, msg.local_peer_str);
    let dm_room_f = crate::node::types::dm_room_code(msg.local_peer_str, &recipient_master);
    let file_targets = collect_dm_file_targets(
        peer_str, device_peer_id, &recipient_master, self_dm, &dm_room_f,
        msg.local_peer_str, ws_room_peers, olm,
    );
    hollow_log!(
        "[HOLLOW-MULTIDEV] DM file fan-out for master {peer_str}: {} target device(s)",
        file_targets.len()
    );

    for target in &file_targets {
        send_dm_file_to_device(
            target, &recipient_master, &dm_room_f, msg,
            olm, crypto_store, event_tx, ws_cmd_tx, ws_room_peers,
            webrtc_peers, pending_webrtc_sends, peer_auto_dl,
        ).await;
    }
}

/// Sender-side pre-negotiation: `true` when the target device ADVERTISED an
/// auto-download preference this push would violate, so stream nothing and send a
/// metadata-only header instead. Voice notes are never gated. No advert means push
/// as before, and the receiver's own gate still enforces.
fn receiver_pref_declines(peer_auto_dl: &HashMap<String, u32>, peer_str: &str, msg: &DmFileMsg<'_>) -> bool {
    if is_voice_note_exempt(msg.file_size, msg.original_name, msg.final_ext, msg.voice) {
        return false;
    }
    match peer_auto_dl.get(peer_str) {
        Some(mb) => *mb == 0 || msg.file_size > (*mb as u64) * 1024 * 1024,
        None => false,
    }
}

/// Compute the per-device target set for a DM file send: the persisted device list
/// UNION the devices currently in the DM room, because live presence is
/// authoritative and a stale list must not hide the connected device.
#[allow(clippy::too_many_arguments)]
fn collect_dm_file_targets(
    peer_str: &str,
    device_peer_id: &str,
    recipient_master: &str,
    self_dm: bool,
    dm_room_f: &str,
    local_peer_str: &str,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    olm: &OlmManager,
) -> Vec<String> {
    // LIVENESS-FILTERED (mirrors message_ops::collect_target_devices): only target
    // stored devices CURRENTLY IN A ROOM. A dead ghost id has a stale session but is
    // in no room, so without this it takes the offline room-send path and fires a
    // spurious push and unread on a phantom device.
    let mut file_set: std::collections::HashSet<String> =
        crate::node::resolver::devices_for(recipient_master)
            .into_iter()
            .filter(|d| ws_room_for_peer(ws_room_peers, d).is_some())
            .collect();
    // Offline-but-real RECIPIENT devices: a real device that is offline but we hold
    // an Olm session with, so the offline image path buffers under it and pushes its
    // token. Recipient only, never our own siblings.
    if !self_dm {
        for d in crate::node::resolver::devices_for(recipient_master) {
            if ws_room_for_peer(ws_room_peers, &d).is_none() && olm.has_session(&d) {
                file_set.insert(d);
            }
        }
    }
    let own_master_f = crate::node::resolver::resolve(local_peer_str);
    for sib in crate::node::resolver::devices_for(&own_master_f) {
        if ws_room_for_peer(ws_room_peers, &sib).is_some() {
            file_set.insert(sib);
        }
    }
    insert_dm_room_live_members(&mut file_set, ws_room_peers, dm_room_f, recipient_master, &own_master_f);
    file_set.remove(device_peer_id);      // never send to ourselves
    file_set.remove(recipient_master);    // never the bare master
    file_set.remove(&own_master_f);
    let mut file_targets: Vec<String> = file_set.into_iter().collect();
    if file_targets.is_empty() && !self_dm {
        // Single-device recipient with no live device → master id as-is.
        file_targets.push(peer_str.to_string());
    }
    file_targets
}

/// Union in the live DM-room members that belong to either side of the
/// conversation (recipient's devices or our own siblings).
fn insert_dm_room_live_members(
    file_set: &mut std::collections::HashSet<String>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    dm_room_f: &str,
    recipient_master: &str,
    own_master_f: &str,
) {
    if let Some(peers) = ws_room_peers.get(dm_room_f) {
        for p in peers {
            let m = crate::node::resolver::resolve(p);
            if m == recipient_master || m == own_master_f {
                file_set.insert(p.clone());
            }
        }
    }
}

/// Deliver one DM file send to a single target DEVICE: the companion caption DM,
/// the FileHeader and the encrypted bytes, branching on live stream, offline image
/// (inline 0x08), offline file (metadata-only card) and no-Olm-session.
#[allow(clippy::too_many_arguments)]
async fn send_dm_file_to_device(
    peer_str: &str,
    recipient_master: &str,
    dm_room_f: &str,
    msg: &DmFileMsg<'_>,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    webrtc_peers: &std::collections::HashSet<String>,
    pending_webrtc_sends: &mut HashMap<String, (String, ws_stream_transfer::StreamKind, String, PathBuf, u64)>,
    peer_auto_dl: &HashMap<String, u32>,
) {
    // Per-device companion DM envelope: a sibling self-echo carries `convo`
    // (recipient master) so it files under the right thread; the recipient's
    // own devices get the plain envelope (convo=None).
    let is_sibling_target = crate::node::resolver::same_identity(peer_str, msg.local_peer_str);
    let envelope = MessageEnvelope::DirectMessage {
        inner: Box::new(DirectMessagePayload {
            text: msg.signing_payload_text.to_string(),
            ts: msg.timestamp,
            sig: msg.sig.clone(),
            pk: msg.pk.clone(),
            mid: Some(msg.message_id.to_string()),
            reply_to: None,
            file_id: Some(msg.file_id.to_string()),
            link_preview: None,
            convo: if is_sibling_target { Some(recipient_master.to_string()) } else { None },
            order_us: Some(msg.order_us),
            album: msg.album.map(str::to_owned),
        }),
    };
    let envelope_json = serde_json::to_string(&envelope)
        .unwrap_or_else(|_| msg.signing_payload_text.to_string());
    if olm.has_session(peer_str) {
        // EXACT-device reachability, not identity-wide: in a fan-out one device may
        // be online while a sibling is offline.
        let reachable = ws_room_for_peer(ws_room_peers, peer_str).is_some();

        // `send_encrypted_message` encrypts BEFORE it checks reachability and
        // DISCARDS the ciphertext for a peer in no room, so for an OFFLINE IMAGE the
        // caption would never arrive. The skipped ratchet step costs the receiver
        // nothing else: Olm steps over a gap, and only a key already used or
        // discarded is missing. So when offline-and-image the caption is sent exactly
        // once inside send_offline_dm_image, AFTER the inlined FileHeader.
        if reachable {
            send_encrypted_message(
                olm, crypto_store,
                peer_str, &envelope_json, event_tx,
                ws_cmd_tx, ws_room_peers,
            ).await;
        } else if !msg.is_image {
            // OFFLINE non-image: target the MASTER-pair DM room directly (0x04, text
            // cap) so the relay's offline buffer holds the caption.
            // `send_encrypted_message` would encrypt and then DISCARD for a peer in
            // no known room: a wasted ratchet slot and nothing buffered.
            crate::node::crypto_handler::send_encrypted_text_to_peer(
                olm, crypto_store,
                peer_str, dm_room_f.to_string(), &envelope_json, event_tx,
                ws_cmd_tx,
            ).await;
        }

        // Only send file data if peer is reachable right now.
        // If offline, the file_id is in the message — sync will request it later.
        if reachable && (msg.share_ref.is_some() || receiver_pref_declines(peer_auto_dl, peer_str, msg)) {
            // Sender-side pre-negotiation: this device ADVERTISED a threshold this
            // push would violate, so its gate would decline the header and discard
            // every byte. The metadata-only header renders the card with a manual
            // Download button, and the explicit FileRequest pull still works. A
            // share-backed file goes the same way: the Share delivers its bytes.
            hollow_log!(
                "[HOLLOW-FILE] Metadata-only header for {} ({} bytes, share {}) to {peer_str}, no bytes",
                msg.file_id, msg.file_size, msg.share_ref.is_some()
            );
            let header = build_dm_file_header(
                msg, msg.sig.clone(), msg.pk.clone(),
                None, None, None,
            );
            let header_json = serde_json::to_string(&header).unwrap_or_default();
            send_encrypted_message(
                olm, crypto_store,
                peer_str, &header_json, event_tx,
                ws_cmd_tx, ws_room_peers,
            ).await;
        } else if reachable {
            stream_dm_file_live(
                peer_str, msg, olm, crypto_store, event_tx,
                ws_cmd_tx, ws_room_peers, webrtc_peers, pending_webrtc_sends,
            ).await;
        } else if msg.is_image && msg.share_ref.is_none() {
            if receiver_pref_declines(peer_auto_dl, peer_str, msg) {
                // Pre-negotiation, offline-image variant: the device advertised a
                // gating threshold before it went offline, so do not inline bytes
                // into a relay buffer it would only discard. The companion envelope
                // is buffered FIRST (a metadata-only header creates no message row),
                // then the card; both rides go through send_encrypted_text_to_peer,
                // so the Olm ratchet has no gap.
                hollow_log!(
                    "[HOLLOW-FILE] Receiver pref gates offline image {} for {peer_str} — buffering metadata-only card",
                    msg.file_id
                );
                crate::node::crypto_handler::send_encrypted_text_to_peer(
                    olm, crypto_store,
                    peer_str, dm_room_f.to_string(), &envelope_json, event_tx,
                    ws_cmd_tx,
                ).await;
                send_offline_dm_file_meta(
                    peer_str, dm_room_f, msg,
                    olm, crypto_store, event_tx, ws_cmd_tx,
                ).await;
            } else {
                send_offline_dm_image(
                    peer_str, dm_room_f, &envelope_json, msg,
                    olm, crypto_store, event_tx, ws_cmd_tx,
                ).await;
            }
        } else {
            send_offline_dm_file_meta(
                peer_str, dm_room_f, msg,
                olm, crypto_store, event_tx, ws_cmd_tx,
            ).await;
        }
    } else if ws_room_for_peer(ws_room_peers, peer_str).is_some() {
        // No Olm session with this device yet. The text-DM path queues and
        // KeyRequests here, but a FILE cannot ride the pending-envelope queue, so
        // kick off the session and let the normal heal paths deliver the content
        // later. Without this the target device got NOTHING, no queue and no key
        // exchange, until unrelated traffic happened to establish the session.
        hollow_log!("[HOLLOW-FILE] No session for DM file target {peer_str} — sending KeyRequest");
        send_message_to_peer(
            ws_cmd_tx, ws_room_peers,
            peer_str,
            crate::node::crypto_handler::signed_key_request(
                msg.device_keypair, msg.device_peer_id, peer_str,
            ),
        );
    }

    hollow_log!("[HOLLOW-FILE] Sent {} chunks for {} to DM {peer_str}", msg.total_chunks, msg.file_id);
}

/// Live DM branch: AES-encrypt to a per-device temp, Olm-send the FileHeader
/// (carries the AES key — tiny, secure), then stream the ciphertext via
/// WebRTC data channel or WS relay.
#[allow(clippy::too_many_arguments)]
async fn stream_dm_file_live(
    peer_str: &str,
    msg: &DmFileMsg<'_>,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    webrtc_peers: &std::collections::HashSet<String>,
    pending_webrtc_sends: &mut HashMap<String, (String, ws_stream_transfer::StreamKind, String, PathBuf, u64)>,
) {
    let encrypted = crate::vault::pipeline::aes_encrypt(msg.final_data);
    if let Ok(enc) = encrypted {
        // Per-device temp file: sibling devices may stream the same
        // file_id concurrently, so the ciphertext temp must not collide.
        let temp_path = file_transfer::files_dir().join(format!(".stream_send_{}_{peer_str}.tmp", msg.file_id));
        if let Ok(()) = tokio::fs::write(&temp_path, &enc.ciphertext).await {
            let header = build_dm_file_header(
                msg, None, None,
                Some(hex::encode(enc.key)), Some(hex::encode(enc.nonce)),
                None,
            );
            let header_json = serde_json::to_string(&header).unwrap_or_default();
            send_encrypted_message(
                olm, crypto_store,
                peer_str, &header_json, event_tx,
                ws_cmd_tx, ws_room_peers,
            ).await;

            stream_to_peer(
                ws_cmd_tx, ws_room_peers,
                webrtc_peers, pending_webrtc_sends, event_tx,
                peer_str, &ws_stream_transfer::StreamKind::File,
                &file_stream_id(msg.file_id, msg.device_peer_id, peer_str),
                &temp_path, enc.ciphertext.len() as u64,
            ).await;
            hollow_log!("[HOLLOW-FILE] Streaming {} ({} bytes) to DM {peer_str}", msg.file_id, enc.ciphertext.len());
            let _ = tokio::fs::remove_file(&temp_path).await;
        }
    }
}

/// Peer is OFFLINE and this is an image: inline the AES-encrypted bytes INTO the
/// FileHeader and send via SendDirectImage (0x08), so the relay buffers it under
/// the per-peer image cap and the FCM fetch node renders a real preview with no
/// live stream. Larger non-image files still fall back to request-on-open.
#[allow(clippy::too_many_arguments)]
async fn send_offline_dm_image(
    peer_str: &str,
    dm_room_f: &str,
    envelope_json: &str,
    msg: &DmFileMsg<'_>,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
) {
    if let Ok(enc) = crate::vault::pipeline::aes_encrypt(msg.final_data) {
        // Carry the signature on the offline-image FileHeader. For a CAPTIONLESS
        // image this is the ONLY transmitted signature, signed over the same
        // "[file:...]" text the fetch node stores, so the row verifies instead of
        // showing "Unsigned". A CAPTIONED image's caption DM carries its own and
        // overwrites this.
        let header = build_dm_file_header(
            msg, msg.sig.clone(), msg.pk.clone(),
            Some(hex::encode(enc.key)), Some(hex::encode(enc.nonce)),
            Some(
                base64::engine::general_purpose::STANDARD
                    .encode(&enc.ciphertext),
            ),
        );
        let header_json = serde_json::to_string(&header).unwrap_or_default();
        // Target the MASTER-pair DM room directly (computed once by the fan-out):
        // the offline peer is in no known room, so a lookup would drop the message,
        // and `dm_room_code` must NOT be recomputed from the per-device `peer_str`,
        // which would key the room on the device rather than the identity.
        crate::node::crypto_handler::send_encrypted_image_to_peer(
            olm, crypto_store,
            peer_str, dm_room_f.to_string(), &header_json, event_tx,
            ws_cmd_tx,
        ).await;
        hollow_log!("[HOLLOW-FILE] Inlined offline image {} ({} enc bytes) to DM {peer_str}", msg.file_id, enc.ciphertext.len());

        // If this image has a CAPTION, send it now, exactly once and AFTER the
        // FileHeader, straight to the DM room. Its normal send was skipped in
        // send_dm_file_to_device to avoid a wasted Olm encryption that would corrupt
        // the ratchet. It shares the FileHeader's message_id, so the fetch node
        // merges them and the offline peer sees the captioned image.
        if !msg.message_text.is_empty() {
            crate::node::crypto_handler::send_encrypted_text_to_peer(
                olm, crypto_store,
                peer_str, dm_room_f.to_string(), envelope_json, event_tx,
                ws_cmd_tx,
            ).await;
            hollow_log!("[HOLLOW-FILE] Buffered offline image caption for DM {peer_str}");
        }
    }
}

/// OFFLINE non-image file: send a METADATA-ONLY FileHeader to the DM room (0x04,
/// text cap) so the relay's offline buffer carries the file card, never the bytes.
/// No aes_key/nonce means the receiver inserts metadata without registering a
/// pending stream and fetches the bytes via the normal request-on-open path.
async fn send_offline_dm_file_meta(
    peer_str: &str,
    dm_room_f: &str,
    msg: &DmFileMsg<'_>,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
) {
    // Carry the signature so a captionless file row verifies instead of
    // showing "Unsigned" (mirrors the offline-image header).
    let header = build_dm_file_header(
        msg, msg.sig.clone(), msg.pk.clone(),
        None, None, None,
    );
    let header_json = serde_json::to_string(&header).unwrap_or_default();
    crate::node::crypto_handler::send_encrypted_text_to_peer(
        olm, crypto_store,
        peer_str, dm_room_f.to_string(), &header_json, event_tx,
        ws_cmd_tx,
    ).await;
    hollow_log!("[HOLLOW-FILE] Buffered metadata-only FileHeader {} for offline DM {peer_str}", msg.file_id);
}

/// Sync DB write for the sender's own channel text row (caption / "[file:...]").
#[allow(clippy::too_many_arguments)]
fn persist_sent_channel_row(
    db_path: &str,
    db_passphrase: &str,
    sid: &str,
    cid: &str,
    local_peer: &str,
    text: &str,
    timestamp: i64,
    sig: Option<&str>,
    pk: Option<&str>,
    message_id: &str,
    file_id: &str,
    order_us: i64,
    album: Option<&str>,
) {
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let _ = store.insert_channel_message(
            sid, cid, local_peer, text, true, timestamp,
            sig, pk, Some(message_id),
            None, Some(file_id), Some(order_us), album,
        );
    }
}

/// Channel file send: persist the caption row, MLS-broadcast the text message and
/// FileHeader over the channel topic, then distribute the encrypted bytes (share
/// skip, vault shards, gossip tree, or small-server full replication).
#[allow(clippy::too_many_arguments)]
async fn send_channel_file(
    sid: &str,
    cid: &str,
    signing_payload_text: &str,
    timestamp: i64,
    sig: &Option<String>,
    pk: &Option<String>,
    message_id: &str,
    file_id: &str,
    order_us: i64,
    album: Option<&str>,
    final_data: &[u8],
    original_name: &str,
    final_ext: &str,
    final_mime: &str,
    file_size: u64,
    sha256: &str,
    is_image: bool,
    width: Option<u32>,
    height: Option<u32>,
    vthumb: &Option<VideoThumbRef>,
    thumb: &Option<String>,
    voice: bool,
    share_ref: &Option<super::types::ShareRef>,
    local_peer: &str,
    device_peer_id: &str,
    event_tx: &mpsc::Sender<NetworkEvent>,
    server_states: &HashMap<String, ServerState>,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    mls: &mut Option<MlsManager>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    webrtc_peers: &std::collections::HashSet<String>,
    pending_webrtc_sends: &mut HashMap<String, (String, ws_stream_transfer::StreamKind, String, PathBuf, u64)>,
    gossip_overlays: &mut HashMap<String, gossip::GossipOverlay>,
    db_path: &str,
    db_passphrase: &str,
) {
    let envelope = MessageEnvelope::ChannelMessage {
        inner: Box::new(ChannelMessagePayload {
            sid: sid.to_string(),
            cid: cid.to_string(),
            text: signing_payload_text.to_string(),
            ts: timestamp,
            sig: sig.clone(),
            pk: pk.clone(),
            mid: Some(message_id.to_string()),
            reply_to: None,
            file_id: Some(file_id.to_string()),
            link_preview: None,
            order_us: Some(order_us),
            album: album.map(str::to_owned),
        }),
    };

    persist_sent_channel_row(
        db_path, db_passphrase, sid, cid, local_peer, signing_payload_text,
        timestamp, sig.as_deref(), pk.as_deref(), message_id, file_id, order_us, album,
    );

    // Send the TEXT MESSAGE via the MLS TOPIC broadcast, the SAME path normal
    // channel text takes. Targeted per-member direct sends silently skipped every
    // OFFLINE member and never entered the relay's per-channel offline ring, so
    // catch-up replayed the FileHeader with no message row to hang it on and the
    // chat showed NOTHING. Restricted channels encrypt under the subgroup.
    //
    // PUBLIC channels mirror message_ops' text branch: plaintext
    // `PublicChannelMessage` carrying `file_meta`, so guests can render the file
    // card live. Members ignore `file_meta` and dedup the row by message_id.
    let is_public_channel = server_states
        .get(sid)
        .is_some_and(|s| s.is_channel_public(cid));
    if is_public_channel {
        let msg = HavenMessage::PublicChannelMessage {
            server_id: sid.to_string(),
            channel_id: cid.to_string(),
            text: signing_payload_text.to_string(),
            ts: timestamp,
            sig: sig.clone(),
            pk: pk.clone(),
            mid: message_id.to_string(),
            reply_to: None,
            file_id: Some(file_id.to_string()),
            link_preview: None,
            order_us: Some(order_us),
            album: album.map(|a| Box::new(a.to_owned())),
            file_meta: Some(super::types::SyncFileMetaItem {
                fid: file_id.to_string(),
                name: original_name.to_string(),
                ext: final_ext.to_string(),
                mime: final_mime.to_string(),
                size: file_size,
                img: is_image,
                w: width,
                h: height,
                mid: Some(message_id.to_string()),
                ts: timestamp,
                sender: local_peer.to_string(),
                vthumb: vthumb.clone(),
                thumb: thumb.clone(),
                sha256: Some(sha256.to_string()),
            }),
        };
        if let Some(server) = server_states.get(sid) {
            super::message_ops::send_public_channel_msg(ws_cmd_tx, server, cid, &msg);
        }
    } else {
        broadcast_channel_caption_mls(mls, server_states, ws_cmd_tx, crypto_store, sid, cid, &envelope);
    }

    // Skip full-file streaming in erasure coding mode (6+ members): vault shards
    // are distributed separately via VaultUploadFile.
    let member_count = server_states.get(sid)
        .map(|s| s.members.len())
        .unwrap_or(0);
    // Stream images to online peers even in vault mode (instant display).
    // Non-image files in 6+ servers use vault shards only, except in a restricted
    // channel, which the vault never takes.
    let restricted = server_states.get(sid).is_some_and(|s| s.channel_uses_subgroup(cid));
    let use_vault_only = member_count >= 6 && !is_image && !restricted;

    let has_share_ref = share_ref.is_some();

    let Some((aes_key_hex, aes_nonce_hex, temp_path, ct_size)) =
        prepare_channel_file_ciphertext(use_vault_only, has_share_ref, final_data, file_id).await
    else {
        return;
    };

    let header = MessageEnvelope::FileHeader {
        inner: Box::new(FileHeaderPayload {
            fid: file_id.to_string(),
            name: original_name.to_string(),
            ext: final_ext.to_string(),
            mime: final_mime.to_string(),
            size: file_size,
            chunks: 0,
            img: is_image,
            w: width,
            h: height,
            mid: Some(message_id.to_string()),
            sid: Some(sid.to_string()),
            cid: Some(cid.to_string()),
            ts: timestamp,
            sig: None,
            pk: None,
            aes_key: Some(aes_key_hex),
            aes_nonce: Some(aes_nonce_hex),
            target: None,
            vthumb: vthumb.clone(),
            share_ref: share_ref.clone(),
            order_us: Some(order_us),
            album: album.map(str::to_owned),
            inline_bytes: None,
            thumb: thumb.clone(),
            voice,
            author: Some(local_peer.to_string()),
            sha256: Some(sha256.to_string()),
        }),
    };
    let header_json = serde_json::to_string(&header).unwrap_or_default();

    if let Some(state) = server_states.get(sid) {
        broadcast_channel_file_header(
            state, mls, olm, crypto_store, ws_cmd_tx, ws_room_peers, event_tx,
            sid, cid, &header, &header_json, local_peer,
        ).await;

        if has_share_ref {
            hollow_log!("[HOLLOW-FILE] Share-backed file {file_id} — skipping binary streaming");
        } else if use_vault_only {
            hollow_log!("[HOLLOW-FILE] Erasure coding active ({member_count} members) — skipping full-file streaming, vault handles shard distribution");
        } else if gossip_overlays.contains_key(sid) {
            // Members of a server this size pull the bytes from whoever holds them.
            let _ = tokio::fs::remove_file(&temp_path).await;
        } else {
            replicate_channel_file_full(
                state, ws_cmd_tx, ws_room_peers, webrtc_peers,
                pending_webrtc_sends, event_tx, local_peer, device_peer_id, cid, file_id,
                &temp_path, ct_size,
            ).await;
        }
    }

    hollow_log!("[HOLLOW-FILE] Streamed {file_id} to channel {cid}");
}

/// MLS topic broadcast for the channel caption/text message; subgroup-aware,
/// mirroring message_ops' channel text sends.
fn broadcast_channel_caption_mls(
    mls: &mut Option<MlsManager>,
    server_states: &HashMap<String, ServerState>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    crypto_store: &CryptoStore,
    sid: &str,
    cid: &str,
    envelope: &MessageEnvelope,
) {
    if let Some(mls_mgr) = mls {
        let server = server_states.get(sid);
        let use_subgroup = server.is_some_and(|s| s.channel_uses_subgroup(cid));
        let ring = server.map_or_else(|| cid.to_string(), |s| super::ring_auth::topic(s, cid));
        let group_key = if use_subgroup {
            crate::crypto::subgroup_id(sid, cid)
        } else {
            sid.to_string()
        };
        if mls_mgr.has_group(&group_key) {
            if let Err(e) = send_mls_broadcast_topic(mls_mgr, ws_cmd_tx, sid, cid, &ring, use_subgroup, envelope, crypto_store, server) {
                hollow_log!("[HOLLOW-MLS] Channel file message broadcast failed: {e}");
            }
        }
    }
}

/// AES material and sender-side ciphertext temp for a channel file send. Vault-only
/// mode generates key and nonce WITHOUT encrypting; share-backed sends skip writing
/// the temp. None after logging when AES setup fails, and the caller aborts.
async fn prepare_channel_file_ciphertext(
    use_vault_only: bool,
    has_share_ref: bool,
    final_data: &[u8],
    file_id: &str,
) -> Option<(String, String, PathBuf, u64)> {
    if use_vault_only {
        match crate::vault::pipeline::aes_generate_key_nonce() {
            Ok((key, nonce)) => {
                let temp_path = file_transfer::files_dir().join(format!(".stream_send_{file_id}.tmp"));
                Some((hex::encode(key), hex::encode(nonce), temp_path, 0u64))
            }
            Err(e) => {
                hollow_log!("[HOLLOW-FILE] AES key generation failed: {e}");
                None
            }
        }
    } else {
        match crate::vault::pipeline::aes_encrypt(final_data) {
            Ok(enc) => {
                let key_hex = hex::encode(&enc.key);
                let nonce_hex = hex::encode(&enc.nonce);
                let temp_path = file_transfer::files_dir().join(format!(".stream_send_{file_id}.tmp"));
                if !has_share_ref {
                    let _ = tokio::fs::write(&temp_path, &enc.ciphertext).await;
                }
                let ct_size = if has_share_ref { 0 } else { enc.ciphertext.len() as u64 };
                Some((key_hex, nonce_hex, temp_path, ct_size))
            }
            Err(e) => {
                hollow_log!("[HOLLOW-FILE] AES encryption failed: {e}");
                None
            }
        }
    }
}

/// Broadcast the channel FileHeader via MLS over the CHANNEL TOPIC (0x07), like the
/// channel text path: subgroup-aware, and the relay tees topic frames into the
/// per-channel offline ring, which a 0x03 room broadcast never reached, so buffered
/// channel files used to render a caption with no file card.
#[allow(clippy::too_many_arguments)]
async fn broadcast_channel_file_header(
    state: &ServerState,
    mls: &mut Option<MlsManager>,
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sid: &str,
    cid: &str,
    header: &MessageEnvelope,
    header_json: &str,
    local_peer: &str,
) {
    let use_subgroup = state.channel_uses_subgroup(cid);
    let group_key = if use_subgroup {
        crate::crypto::subgroup_id(sid, cid)
    } else {
        sid.to_string()
    };
    let mls_ok = mls.as_ref().is_some_and(|m| m.has_group(&group_key));
    if mls_ok
        && let Err(e) = send_mls_broadcast_topic(
            mls.as_mut().unwrap(), ws_cmd_tx, sid, cid, &super::ring_auth::topic(state, cid), use_subgroup, header, crypto_store, Some(state),
        )
    {
        hollow_log!("[HOLLOW-MLS] FileHeader broadcast failed: {e}");
    }
    // PLUS the Olm copy to exactly the online member devices with no leaf in the
    // group we just encrypted under. Measuring OUR OWN encrypt says nothing about
    // whether a member can decrypt: one with no leaf, a just-admitted parked joiner,
    // saw the caption with no file card at all, forever. A fully formed group costs
    // zero extra frames, because the leaf-less set is then empty.
    //
    // `group_key` is the SUBGROUP id for a restricted channel, so leaf-less is
    // measured against the group that actually carried the header; a member who does
    // not qualify is not leaf-less, they must never receive it, hence the filter.
    let leafless = if use_subgroup {
        super::crypto_handler::leafless_member_devices_where(
            mls, &group_key, state, ws_room_peers, local_peer,
            |master| state.can_see_channel(master, cid),
        )
    } else {
        super::crypto_handler::leafless_member_devices(
            mls, &group_key, state, ws_room_peers, local_peer,
        )
    };
    if !leafless.is_empty() {
        olm_fallback_channel_file_header(
            olm, crypto_store, ws_cmd_tx, ws_room_peers, event_tx,
            header_json, &leafless,
        ).await;
    }
}

/// Olm copy of the FileHeader to the given ONLINE DEVICE ids (the leaf-less
/// member devices computed by the caller).
#[allow(clippy::too_many_arguments)]
async fn olm_fallback_channel_file_header(
    olm: &mut OlmManager,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    header_json: &str,
    devices: &[String],
) {
    for dev in devices {
        if olm.has_session(dev) {
            send_encrypted_message(
                olm, crypto_store,
                dev, header_json, event_tx,
                ws_cmd_tx, ws_room_peers,
            ).await;
        }
    }
}

/// Small server (<6 members, no gossip overlay): full replication to each ONLINE
/// DEVICE of each member, each under its own stream id, then delete the ciphertext
/// temp: every relay stream has read it, and a data-channel send streams from a copy
/// of its own.
#[allow(clippy::too_many_arguments)]
async fn replicate_channel_file_full(
    state: &ServerState,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    webrtc_peers: &std::collections::HashSet<String>,
    pending_webrtc_sends: &mut HashMap<String, (String, ws_stream_transfer::StreamKind, String, PathBuf, u64)>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    local_peer: &str,
    device_peer_id: &str,
    cid: &str,
    file_id: &str,
    temp_path: &std::path::Path,
    ct_size: u64,
) {
    for member_peer_str in state.members.keys() {
        if super::resolver::same_identity(member_peer_str, local_peer) { continue; }
        // A restricted channel's bytes go only to members who can SEE it. Full
        // replication used to push the ciphertext at every member device with no
        // visibility check at all, so a plain Member ended up holding an Admin-only
        // channel's file. Membership is not entitlement here; the channel ladder is.
        if !super::crypto_handler::channel_readable_by(state, member_peer_str, cid) { continue; }
        for dev in super::crypto_handler::online_devices_for(ws_room_peers, member_peer_str) {
            stream_to_peer(
                ws_cmd_tx, ws_room_peers,
                webrtc_peers, pending_webrtc_sends, event_tx,
                &dev, &ws_stream_transfer::StreamKind::File,
                &file_stream_id(file_id, device_peer_id, &dev), temp_path, ct_size,
            ).await;
        }
    }
    let _ = tokio::fs::remove_file(temp_path).await;
}

/// Every online DEVICE that may LEGITIMATELY hold a channel file's bytes, in
/// ascending device-id order so the walk is reproducible.
///
/// Full replication (<6-member servers) means every member online at send time
/// holds the bytes, which closes the gap where the sender went offline and the
/// request still only targeted the sender. Membership alone is NOT entitlement: a
/// restricted channel's bytes only ever went to members who can SEE it, so
/// rerouting elsewhere would ask a non-qualifier to serve content it never had.
/// Best effort: a picked member without the bytes answers `FileUnavailable`.
pub(crate) fn channel_holder_candidates(
    state: &ServerState,
    channel_id: &str,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    local_peer: &str,
) -> Vec<String> {
    // Members are MASTER-keyed; sends must target DEVICE ids.
    let mut candidates: Vec<String> = Vec::new();
    for member in state.members.keys() {
        if super::resolver::same_identity(member, local_peer) {
            continue;
        }
        if !super::crypto_handler::channel_readable_by(state, member, channel_id) {
            continue;
        }
        candidates.extend(super::crypto_handler::online_devices_for(ws_room_peers, member));
    }
    candidates.sort();
    candidates.dedup();
    candidates
}

/// Handle NodeCommand::RequestFile: the explicit pull (the Download button, the
/// chat-open sweep, a guest download).
///
/// The request goes through the PENDING ASK TABLE (`node/file_asks.rs`) whenever we
/// hold a row for the file, which is what lets an unanswerable request be QUEUED
/// instead of dropped, rotated to the next holder, and narrated to the card.
///
/// CRITICAL: request from ONE device, NOT a fan-out. A DM file is fanned out at
/// SEND time, so multiple devices hold a copy, but each re-encrypts its stream with
/// its OWN random AES key while the receiver kept only ONE FileHeader's key: every
/// other stream then fails AES-GCM decrypt and auto-re-requests, forever.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_request_file(
    file_id: String,
    peer_id_str: String,
    chunks: Vec<u32>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    pending_ws_transfers: &HashMap<String, super::ws_stream_transfer::WsTransferState>,
    server_states: &HashMap<String, ServerState>,
    event_tx: &tokio::sync::mpsc::Sender<crate::node::NetworkEvent>,
    pending_file_asks: &mut HashMap<String, super::file_asks::PendingFileAsk>,
    requested_file_receipts: &mut HashMap<String, std::time::Instant>,
    declined_file_ids: &mut std::collections::HashSet<String>,
    local_peer: &str,
    device_peer_id: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    // Where may this file be pulled from? Read off OUR row, ONE store open on
    // this path (the same inline-open pattern the FileRequest responder uses),
    // and cached in the ask entry from here on.
    let row = crate::storage::MessageStore::open(db_path, db_passphrase)
        .ok()
        .and_then(|store| store.get_file_metadata(&file_id).ok().flatten())
        .and_then(|meta| {
            let sender = super::resolver::resolve(&meta.sender_id);
            match meta.context_type.as_str() {
                "dm" => Some((
                    super::file_asks::FileAskContext::Dm {
                        peer: meta.context_id.clone(),
                    },
                    sender,
                )),
                "channel" => {
                    let mut parts = meta.context_id.splitn(2, ':');
                    match (parts.next(), parts.next()) {
                        (Some(sid), Some(cid)) => Some((
                            super::file_asks::FileAskContext::Channel {
                                server_id: sid.to_string(),
                                channel_id: cid.to_string(),
                            },
                            sender,
                        )),
                        _ => None,
                    }
                }
                _ => None,
            }
        });

    if let Some((context, sender)) = row {
        // A live device id from the caller is the preferred first hop; a master
        // id is not a socket anybody authenticates as, so it is not a target.
        let prefer = ws_room_peers
            .values()
            .any(|peers| peers.contains(&peer_id_str))
            .then(|| peer_id_str.clone());
        super::file_asks::upsert_and_advance(
            ws_cmd_tx,
            ws_room_peers,
            server_states,
            event_tx,
            pending_file_asks,
            requested_file_receipts,
            declined_file_ids,
            pending_ws_transfers,
            &file_id,
            context,
            sender,
            prefer.as_deref(),
            local_peer,
            device_peer_id,
        )
        .await;
        return;
    }

    // No row of our own (a guest pull, a file we only know by id): a single direct
    // send to whichever device of the named identity is reachable. There is no
    // context to queue against, so there is no ask to keep.
    let target = if ws_room_peers.values().any(|peers| peers.contains(&peer_id_str)) {
        Some(peer_id_str.clone())
    } else {
        let mut devices = super::crypto_handler::online_devices_for(ws_room_peers, &peer_id_str);
        devices.sort();
        devices
            .into_iter()
            .next()
            .or_else(|| peer_is_reachable(ws_room_peers, &peer_id_str).then(|| peer_id_str.clone()))
    };
    match target {
        Some(t) => {
            let offset = pending_ws_transfers
                .get(&file_stream_id(&file_id, &t, device_peer_id))
                .filter(|s| s.sender == t)
                .map(|s| s.bytes_received)
                .unwrap_or(0);
            hollow_log!("[HOLLOW-FILE] Requesting rowless file {file_id} from {t} (offset {offset})");
            super::olm_lane::carry(
                ws_cmd_tx,
                &t,
                None,
                &HavenMessage::FileRequest { file_id, chunks, offset },
                super::olm_lane::NoSession::Queue,
            );
        }
        None => {
            hollow_log!("[HOLLOW-FILE] No online device for {peer_id_str} — FileRequest for {file_id} not sent");
        }
    }
}

/// Handle NodeCommand::WebRtcTransferComplete — completed WebRTC transfer.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_webrtc_transfer_complete(
    transfer_id: String,
    temp_path: String,
    sender_peer_id: String,
    kind: String,
    shard_index: u16,
    us: &str,
    pending_file_streams: &mut HashMap<String, PendingFileStream>,
    pending_shard_streams: &mut HashMap<String, PendingShardStream>,
    pending_vault_downloads: &mut HashMap<String, (String, usize, usize)>,
    early_file_streams: &mut HashMap<String, EarlyStream>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    db_path: &str,
    db_passphrase: &str,
) -> Option<super::vault_ops::VaultRepull> {
    hollow_log!("[HOLLOW-WEBRTC] Transfer complete: {transfer_id} from {sender_peer_id}");
    let stream_kind = if kind == "shard" {
        ws_stream_transfer::StreamKind::Shard { shard_index }
    } else {
        ws_stream_transfer::StreamKind::File
    };
    let temp_path_buf = PathBuf::from(&temp_path);
    let file_size = tokio::fs::metadata(&temp_path).await.map(|m| m.len()).unwrap_or(0);
    let request = ws_stream_transfer::StreamRequest {
        kind: stream_kind,
        id: transfer_id.clone(),
        size: file_size,
        temp_path: temp_path_buf,
    };
    // WebRTC-completed transfers are File/Shard only; link snapshots are relay-only.
    let mut empty_link_snapshots = HashMap::new();
    handle_completed_stream(
        request,
        &sender_peer_id,
        us,
        pending_file_streams,
        pending_shard_streams,
        pending_vault_downloads,
        early_file_streams,
        &mut empty_link_snapshots,
        bundle_keypair,
        event_tx,
        ws_cmd_tx,
        ws_room_peers,
        db_path,
        db_passphrase,
    ).await
}

/// Whether `path` is a shard send's temp, which one transfer alone streams from.
fn is_shard_send_temp(path: &std::path::Path) -> bool {
    path.file_name().is_some_and(|n| n.to_string_lossy().starts_with(".stream_shard_"))
}

/// Handle NodeCommand::WebRtcSendComplete — completed send.
pub(crate) fn handle_webrtc_send_complete(
    transfer_id: String,
    pending_webrtc_sends: &mut HashMap<String, (String, ws_stream_transfer::StreamKind, String, PathBuf, u64)>,
) {
    hollow_log!("[HOLLOW-WEBRTC] Send complete: {transfer_id}");
    if let Some((_, _, _, path, _)) = pending_webrtc_sends.remove(&transfer_id) {
        if is_shard_send_temp(&path) || path.file_name().map(|n| n.to_string_lossy().starts_with(".stream_send_")).unwrap_or(false) {
            let _ = std::fs::remove_file(&path);
        }
    }
    // Share chunk temps bypass pending_webrtc_sends — clean by transfer_id pattern.
    // Share transfer_ids are "{short_root}:{chunk_index}".
    if transfer_id.contains(':') {
        let short_root = transfer_id.split(':').next().unwrap_or("");
        let idx_str = transfer_id.split(':').nth(1).unwrap_or("");
        if let Ok(shares_dir) = super::share_handler::shares_dir() {
            let tmp = shares_dir.join(format!(".send_{short_root}_{idx_str}.tmp"));
            let _ = std::fs::remove_file(&tmp);
        }
    }
}

/// Handle NodeCommand::WebRtcTransferFailed — failed transfer with retry.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_webrtc_transfer_failed(
    transfer_id: String,
    peer_id: String,
    error: String,
    us: &str,
    webrtc_peers: &mut std::collections::HashSet<String>,
    pending_webrtc_sends: &mut HashMap<String, (String, ws_stream_transfer::StreamKind, String, PathBuf, u64)>,
    pending_file_streams: &HashMap<String, PendingFileStream>,
    early_file_streams: &mut HashMap<String, EarlyStream>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    event_tx: &mpsc::Sender<NetworkEvent>,
) {
    hollow_log!("[HOLLOW-WEBRTC] Transfer failed: {transfer_id} to/from {peer_id}: {error}");
    webrtc_peers.remove(&peer_id);
    // Sender-side retry: the same transfer over the relay, from its own temp.
    if let Some((target, kind, id, source_path, total_size)) = pending_webrtc_sends.remove(&transfer_id) {
        hollow_log!("[HOLLOW-WEBRTC] Sender fallback: retrying {id} via WSS relay");
        webrtc_peers.remove(&target);
        stream_to_peer(
            &ws_cmd_tx, &ws_room_peers,
            &webrtc_peers, pending_webrtc_sends, &event_tx,
            &target, &kind, &id, &source_path, total_size,
        ).await;
        let _ = tokio::fs::remove_file(&source_path).await;
    }
    // Receiver-side retry: ask the sender again for the file its header named.
    if let Some(early) = early_file_streams.remove(&transfer_id) {
        let _ = tokio::fs::remove_file(&early.temp_path).await;
    }
    if let Some(file_id) = file_of_stream(pending_file_streams, &transfer_id, &peer_id, us) {
        hollow_log!("[HOLLOW-WEBRTC] Receiver fallback: requesting {file_id} via FileRequest");
        super::olm_lane::carry(
            &ws_cmd_tx, &peer_id, None,
            &HavenMessage::FileRequest {
                file_id,
                chunks: vec![],
                offset: 0,
            },
            super::olm_lane::NoSession::Queue,
        );
    }
}

/// What opens an in-flight link snapshot and what it installs. Stashed with the blob
/// for a next-launch import through the `import_backup` pipeline, never in place.
pub(crate) struct LinkSnapshotState {
    /// The one-time passphrase of the `.hollow` blob, received inside the link channel.
    pub passphrase: zeroize::Zeroizing<String>,
    /// The device that offered it; only its stream may complete it.
    pub sender: String,
    /// The device key this install runs as after the import (protobuf), the one the
    /// presenter vouched for.
    pub device: zeroize::Zeroizing<Vec<u8>>,
}

/// AES-256-GCM appends its tag to every file and shard ciphertext.
const AES_GCM_TAG: u64 = 16;

/// Room for a packed shard's own header (`erasure::pack_shard`) on top of its data.
const SHARD_HEADER_SLACK: u64 = 4096;

/// How long an explicit pull keeps its receipt (the header arms consume it).
const RECEIPT_TTL: std::time::Duration = std::time::Duration::from_secs(300);

/// How long a guest's pull of a public file waits for its header.
const GUEST_PULL_TTL: std::time::Duration = std::time::Duration::from_secs(120);

/// Whether a public file header answers a guest pull made in `asked_sid` at `asked_at`:
/// it names that server and the pull is still fresh.
pub(crate) fn guest_answer_fresh(asked_sid: &str, asked_at: std::time::Instant, sid: &str) -> bool {
    asked_sid == sid && asked_at.elapsed() <= GUEST_PULL_TTL
}

/// The wire id of the stream carrying file `fid` from device `from` to device `to`.
/// One file streams to several devices at once and its id fills the 64-byte id field
/// by itself, so each transfer needs its own; both ends derive it, and the relay cannot
/// read which file a stream carries.
pub(crate) fn file_stream_id(fid: &str, from: &str, to: &str) -> String {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(b"hollow-file-stream1");
    for part in [fid, from, to] {
        h.update((part.len() as u64).to_be_bytes());
        h.update(part.as_bytes());
    }
    hex::encode(h.finalize())
}

/// The file among `fids` whose stream from `from` to us (`us`) is `id`.
fn stream_names<'a>(id: &str, from: &str, us: &str, fids: impl IntoIterator<Item = &'a String>) -> Option<&'a String> {
    fids.into_iter().find(|fid| file_stream_id(fid, from, us) == id)
}

/// The file whose pending header from `from` names stream `id`: the only file those
/// bytes may complete, since only that header holds their key.
pub(crate) fn file_of_stream(
    pending_file_streams: &HashMap<String, PendingFileStream>,
    id: &str,
    from: &str,
    us: &str,
) -> Option<String> {
    stream_names(id, from, us, pending_file_streams.iter().filter(|(_, p)| p.sender == from).map(|(f, _)| f)).cloned()
}

/// The file a declined push streaming as `id` from `from` was for.
pub(crate) fn declined_stream(
    declined_file_ids: &std::collections::HashSet<String>,
    id: &str,
    from: &str,
    us: &str,
) -> Option<String> {
    stream_names(id, from, us, declined_file_ids).cloned()
}

/// The file a stream `from` opens under `id` carries, when we expect it: its sender's
/// header names it (`true`), or we asked that very device for it.
fn expected_file(
    id: &str,
    from: &str,
    us: &str,
    pending_file_streams: &HashMap<String, PendingFileStream>,
    pending_file_asks: &HashMap<String, super::file_asks::PendingFileAsk>,
    pending_public_file_requests: &HashMap<String, (String, String, std::time::Instant)>,
) -> Option<(String, bool)> {
    if let Some(fid) = file_of_stream(pending_file_streams, id, from, us) {
        return Some((fid, true));
    }
    let asked = pending_file_asks.iter().filter(|(_, ask)| ask.asked.contains(from)).map(|(f, _)| f);
    let pulled = pending_public_file_requests.iter().filter(|(_, (_, asked, _))| asked == from).map(|(f, _)| f);
    stream_names(id, from, us, asked.chain(pulled)).map(|fid| (fid.clone(), false))
}

/// The file a stream carries, for showing its progress.
pub(crate) fn stream_file_label(
    id: &str,
    from: &str,
    us: &str,
    pending_file_streams: &HashMap<String, PendingFileStream>,
    pending_file_asks: &HashMap<String, super::file_asks::PendingFileAsk>,
    pending_public_file_requests: &HashMap<String, (String, String, std::time::Instant)>,
) -> Option<String> {
    expected_file(id, from, us, pending_file_streams, pending_file_asks, pending_public_file_requests).map(|(fid, _)| fid)
}

/// The most bytes a stream `from` opens for `id` may declare: what we expect of it.
/// A file without its sender's header, or our own fresh pull from that very device,
/// stays within the send limit; a share chunk never rides the WS lane, and a link
/// snapshot comes only from its offerer.
#[allow(clippy::too_many_arguments)]
pub(crate) fn stream_ceiling(
    kind: &ws_stream_transfer::StreamKind,
    id: &str,
    from: &str,
    us: &str,
    pending_file_streams: &HashMap<String, PendingFileStream>,
    requested_file_receipts: &HashMap<String, std::time::Instant>,
    pending_file_asks: &HashMap<String, super::file_asks::PendingFileAsk>,
    pending_public_file_requests: &HashMap<String, (String, String, std::time::Instant)>,
    pending_link_snapshots: &HashMap<String, LinkSnapshotState>,
) -> u64 {
    use ws_stream_transfer::StreamKind;
    let send_limit = file_transfer::DEFAULT_MAX_FILE_SIZE + AES_GCM_TAG;
    match kind {
        StreamKind::File => match expected_file(id, from, us, pending_file_streams, pending_file_asks, pending_public_file_requests) {
            Some((fid, true)) => pending_file_streams.get(&fid).map_or(send_limit, |h| h.size.saturating_add(AES_GCM_TAG)),
            Some((fid, false)) if requested_file_receipts.get(&fid).is_some_and(|at| at.elapsed() < RECEIPT_TTL) => u64::MAX,
            _ => send_limit,
        },
        StreamKind::Shard { .. } => send_limit + SHARD_HEADER_SLACK,
        StreamKind::ShareChunk { .. } => 0,
        StreamKind::LinkSnapshot => {
            if pending_link_snapshots.get(id).is_some_and(|link| link.sender == from) {
                u64::MAX
            } else {
                0
            }
        }
    }
}

/// Early arrivals one sender may park, and the bytes all of them together may hold.
const MAX_EARLY_STREAMS_PER_SENDER: usize = 16;
const MAX_EARLY_STREAM_BYTES: u64 = 8 * file_transfer::DEFAULT_MAX_FILE_SIZE;
/// What one parked stream counts against the budget at least, so tiny ones fill it too.
const EARLY_STREAM_MIN_CHARGE: u64 = 1024 * 1024;

/// Park a completed stream whose FileHeader has not landed, under its stream id,
/// returning the temps the caller deletes. A sender past its count pays with its own
/// oldest; past the byte budget the sender holding the most pays, so a flood only ever
/// evicts its own.
pub(crate) fn park_early_stream(
    early: &mut HashMap<String, EarlyStream>,
    stream_id: String,
    stream: EarlyStream,
) -> Vec<PathBuf> {
    let mut evicted = Vec::new();
    let (sender, path) = (stream.sender.clone(), stream.temp_path.clone());
    if let Some(replaced) = early.insert(stream_id, stream)
        && replaced.temp_path != path
    {
        evicted.push(replaced.temp_path);
    }
    let charge = |s: &EarlyStream| s.size.max(EARLY_STREAM_MIN_CHARGE);
    let oldest_of = |early: &HashMap<String, EarlyStream>, who: &str| {
        early.iter()
            .filter(|(_, s)| s.sender == who)
            .min_by_key(|(_, s)| s.parked_at)
            .map(|(id, _)| id.clone())
    };
    while early.values().filter(|s| s.sender == sender).count() > MAX_EARLY_STREAMS_PER_SENDER {
        let Some(id) = oldest_of(early, &sender) else { break };
        evicted.extend(early.remove(&id).map(|s| s.temp_path));
    }
    while early.values().map(charge).sum::<u64>() > MAX_EARLY_STREAM_BYTES {
        let mut held: HashMap<&str, u64> = HashMap::new();
        for s in early.values() {
            *held.entry(s.sender.as_str()).or_default() += charge(s);
        }
        let Some(heaviest) = held.into_iter().max_by_key(|(_, bytes)| *bytes).map(|(who, _)| who.to_string()) else { break };
        let Some(id) = oldest_of(early, &heaviest) else { break };
        evicted.extend(early.remove(&id).map(|s| s.temp_path));
    }
    evicted
}

/// Why a FileHeader's size may not land, `None` when it may: a declared size over
/// the server's file limit (the send limit outside a server) unless Share delivers
/// the file, or inline bytes too long to be such a file, judged before decoding.
pub(crate) fn header_size_refused(
    server_states: &HashMap<String, ServerState>,
    sid: Option<&str>,
    size: u64,
    share_backed: bool,
    inline_b64_len: usize,
) -> Option<&'static str> {
    let max_bytes = sid
        .and_then(|s| server_states.get(s))
        .and_then(|state| state.settings.get("max_file_size_mb"))
        .and_then(|mb| mb.read().parse::<u64>().ok())
        .map_or(file_transfer::DEFAULT_MAX_FILE_SIZE, |mb| mb.saturating_mul(1024 * 1024));
    if !share_backed && size > max_bytes {
        return Some("the file is over the size limit");
    }
    let max_inline_b64 = max_bytes.saturating_add(AES_GCM_TAG).div_ceil(3).saturating_mul(4);
    if inline_b64_len as u64 > max_inline_b64 {
        return Some("the inline bytes are over the size limit");
    }
    None
}

/// Handle a completed stream transfer (file, shard, or link snapshot) that `sender_peer`
/// sent to our device `us`; a shard can hand back a vault download to pull afresh.
///
/// Boxed: several swarm arms await it, and their futures sit near the worker stack.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_completed_stream(
    request: ws_stream_transfer::StreamRequest,
    sender_peer: &str,
    us: &str,
    pending_file_streams: &mut HashMap<String, PendingFileStream>,
    pending_shard_streams: &mut HashMap<String, PendingShardStream>,
    pending_vault_downloads: &mut HashMap<String, (String, usize, usize)>,
    early_file_streams: &mut HashMap<String, EarlyStream>,
    pending_link_snapshots: &mut HashMap<String, LinkSnapshotState>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    db_path: &str,
    db_passphrase: &str,
) -> Option<super::vault_ops::VaultRepull> {
    Box::pin(completed_stream_inner(
        request, sender_peer, us, pending_file_streams, pending_shard_streams, pending_vault_downloads,
        early_file_streams, pending_link_snapshots, bundle_keypair, event_tx, ws_cmd_tx, ws_room_peers,
        db_path, db_passphrase,
    ))
    .await
}

#[allow(clippy::too_many_arguments)]
async fn completed_stream_inner(
    request: ws_stream_transfer::StreamRequest,
    sender_peer: &str,
    us: &str,
    pending_file_streams: &mut HashMap<String, PendingFileStream>,
    pending_shard_streams: &mut HashMap<String, PendingShardStream>,
    pending_vault_downloads: &mut HashMap<String, (String, usize, usize)>,
    early_file_streams: &mut HashMap<String, EarlyStream>,
    pending_link_snapshots: &mut HashMap<String, LinkSnapshotState>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    db_path: &str,
    db_passphrase: &str,
) -> Option<super::vault_ops::VaultRepull> {
    use ws_stream_transfer::StreamKind;

    // Share chunks have their own completion path (handle_webrtc_share_chunk_complete)
    // and never ride the WS stream lane, so one arriving here is nobody's: drop it
    // with its temp.
    if matches!(request.kind, StreamKind::ShareChunk { .. }) {
        let _ = tokio::fs::remove_file(&request.temp_path).await;
        return None;
    }

    match request.kind {
        StreamKind::ShareChunk { .. } => unreachable!(),
        StreamKind::LinkSnapshot => {
            handle_link_snapshot_stream(
                &request, sender_peer, pending_link_snapshots,
                event_tx, ws_cmd_tx, ws_room_peers,
            ).await;
            None
        }
        StreamKind::File => {
            handle_file_stream_complete(
                &request, sender_peer, us, pending_file_streams, early_file_streams,
                event_tx, ws_cmd_tx, ws_room_peers, db_path, db_passphrase,
            ).await;
            None
        }
        StreamKind::Shard { .. } => {
            handle_shard_stream_complete(
                &request, sender_peer, pending_shard_streams,
                pending_vault_downloads, event_tx, db_path, db_passphrase,
            ).await
        }
    }
}

/// LinkSnapshot arm of handle_completed_stream: stash the encrypted `.hollow`
/// blob + link code for a next-launch import via the proven `import_backup`
/// pipeline (NOT an in-place import), then ack the sender.
async fn handle_link_snapshot_stream(
    request: &ws_stream_transfer::StreamRequest,
    sender_peer: &str,
    pending_link_snapshots: &mut HashMap<String, LinkSnapshotState>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) {
    let link_id = request.id.clone();
    // Events use the bare session id (no "link_" transport prefix) so Dart
    // sees a consistent id across LinkProgress/LinkComplete/LinkFailed.
    let bare_id = link_id.strip_prefix("link_").unwrap_or(&link_id).to_string();
    hollow_log!("[HOLLOW-LINK] Inbound link snapshot: {link_id} ({} bytes)", request.size);

    let announced_by_sender = pending_link_snapshots
        .get(&link_id)
        .is_some_and(|state| state.sender == sender_peer);
    let Some(state) = announced_by_sender.then(|| pending_link_snapshots.remove(&link_id)).flatten() else {
        // No decryption material registered for this link session — drop it.
        hollow_log!("[HOLLOW-LINK] No pending link state for {link_id} — dropping snapshot");
        let _ = tokio::fs::remove_file(&request.temp_path).await;
        let _ = event_tx.send(NetworkEvent::LinkFailed {
            link_id: bare_id,
            error: "no pending link session".to_string(),
        }).await;
        return;
    };

    // Rather than import in place, STASH the blob, its key and our new device key
    // and signal a restart, so the bootstrap imports it pre-node-start like a
    // manual restore.
    let outcome: Result<(), String> = match tokio::fs::read(&request.temp_path).await {
        Ok(blob) => crate::api::storage::stash_pending_link(&blob, &state.passphrase, &state.device)
            .map_err(|e| format!("stash failed: {e}")),
        Err(e) => Err(format!("read link blob: {e}")),
    };

    let _ = tokio::fs::remove_file(&request.temp_path).await;

    match outcome {
        Ok(()) => {
            hollow_log!("[HOLLOW-LINK] Snapshot {link_id} stashed ({} bytes) — restart to import", request.size);
            // Tell the SENDER we truly have everything, so its spinner flips to
            // "Data sent" only now (not when it merely finished queuing bytes).
            super::crypto_handler::send_message_to_peer(
                ws_cmd_tx, ws_room_peers, sender_peer,
                super::types::HavenMessage::LinkSnapshotAck { link_id: link_id.clone() },
            );
            hollow_log!("[HOLLOW-LINK] Sent LinkSnapshotAck for {link_id} to {sender_peer}");
            let _ = event_tx.send(NetworkEvent::LinkComplete {
                link_id: bare_id,
                msg_count: 0,
                friend_count: 0,
                server_count: 0,
            }).await;
        }
        Err(e) => {
            hollow_log!("[HOLLOW-LINK] Snapshot {link_id} stash failed: {e}");
            let _ = event_tx.send(NetworkEvent::LinkFailed { link_id: bare_id, error: e }).await;
        }
    }
}

/// StreamKind::File arm of handle_completed_stream: the stream completes the file whose
/// header its sender gave us; bytes no header names yet wait for theirs, keyed by stream.
#[allow(clippy::too_many_arguments)]
async fn handle_file_stream_complete(
    request: &ws_stream_transfer::StreamRequest,
    sender_peer: &str,
    us: &str,
    pending_file_streams: &mut HashMap<String, PendingFileStream>,
    early_file_streams: &mut HashMap<String, EarlyStream>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    db_path: &str,
    db_passphrase: &str,
) {
    let stream_id = request.id.clone();
    hollow_log!("[HOLLOW-STREAM] Inbound file stream {stream_id} from {sender_peer} ({} bytes)", request.size);

    let Some((file_id, pfs)) = file_of_stream(pending_file_streams, &stream_id, sender_peer, us)
        .and_then(|fid| pending_file_streams.remove(&fid).map(|pfs| (fid, pfs)))
    else {
        // WebRTC race: bytes arrived before FileHeader. Save for later.
        hollow_log!("[HOLLOW-STREAM] No pending FileHeader names stream {stream_id} — saving as early arrival");
        let parked = EarlyStream {
            temp_path: request.temp_path.clone(),
            size: request.size,
            sender: sender_peer.to_string(),
            parked_at: std::time::Instant::now(),
        };
        for evicted in park_early_stream(early_file_streams, stream_id, parked) {
            let _ = tokio::fs::remove_file(&evicted).await;
        }
        return;
    };

    match try_decrypt_file_stream(request, &file_id, &pfs, db_path, db_passphrase).await {
        StreamOutcome::Done(disk_path) => {
            let _ = tokio::fs::remove_file(&request.temp_path).await;
            let _ = event_tx.send(NetworkEvent::FileCompleted { file_id, disk_path }).await;
        }
        StreamOutcome::WrongKey(fail_reason) => {
            hold_early_arrival_and_retry(
                &file_id, &fail_reason, request, sender_peer, pfs,
                pending_file_streams, early_file_streams, ws_cmd_tx, ws_room_peers,
            );
        }
        StreamOutcome::Forged(reason) => {
            // The bytes decrypted, so no later header makes them right: drop them.
            hollow_log!("[HOLLOW-SECURITY] DROPPED the bytes {sender_peer} delivered for {file_id}: {reason}");
            let _ = tokio::fs::remove_file(&request.temp_path).await;
            let _ = event_tx.send(NetworkEvent::FileFailed {
                file_id,
                error: FORGED_FILE_ERROR.to_string(),
            }).await;
        }
    }
}

/// What a person sees when delivered bytes are not the file its id commits to.
pub(crate) const FORGED_FILE_ERROR: &str = "This file didn't match what the sender sent, so it wasn't saved. Try again.";

/// How an assembled inbound stream ended.
enum StreamOutcome {
    /// Written and marked complete at this path.
    Done(String),
    /// Unreadable under this pending stream's key (usually a header still in flight).
    WrongKey(String),
    /// Decrypted, but not the bytes the file id commits to.
    Forged(&'static str),
}

/// Decrypt an assembled inbound file stream against its pending FileHeader key and
/// write the plaintext to its final path. A GCM failure here is usually a transient
/// assembly race under concurrent transfers, so the caller holds the bytes and
/// bounded-re-requests rather than giving up (see FILE_DECRYPT_MAX_RETRIES).
async fn try_decrypt_file_stream(
    request: &ws_stream_transfer::StreamRequest,
    file_id: &str,
    pfs: &PendingFileStream,
    db_path: &str,
    db_passphrase: &str,
) -> StreamOutcome {
    let Ok(ciphertext) = tokio::fs::read(&request.temp_path).await else {
        return StreamOutcome::WrongKey("unreadable stream".to_string());
    };
    let key_bytes = hex::decode(&pfs.aes_key).unwrap_or_default();
    let nonce_bytes = hex::decode(&pfs.aes_nonce).unwrap_or_default();
    if key_bytes.len() != 32 || nonce_bytes.len() != 12 {
        return StreamOutcome::WrongKey("invalid AES key/nonce length".to_string());
    }
    let key: [u8; 32] = key_bytes.try_into().unwrap();
    let nonce: [u8; 12] = nonce_bytes.try_into().unwrap();
    let plaintext = match crate::vault::pipeline::aes_decrypt(&ciphertext, &key, &nonce) {
        Ok(p) => p,
        Err(e) => return StreamOutcome::WrongKey(format!("decrypt failed: {e}")),
    };
    let (plaintext, sha256) = if super::file_commit::is_committed_id(file_id) {
        match tokio::task::spawn_blocking(move || {
            let sha256 = super::file_commit::sha256_hex(&plaintext);
            (plaintext, sha256)
        })
        .await
        {
            Ok(hashed) => hashed,
            Err(e) => return StreamOutcome::WrongKey(format!("hash task failed: {e}")),
        }
    } else {
        (plaintext, String::new())
    };
    let refusal = match crate::storage::MessageStore::open(db_path, db_passphrase) {
        Ok(store) => super::file_commit::completion_refused_hashed(
            &store, file_id, plaintext.len() as u64, &sha256,
        ),
        Err(_) => Some("the store could not be opened"),
    };
    if let Some(reason) = refusal {
        return StreamOutcome::Forged(reason);
    }
    let final_path = file_transfer::final_file_path(file_id, &pfs.ext);
    let dest = final_path.clone();
    if tokio::task::spawn_blocking(move || crate::node::at_rest::write_all(&dest, &plaintext))
        .await
        .unwrap_or_else(|e| Err(format!("write task failed: {e}")))
        .is_err()
    {
        return StreamOutcome::WrongKey("failed to write decrypted file".to_string());
    }
    let disk_path = final_path.to_string_lossy().to_string();
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let _ = store.mark_file_complete(file_id, &disk_path);
    }
    hollow_log!("[HOLLOW-STREAM] File {file_id} complete: {disk_path}");
    StreamOutcome::Done(disk_path)
}

/// The ciphertext is intact but did not decrypt against THIS pending stream's key.
///
/// The bytes (fast WebRTC) routinely BEAT the FileHeader (slower Olm/relay), so
/// they belong to a header that has not landed and the popped `pfs` is a STALE
/// pending stream with the wrong key. Deleting the bytes and re-requesting spawned
/// another crossed pair and looped forever, so instead the bytes are PRESERVED as
/// an early arrival keyed by their stream id and nothing is re-requested: the header
/// in flight arrives and reprocesses them against the CORRECT key.
#[allow(clippy::too_many_arguments)]
fn hold_early_arrival_and_retry(
    file_id: &str,
    fail_reason: &str,
    request: &ws_stream_transfer::StreamRequest,
    sender_peer: &str,
    pfs: PendingFileStream,
    pending_file_streams: &mut HashMap<String, PendingFileStream>,
    early_file_streams: &mut HashMap<String, EarlyStream>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) {
    hollow_log!(
        "[HOLLOW-STREAM] File {file_id} {fail_reason} — bytes arrived before their header; holding as early-arrival for the matching key"
    );
    let parked = EarlyStream {
        temp_path: request.temp_path.clone(),
        size: request.size,
        sender: sender_peer.to_string(),
        parked_at: std::time::Instant::now(),
    };
    for evicted in park_early_stream(early_file_streams, request.id.clone(), parked) {
        let _ = std::fs::remove_file(&evicted);
    }
    // Safety net: if NO matching header ever arrives (e.g. the Olm
    // header was genuinely lost, not just late), one bounded
    // re-request recovers it. Gated on retry_count so it can't loop.
    if pfs.retry_count < FILE_DECRYPT_MAX_RETRIES
        && peer_is_reachable(ws_room_peers, &pfs.sender)
    {
        let next = pfs.retry_count + 1;
        let sender = pfs.sender.clone();
        let mut retry_pfs = pfs;
        retry_pfs.retry_count = next;
        // Keep the pending stream so a late header preserves the count.
        pending_file_streams.insert(file_id.to_string(), retry_pfs);
        super::olm_lane::carry(
            ws_cmd_tx, &sender, None,
            &HavenMessage::FileRequest {
                file_id: file_id.to_string(),
                chunks: vec![],
                offset: 0,
            },
            super::olm_lane::NoSession::Queue,
        );
        hollow_log!("[HOLLOW-STREAM] File {file_id} — safety re-request {next}/{FILE_DECRYPT_MAX_RETRIES} from {sender}");
    }
}

/// StreamKind::Shard arm of handle_completed_stream: store the shard, emit ShardStored,
/// and attempt reconstruction if a vault download is pending. Returns the download to
/// pull afresh when its shards failed their manifest.
#[allow(clippy::too_many_arguments)]
async fn handle_shard_stream_complete(
    request: &ws_stream_transfer::StreamRequest,
    sender_peer: &str,
    pending_shard_streams: &mut HashMap<String, PendingShardStream>,
    pending_vault_downloads: &mut HashMap<String, (String, usize, usize)>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    db_path: &str,
    db_passphrase: &str,
) -> Option<super::vault_ops::VaultRepull> {
    // The stream id names one registered transfer: its shard, its sender and us.
    let found = pending_shard_streams
        .iter()
        .find(|(_, p)| p.stream_id == request.id)
        .map(|(key, p)| (key.clone(), p.sender == sender_peer));
    let pss = match found {
        Some((key, true)) => pending_shard_streams.remove(&key),
        // Kept for the device it was registered for, whose own stream may still come.
        Some((key, false)) => {
            hollow_log!("[HOLLOW-SECURITY] DROPPED shard stream {key} from {sender_peer}: registered for another device");
            None
        }
        None => {
            hollow_log!("[HOLLOW-STREAM] No pending shard transfer for stream {} from {sender_peer} — ignoring", request.id);
            None
        }
    };
    let Some(pss) = pss else {
        let _ = tokio::fs::remove_file(&request.temp_path).await;
        return None;
    };
    let (content_id, shard_index) = (pss.content_id.clone(), pss.shard_index);
    hollow_log!("[HOLLOW-STREAM] Inbound shard stream: cid={content_id} si={shard_index} ({} bytes)", request.size);
    let mut repull = None;
    if let Ok(shard_bytes) = tokio::fs::read(&request.temp_path).await {
        // SECURITY (FILE-3): `store_shard` hashes the bytes it is handed against
        // themselves, so a holder that returned someone else's bytes was
        // indistinguishable from an honest one until reconstruction failed. An
        // erasure shard now has to match the hash the split stamped into its own
        // header. Replication-mode shards (k = m = 0) carry no header and skip this.
        if pss.k > 0 || pss.m > 0 {
            let ok = match crate::vault::erasure::unpack_shard(&shard_bytes) {
                Ok((meta, data)) => {
                    !meta.shard_sha256.is_empty()
                        && meta.shard_sha256 == crate::vault::erasure::shard_hash(&data)
                }
                Err(_) => false,
            };
            if !ok {
                hollow_log!("[HOLLOW-SECURITY] DROPPED vault shard {shard_index} for {content_id} from {sender_peer}: missing or wrong per-shard hash");
                let _ = tokio::fs::remove_file(&request.temp_path).await;
                return None;
            }
        }
        let data_dir = crate::identity::data_dir().unwrap_or_default();
        let vault_dir = data_dir.join("vault");
        if let Ok(content_store) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) {
            let key = crate::vault::content_store::shard_key(&pss.content_id, pss.shard_index);
            if content_store.has_shard(&key).unwrap_or(true) {
                hollow_log!("[HOLLOW-VAULT] Shard {shard_index} of {content_id} from {sender_peer} dropped: already held");
                let _ = tokio::fs::remove_file(&request.temp_path).await;
                return None;
            }
            // The envelope that registered the stream was judged before its size was known.
            let used = content_store.total_storage_used(&pss.server_id).unwrap_or(0);
            if super::vault_ops::pledge_refused(pss.pledge, used, shard_bytes.len() as u64) {
                hollow_log!("[HOLLOW-VAULT] Shard {shard_index} of {content_id} from {sender_peer} dropped: our storage pledge for the server is full");
                let _ = tokio::fs::remove_file(&request.temp_path).await;
                return None;
            }
            // A store nobody asked for, of content our own download is pulling.
            let pulling = !pss.asked && !pss.recovery && pending_vault_downloads.contains_key(&content_id);
            if let Some(reason) = super::vault_ops::shard_bytes_refused(
                &content_store, &pss.content_id, pss.shard_index, &shard_bytes, pulling,
            ) {
                hollow_log!("[HOLLOW-SECURITY] DROPPED vault shard {shard_index} for {content_id} from {sender_peer}: {reason}");
                let _ = tokio::fs::remove_file(&request.temp_path).await;
                // An answer to our own pull: its download asks someone else.
                return (pss.asked && pending_vault_downloads.contains_key(&content_id)).then(|| {
                    super::vault_ops::VaultRepull {
                        server_id: pss.server_id,
                        content_id,
                        refuted: Some(sender_peer.to_string()),
                    }
                });
            }
            let tier = crate::vault::content_store::StorageTier::from_str(&pss.tier);
            let _ = content_store.store_shard(
                &pss.server_id, &pss.content_id, pss.shard_index,
                pss.k, pss.m, pss.total_size, tier, &shard_bytes,
            );
            hollow_log!("[HOLLOW-STREAM] Shard stored: cid={content_id} si={shard_index}");
            let _ = event_tx.send(NetworkEvent::ShardStored {
                server_id: pss.server_id.clone(),
                content_id: content_id.clone(),
                shard_index,
                from_peer: sender_peer.to_string(),
            }).await;

            if let Some((dl_server_id, dl_k, _)) = pending_vault_downloads.remove(&content_id) {
                hollow_log!("[HOLLOW-VAULT] Shard arrived for pending download — attempting reconstruction: {content_id}");
                repull = attempt_vault_reconstruction(
                    content_store, pending_vault_downloads, event_tx,
                    &content_id, dl_server_id, dl_k, db_path, db_passphrase,
                ).await;
            }
        }
    }
    let _ = tokio::fs::remove_file(&request.temp_path).await;
    repull
}

/// Try to reconstruct a pending vault download after a new shard landed: gather
/// local shards, reconstruct when enough are held, else re-register the pending
/// download and keep waiting for more shards. Returns the download to pull afresh
/// when shards were deleted on the way, or its rebuild failed on copies the manifest
/// cannot vouch for.
///
/// Takes the ContentStore by VALUE (last use in the shard arm): an owned store is
/// Send across .await points, while a `&ContentStore` is not.
#[allow(clippy::too_many_arguments)]
async fn attempt_vault_reconstruction(
    content_store: crate::vault::content_store::ContentStore,
    pending_vault_downloads: &mut HashMap<String, (String, usize, usize)>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    content_id: &str,
    dl_server_id: String,
    dl_k: usize,
    db_path: &str,
    db_passphrase: &str,
) -> Option<super::vault_ops::VaultRepull> {
    // The caller already removed the pending-download registration — bailing
    // out here without rolling it back would wedge this content_id forever
    // (later shards find no pending entry and never retry reconstruction).
    let manifest = match content_store.load_manifest(content_id) {
        Ok(Some(m)) => m,
        Ok(None) => {
            // Manifest genuinely absent — reconstruction can never succeed;
            // fail the download visibly instead of leaving the UI waiting.
            hollow_log!("[HOLLOW-VAULT] No manifest for {content_id} — cannot reconstruct");
            let _ = event_tx.send(NetworkEvent::VaultDownloadFailed {
                server_id: dl_server_id,
                content_id: content_id.to_string(),
                error: "Manifest missing for this file".to_string(),
            }).await;
            return None;
        }
        Err(e) => {
            // Transient store failure — re-register the pending download so
            // the next shard arrival retries instead of abandoning it.
            hollow_log!("[HOLLOW-VAULT] load_manifest failed for {content_id}: {e} — keeping download pending for retry");
            pending_vault_downloads.insert(content_id.to_string(), (dl_server_id, dl_k, 0));
            return None;
        }
    };
    let repull = |server_id: String| super::vault_ops::VaultRepull {
        server_id,
        content_id: content_id.to_string(),
        refuted: None,
    };
    let need = (manifest.k as usize).max(1);
    let (packed, dropped) = super::vault_ops::gather_vault_shards(&content_store, &manifest);
    let avail = packed.iter().flatten().count();
    if avail < need {
        if dropped > 0 {
            // Nothing asks for the shards just deleted but a fresh pull.
            return Some(repull(dl_server_id));
        }
        pending_vault_downloads.insert(content_id.to_string(), (dl_server_id, dl_k, 0));
        hollow_log!("[HOLLOW-VAULT] Still need more shards: have {avail}, need {need}");
        return None;
    }
    let ext = crate::vault::pipeline::ext_from_filename(&manifest.file_name);
    let rebuilt = crate::vault::pipeline::reconstruct_file(&manifest, &packed);
    // The fresh pull decides which unvouched copies go: it knows what we hold for others.
    if let Err(e) = &rebuilt
        && super::vault_ops::holds_unpinned(&manifest, &packed)
    {
        hollow_log!("[HOLLOW-VAULT] Rebuild of {content_id} failed ({e}): pulling its shards again");
        return Some(repull(dl_server_id));
    }
    let reconstructed = rebuilt.and_then(|plaintext| {
        match crate::storage::MessageStore::open(db_path, db_passphrase) {
            Ok(store) => match super::file_commit::vault_plaintext_refused(&store, content_id, &plaintext) {
                Some(reason) => Err(format!("{FORGED_FILE_ERROR} ({reason})")),
                None => Ok(plaintext),
            },
            Err(e) => Err(e),
        }
    });
    match reconstructed {
        Ok(plaintext) => {
            if let Ok(path) = crate::vault::pipeline::write_to_cache(content_id, &ext, &plaintext) {
                let disk_path = path.to_string_lossy().to_string();
                hollow_log!("[HOLLOW-VAULT] Download reconstructed: {disk_path}");
                let _ = event_tx.send(NetworkEvent::VaultDownloadComplete {
                    server_id: dl_server_id, content_id: content_id.to_string(), disk_path,
                }).await;
            }
        }
        Err(e) => {
            hollow_log!("[HOLLOW-VAULT] Reconstruction failed: {e}");
            let _ = event_tx.send(NetworkEvent::VaultDownloadFailed {
                server_id: dl_server_id, content_id: content_id.to_string(), error: e,
            }).await;
        }
    }
    None
}

/// The temp a data-channel send of transfer `id` streams from, holding `source`'s bytes:
/// its own name, so the send owns it until it ends whatever happens to `source`.
async fn stage_send_temp(source: &std::path::Path, id: &str) -> Option<PathBuf> {
    let name: String = id.chars().filter(|c| c.is_ascii_alphanumeric()).take(64).collect();
    let staged = file_transfer::files_dir().join(format!(".stream_send_{name}.tmp"));
    if staged == source {
        return Some(staged);
    }
    let _ = tokio::fs::remove_file(&staged).await;
    if tokio::fs::hard_link(source, &staged).await.is_ok() || tokio::fs::copy(source, &staged).await.is_ok() {
        return Some(staged);
    }
    hollow_log!("[HOLLOW-WEBRTC] Could not stage the send of {id}");
    None
}

/// Stream file or shard data to a peer under the transfer's wire id. Prefers WebRTC
/// data channel if available, falls back to WS binary frames via relay. `source_path`
/// stays the caller's: a data-channel send streams from a staged copy of its own, and
/// the relay reads `source_path` in full before this returns.
pub(crate) async fn stream_to_peer(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    webrtc_peers: &std::collections::HashSet<String>,
    pending_webrtc_sends: &mut HashMap<String, (String, ws_stream_transfer::StreamKind, String, PathBuf, u64)>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    peer_str: &str,
    kind: &ws_stream_transfer::StreamKind,
    id: &str,
    source_path: &std::path::Path,
    total_size: u64,
) {
    // A data-channel send owns its temp until it ends, so a repeat of a transfer still
    // running there rides the relay.
    let staged = if webrtc_peers.contains(peer_str) && !pending_webrtc_sends.contains_key(id) {
        stage_send_temp(source_path, id).await
    } else {
        None
    };
    if let Some(staged) = staged {
        let kind_str = match kind {
            ws_stream_transfer::StreamKind::Shard { .. } => "shard",
            ws_stream_transfer::StreamKind::ShareChunk { .. } => "share_chunk",
            // LinkSnapshot is relay-only and never routed over WebRTC; treat as file.
            ws_stream_transfer::StreamKind::File | ws_stream_transfer::StreamKind::LinkSnapshot => "file",
        };
        let shard_index = match kind {
            ws_stream_transfer::StreamKind::Shard { shard_index } => *shard_index,
            _ => 0,
        };
        // Store for fallback on failure.
        pending_webrtc_sends.insert(id.to_string(), (
            peer_str.to_string(), kind.clone(), id.to_string(),
            staged.clone(), total_size,
        ));
        let _ = event_tx.send(NetworkEvent::WebRtcSendFile {
            peer_id: peer_str.to_string(),
            transfer_id: id.to_string(),
            file_path: staged.to_string_lossy().to_string(),
            total_size,
            kind: kind_str.to_string(),
            shard_index,
            chunk_index: 0,
        }).await;
        hollow_log!("[HOLLOW-WEBRTC] Routing {id} to {peer_str} via WebRTC data channel");
        return;
    }
    // Fallback: WSS relay binary streaming.
    if let Some(room) = super::crypto_handler::send_room_for_peer(ws_room_peers, peer_str) {
        ws_stream_transfer::ws_stream_send(
            ws_cmd_tx, &room, peer_str, kind, id, source_path, total_size, 0,
        ).await;
    } else {
        hollow_log!("[HOLLOW-STREAM] Peer {peer_str} unreachable via WS — cannot stream {id}");
    }
}

/// Stream shard bytes held in memory to a peer under the transfer's stream id. Prefers
/// WebRTC (writes a temp file for Dart), falls back to WS binary frames via relay
/// (streams from memory, no disk).
pub(crate) async fn stream_to_peer_bytes(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    webrtc_peers: &std::collections::HashSet<String>,
    pending_webrtc_sends: &mut HashMap<String, (String, ws_stream_transfer::StreamKind, String, PathBuf, u64)>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    peer_str: &str,
    kind: &ws_stream_transfer::StreamKind,
    id: &str,
    data: &[u8],
) {
    // A data-channel send owns its temp until it ends, so a repeat of a transfer still
    // running there rides the relay.
    if webrtc_peers.contains(peer_str) && !pending_webrtc_sends.contains_key(id) {
        // WebRTC: Dart reads from file path — must write temp file.
        // Vault shard bytes are already AES ciphertext and the WS fallback streams
        // this file raw, so it is staged as-is.
        let temp_path = super::vault_ops::shard_send_temp(&file_transfer::files_dir(), id);
        let _ = tokio::fs::write(&temp_path, data).await;
        let total_size = data.len() as u64;
        let kind_str = match kind {
            ws_stream_transfer::StreamKind::Shard { .. } => "shard",
            ws_stream_transfer::StreamKind::ShareChunk { .. } => "share_chunk",
            // LinkSnapshot is relay-only and never routed over WebRTC; treat as file.
            ws_stream_transfer::StreamKind::File | ws_stream_transfer::StreamKind::LinkSnapshot => "file",
        };
        let shard_index = match kind {
            ws_stream_transfer::StreamKind::Shard { shard_index } => *shard_index,
            _ => 0,
        };
        pending_webrtc_sends.insert(id.to_string(), (
            peer_str.to_string(), kind.clone(), id.to_string(),
            temp_path.to_path_buf(), total_size,
        ));
        let _ = event_tx.send(NetworkEvent::WebRtcSendFile {
            peer_id: peer_str.to_string(),
            transfer_id: id.to_string(),
            file_path: temp_path.to_string_lossy().to_string(),
            total_size,
            kind: kind_str.to_string(),
            shard_index,
            chunk_index: 0,
        }).await;
        hollow_log!("[HOLLOW-WEBRTC] Routing {id} to {peer_str} via WebRTC data channel (from bytes)");
        return;
    }
    if let Some(room) = super::crypto_handler::send_room_for_peer(ws_room_peers, peer_str) {
        ws_stream_transfer::ws_stream_send_bytes(
            ws_cmd_tx, &room, peer_str, kind, id, data,
        ).await;
    } else {
        hollow_log!("[HOLLOW-STREAM] Peer {peer_str} unreachable via WS — cannot stream {id}");
    }
}

/// Handle `MessageEnvelope::FileHeader` — register pending stream + emit FileHeaderReceived.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_file_header(
    server_states: &HashMap<String, ServerState>,
    pending_file_streams: &mut HashMap<String, PendingFileStream>,
    pending_shard_streams: &mut HashMap<String, PendingShardStream>,
    early_file_streams: &mut HashMap<String, EarlyStream>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    server_id: &str,
    sender_peer_id: String,
    fid: String,
    name: String,
    ext: String,
    mime: String,
    size: u64,
    chunks: u32,
    img: bool,
    w: Option<u32>,
    h: Option<u32>,
    mid: Option<String>,
    sid: Option<String>,
    cid: Option<String>,
    ts: i64,
    aes_key: Option<String>,
    aes_nonce: Option<String>,
    vthumb: Option<VideoThumbRef>,
    share_ref: Option<super::types::ShareRef>,
    thumb: Option<String>,
    voice: bool,
    author: Option<String>,
    sha256: Option<String>,
    // The answer to a guest pull, from the peer we asked (the caller checked the
    // receipt): we hold no membership to judge the channel by.
    from_guest_pull: bool,
    requested_file_receipts: &mut HashMap<String, std::time::Instant>,
    declined_file_ids: &mut std::collections::HashSet<String>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    local_device: &str,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-FILE] MLS FileHeader: {fid} ({size} bytes, {chunks} chunks, share_ref={})", share_ref.is_some());
    // The stream this header's bytes ride from its sender to us.
    let stream_id = file_stream_id(&fid, &sender_peer_id, local_device);

    let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) else { return };
    let judged_sid = if from_guest_pull { None } else { sid.as_deref() };
    if let Some(reason) = file_header_refused(
        &store, server_states, &fid, judged_sid, cid.as_deref(), &sender_peer_id, from_guest_pull,
    ).or_else(|| super::file_commit::header_claim_refused(
        &fid, author.as_deref(), mid.as_deref(), size, sha256.as_deref(), &name, &ext,
        vthumb.as_ref(), &sender_peer_id, from_guest_pull,
    )) {
        hollow_log!("[HOLLOW-SECURITY] REJECTED FileHeader for {fid} from {sender_peer_id}: {reason}");
        return;
    }
    let complete = file_bytes_on_disk(&store, &fid);
    // A committed card belongs to the author its id names, whoever delivered it.
    let card_owner = match author.as_deref() {
        Some(a) if super::file_commit::is_committed_id(&fid) => a.to_string(),
        _ => sender_peer_id.clone(),
    };

    // Explicit pull — bypasses the size cap and the auto-download gate
    // (mirrors the DM/Olm header arm in swarm.rs; issue #41).
    let explicitly_requested = requested_file_receipts
        .remove(&fid)
        .map(|t| t.elapsed() < std::time::Duration::from_secs(300))
        .unwrap_or(false);
    if explicitly_requested {
        declined_file_ids.remove(&fid);
    }

    if share_ref.is_none()
        && !explicitly_requested
        && mls_file_header_exceeds_cap(server_states, server_id, size, &sender_peer_id)
    {
        return;
    }

    if mls_file_header_moderation_dropped(
        server_states, server_id, &sender_peer_id, &cid, &mime, img, &vthumb,
    ) {
        return;
    }

    let ctx_type = "channel";
    let ctx_id = match (&sid, &cid) {
        (Some(s), Some(c)) => format!("{s}:{c}"),
        _ => server_id.to_string(),
    };

    // Envelope-borne thumb: image blur placeholder or video poster,
    // size-capped — see accept_header_thumb.
    let thumb = accept_header_thumb(thumb, img, &mime);

    // Owner guard (0.8.5): MLS proves the sender is a group member, not
    // that this `file_id` is theirs to relabel. See `file_meta_write_allowed`.
    let meta_written = file_meta_write_allowed(&store, &fid, &sender_peer_id);
    if meta_written {
        let _ = store.insert_file_metadata(
            &fid, &name, &ext, &mime,
            size, chunks, img,
            w, h,
            mid.as_deref(), ctx_type, &ctx_id,
            &card_owner, false, ts,
            vthumb.as_ref(), thumb.as_deref(), sha256.as_deref(),
        );
        // Persist the share back-reference (issue #41) so a manual
        // download can rejoin the share swarm after a restart.
        if let Some(sr) = share_ref.as_ref() {
            let _ = store.set_file_share_ref(&fid, sr);
        }
    }
    drop(store);
    if complete {
        pending_file_streams.remove(&fid);
        if let Some(early) = early_file_streams.remove(&stream_id) {
            let _ = tokio::fs::remove_file(&early.temp_path).await;
        }
        hollow_log!("[HOLLOW-FILE] MLS FileHeader for {fid} registers nothing: already complete on disk");
    }

    // AUTO-DOWNLOAD GATE (#41), mirroring the DM/Olm arm: metadata above still
    // renders the card, but a gated push registers no pending stream and late bytes
    // are deleted rather than parked. An existing pending stream means a transfer we
    // already accepted, since the decrypt-fail retry re-requests WITHOUT a receipt.
    let auto_ok = explicitly_requested
        || pending_file_streams.contains_key(&fid)
        || auto_download_allows(size, &name, &ext, &format!("server:{server_id}"), voice);
    if !complete && !auto_ok && share_ref.is_none() && aes_key.is_some() {
        declined_file_ids.insert(fid.clone());
        if let Some(early) = early_file_streams.remove(&stream_id) {
            let _ = tokio::fs::remove_file(&early.temp_path).await;
        }
        hollow_log!("[HOLLOW-FILE] Auto-download gate declined pushed MLS file {fid} ({size} bytes, server:{server_id}) — metadata kept, manual download available");
        // Header-time decline signal — see the DM/Olm arm twin.
        let _ = event_tx.send(NetworkEvent::FileFailed {
            file_id: fid.clone(),
            error: "auto_download_off".to_string(),
        }).await;
    }

    // Register pending stream so binary file bytes can be decrypted on arrival.
    // Skip for share-backed files — no binary data arrives via P2P, Share handles delivery.
    if !complete && auto_ok && share_ref.is_none() && let (Some(ak), Some(an)) = (aes_key, aes_nonce) {
        register_pending_file_stream_and_reprocess(
            &fid, ak, an, &name, &ext, &sender_peer_id, server_id,
            &sid, &cid, &mid, img, w, h, size,
            pending_file_streams, pending_shard_streams, early_file_streams,
            bundle_keypair, event_tx, ws_cmd_tx, ws_room_peers,
            local_device, stream_id, db_path, db_passphrase,
        ).await;
    }

    let _ = event_tx.send(NetworkEvent::FileHeaderReceived {
        file_id: fid,
        file_name: name,
        size_bytes: size,
        is_image: img,
        width: w,
        height: h,
        message_id: mid.unwrap_or_default(),
        sender_id: sender_peer_id,
        server_id: sid.unwrap_or_else(|| server_id.to_string()),
        channel_id: cid.unwrap_or_default(),
        video_thumb: vthumb,
        // Dart starts a share download from this, so only the card's owner names one.
        share_ref: share_ref.filter(|_| meta_written),
        thumb_b64: thumb,
    }).await;
}

/// Size-cap gate for a non-share-backed MLS FileHeader (server-configurable
/// max_file_size_mb, default 34). Logs + returns true when it must be dropped.
fn mls_file_header_exceeds_cap(
    server_states: &HashMap<String, ServerState>,
    server_id: &str,
    size: u64,
    sender_peer_id: &str,
) -> bool {
    match header_size_refused(server_states, Some(server_id), size, false, 0) {
        Some(reason) => {
            hollow_log!("[HOLLOW-SECURITY] REJECTED MLS FileHeader from {sender_peer_id} (size {size}): {reason}");
            true
        }
        None => false,
    }
}

/// Moderation trio (receive-side) for an MLS FileHeader: drop files from
/// muted members and non-media files headed into a media-only channel.
/// Mirrors the text ingest gate in message_ops::handle_envelope_channel_message.
fn mls_file_header_moderation_dropped(
    server_states: &HashMap<String, ServerState>,
    server_id: &str,
    sender_peer_id: &str,
    cid: &Option<String>,
    mime: &str,
    img: bool,
    vthumb: &Option<VideoThumbRef>,
) -> bool {
    let Some(state) = server_states.get(server_id) else { return false; };
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;
    if state.is_muted(sender_peer_id, now_ms) {
        hollow_log!("[HOLLOW-MOD] DROPPED MLS FileHeader from muted member {sender_peer_id} in {server_id}");
        return true;
    }
    if let Some(c) = cid {
        if state.is_channel_media_only(c) {
            let is_media = img
                || vthumb.is_some()
                || mime.starts_with("video/")
                || file_transfer::is_image_mime(mime);
            if !is_media {
                hollow_log!("[HOLLOW-MOD] DROPPED non-media FileHeader ({mime}) from {sender_peer_id} in media-only channel {c}");
                return true;
            }
        }
    }
    false
}

/// Register the pending stream keyed by the FileHeader's AES material, then
/// reprocess any WebRTC bytes that arrived before this header.
#[allow(clippy::too_many_arguments)]
async fn register_pending_file_stream_and_reprocess(
    fid: &str,
    ak: String,
    an: String,
    name: &str,
    ext: &str,
    sender_peer_id: &str,
    server_id: &str,
    sid: &Option<String>,
    cid: &Option<String>,
    mid: &Option<String>,
    img: bool,
    w: Option<u32>,
    h: Option<u32>,
    size: u64,
    pending_file_streams: &mut HashMap<String, PendingFileStream>,
    pending_shard_streams: &mut HashMap<String, PendingShardStream>,
    early_file_streams: &mut HashMap<String, EarlyStream>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    local_device: &str,
    stream_id: String,
    db_path: &str,
    db_passphrase: &str,
) {
    pending_file_streams.insert(fid.to_string(), PendingFileStream {
        aes_key: ak,
        aes_nonce: an,
        file_name: name.to_string(),
        ext: ext.to_string(),
        sender: sender_peer_id.to_string(),
        server_id: sid.clone().unwrap_or_else(|| server_id.to_string()),
        channel_id: cid.clone().unwrap_or_default(),
        message_id: mid.clone().unwrap_or_default(),
        is_image: img,
        width: w,
        height: h,
        retry_count: 0,
        size,
    });
    hollow_log!("[HOLLOW-FILE] Registered pending stream for {fid} (MLS streamed transfer)");

    // Check if WebRTC bytes already arrived before this FileHeader.
    if let Some(EarlyStream { temp_path, size: file_size, sender, .. }) = early_file_streams.remove(&stream_id) {
        hollow_log!("[HOLLOW-FILE] Early arrival found for {fid} (MLS path) — processing now");
        let request = ws_stream_transfer::StreamRequest {
            kind: ws_stream_transfer::StreamKind::File,
            id: stream_id,
            size: file_size,
            temp_path,
        };
        let mut empty_vault_dl = HashMap::new();
        // This early-arrival path only ever carries StreamKind::File; link
        // snapshots never take the WebRTC early-arrival route, so an empty map is fine.
        let mut empty_link_snapshots = HashMap::new();
        handle_completed_stream(
            request, &sender, local_device,
            pending_file_streams, pending_shard_streams,
            &mut empty_vault_dl, early_file_streams,
            &mut empty_link_snapshots,
            bundle_keypair, event_tx,
            ws_cmd_tx, ws_room_peers,
            db_path, db_passphrase,
        ).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The gossip file relay is gone: any MLS member could arm it for any file id with a
    /// BroadcastMeta, and our next transfer carrying that id went on to that server's
    /// gossip neighbours. Honest gossip transfers never carried the file id, so the
    /// envelope served only that.
    #[test]
    fn a_broadcast_meta_envelope_arms_nothing() {
        let json = r#"{"t":"broadcast_meta","broadcast_id":"b","origin":"o","sid":"s","cid":"c","file_id":"f","ttl":3}"#;
        assert!(serde_json::from_str::<MessageEnvelope>(json).is_err(), "a BroadcastMeta envelope still parses");
    }

    /// One MLS FileHeader for `fid` in `srv`'s #general from `sender` to device "us",
    /// answering an explicit pull so the auto-download setting plays no part.
    async fn deliver_header(
        states: &HashMap<String, ServerState>,
        pending: &mut HashMap<String, PendingFileStream>,
        early: &mut HashMap<String, EarlyStream>,
        sender: &str,
        fid: &str,
        path: &str,
        pass: &str,
    ) {
        let (tx, _rx) = mpsc::channel(64);
        let (ws_tx, _ws_rx) = tokio::sync::mpsc::unbounded_channel();
        let mut receipts = HashMap::from([(fid.to_string(), std::time::Instant::now())]);
        handle_envelope_file_header(
            states, pending, &mut HashMap::new(), early,
            &crate::identity::native_identity::NativeKeypair::from_secret_bytes(&[9; 32]), &tx,
            "srv", sender.to_string(),
            fid.to_string(), "a.png".into(), "png".into(), "image/png".into(), 10, 0, true, None, None,
            Some("m1".into()), Some("srv".into()), Some("srv-general".into()), 1,
            Some("11".repeat(32)), Some("22".repeat(12)), None, None, None, false, None, None, false,
            &mut receipts, &mut std::collections::HashSet::new(), &ws_tx, &HashMap::new(),
            "us", path, pass,
        ).await;
    }

    /// The Olm and push header arms run the same gate before anything else: the
    /// unit test above drives only the MLS handler.
    #[test]
    fn file_header_gate_stays_wired() {
        let node = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src").join("node");
        let read = |f: &str| std::fs::read_to_string(node.join(f)).expect("read node source");
        let (swarm, fetch) = (read("swarm.rs"), read("fetch.rs"));
        let arm = |src: &str, from: &str, to: &str| {
            let start = src.find(from).unwrap_or_else(|| panic!("missing {from}"));
            let end = src[start..].find(to).unwrap_or_else(|| panic!("missing {to}"));
            src[start..start + end].to_string()
        };
        let olm = arm(&swarm, "Ok(MessageEnvelope::FileHeader { inner }) => {", "requested_file_receipts");
        assert!(olm.contains("file_handler::file_header_refused("), "swarm.rs: the Olm header arm skips the gate");
        let push = arm(&fetch, "fn handle_file_header(", "inline_bytes.is_some()");
        assert!(push.contains("file_header_refused(") && push.contains("file_bytes_on_disk("), "fetch.rs: the push header skips the gate");
        let sized = arm(&swarm, "Ok(MessageEnvelope::FileHeader { inner }) => {", "insert_file_metadata(");
        assert!(sized.contains("file_handler::header_size_refused("), "A-T06: the Olm header arm skips the size gate");
        assert!(push.contains("header_size_refused("), "A-T06: the push header skips the size gate");
        let mls = arm(&read("file_handler.rs"), "fn mls_file_header_exceeds_cap(", "\n}");
        assert!(mls.contains("header_size_refused("), "A-T06: the MLS header skips the size gate");
    }

    /// A-T06: one size gate for every header arm. Inline bytes are judged by their
    /// encoded length before anything decodes them, whatever size the header claims.
    #[test]
    fn header_size_gate_judges_inline_bytes_before_decoding() {
        let none = HashMap::new();
        let limit = file_transfer::DEFAULT_MAX_FILE_SIZE;
        let b64_len = |ciphertext: u64| (ciphertext.div_ceil(3) * 4) as usize;
        assert_eq!(header_size_refused(&none, None, limit, false, b64_len(limit + 16)), None);
        assert_eq!(header_size_refused(&none, None, limit + 1, false, 0), Some("the file is over the size limit"));
        assert_eq!(header_size_refused(&none, None, limit + 1, true, 0), None, "Share delivers any size");
        let one_group_over = b64_len(limit + 16) + 4;
        assert_eq!(
            header_size_refused(&none, None, 1, false, one_group_over),
            Some("the inline bytes are over the size limit"),
            "A-T06: inline bytes past the limit under a claimed size of 1",
        );
        assert_eq!(header_size_refused(&none, None, 1, true, one_group_over), Some("the inline bytes are over the size limit"));
    }

    fn pending_header(sender: &str, size: u64) -> PendingFileStream {
        PendingFileStream {
            aes_key: String::new(), aes_nonce: String::new(), file_name: "a.bin".into(), ext: "bin".into(),
            sender: sender.into(), server_id: String::new(), channel_id: String::new(), message_id: String::new(),
            is_image: false, width: None, height: None, retry_count: 0, size,
        }
    }

    /// Each transfer of a file streams under its own id: another file, sender or receiver
    /// is another id, both ends derive the same one, it is never a shard stream's id, and
    /// it has the one shape the stream lanes take for a file.
    #[test]
    fn each_file_transfer_has_its_own_stream_id() {
        let fid = "ab".repeat(32);
        let id = file_stream_id(&fid, "alice", "bob");
        assert_eq!(id, file_stream_id(&fid, "alice", "bob"), "the two ends derive different ids");
        assert!(ws_stream_transfer::is_stream_id(&id), "{id:?}");
        let mut seen = std::collections::HashSet::from([id.clone()]);
        for other in [
            file_stream_id(&"cd".repeat(32), "alice", "bob"),
            file_stream_id(&fid, "carol", "bob"),
            file_stream_id(&fid, "alice", "carol"),
            file_stream_id(&fid, "bob", "alice"),
            file_stream_id(&fid, "alic", "ebob"),
            file_stream_id(&format!("{fid}alice"), "", "bob"),
        ] {
            assert!(seen.insert(other), "two transfers share a stream id");
        }
        for si in 0..8u16 {
            assert_ne!(id, super::super::vault_ops::shard_stream_id(&fid, si, "alice", "bob"), "a file stream id is a shard's");
        }
        assert_ne!(id, fid, "the stream id names the file");
        for (fid, from, to) in [("../../x", "a/b", "C:\\x"), ("é", "", "")] {
            assert!(ws_stream_transfer::is_stream_id(&file_stream_id(fid, from, to)));
        }
    }

    /// A stream completes only the file whose header its own sender gave us, for the id
    /// that sender derives for us; a declined push is found the same way.
    #[test]
    fn a_stream_completes_only_the_file_its_senders_header_names() {
        let (f1, f2) = ("f1".repeat(32), "f2".repeat(32));
        let headers = HashMap::from([(f1.clone(), pending_header("bob", 10)), (f2.clone(), pending_header("carol", 10))]);
        assert_eq!(file_of_stream(&headers, &file_stream_id(&f1, "bob", "us"), "bob", "us"), Some(f1.clone()));
        assert_eq!(file_of_stream(&headers, &file_stream_id(&f2, "carol", "us"), "carol", "us"), Some(f2.clone()));
        assert_eq!(file_of_stream(&headers, &file_stream_id(&f1, "carol", "us"), "carol", "us"), None, "bytes for bob's header from carol");
        assert_eq!(file_of_stream(&headers, &file_stream_id(&f1, "bob", "us"), "carol", "us"), None, "carol replayed bob's stream id");
        assert_eq!(file_of_stream(&headers, &file_stream_id(&f1, "bob", "sibling"), "bob", "us"), None, "a stream meant for another device");
        assert_eq!(file_of_stream(&headers, &f1, "bob", "us"), None, "a stream under the bare file id");
        let declined = std::collections::HashSet::from([f1.clone()]);
        assert_eq!(declined_stream(&declined, &file_stream_id(&f1, "bob", "us"), "bob", "us"), Some(f1.clone()));
        assert_eq!(declined_stream(&declined, &file_stream_id(&f2, "bob", "us"), "bob", "us"), None);
    }

    /// A data-channel send streams from a temp of its own, so it outlives the caller's
    /// source; a repeat of a transfer still on its data channel rides the relay, so the
    /// temp a running send reads is never replaced under it.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)] // HOLLOW_DATA_DIR is process-global
    async fn a_data_channel_send_owns_its_temp_and_a_repeat_rides_the_relay() {
        use ws_stream_transfer::StreamKind;
        let _g = super::super::resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        unsafe { std::env::set_var("HOLLOW_DATA_DIR", tmp.path()); }
        let (event_tx, mut events) = mpsc::channel(8);
        let (ws_tx, mut ws_rx) = tokio::sync::mpsc::unbounded_channel();
        let rooms = HashMap::from([("room".to_string(), std::collections::HashSet::from(["bob".to_string()]))]);
        let webrtc = std::collections::HashSet::from(["bob".to_string()]);
        let mut sends = HashMap::new();
        let id = file_stream_id(&"f1".repeat(32), "us", "bob");

        let first = tmp.path().join("first.tmp");
        std::fs::write(&first, b"first ciphertext").unwrap();
        stream_to_peer(&ws_tx, &rooms, &webrtc, &mut sends, &event_tx, "bob", &StreamKind::File, &id, &first, 16).await;
        std::fs::remove_file(&first).unwrap();
        let Ok(NetworkEvent::WebRtcSendFile { transfer_id, file_path, .. }) = events.try_recv() else {
            panic!("the send never went to the data channel");
        };
        assert_eq!(transfer_id, id);
        assert_ne!(PathBuf::from(&file_path), first, "the send streams from its caller's temp");
        assert_eq!(std::fs::read(&file_path).ok().as_deref(), Some(&b"first ciphertext"[..]), "the send's temp went with its source");

        let again = tmp.path().join("again.tmp");
        std::fs::write(&again, b"second ciphertext").unwrap();
        stream_to_peer(&ws_tx, &rooms, &webrtc, &mut sends, &event_tx, "bob", &StreamKind::File, &id, &again, 17).await;
        assert!(events.try_recv().is_err(), "a repeat went to the data channel while the first send runs");
        assert_eq!(std::fs::read(&file_path).ok().as_deref(), Some(&b"first ciphertext"[..]), "the running send's temp was rewritten");
        assert!(matches!(ws_rx.try_recv(), Ok(super::super::ws_client::WsCommand::SendBinaryDirect { .. })), "the repeat never rode the relay");
        assert_eq!(sends.get(&id).map(|s| s.3.clone()), Some(PathBuf::from(&file_path)));

        handle_webrtc_send_complete(id.clone(), &mut sends);
        assert!(!std::path::Path::new(&file_path).exists(), "a finished send left its temp");
    }

    /// A-F7: what a stream may declare follows what we expect of it: its own header's
    /// size, anything for a file we asked for, a link snapshot only from the device
    /// that offered it, and the send limit otherwise. A file stream names its file by
    /// the id its sender derives for us.
    #[test]
    fn a_stream_ceiling_follows_the_header_the_ask_or_the_link() {
        use ws_stream_transfer::StreamKind;
        let headers = HashMap::from([("hdr".to_string(), pending_header("bob", 100 << 20))]);
        let mut receipts = HashMap::from([("asked".to_string(), std::time::Instant::now())]);
        if let Some(old) = std::time::Instant::now().checked_sub(RECEIPT_TTL) {
            receipts.insert("stale".to_string(), old);
        }
        let link = LinkSnapshotState {
            passphrase: zeroize::Zeroizing::new("k".into()),
            sender: "bob".into(),
            device: zeroize::Zeroizing::new(Vec::new()),
        };
        let links = HashMap::from([("link_ab".to_string(), link)]);
        let now = std::time::Instant::now();
        let ask = |device: &str| super::super::file_asks::PendingFileAsk {
            context: super::super::file_asks::FileAskContext::Dm { peer: "bob-master".into() },
            sender: "bob-master".into(),
            asked: std::collections::HashSet::from([device.to_string()]),
            in_flight: Some((device.to_string(), now)),
            negatives: Vec::new(),
            first_asked_at: now,
            last_asked_at: now,
        };
        let asks = HashMap::from([("asked".to_string(), ask("bob")), ("stale".to_string(), ask("bob"))]);
        receipts.insert("guest".to_string(), now);
        let guest = HashMap::from([("guest".to_string(), ("srv".to_string(), "carol".to_string(), now))]);
        let ceiling = |kind: &StreamKind, id: &str, from: &str| {
            stream_ceiling(kind, id, from, "us", &headers, &receipts, &asks, &guest, &links)
        };
        // A file stream from `from` carrying `fid`, as `from` derives its id for us.
        let file = |fid: &str, from: &str| ceiling(&StreamKind::File, &file_stream_id(fid, from, "us"), from);
        let send_limit = file_transfer::DEFAULT_MAX_FILE_SIZE + 16;
        assert_eq!(file("hdr", "bob"), (100 << 20) + 16);
        assert_eq!(file("hdr", "mallory"), send_limit, "another device rode bob's header");
        assert_eq!(
            ceiling(&StreamKind::File, &file_stream_id("hdr", "bob", "us"), "mallory"),
            send_limit,
            "another device replayed bob's stream id",
        );
        assert_eq!(
            ceiling(&StreamKind::File, &file_stream_id("hdr", "bob", "sibling"), "bob"),
            send_limit,
            "bob's stream to another device took the size of his header to us",
        );
        assert_eq!(ceiling(&StreamKind::File, "hdr", "bob"), send_limit, "a stream under the bare file id");
        assert_eq!(file("asked", "bob"), u64::MAX, "the device we asked outruns its header");
        assert_eq!(
            file("asked", "mallory"),
            send_limit,
            "a device we never asked opened an unlimited stream for a file we pull",
        );
        assert_eq!(file("guest", "carol"), u64::MAX, "the peer a guest pull went to");
        assert_eq!(file("guest", "mallory"), send_limit, "another peer answered a guest pull");
        assert_eq!(file("stale", "bob"), send_limit, "an expired ask");
        assert_eq!(file("unknown", "mallory"), send_limit);
        let label = |fid: &str, from: &str| stream_file_label(&file_stream_id(fid, from, "us"), from, "us", &headers, &asks, &guest);
        assert_eq!(label("hdr", "bob").as_deref(), Some("hdr"));
        assert_eq!(label("asked", "bob").as_deref(), Some("asked"));
        assert_eq!(label("guest", "carol").as_deref(), Some("guest"));
        assert_eq!(label("hdr", "mallory"), None, "progress shown for a stream nobody expects");
        assert_eq!(ceiling(&StreamKind::LinkSnapshot, "link_ab", "bob"), u64::MAX);
        assert_eq!(ceiling(&StreamKind::LinkSnapshot, "link_ab", "mallory"), 0, "another device's link snapshot");
        assert_eq!(ceiling(&StreamKind::LinkSnapshot, "link_xy", "bob"), 0, "a link we never registered");
        assert_eq!(ceiling(&StreamKind::ShareChunk { chunk_index: 0 }, "x", "bob"), 0);
        let shard = ceiling(&StreamKind::Shard { shard_index: 0 }, "x", "bob");
        assert!(shard > send_limit && shard < send_limit + 64 * 1024, "{shard}");
    }

    /// A-F5: a guest's public file header counts only for the server the pull was made
    /// in, and only while the pull is fresh.
    #[test]
    fn a_guest_pull_is_answered_only_for_its_server_while_fresh() {
        let now = std::time::Instant::now();
        assert!(guest_answer_fresh("srv", now, "srv"));
        assert!(!guest_answer_fresh("srv", now, "other-srv"), "A-F5: a header for another server answered the pull");
        if let Some(old) = now.checked_sub(GUEST_PULL_TTL + std::time::Duration::from_secs(1)) {
            assert!(!guest_answer_fresh("srv", old, "srv"), "A-F5: an expired pull was answered");
        }
    }

    /// A-F7, A-T20: a completed stream with no header yet parks, but one sender holds
    /// at most its share and pays with its own oldest, and past the byte budget the
    /// heaviest sender pays, so another peer's early arrival outlives the flood.
    #[test]
    fn early_streams_cap_each_sender_and_evict_its_own_oldest() {
        let base = std::time::Instant::now();
        let parked = |who: &str, size: u64, n: u64| EarlyStream {
            temp_path: PathBuf::from(format!("{who}_{n}.tmp")),
            size,
            sender: who.into(),
            parked_at: base + std::time::Duration::from_millis(n),
        };
        let mut early = HashMap::new();
        assert!(park_early_stream(&mut early, "bob-0".into(), parked("bob", 10, 0)).is_empty());
        let mut evicted = Vec::new();
        for n in 1..=20 {
            evicted.extend(park_early_stream(&mut early, format!("mal-{n}"), parked("mallory", 10, n)));
        }
        let oldest: Vec<PathBuf> = (1..=4).map(|n| PathBuf::from(format!("mallory_{n}.tmp"))).collect();
        assert_eq!(evicted, oldest, "A-T20: a sender kept more than its share, or paid with the wrong ones");
        assert_eq!(early.values().filter(|s| s.sender == "mallory").count(), MAX_EARLY_STREAMS_PER_SENDER);

        let big = MAX_EARLY_STREAM_BYTES / 4;
        let mut evicted = Vec::new();
        for n in 21..=26 {
            evicted.extend(park_early_stream(&mut early, format!("mal-{n}"), parked("mallory", big, n)));
        }
        let held: u64 = early.values().map(|s| s.size.max(EARLY_STREAM_MIN_CHARGE)).sum();
        assert!(held <= MAX_EARLY_STREAM_BYTES, "A-T20: {held} bytes parked past the budget");
        assert!(evicted.iter().all(|p| p.to_string_lossy().starts_with("mallory_")), "{evicted:?}");
        assert!(early.contains_key("bob-0"), "A-T20: another sender's early arrival paid for the flood");

        let replaced = park_early_stream(&mut early, "bob-0".into(), parked("bob", 10, 30));
        assert_eq!(replaced, vec![PathBuf::from("bob_0.tmp")], "a re-parked id leaked its old temp");

        let node = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src").join("node");
        let direct_park = ["early_file_streams", ".insert("].concat();
        for f in ["file_handler.rs", "swarm.rs"] {
            let src = std::fs::read_to_string(node.join(f)).expect("read node source");
            assert!(!src.contains(&direct_park), "A-T20: {f} parks a stream past park_early_stream");
        }
    }

    /// H1, H2, H6: a FileHeader registers the key its file's bytes decrypt under,
    /// so it lands only from the file's owner (or a holder we asked), only from a
    /// member who can read the channel, and never for bytes already on disk. Each
    /// refused header is a well-formed MLS header from its own sender.
    #[tokio::test]
    #[allow(clippy::await_holding_lock)] // the resolver guard is process-global
    async fn authz_file_header_delivers_only_for_its_owner() {
        let _g = super::super::resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let path = tmp.path().join("hdr.db").to_string_lossy().into_owned();
        let pass = "ab".repeat(32);
        let (mut state, _owner) = crate::crdt::testkeys::owned_state("srv", "S", 1);
        let (bob, mallory, stranger) = (
            crate::crdt::testkeys::keys(2).1,
            crate::crdt::testkeys::keys(3).1,
            crate::crdt::testkeys::keys(4).1,
        );
        for id in [&bob, &mallory] {
            let op = state.create_op(crate::crdt::operations::CrdtPayload::MemberAdded {
                peer_id: id.clone(),
                display_name: "m".into(),
                follow: None,
                ask: None,
            });
            state.apply_op(&op).unwrap();
        }
        let states = HashMap::from([("srv".to_string(), state)]);
        let store = || crate::storage::MessageStore::open(&path, &pass).unwrap();
        store().insert_file_metadata(
            "f1", "a.png", "png", "image/png", 10, 0, true, None, None, Some("m1"),
            "channel", "srv:srv-general", &bob, false, 1, None, None, None,
        ).unwrap();
        let mut pending = HashMap::new();
        let mut early = HashMap::new();

        deliver_header(&states, &mut pending, &mut early, &mallory, "f1", &path, &pass).await;
        assert!(!pending.contains_key("f1"), "a member registered a key for Bob's file");
        deliver_header(&states, &mut pending, &mut early, &stranger, "f2", &path, &pass).await;
        assert!(!pending.contains_key("f2"), "a non-member registered a key in the channel");
        assert!(
            file_header_refused(&store(), &states, "f1", Some("srv"), Some("srv-general"), &mallory, true).is_none(),
            "the holder we asked answers for Bob's file",
        );

        deliver_header(&states, &mut pending, &mut early, &bob, "f1", &path, &pass).await;
        assert_eq!(pending.remove("f1").map(|p| (p.sender, p.size)), Some((bob.clone(), 10)), "A-F7: the header's size bounds its stream");

        // Bytes that beat Bob's header wait under the stream it names, and bytes of his
        // stream to another device under that one; the header tries only its own at once.
        let parked = |name: &str| {
            let temp = tmp.path().join(name);
            std::fs::write(&temp, b"ciphertext").unwrap();
            EarlyStream { temp_path: temp, size: 10, sender: bob.clone(), parked_at: std::time::Instant::now() }
        };
        let (named, other) = (file_stream_id("f1", &bob, "us"), file_stream_id("f1", &bob, "sibling"));
        early.insert(named.clone(), parked("named.tmp"));
        early.insert(other.clone(), parked("other.tmp"));
        deliver_header(&states, &mut pending, &mut early, &bob, "f1", &path, &pass).await;
        assert!(!pending.contains_key("f1"), "Bob's header never tried the bytes that came before it");
        assert!(early.contains_key(&named), "bytes its key cannot open were dropped, not held for their own header");

        let bytes = tmp.path().join("f1.png");
        std::fs::write(&bytes, b"done").unwrap();
        store().mark_file_complete("f1", &bytes.to_string_lossy()).unwrap();
        deliver_header(&states, &mut pending, &mut early, &bob, "f1", &path, &pass).await;
        assert!(!pending.contains_key("f1"), "a completed file took a new key");
        assert!(
            !early.contains_key(&named) && !tmp.path().join("named.tmp").exists(),
            "the header of a completed file left its own stream's early bytes behind",
        );
        assert!(early.contains_key(&other), "a header took another device's stream as its own");
    }

    /// A-D2: a card riding a signed item must describe the file its committed id
    /// hashes from, so a sync responder cannot rename or resize someone's file.
    #[test]
    fn authz_a_synced_card_cannot_relabel_a_committed_file() {
        let _g = super::super::resolver::test_lock();
        let tmp = crate::test_tmp::tempdir().unwrap();
        let store = crate::storage::MessageStore::open(
            &tmp.path().join("s.db").to_string_lossy(), &"ab".repeat(32),
        ).unwrap();
        let sha = super::super::file_commit::sha256_hex(b"invoice");
        let fid = super::super::file_commit::file_id_for(&super::super::file_commit::FileCommit {
            author: "bob", mid: "m1", size: 7, sha256: &sha, name: "invoice.pdf", ext: "pdf", vthumb: None,
        });
        let card = super::super::types::SyncFileMetaItem {
            fid: fid.clone(), name: "invoice.pdf".into(), ext: "pdf".into(), mime: "application/pdf".into(),
            size: 7, img: false, w: None, h: None, mid: Some("m1".into()), ts: 1, sender: "bob".into(),
            vthumb: None, thumb: None, sha256: Some(sha.clone()),
        };
        let lands = |fm: &super::super::types::SyncFileMetaItem, mid: &str, author: &str| {
            synced_file_meta(&store, Some(fm), Some(&fid), Some(mid), author).is_some()
        };
        assert!(lands(&card, "m1", "bob"));
        let renamed = super::super::types::SyncFileMetaItem { name: "invoice.exe".into(), ..card.clone() };
        assert!(!lands(&renamed, "m1", "bob"), "a renamed card");
        let resized = super::super::types::SyncFileMetaItem { size: 8, ..card.clone() };
        assert!(!lands(&resized, "m1", "bob"), "a resized card");
        let bare = super::super::types::SyncFileMetaItem { sha256: None, ..card.clone() };
        assert!(!lands(&bare, "m1", "bob"), "a card without its hash");
        assert!(!lands(&card, "m1", "mallory"), "another author's item");
        assert!(!lands(&card, "m2", "bob"), "another message");
    }

    /// C-FILES-03: when the encoder cannot read a photo, the original goes out,
    /// and it used to go out with its Exif GPS. Every arm now strips it, and a
    /// photo nothing can clean is refused.
    #[test]
    fn a_photo_the_encoder_cannot_read_still_leaves_without_its_gps() {
        use super::super::media_strip::fixtures::{jpeg_with_gps, LOCATION};
        let mut jpeg = jpeg_with_gps(6);
        // SOF3, lossless coding: valid markers the encoder refuses to decode.
        let sof = jpeg.windows(4).position(|w| w == [0xFF, 0xC0, 0x00, 0x11]).expect("baseline frame header");
        jpeg[sof + 1] = 0xC3;
        assert!(image_convert::convert_to_webp_with_quality(&jpeg, image_convert::WebpQuality::Balanced).is_err());

        let (out, ext, ..) = convert_image_data(jpeg, "jpg", image_convert::WebpQuality::Balanced, None, None)
            .expect("the original is cleaned and sent");
        assert_eq!(ext, "jpg");
        assert!(!out.windows(LOCATION.len()).any(|w| w == LOCATION), "no GPS leaves with the original");

        // Every GIF takes the animation encoder, so the last arm only ever meets
        // a `.gif` holding something else.
        let (misnamed, ext, ..) =
            convert_image_data(jpeg_with_gps(1), "gif", image_convert::WebpQuality::Balanced, None, None).unwrap();
        assert_eq!(ext, "gif");
        assert!(!misnamed.windows(LOCATION.len()).any(|w| w == LOCATION), "a photo named .gif is cleaned too");

        assert_eq!(
            convert_image_for_send(b"not a picture".to_vec(), "png", image_convert::WebpQuality::Balanced, None, None).err(),
            Some(super::super::media_strip::REFUSED.to_string()),
            "a photo nothing can clean is refused, not sent as it is",
        );
    }

    /// FILE-2 regression. The auto-download exemption is the one way a pushed
    /// transfer writes bytes in a conversation the user gated, so it has to name a
    /// real voice note: flag, filename, extension and size all have to agree.
    #[test]
    fn voice_exemption_requires_flag_name_ext_and_size() {
        // The auto-download conf is process-global; this is the same lock the
        // harness tests take, so the two families cannot cross each other's
        // settings under a threaded `cargo test`.
        let _g = super::super::resolver::test_lock();
        const SMALL: u64 = 90 * 1024; // a real 30-second note

        // The genuine article, in both filename shapes the recorder produces.
        assert!(
            is_voice_note_exempt(SMALL, "voice_1730000000000_12345.ogg", "ogg", true),
            "the recorder's own temp basename is a voice note",
        );
        assert!(
            is_voice_note_exempt(SMALL, "Voice message.ogg", "ogg", true),
            "the display name is a voice note",
        );
        assert!(
            is_voice_note_exempt(SMALL, "voice_1.ogg", "OGG", true),
            "the extension compare is case-insensitive",
        );
        assert!(
            is_voice_note_exempt(VOICE_NOTE_MAX_BYTES, "voice_1.ogg", "ogg", true),
            "the ceiling itself is still a note",
        );

        // (a) The flag and the name say voice, the extension says executable.
        assert!(
            !is_voice_note_exempt(SMALL, "voice_1.ogg", "exe", true),
            "a voice-flagged header with a non-ogg extension is not a note",
        );
        // (b) Flag, name and extension all agree, the size does not.
        assert!(
            !is_voice_note_exempt(VOICE_NOTE_MAX_BYTES + 1, "voice_1.ogg", "ogg", true),
            "one byte over the ceiling is not a note",
        );
        assert!(
            !is_voice_note_exempt(34 * 1024 * 1024, "voice_1.ogg", "ogg", true),
            "a 34 MB push is not a note however it is flagged",
        );
        // (c) The name alone no longer buys the exemption: `voice` is a
        // sender-chosen field, and so is the filename.
        assert!(
            !is_voice_note_exempt(SMALL, "Voice message.ogg", "ogg", false),
            "the filename alone does not make a note",
        );
        assert!(
            !is_voice_note_exempt(SMALL, "payload.ogg", "ogg", true),
            "the flag alone does not make a note",
        );

        // And the whole gate, through the exemption and around it.
        let key = "dm:12D3KooW-file2-unit";
        set_auto_download_conf(0, HashMap::new()); // never, globally
        assert!(
            auto_download_allows(SMALL, "voice_1.ogg", "ogg", key, true),
            "a genuine note still rides through a global never",
        );
        assert!(
            !auto_download_allows(SMALL, "voice_1.ogg", "exe", key, true),
            "a forged voice flag does not",
        );
        assert!(
            !auto_download_allows(SMALL, "holiday.png", "png", key, false),
            "an ordinary push does not",
        );

        set_auto_download_conf(169, HashMap::new()); // the permissive default
        assert!(
            auto_download_allows(SMALL, "holiday.png", "png", key, false),
            "an ordinary push rides through a permissive threshold",
        );
        assert!(
            !auto_download_allows(200 * 1024 * 1024, "movie.mkv", "mkv", key, false),
            "and stops at it",
        );

        // Leave the permissive default behind for the rest of the suite.
        set_auto_download_conf(169, HashMap::new());
    }

    /// HOL-SEC-117: a shard landing for a download whose other copies fail their manifest
    /// hands the download back for a fresh pull instead of failing it for good: refuted
    /// copies deleted here, unvouched ones left to the pull, which knows our placements.
    #[tokio::test]
    async fn a_failed_rebuild_hands_back_a_fresh_pull() {
        use crate::vault::content_store::{ContentStore, StorageTier, content_id, shard_key};
        let tmp = crate::test_tmp::tempdir().unwrap();
        let db = tmp.path().join("vault.db").to_string_lossy().into_owned();
        let pass = "ab".repeat(32);
        let vault = tmp.path().join("vault");
        let (tx, _rx) = mpsc::channel(8);
        let manifest = |cid: &str, shard_hashes: Vec<String>| crate::vault::pipeline::VaultManifest {
            content_id: cid.to_string(),
            encryption_key: "00".repeat(32),
            nonce: "00".repeat(12),
            original_size: 40,
            k: 3,
            m: 2,
            shard_count: 5,
            file_name: "a.bin".into(),
            mime_type: "application/octet-stream".into(),
            storage_tier: "standard".into(),
            created_at: 1,
            creator_peer_id: "creator".into(),
            channel_id: "srv-general".into(),
            message_id: String::new(),
            shard_hashes,
        };
        let ciphertext = b"an erasure-coded ciphertext long enough to split in three".to_vec();
        let cid = content_id(&ciphertext);
        let shards = crate::vault::erasure::encode(&ciphertext, 3, 2, &cid).unwrap();
        let rebuild = async |cid: &str| {
            let cs = ContentStore::open(&db, &pass, &vault).unwrap();
            attempt_vault_reconstruction(cs, &mut HashMap::new(), &tx, cid, "srv".into(), 3, &db, &pass).await
        };
        let cs = ContentStore::open(&db, &pass, &vault).unwrap();

        // No hashes to tell which copy is bad: the fresh pull sorts them out.
        cs.save_manifest("srv", "srv-general", &manifest(&cid, Vec::new())).unwrap();
        for si in 0..2u16 {
            cs.store_shard("srv", &cid, si, 3, 2, 0, StorageTier::Standard, &shards[si as usize]).unwrap();
        }
        cs.store_shard("srv", &cid, 2, 3, 2, 0, StorageTier::Standard, b"planted").unwrap();
        let repull = rebuild(&cid).await;
        assert!(
            repull.is_some_and(|r| r.content_id == cid && r.refuted.is_none()),
            "HOL-SEC-117: a rebuild that failed on unvouched copies was not pulled afresh",
        );
        assert!(
            (0..3u16).all(|si| cs.has_shard(&shard_key(&cid, si)).unwrap()),
            "a stream completion deleted unvouched copies without knowing which we hold for others",
        );

        // Hashes in the manifest: only the refuted copy goes, and the download pulls again.
        let pinned = "e1".repeat(32);
        cs.save_manifest("srv", "srv-general", &manifest(&pinned, shards.iter().map(|s| content_id(s)).collect())).unwrap();
        cs.store_shard("srv", &pinned, 0, 3, 2, 0, StorageTier::Standard, &shards[0]).unwrap();
        cs.store_shard("srv", &pinned, 1, 3, 2, 0, StorageTier::Standard, b"planted").unwrap();
        assert!(rebuild(&pinned).await.is_some(), "HOL-SEC-117: a deleted copy was never asked for again");
        assert!(cs.has_shard(&shard_key(&pinned, 0)).unwrap() && !cs.has_shard(&shard_key(&pinned, 1)).unwrap());

        // Every copy is the one its manifest pins: a failed rebuild is not theirs to pull again.
        let vouched = "e2".repeat(32);
        cs.save_manifest("srv", "srv-general", &manifest(&vouched, shards.iter().map(|s| content_id(s)).collect())).unwrap();
        for si in 0..3u16 {
            cs.store_shard("srv", &vouched, si, 3, 2, 0, StorageTier::Standard, &shards[si as usize]).unwrap();
        }
        assert!(rebuild(&vouched).await.is_none(), "a rebuild that failed on vouched copies was pulled again");
        assert!((0..3u16).all(|si| cs.has_shard(&shard_key(&vouched, si)).unwrap()), "a vouched copy was deleted");
    }

    /// C-FILES-04: only a placeholder-sized WebP reaches the store; its pixels are
    /// judged again where they cross to Dart (`peer_thumb_for_display`).
    #[test]
    fn a_header_thumb_must_be_a_placeholder_sized_webp() {
        let b64 = |b: &[u8]| base64::engine::general_purpose::STANDARD.encode(b);
        let still = |w: u32, h: u32| {
            let img = image::RgbaImage::from_pixel(w, h, image::Rgba([40, 90, 160, 255]));
            let mut png = Vec::new();
            image::DynamicImage::ImageRgba8(img)
                .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
                .unwrap();
            image_convert::convert_to_webp_preview(&png, 4096).unwrap().0
        };

        let blur = b64(&still(32, 24));
        assert_eq!(accept_header_thumb(Some(blur.clone()), true, "image/png"), Some(blur));
        let poster = b64(&still(400, 225));
        assert!(accept_header_thumb(Some(poster), false, "video/mp4").is_some());

        let png = {
            let mut out = Vec::new();
            image::DynamicImage::new_rgba8(8, 8)
                .write_to(&mut std::io::Cursor::new(&mut out), image::ImageFormat::Png)
                .unwrap();
            out
        };
        // VP8X header declaring a 4000x4000 canvas over a few bytes.
        let mut huge = b"RIFF\x40\x00\x00\x00WEBPVP8X\x0a\x00\x00\x00".to_vec();
        huge.extend_from_slice(&[0, 0, 0, 0, 0x9F, 0x0F, 0, 0x9F, 0x0F, 0]);
        for refused in [b64(&png), b64(&still(600, 300)), b64(&huge), "not base64!".to_string()] {
            assert!(accept_header_thumb(Some(refused.clone()), true, "image/png").is_none(), "{refused:.40}");
        }
        assert!(accept_header_thumb(Some(b64(&still(32, 24))), false, "application/pdf").is_none());
    }
}
