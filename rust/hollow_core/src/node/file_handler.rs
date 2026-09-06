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
    send_mls_broadcast, send_mls_broadcast_topic, send_encrypted_message,
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
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    local_peer_str: &str,
    peer_str: &str,
) {
    let mb = if crate::node::resolver::same_identity(peer_str, local_peer_str) {
        global_auto_download_mb()
    } else {
        let master = crate::node::resolver::resolve(peer_str);
        effective_auto_download_mb(&format!("dm:{master}"))
    };
    send_message_to_peer(
        ws_cmd_tx, ws_room_peers, peer_str,
        HavenMessage::AutoDownloadPref { mb },
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
                advertise_auto_dl_pref_to_peer(ws_cmd_tx, ws_room_peers, local_peer_str, peer);
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

    let mut file_data = match tokio::fs::read(&file_path).await {
        Ok(d) => d,
        Err(e) => {
            hollow_log!("[HOLLOW-FILE] Failed to read file: {e}");
            let _ = event_tx.send(NetworkEvent::FileFailed {
                file_id: message_id.clone(),
                error: format!("Failed to read file: {e}"),
            }).await;
            return;
        }
    };

    let path = std::path::Path::new(&file_path);
    let original_name = path.file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .to_string();
    let original_ext = path.extension()
        .unwrap_or_default()
        .to_string_lossy()
        .to_lowercase();

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

    let needs_convert = is_image
        && (image_convert::should_convert_to_webp(&original_ext)
            || original_ext == "webp"
            || original_ext == "gif");

    if needs_convert {
        // CPU-heavy conversion: hop off the event loop and re-enter via
        // SendFileConverted, so messages, CRDT and call signaling keep flowing.
        spawn_image_conversion(
            peer_id, server_id, channel_id, message_id, message_text,
            vthumb, share_ref, original_name, is_image, voice,
            file_data, original_ext, override_width, override_height,
            cmd_tx.clone(), db_path, db_passphrase,
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
            vthumb, share_ref, original_name, voice,
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
        None, voice,
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
                    width, height, thumb, voice,
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

/// Receive-side acceptance filter for the envelope-borne `thumb`: images get the
/// tiny blur placeholder, videos the poster frame, and anything else or anything
/// oversized is dropped before it reaches the DB or UI. ONE helper, so every
/// ingest path stays in lockstep.
pub(crate) fn accept_header_thumb(thumb: Option<String>, img: bool, mime: &str) -> Option<String> {
    thumb.filter(|t| {
        (img || mime.starts_with("video/"))
            && !t.is_empty()
            && t.len() <= FILE_THUMB_MAX_B64_LEN
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

/// The moved step-4 conversion block: runs on the blocking pool, never the
/// event loop. Fallbacks mirror the original inline behavior exactly.
fn convert_image_for_send(
    file_data: Vec<u8>,
    original_ext: &str,
    webp_quality: image_convert::WebpQuality,
    override_width: Option<u32>,
    override_height: Option<u32>,
) -> (Vec<u8>, String, Option<u32>, Option<u32>, Option<String>) {
    // Placeholder thumb first, from the ORIGINAL bytes (issue #41 carry-over).
    let thumb = generate_file_thumb(&file_data);
    let (data, ext, w, h) = convert_image_data(file_data, original_ext, webp_quality, override_width, override_height);
    (data, ext, w, h, thumb)
}

fn convert_image_data(
    mut file_data: Vec<u8>,
    original_ext: &str,
    webp_quality: image_convert::WebpQuality,
    override_width: Option<u32>,
    override_height: Option<u32>,
) -> (Vec<u8>, String, Option<u32>, Option<u32>) {
    // ANIMATED sources first, decided from the BYTES. Branching on the extension is
    // what froze an APNG and flattened an animated WebP to frame 0. Re-encoding
    // through the animation encoder drops metadata too, which is the whole reason
    // the still paths re-encode.
    if image_convert::is_animated_image(&file_data) {
        match image_convert::convert_animation_to_webp(&file_data, webp_quality) {
            Ok((webp_data, w, h)) => {
                hollow_log!(
                    "[HOLLOW-FILE] Converted animation to animated WebP ({:?}): {}KB -> {}KB ({}x{})",
                    webp_quality, file_data.len() / 1024, webp_data.len() / 1024, w, h
                );
                return (webp_data, "webp".to_string(), Some(w), Some(h));
            }
            Err(e) => {
                // Send the original rather than a frozen frame: a GIF gets its
                // metadata stripped in place, anything else rides as-is.
                hollow_log!("[HOLLOW-FILE] Animation conversion failed, sending original: {e}");
                let out = if original_ext == "gif" {
                    image_convert::strip_gif_metadata(&file_data)
                } else {
                    std::mem::take(&mut file_data)
                };
                let dims = image_convert::get_image_dimensions(&out).ok();
                return (out, original_ext.to_string(), dims.map(|d| d.0), dims.map(|d| d.1));
            }
        }
    }
    if image_convert::should_convert_to_webp(original_ext) {
        match image_convert::convert_to_webp_with_quality(&file_data, webp_quality) {
            Ok((webp_data, w, h)) => {
                hollow_log!("[HOLLOW-FILE] Converted to WebP ({:?}): {}KB -> {}KB ({}x{})",
                    webp_quality, file_data.len() / 1024, webp_data.len() / 1024, w, h);
                (webp_data, "webp".to_string(), Some(w), Some(h))
            }
            Err(e) => {
                hollow_log!("[HOLLOW-FILE] WebP conversion failed, sending original: {e}");
                let dims = image_convert::get_image_dimensions(&file_data).ok();
                (file_data, original_ext.to_string(), dims.map(|d| d.0), dims.map(|d| d.1))
            }
        }
    } else if original_ext == "webp" {
        // WebP passthrough — strip metadata by decode+re-encode.
        let stripped = image_convert::strip_webp_metadata(&file_data)
            .unwrap_or_else(|_| std::mem::take(&mut file_data));
        let dims = image_convert::get_image_dimensions(&stripped).ok();
        (stripped, original_ext.to_string(), dims.map(|d| d.0), dims.map(|d| d.1))
    } else {
        (file_data, original_ext.to_string(), override_width, override_height)
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
    file_data: Vec<u8>,
    original_ext: String,
    override_width: Option<u32>,
    override_height: Option<u32>,
    cmd_tx: mpsc::Sender<super::types::NodeCommand>,
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
            Ok(t) => t,
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
                    thumb, voice,
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

    let file_id = file_transfer::generate_file_id();
    let file_size = final_data.len() as u64;
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

    hollow_log!("[HOLLOW-FILE] File {file_id}: {original_name} -> {file_size} bytes (streamed={store_full_file})");

    // 6. Store file locally (skip for non-image vault files — shards handle storage).
    let final_path = file_transfer::final_file_path(&file_id, &final_ext);
    if store_full_file {
        if let Err(e) = tokio::fs::write(&final_path, &final_data).await {
            hollow_log!("[HOLLOW-FILE] Failed to save local file: {e}");
        }
    }

    let local_peer = local_peer_str.to_string();
    // Lamport-bumped send stamp — see message_ops DM send / chat_clock.rs.
    let order_us = crate::chat_clock::next_send_stamp_us();
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
        vthumb.as_ref(), thumb.as_deref(), store_full_file, &final_path,
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
        &signing_payload_text, &message_id, &file_id, order_us,
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
        );

        let msg = DmFileMsg {
            signing_payload_text: &signing_payload_text,
            timestamp,
            sig: &sig,
            pk: &pk,
            message_id: &message_id,
            file_id: &file_id,
            order_us,
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
            message_text: &message_text,
            local_peer_str,
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
            &message_id, &file_id, order_us, &final_data,
            &original_name, &final_ext, &final_mime, file_size,
            is_image, width, height, &vthumb, &thumb, voice, &share_ref, &local_peer,
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
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    pub_key_b64: &str,
) -> (Option<String>, Option<String>) {
    let extras = crate::node::crypto_handler::SignedExtras {
        mid: Some(message_id),
        reply_to: None,
        file_id: Some(file_id),
        order_us: Some(order_us),
        lp_digest: None,
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
            vthumb, thumb,
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
) {
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let _ = store.insert(
            peer_str, text, true, timestamp,
            sig, pk, Some(message_id),
            None, Some(file_id), Some(order_us),
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
    message_text: &'a str,
    local_peer_str: &'a str,
    total_chunks: u32,
    // THIS device's identity — signs the Olm KeyRequest fired when a DM file
    // targets a device we have no session with (Fix B).
    device_keypair: &'a crate::identity::native_identity::NativeKeypair,
    device_peer_id: &'a str,
}

/// Shared DM FileHeader builder — every DM header uses chunks=0 (streamed),
/// sid/cid=None, target=None, share_ref=None; the varying fields (signature,
/// AES material, inline bytes) are parameterized per branch.
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
            share_ref: None,
            order_us: Some(msg.order_us),
            inline_bytes,
            thumb: msg.thumb.clone(),
            voice: msg.voice,
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
        }),
    };
    let envelope_json = serde_json::to_string(&envelope)
        .unwrap_or_else(|_| msg.signing_payload_text.to_string());
    if olm.has_session(peer_str) {
        // EXACT-device reachability, not identity-wide: in a fan-out one device may
        // be online while a sibling is offline.
        let reachable = ws_room_for_peer(ws_room_peers, peer_str).is_some();

        // CRITICAL, Olm ratchet ordering: `send_encrypted_message` ALWAYS calls
        // olm.encrypt(), advancing and persisting the ratchet, BEFORE it checks
        // reachability, and DISCARDS the ciphertext if the peer is offline. For an
        // OFFLINE IMAGE that wasted encryption burns a ratchet slot the receiver
        // never sees, a permanent gap that breaks decrypt of everything after it.
        // So when offline-and-image the caption is sent exactly once inside
        // send_offline_dm_image, AFTER the inlined FileHeader.
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
        if reachable && receiver_pref_declines(peer_auto_dl, peer_str, msg) {
            // Sender-side pre-negotiation: this device ADVERTISED a threshold this
            // push would violate, so its gate would decline the header and discard
            // every byte. The metadata-only header renders the card with a manual
            // Download button, and the explicit FileRequest pull still works.
            hollow_log!(
                "[HOLLOW-FILE] Receiver pref gates {} ({} bytes) for {peer_str} — sending metadata-only header, no bytes",
                msg.file_id, msg.file_size
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
        } else if msg.is_image {
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
                msg.file_id, &temp_path, enc.ciphertext.len() as u64,
            ).await;
            hollow_log!("[HOLLOW-FILE] Streaming {} ({} bytes) to DM {peer_str}", msg.file_id, enc.ciphertext.len());
            // Clean up the sender-side ciphertext temp once the WS-relay stream is
            // queued. A WebRTC send still in flight owns the temp and removes it on
            // WebRtcTransferComplete, so only delete when no such send is pending.
            if !pending_webrtc_sends.contains_key(msg.file_id) {
                let _ = tokio::fs::remove_file(&temp_path).await;
            }
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
) {
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let _ = store.insert_channel_message(
            sid, cid, local_peer, text, true, timestamp,
            sig, pk, Some(message_id),
            None, Some(file_id), Some(order_us),
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
    final_data: &[u8],
    original_name: &str,
    final_ext: &str,
    final_mime: &str,
    file_size: u64,
    is_image: bool,
    width: Option<u32>,
    height: Option<u32>,
    vthumb: &Option<VideoThumbRef>,
    thumb: &Option<String>,
    voice: bool,
    share_ref: &Option<super::types::ShareRef>,
    local_peer: &str,
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
        }),
    };

    persist_sent_channel_row(
        db_path, db_passphrase, sid, cid, local_peer, signing_payload_text,
        timestamp, sig.as_deref(), pk.as_deref(), message_id, file_id, order_us,
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
            }),
        };
        super::message_ops::send_public_channel_msg(ws_cmd_tx, sid, cid, &msg);
    } else {
        broadcast_channel_caption_mls(mls, server_states, ws_cmd_tx, crypto_store, sid, cid, &envelope);
    }

    // Skip full-file streaming in erasure coding mode (6+ members): vault shards
    // are distributed separately via VaultUploadFile.
    let member_count = server_states.get(sid)
        .map(|s| s.members.len())
        .unwrap_or(0);
    // Stream images to online peers even in vault mode (instant display).
    // Non-image files in 6+ servers use vault shards only.
    let use_vault_only = member_count >= 6 && !is_image;

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
            inline_bytes: None,
            thumb: thumb.clone(),
            voice,
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
        } else if let Some(overlay) = gossip_overlays.get_mut(sid) {
            gossip_broadcast_channel_file(
                overlay, mls, crypto_store, ws_cmd_tx, webrtc_peers, event_tx,
                sid, cid, file_id, local_peer, &temp_path, ct_size,
            ).await;
        } else {
            replicate_channel_file_full(
                state, ws_cmd_tx, ws_room_peers, webrtc_peers,
                pending_webrtc_sends, event_tx, local_peer, cid, file_id,
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
        let use_subgroup = server_states.get(sid)
            .is_some_and(|s| s.channel_uses_subgroup(cid));
        let group_key = if use_subgroup {
            crate::crypto::subgroup_id(sid, cid)
        } else {
            sid.to_string()
        };
        if mls_mgr.has_group(&group_key) {
            if let Err(e) = send_mls_broadcast_topic(mls_mgr, ws_cmd_tx, sid, cid, use_subgroup, envelope, crypto_store) {
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
        && let Err(e) = send_mls_broadcast_topic(mls.as_mut().unwrap(), ws_cmd_tx, sid, cid, use_subgroup, header, crypto_store)
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

/// Gossip broadcast: MLS-announce BroadcastMeta so all peers know this file
/// is coming, then send to gossip neighbors only (they relay further).
#[allow(clippy::too_many_arguments)]
async fn gossip_broadcast_channel_file(
    overlay: &mut gossip::GossipOverlay,
    mls: &mut Option<MlsManager>,
    crypto_store: &CryptoStore,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    webrtc_peers: &std::collections::HashSet<String>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    sid: &str,
    cid: &str,
    file_id: &str,
    local_peer: &str,
    temp_path: &std::path::Path,
    ct_size: u64,
) {
    let broadcast_id = gossip::generate_broadcast_id();
    overlay.mark_broadcast_seen(&broadcast_id);

    let meta_envelope = MessageEnvelope::BroadcastMeta {
        broadcast_id: broadcast_id.clone(),
        origin: local_peer.to_string(),
        sid: sid.to_string(),
        cid: cid.to_string(),
        file_id: file_id.to_string(),
        ttl: gossip::DEFAULT_BROADCAST_TTL,
    };
    if let Some(mls_mgr) = mls {
        if mls_mgr.has_group(sid) {
            let _ = send_mls_broadcast(mls_mgr, ws_cmd_tx, sid, &meta_envelope, crypto_store);
        }
    }

    broadcast_to_gossip_neighbors(
        overlay, webrtc_peers, event_tx,
        &broadcast_id, gossip::DEFAULT_BROADCAST_TTL,
        local_peer, &temp_path.to_string_lossy(),
        ct_size, "file", 0, None, cid,
    ).await;

    hollow_log!("[HOLLOW-GOSSIP] File {file_id} broadcast initiated (bid={broadcast_id})");
}

/// Small server (<6 members, no gossip overlay): full replication to each ONLINE
/// DEVICE of each member, then clean up the sender-side ciphertext temp once all
/// WS-relay streams have been queued. A WebRTC send still in flight owns the temp
/// and removes it on WebRtcTransferComplete, so it must not be deleted here.
/// Without the cleanup the encrypted temp leaked forever.
#[allow(clippy::too_many_arguments)]
async fn replicate_channel_file_full(
    state: &ServerState,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    webrtc_peers: &std::collections::HashSet<String>,
    pending_webrtc_sends: &mut HashMap<String, (String, ws_stream_transfer::StreamKind, String, PathBuf, u64)>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    local_peer: &str,
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
                file_id, temp_path, ct_size,
            ).await;
        }
    }
    if !pending_webrtc_sends.contains_key(file_id) {
        let _ = tokio::fs::remove_file(temp_path).await;
    }
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
    let offset = pending_ws_transfers
        .get(&file_id)
        .map(|s| s.bytes_received)
        .unwrap_or(0);
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
            hollow_log!("[HOLLOW-FILE] Requesting rowless file {file_id} from {t} (offset {offset})");
            send_message_to_peer(
                ws_cmd_tx,
                ws_room_peers,
                &t,
                HavenMessage::FileRequest { file_id, chunks, offset },
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
    pending_file_streams: &mut HashMap<String, PendingFileStream>,
    pending_shard_streams: &mut HashMap<String, PendingShardStream>,
    pending_vault_downloads: &mut HashMap<String, (String, usize, usize)>,
    early_file_streams: &mut HashMap<String, (PathBuf, u64, String)>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    gossip_overlays: &mut HashMap<String, gossip::GossipOverlay>,
    webrtc_peers: &std::collections::HashSet<String>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-WEBRTC] Transfer complete: {transfer_id} from {sender_peer_id}");
    let stream_kind = if kind == "shard" {
        ws_stream_transfer::StreamKind::Shard { shard_index }
    } else {
        ws_stream_transfer::StreamKind::File
    };
    let temp_path_buf = PathBuf::from(&temp_path);
    let file_size = std::fs::metadata(&temp_path).map(|m| m.len()).unwrap_or(0);
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
    ).await;

    // Gossip relay: if this file has a pending relay, forward to neighbors.
    if kind == "file" {
        for overlay in gossip_overlays.values_mut() {
            if let Some(relay) = overlay.take_pending_relay(&transfer_id) {
                if relay.ttl > 0 {
                    hollow_log!(
                        "[HOLLOW-GOSSIP] Relaying file {transfer_id} (bid={}, ttl={}) to neighbors",
                        relay.broadcast_id, relay.ttl
                    );
                    broadcast_to_gossip_neighbors(
                        overlay, webrtc_peers, event_tx,
                        &relay.broadcast_id, relay.ttl.saturating_sub(1),
                        &relay.origin, &temp_path,
                        file_size, "file", 0,
                        Some(&relay.sender_peer_id),
                        &relay.channel_id,
                    ).await;
                }
                break;
            }
        }
    }
}

/// Handle NodeCommand::WebRtcSendComplete — completed send.
pub(crate) fn handle_webrtc_send_complete(
    transfer_id: String,
    pending_webrtc_sends: &mut HashMap<String, (String, ws_stream_transfer::StreamKind, String, PathBuf, u64)>,
) {
    hollow_log!("[HOLLOW-WEBRTC] Send complete: {transfer_id}");
    if let Some((_, _, _, path, _)) = pending_webrtc_sends.remove(&transfer_id) {
        if path.file_name().map(|n| n.to_string_lossy().starts_with(".stream_send_")).unwrap_or(false) {
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
    webrtc_peers: &mut std::collections::HashSet<String>,
    pending_webrtc_sends: &mut HashMap<String, (String, ws_stream_transfer::StreamKind, String, PathBuf, u64)>,
    pending_file_streams: &HashMap<String, PendingFileStream>,
    early_file_streams: &mut HashMap<String, (PathBuf, u64, String)>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    event_tx: &mpsc::Sender<NetworkEvent>,
) {
    hollow_log!("[HOLLOW-WEBRTC] Transfer failed: {transfer_id} to/from {peer_id}: {error}");
    webrtc_peers.remove(&peer_id);
    // Sender-side retry: re-send via WSS relay.
    if let Some((_, kind, id, source_path, total_size)) = pending_webrtc_sends.remove(&transfer_id) {
        hollow_log!("[HOLLOW-WEBRTC] Sender fallback: retrying {id} via WSS relay");
        stream_to_peer(
            &ws_cmd_tx, &ws_room_peers,
            &webrtc_peers, pending_webrtc_sends, &event_tx,
            &peer_id, &kind, &id, &source_path, total_size,
        ).await;
    }
    // Receiver-side retry: if we have a pending file stream for this transfer,
    // send a FileRequest to get it via WSS. Also remove early arrival if present.
    if pending_file_streams.contains_key(&transfer_id) || early_file_streams.contains_key(&transfer_id) {
        early_file_streams.remove(&transfer_id);
        hollow_log!("[HOLLOW-WEBRTC] Receiver fallback: requesting {transfer_id} via FileRequest");
        send_message_to_peer(
            &ws_cmd_tx, &ws_room_peers,
            &peer_id, HavenMessage::FileRequest {
                file_id: transfer_id,
                chunks: vec![],
                offset: 0,
            },
        );
    }
}

/// Decryption material for an in-flight multi-device link snapshot. The bytes are
/// AES-256-GCM encrypted with a one-time key generated for this link session; the
/// receiver holds the key and nonce here until the chunked transfer reassembles.
pub(crate) struct LinkSnapshotState {
    /// The link CODE the receiver typed — the passphrase the inbound `.hollow` blob
    /// is encrypted with. We stash the blob + this code for a next-launch import via
    /// the proven `import_backup` pipeline (NOT an in-place import).
    pub code: String,
}

/// Handle a completed stream transfer (file, shard, or link snapshot).
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_completed_stream(
    request: ws_stream_transfer::StreamRequest,
    sender_peer: &str,
    pending_file_streams: &mut HashMap<String, PendingFileStream>,
    pending_shard_streams: &mut HashMap<String, PendingShardStream>,
    pending_vault_downloads: &mut HashMap<String, (String, usize, usize)>,
    early_file_streams: &mut HashMap<String, (PathBuf, u64, String)>,
    pending_link_snapshots: &mut HashMap<String, LinkSnapshotState>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    db_path: &str,
    db_passphrase: &str,
) {
    use ws_stream_transfer::StreamKind;

    // Share chunks have their own completion path (handle_webrtc_share_chunk_complete)
    // and never flow through this function — early return defensively.
    if matches!(request.kind, StreamKind::ShareChunk { .. }) { return; }

    match request.kind {
        StreamKind::ShareChunk { .. } => unreachable!(),
        StreamKind::LinkSnapshot => {
            handle_link_snapshot_stream(
                &request, sender_peer, pending_link_snapshots,
                event_tx, ws_cmd_tx, ws_room_peers,
            ).await;
        }
        StreamKind::File => {
            handle_file_stream_complete(
                &request, sender_peer, pending_file_streams, early_file_streams,
                event_tx, ws_cmd_tx, ws_room_peers, db_path, db_passphrase,
            ).await;
        }
        StreamKind::Shard { shard_index } => {
            handle_shard_stream_complete(
                &request, shard_index, sender_peer, pending_shard_streams,
                pending_vault_downloads, event_tx, db_path, db_passphrase,
            ).await;
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

    let Some(state) = pending_link_snapshots.remove(&link_id) else {
        // No decryption material registered for this link session — drop it.
        hollow_log!("[HOLLOW-LINK] No pending link state for {link_id} — dropping snapshot");
        let _ = std::fs::remove_file(&request.temp_path);
        let _ = event_tx.send(NetworkEvent::LinkFailed {
            link_id: bare_id,
            error: "no pending link session".to_string(),
        }).await;
        return;
    };

    // The inbound bytes are a full `.hollow` backup blob encrypted with the link
    // CODE. Rather than import in place, STASH the blob and code and signal a
    // restart, so the bootstrap imports it pre-node-start like a manual restore.
    let outcome: Result<(), String> = (|| {
        let blob = std::fs::read(&request.temp_path)
            .map_err(|e| format!("read link blob: {e}"))?;
        crate::api::storage::stash_pending_link(&blob, &state.code)
            .map_err(|e| format!("stash failed: {e}"))
    })();

    let _ = std::fs::remove_file(&request.temp_path);

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

/// StreamKind::File arm of handle_completed_stream.
#[allow(clippy::too_many_arguments)]
async fn handle_file_stream_complete(
    request: &ws_stream_transfer::StreamRequest,
    sender_peer: &str,
    pending_file_streams: &mut HashMap<String, PendingFileStream>,
    early_file_streams: &mut HashMap<String, (PathBuf, u64, String)>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    db_path: &str,
    db_passphrase: &str,
) {
    let file_id = request.id.clone();
    hollow_log!("[HOLLOW-STREAM] Inbound file stream: {file_id} ({} bytes)", request.size);

    let Some(pfs) = pending_file_streams.remove(&file_id) else {
        // WebRTC race: bytes arrived before FileHeader. Save for later.
        hollow_log!("[HOLLOW-STREAM] No pending FileHeader for stream {file_id} — saving as early arrival");
        early_file_streams.insert(file_id, (request.temp_path.clone(), request.size, sender_peer.to_string()));
        // Don't delete the temp file — FileHeader handler will pick it up.
        return;
    };

    // Outcome of the decrypt attempt: Ok(disk_path) on success, Err(reason) on
    // any failure (read error, bad key length, or GCM auth failure).
    match try_decrypt_file_stream(request, &pfs, db_path, db_passphrase).await {
        Ok(disk_path) => {
            // Success — consume the assembled stream.
            let _ = std::fs::remove_file(&request.temp_path);
            let _ = event_tx.send(NetworkEvent::FileCompleted { file_id, disk_path }).await;
        }
        Err(fail_reason) => {
            hold_early_arrival_and_retry(
                &file_id, &fail_reason, request, sender_peer, pfs,
                pending_file_streams, early_file_streams, ws_cmd_tx, ws_room_peers,
            );
        }
    }
}

/// Decrypt an assembled inbound file stream against its pending FileHeader key and
/// write the plaintext to its final path. A GCM failure here is usually a transient
/// assembly race under concurrent transfers, so the caller holds the bytes and
/// bounded-re-requests rather than giving up (see FILE_DECRYPT_MAX_RETRIES).
async fn try_decrypt_file_stream(
    request: &ws_stream_transfer::StreamRequest,
    pfs: &PendingFileStream,
    db_path: &str,
    db_passphrase: &str,
) -> Result<String, String> {
    let Ok(ciphertext) = tokio::fs::read(&request.temp_path).await else {
        return Err("unreadable stream".to_string());
    };
    let key_bytes = hex::decode(&pfs.aes_key).unwrap_or_default();
    let nonce_bytes = hex::decode(&pfs.aes_nonce).unwrap_or_default();
    if key_bytes.len() != 32 || nonce_bytes.len() != 12 {
        return Err("invalid AES key/nonce length".to_string());
    }
    let key: [u8; 32] = key_bytes.try_into().unwrap();
    let nonce: [u8; 12] = nonce_bytes.try_into().unwrap();
    let plaintext = crate::vault::pipeline::aes_decrypt(&ciphertext, &key, &nonce)
        .map_err(|e| format!("decrypt failed: {e}"))?;
    let final_path = file_transfer::final_file_path(&request.id, &pfs.ext);
    if tokio::fs::write(&final_path, &plaintext).await.is_err() {
        return Err("failed to write decrypted file".to_string());
    }
    let disk_path = final_path.to_string_lossy().to_string();
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        let _ = store.mark_file_complete(&request.id, &disk_path);
    }
    hollow_log!("[HOLLOW-STREAM] File {} complete: {disk_path}", request.id);
    Ok(disk_path)
}

/// The ciphertext is intact but did not decrypt against THIS pending stream's key.
///
/// The bytes (fast WebRTC) routinely BEAT the FileHeader (slower Olm/relay), so
/// they belong to a header that has not landed and the popped `pfs` is a STALE
/// pending stream with the wrong key. Deleting the bytes and re-requesting spawned
/// another crossed pair and looped forever, so instead the bytes are PRESERVED as
/// an early arrival keyed by file_id and nothing is re-requested: the header in
/// flight arrives and reprocesses them against the CORRECT key.
#[allow(clippy::too_many_arguments)]
fn hold_early_arrival_and_retry(
    file_id: &str,
    fail_reason: &str,
    request: &ws_stream_transfer::StreamRequest,
    sender_peer: &str,
    pfs: PendingFileStream,
    pending_file_streams: &mut HashMap<String, PendingFileStream>,
    early_file_streams: &mut HashMap<String, (PathBuf, u64, String)>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
) {
    hollow_log!(
        "[HOLLOW-STREAM] File {file_id} {fail_reason} — bytes arrived before their header; holding as early-arrival for the matching key"
    );
    early_file_streams.insert(
        file_id.to_string(),
        (request.temp_path.clone(), request.size, sender_peer.to_string()),
    );
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
        send_message_to_peer(
            ws_cmd_tx, ws_room_peers,
            &sender, HavenMessage::FileRequest {
                file_id: file_id.to_string(),
                chunks: vec![],
                offset: 0,
            },
        );
        hollow_log!("[HOLLOW-STREAM] File {file_id} — safety re-request {next}/{FILE_DECRYPT_MAX_RETRIES} from {sender}");
    }
}

/// StreamKind::Shard arm of handle_completed_stream: store the shard, emit
/// ShardStored, and attempt reconstruction if a vault download is pending.
#[allow(clippy::too_many_arguments)]
async fn handle_shard_stream_complete(
    request: &ws_stream_transfer::StreamRequest,
    shard_index: u16,
    sender_peer: &str,
    pending_shard_streams: &mut HashMap<String, PendingShardStream>,
    pending_vault_downloads: &mut HashMap<String, (String, usize, usize)>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    db_path: &str,
    db_passphrase: &str,
) {
    let content_id = request.id.clone();
    let key = format!("{content_id}:{shard_index}");
    hollow_log!("[HOLLOW-STREAM] Inbound shard stream: cid={content_id} si={shard_index} ({} bytes)", request.size);

    let Some(pss) = pending_shard_streams.remove(&key) else {
        hollow_log!("[HOLLOW-STREAM] No pending ShardStore for stream {key} — ignoring");
        let _ = std::fs::remove_file(&request.temp_path);
        return;
    };
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
                let _ = std::fs::remove_file(&request.temp_path);
                return;
            }
        }
        let data_dir = crate::identity::data_dir().unwrap_or_default();
        let vault_dir = data_dir.join("vault");
        if let Ok(content_store) = crate::vault::content_store::ContentStore::open(db_path, db_passphrase, &vault_dir) {
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
                attempt_vault_reconstruction(
                    content_store, pending_vault_downloads, event_tx,
                    &content_id, dl_server_id, dl_k,
                ).await;
            }
        }
    }
    let _ = std::fs::remove_file(&request.temp_path);
}

/// Try to reconstruct a pending vault download after a new shard landed: gather
/// local shards, reconstruct when >= k are available, else re-register the pending
/// download and keep waiting for more shards.
///
/// Takes the ContentStore by VALUE (last use in the shard arm): an owned store is
/// Send across .await points, while a `&ContentStore` is not.
async fn attempt_vault_reconstruction(
    content_store: crate::vault::content_store::ContentStore,
    pending_vault_downloads: &mut HashMap<String, (String, usize, usize)>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    content_id: &str,
    dl_server_id: String,
    dl_k: usize,
) {
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
            return;
        }
        Err(e) => {
            // Transient store failure — re-register the pending download so
            // the next shard arrival retries instead of abandoning it.
            hollow_log!("[HOLLOW-VAULT] load_manifest failed for {content_id}: {e} — keeping download pending for retry");
            pending_vault_downloads.insert(content_id.to_string(), (dl_server_id, dl_k, 0));
            return;
        }
    };
    let n = dl_k + manifest.m as usize;
    let local_shards = content_store.list_content_shards(&dl_server_id, content_id).unwrap_or_default();
    let mut packed: Vec<Option<Vec<u8>>> = vec![None; n];
    for record in &local_shards {
        let idx = record.shard_index as usize;
        if idx < n {
            // SECURITY (FILE-3): the CHECKED read, so a shard that rotted on
            // disk (or was swapped underneath us) is left out of the decode
            // rather than fed to Reed-Solomon and blamed on the AES layer.
            match content_store.read_shard(&dl_server_id, &record.shard_key) {
                Ok(data) => packed[idx] = Some(data),
                Err(e) => hollow_log!(
                    "[HOLLOW-SECURITY] vault shard {idx} for {content_id} failed its stored hash: {e}"
                ),
            }
        }
    }
    let avail = packed.iter().filter(|s| s.is_some()).count();
    if avail < dl_k {
        pending_vault_downloads.insert(content_id.to_string(), (dl_server_id, dl_k, 0));
        hollow_log!("[HOLLOW-VAULT] Still need more shards: have {avail}, need {dl_k}");
        return;
    }
    let ext = crate::vault::pipeline::ext_from_filename(&manifest.file_name);
    match crate::vault::pipeline::reconstruct_file(&manifest, &packed) {
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
}


/// Stream file or shard data to a peer. Prefers WebRTC data channel if available,
/// falls back to WS binary frames via relay.
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
    // Prefer WebRTC data channel if peer has one active.
    if webrtc_peers.contains(peer_str) {
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
            source_path.to_path_buf(), total_size,
        ));
        let _ = event_tx.send(NetworkEvent::WebRtcSendFile {
            peer_id: peer_str.to_string(),
            transfer_id: id.to_string(),
            file_path: source_path.to_string_lossy().to_string(),
            total_size,
            kind: kind_str.to_string(),
            shard_index,
            chunk_index: 0,
        }).await;
        hollow_log!("[HOLLOW-WEBRTC] Routing {id} to {peer_str} via WebRTC data channel");
        return;
    }
    // Fallback: WSS relay binary streaming.
    if let Some(room) = ws_room_for_peer(ws_room_peers, peer_str) {
        ws_stream_transfer::ws_stream_send(
            ws_cmd_tx, &room, peer_str, kind, id, source_path, total_size, 0,
        ).await;
    } else {
        hollow_log!("[HOLLOW-STREAM] Peer {peer_str} unreachable via WS — cannot stream {id}");
    }
}

/// Stream data from an in-memory buffer to a peer. Prefers WebRTC (writes temp file for Dart),
/// falls back to WS binary frames via relay (streams from memory, no disk).
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
    if webrtc_peers.contains(peer_str) {
        // WebRTC: Dart reads from file path — must write temp file.
        let temp_path = file_transfer::files_dir().join(format!(".stream_shard_{id}.tmp"));
        let _ = std::fs::write(&temp_path, data);
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
    if let Some(room) = ws_room_for_peer(ws_room_peers, peer_str) {
        ws_stream_transfer::ws_stream_send_bytes(
            ws_cmd_tx, &room, peer_str, kind, id, data,
        ).await;
    } else {
        hollow_log!("[HOLLOW-STREAM] Peer {peer_str} unreachable via WS — cannot stream {id}");
    }
}

/// Broadcast a file to all gossip neighbors for a server (minus an optional exclude peer).
/// Used for gossip relay tree file distribution.
pub(crate) async fn broadcast_to_gossip_neighbors(
    gossip_overlay: &gossip::GossipOverlay,
    webrtc_peers: &std::collections::HashSet<String>,
    event_tx: &mpsc::Sender<NetworkEvent>,
    broadcast_id: &str,
    ttl: u8,
    origin_peer_id: &str,
    file_path: &str,
    total_size: u64,
    kind: &str,
    shard_index: u16,
    exclude_peer: Option<&str>,
    channel_id: &str,
) {
    let targets = gossip_overlay.get_relay_targets(exclude_peer);
    let target_count = targets.len();
    hollow_log!(
        "[HOLLOW-GOSSIP] Broadcasting {broadcast_id} (ttl={ttl}) to {target_count} neighbors (server={})",
        gossip_overlay.server_id
    );

    for peer_id in targets {
        if webrtc_peers.contains(&peer_id) {
            // Emit GossipRelayFile event — Dart will send via data channel with broadcast header.
            let _ = event_tx.send(NetworkEvent::GossipRelayFile {
                broadcast_id: broadcast_id.to_string(),
                ttl,
                origin_peer_id: origin_peer_id.to_string(),
                file_path: file_path.to_string(),
                total_size,
                kind: kind.to_string(),
                shard_index,
                exclude_peer_id: exclude_peer.unwrap_or("").to_string(),
                server_id: gossip_overlay.server_id.clone(),
                channel_id: channel_id.to_string(),
            }).await;
        } else {
            hollow_log!("[HOLLOW-GOSSIP] Neighbor {peer_id} has no data channel — skipping");
        }
    }
}

/// Handle `MessageEnvelope::FileHeader` — register pending stream + emit FileHeaderReceived.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_file_header(
    server_states: &HashMap<String, ServerState>,
    pending_file_streams: &mut HashMap<String, PendingFileStream>,
    pending_shard_streams: &mut HashMap<String, PendingShardStream>,
    early_file_streams: &mut HashMap<String, (PathBuf, u64, String)>,
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
    requested_file_receipts: &mut HashMap<String, std::time::Instant>,
    declined_file_ids: &mut std::collections::HashSet<String>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
    db_path: &str,
    db_passphrase: &str,
) {
    hollow_log!("[HOLLOW-FILE] MLS FileHeader: {fid} ({name}, {size} bytes, {chunks} chunks, share_ref={})", share_ref.is_some());

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

    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        // Owner guard (0.8.5): MLS proves the sender is a group member, not
        // that this `file_id` is theirs to relabel. See `file_meta_write_allowed`.
        if file_meta_write_allowed(&store, &fid, &sender_peer_id) {
            let _ = store.insert_file_metadata(
                &fid, &name, &ext, &mime,
                size, chunks, img,
                w, h,
                mid.as_deref(), ctx_type, &ctx_id,
                &sender_peer_id, false, ts,
                vthumb.as_ref(), thumb.as_deref(),
            );
            // Persist the share back-reference (issue #41) so a manual
            // download can rejoin the share swarm after a restart.
            if let Some(sr) = share_ref.as_ref() {
                let _ = store.set_file_share_ref(&fid, sr);
            }
        }
    }

    // AUTO-DOWNLOAD GATE (#41), mirroring the DM/Olm arm: metadata above still
    // renders the card, but a gated push registers no pending stream and late bytes
    // are deleted rather than parked. An existing pending stream means a transfer we
    // already accepted, since the decrypt-fail retry re-requests WITHOUT a receipt.
    let auto_ok = explicitly_requested
        || pending_file_streams.contains_key(&fid)
        || auto_download_allows(size, &name, &ext, &format!("server:{server_id}"), voice);
    if !auto_ok && share_ref.is_none() && aes_key.is_some() {
        declined_file_ids.insert(fid.clone());
        if let Some((temp_path, _, _)) = early_file_streams.remove(&fid) {
            let _ = std::fs::remove_file(&temp_path);
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
    if auto_ok && share_ref.is_none() && let (Some(ak), Some(an)) = (aes_key, aes_nonce) {
        register_pending_file_stream_and_reprocess(
            &fid, ak, an, &name, &ext, &sender_peer_id, server_id,
            &sid, &cid, &mid, img, w, h,
            pending_file_streams, pending_shard_streams, early_file_streams,
            bundle_keypair, event_tx, ws_cmd_tx, ws_room_peers,
            db_path, db_passphrase,
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
        share_ref,
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
    let max_mb_str = if let Some(state) = server_states.get(server_id) {
        state.settings.get("max_file_size_mb")
            .map(|r| r.read().clone())
            .unwrap_or_else(|| "34".to_string())
    } else { "34".to_string() };
    let max_bytes = max_mb_str.parse::<u64>().unwrap_or(34) * 1024 * 1024;
    if size > max_bytes {
        hollow_log!("[HOLLOW-SECURITY] REJECTED MLS FileHeader from {sender_peer_id} — size {size} exceeds max {max_bytes}");
        return true;
    }
    false
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
    pending_file_streams: &mut HashMap<String, PendingFileStream>,
    pending_shard_streams: &mut HashMap<String, PendingShardStream>,
    early_file_streams: &mut HashMap<String, (PathBuf, u64, String)>,
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    ws_room_peers: &HashMap<String, std::collections::HashSet<String>>,
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
    });
    hollow_log!("[HOLLOW-FILE] Registered pending stream for {fid} (MLS streamed transfer)");

    // Check if WebRTC bytes already arrived before this FileHeader.
    if let Some((temp_path, file_size, sender)) = early_file_streams.remove(fid) {
        hollow_log!("[HOLLOW-FILE] Early arrival found for {fid} (MLS path) — processing now");
        let request = ws_stream_transfer::StreamRequest {
            kind: ws_stream_transfer::StreamKind::File,
            id: fid.to_string(),
            size: file_size,
            temp_path,
        };
        let mut empty_vault_dl = HashMap::new();
        // This early-arrival path only ever carries StreamKind::File; link
        // snapshots never take the WebRTC early-arrival route, so an empty map is fine.
        let mut empty_link_snapshots = HashMap::new();
        handle_completed_stream(
            request, &sender,
            pending_file_streams, pending_shard_streams,
            &mut empty_vault_dl, early_file_streams,
            &mut empty_link_snapshots,
            bundle_keypair, event_tx,
            ws_cmd_tx, ws_room_peers,
            db_path, db_passphrase,
        ).await;
    }
}

/// Handle `MessageEnvelope::FileChunk` — write chunk + assemble on completion.
pub(crate) async fn handle_envelope_file_chunk(
    bundle_keypair: &crate::identity::native_identity::NativeKeypair,
    event_tx: &mpsc::Sender<NetworkEvent>,
    fid: String,
    idx: u32,
    data: String,
    db_path: &str,
    db_passphrase: &str,
) {
    let chunk_bytes = match base64::engine::general_purpose::STANDARD.decode(&data) {
        Ok(b) => b,
        Err(e) => {
            hollow_log!("[HOLLOW-FILE] MLS chunk decode failed: {e}");
            return;
        }
    };

    if let Err(e) = file_transfer::write_chunk(&fid, idx, &chunk_bytes) {
        hollow_log!("[HOLLOW-FILE] {e}");
    } else {
        ingest_file_chunk_progress(fid, idx, event_tx, db_path, db_passphrase).await;
    }
}

/// DB-side chunk ingest: mark the chunk received, emit FileProgress, and
/// assemble + mark complete when all chunks have arrived (event emit order:
/// FileProgress first, then FileCompleted/FileFailed — unchanged).
async fn ingest_file_chunk_progress(
    fid: String,
    idx: u32,
    event_tx: &mpsc::Sender<NetworkEvent>,
    db_path: &str,
    db_passphrase: &str,
) {
    if let Ok(store) = crate::storage::MessageStore::open(db_path, db_passphrase) {
        if let Ok(received) = store.mark_chunk_received(&fid, idx) {
            if let Ok(Some(file_meta)) = store.get_file_metadata(&fid) {
                let _ = event_tx.send(NetworkEvent::FileProgress {
                    file_id: fid.clone(),
                    chunks_received: received,
                    total_chunks: file_meta.chunk_count,
                }).await;

                if received >= file_meta.chunk_count {
                    let completion = assemble_completed_chunked_file(
                        &store, &fid, file_meta.chunk_count, &file_meta.file_ext,
                    );
                    let _ = event_tx.send(completion).await;
                }
            }
        }
    }
}

/// Assemble a fully-received chunked file and mark it complete in the store.
/// Sync (takes the already-open store) — returns the completion/failure event
/// for the async caller to emit.
fn assemble_completed_chunked_file(
    store: &crate::storage::MessageStore,
    fid: &str,
    chunk_count: u32,
    file_ext: &str,
) -> NetworkEvent {
    let final_path = file_transfer::final_file_path(fid, file_ext);
    match file_transfer::assemble_file(fid, chunk_count, &final_path) {
        Ok(()) => {
            let disk_path = final_path.to_string_lossy().to_string();
            let _ = store.mark_file_complete(fid, &disk_path);
            hollow_log!("[HOLLOW-FILE] MLS file {fid} complete: {disk_path}");
            NetworkEvent::FileCompleted { file_id: fid.to_string(), disk_path }
        }
        Err(e) => {
            hollow_log!("[HOLLOW-FILE] MLS assembly failed: {e}");
            NetworkEvent::FileFailed { file_id: fid.to_string(), error: e }
        }
    }
}

/// Handle `MessageEnvelope::BroadcastMeta` — gossip relay tree dedup + pending relay registration.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn handle_envelope_broadcast_meta(
    gossip_overlays: &mut HashMap<String, gossip::GossipOverlay>,
    local_peer_str: &str,
    sender_peer_id: &str,
    broadcast_id: String,
    origin: String,
    sid: String,
    cid: String,
    file_id: String,
    ttl: u8,
) {
    // SECURITY (Phase 6.25): Validate TTL from wire, cap at MAX_BROADCAST_TTL.
    let effective_ttl = ttl.min(MAX_BROADCAST_TTL);
    hollow_log!("[HOLLOW-GOSSIP] BroadcastMeta: bid={broadcast_id} origin={origin} fid={file_id} server={sid} ch={cid} ttl={effective_ttl}");
    if effective_ttl == 0 {
        hollow_log!("[HOLLOW-GOSSIP] BroadcastMeta TTL=0, not relaying");
    } else if let Some(overlay) = gossip_overlays.get_mut(&sid) {
        overlay.mark_broadcast_seen(&broadcast_id);
        if origin != local_peer_str {
            overlay.add_pending_relay(
                &file_id, &broadcast_id,
                effective_ttl.saturating_sub(1),
                &origin, &cid, sender_peer_id,
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
