//! A floor against new `MessageStore::open` calls in `node/`: every one opens a SQLCipher
//! connection, and on the event loop that stalls every peer. The message-store actor
//! (0.13) moves the kept sites off the loop; until then the count may only go down.

use std::collections::BTreeMap;

/// Every `MessageStore::open` in `node/` outside tests at 0.12.2, by (file, enclosing
/// fn): on the event loop today, the message-store actor in 0.13 moves them.
const KEPT: &[(&str, &str, usize)] = &[
    ("assets.rs", "public_banner_thumb", 1),
    ("at_rest.rs", "forget_key", 1),
    ("at_rest.rs", "init", 1),
    ("at_rest.rs", "persist_key", 1),
    ("crdt_store.rs", "open", 1),
    ("crypto_handler.rs", "accepted_friend_entries", 1),
    ("crypto_handler.rs", "request_sibling_dm_backfill", 1),
    ("crypto_handler.rs", "send_friend_list_to_sibling", 1),
    ("crypto_handler.rs", "send_read_markers_to_sibling", 1),
    ("destroy.rs", "announce_to_friends", 1),
    ("destroy.rs", "apply_friend_order", 1),
    ("destroy.rs", "judge_own_order", 1),
    ("destroy.rs", "note_identity_reappeared", 1),
    ("destroy.rs", "stamp_device_link", 1),
    ("emotes.rs", "handle_emote_assets", 1),
    ("emotes.rs", "handle_emote_request", 1),
    ("emotes.rs", "handle_request_emotes", 1),
    ("emotes.rs", "retry_stale_asks", 1),
    ("fetch.rs", "fetch_post_refused", 1),
    ("fetch.rs", "fetched_post_mentions", 1),
    ("fetch.rs", "filter_by_notification_level", 1),
    ("fetch.rs", "handle_direct_message", 2),
    ("fetch.rs", "handle_edit_message", 1),
    ("fetch.rs", "handle_file_header", 3),
    ("fetch.rs", "handle_link_preview_set", 1),
    ("fetch.rs", "insert_channel_row", 1),
    ("fetch.rs", "load_auto_download_conf_from_settings", 1),
    ("fetch.rs", "persist_direct_message", 1),
    ("fetch.rs", "persist_inline_image", 1),
    ("fetch.rs", "run_fetch", 1),
    ("fetch.rs", "stored_server_state", 1),
    ("fetch.rs", "try_decrypt_dm", 1),
    ("file_asks.rs", "retention_expired_locally", 1),
    ("file_asks.rs", "retry_stale_asks", 1),
    ("file_handler.rs", "attempt_vault_reconstruction", 1),
    ("file_handler.rs", "handle_envelope_file_header", 1),
    ("file_handler.rs", "handle_request_file", 1),
    ("file_handler.rs", "persist_sent_channel_row", 1),
    ("file_handler.rs", "persist_sent_dm_row", 1),
    ("file_handler.rs", "persist_sent_file_row", 1),
    ("file_handler.rs", "spawn_image_conversion", 1),
    ("file_handler.rs", "try_decrypt_file_stream", 2),
    ("guest_view.rs", "enter", 1),
    ("link_handler.rs", "accept", 1),
    ("message_ops.rs", "handle_add_channel_reaction", 1),
    ("message_ops.rs", "handle_add_dm_reaction", 1),
    ("message_ops.rs", "handle_attach_channel_link_preview", 1),
    ("message_ops.rs", "handle_attach_dm_link_preview", 1),
    ("message_ops.rs", "handle_delete_channel_message", 1),
    ("message_ops.rs", "handle_delete_dm_message", 1),
    ("message_ops.rs", "handle_edit_channel_message", 1),
    ("message_ops.rs", "handle_edit_dm_message", 1),
    ("message_ops.rs", "handle_envelope_add_reaction", 1),
    ("message_ops.rs", "handle_envelope_delete_message", 1),
    ("message_ops.rs", "handle_envelope_dm_delete", 1),
    ("message_ops.rs", "handle_envelope_dm_edit", 1),
    ("message_ops.rs", "handle_envelope_edit_message", 1),
    ("message_ops.rs", "handle_envelope_link_preview_set", 1),
    ("message_ops.rs", "handle_envelope_remove_reaction", 1),
    ("message_ops.rs", "handle_remove_channel_reaction", 1),
    ("message_ops.rs", "handle_remove_dm_reaction", 1),
    ("message_ops.rs", "handle_send_channel_message", 1),
    ("message_ops.rs", "handle_send_message", 1),
    ("message_ops.rs", "latest_own_channel_ts_blocking", 1),
    ("message_ops.rs", "live_channel_moderation_drop", 1),
    ("message_ops.rs", "persist_incoming_channel_message", 1),
    ("message_ops.rs", "persist_sent_channel_message", 1),
    ("overlay.rs", "build_announce", 1),
    ("overlay.rs", "handle_envelope_overlay_look_answer_inner", 1),
    ("overlay.rs", "handle_envelope_overlay_look_ask_inner", 1),
    ("overlay.rs", "react_to_notices_inner", 1),
    ("overlay.rs", "save_own_inner", 1),
    ("overlay.rs", "tick_inner", 1),
    ("profile_card.rs", "keep_card", 1),
    ("profile_card.rs", "own_avatar", 1),
    ("profile_card.rs", "own_card", 1),
    ("profile_card.rs", "store_card", 1),
    ("roster_book.rs", "announce_own_state_inner", 1),
    ("roster_book.rs", "ask_again", 1),
    ("roster_book.rs", "carried_member", 1),
    ("roster_book.rs", "change_own", 1),
    ("roster_book.rs", "fan_out", 1),
    ("roster_book.rs", "fold_in", 1),
    ("roster_book.rs", "own", 1),
    ("roster_book.rs", "own_changes", 1),
    ("roster_book.rs", "remove_self", 1),
    ("roster_book.rs", "rooted_by", 1),
    ("roster_book.rs", "stored_ingest", 1),
    ("roster_reach.rs", "answer", 1),
    ("roster_reach.rs", "arm_backstop", 1),
    ("roster_reach.rs", "fetch_roster", 1),
    ("roster_reach.rs", "for_dm", 1),
    ("roster_reach.rs", "hold_for_stale_roster", 1),
    ("roster_reach.rs", "on_room_listed", 1),
    ("roster_reach.rs", "send_due_asks", 1),
    ("security_alerts.rs", "note_olm_identity_key", 1),
    ("security_alerts.rs", "record", 1),
    ("share_handler.rs", "open_message_store", 1),
    ("social.rs", "build_friend_request", 1),
    ("social.rs", "co_members_to_introduce", 1),
    ("social.rs", "handle_accept_friend_request", 2),
    ("social.rs", "handle_block_changed", 1),
    ("social.rs", "handle_profile_relay", 1),
    ("social.rs", "handle_profile_request_for", 1),
    ("social.rs", "handle_reject_friend_request", 1),
    ("social.rs", "handle_remove_friend", 2),
    ("social.rs", "handle_send_friend_request", 2),
    ("social.rs", "handle_update_profile", 3),
    ("social.rs", "holds_accepted_friend", 1),
    ("social.rs", "maybe_request_full_profile", 1),
    ("social.rs", "outstanding_outgoing_requests", 1),
    ("social.rs", "own_block_entry", 1),
    ("social.rs", "own_profile_update", 1),
    ("social.rs", "profile_audience", 1),
    ("social.rs", "request_predates_removal", 1),
    ("social.rs", "save_incoming_profile", 1),
    ("social.rs", "share_friend_with_siblings", 1),
    ("social.rs", "take_friend_card", 1),
    ("social.rs", "take_sibling_blocks", 1),
    ("social.rs", "take_sibling_removals", 1),
    ("swarm.rs", "after_welcome_joined", 2),
    ("swarm.rs", "ask_sender_for_channels", 1),
    ("swarm.rs", "dm_event_convo", 1),
    ("swarm.rs", "handle_incoming_request_inner", 29),
    ("swarm.rs", "on_verified_sibling", 1),
    ("swarm.rs", "request_dm_resync_after_rekey", 1),
    ("swarm.rs", "run_event_loop", 25),
    ("swarm.rs", "send_personal_emotes_to_sibling", 1),
    ("sync_handler.rs", "ask_peers_to_fill", 1),
    ("sync_handler.rs", "flush_pending_sync_requests", 1),
    ("sync_handler.rs", "handle_envelope_channel_sync_batch", 1),
    ("sync_handler.rs", "handle_request_channel_sync", 1),
    ("vault_ops.rs", "handle_vault_upload_prepared", 1),
    ("vault_ops.rs", "ingest_vault_manifest", 1),
    ("vault_ops.rs", "vault_bytes_checked", 1),
    ("voice_handler.rs", "call_invite_allowed", 1),
];

/// `src` with every top-level `#[cfg(test)]` item, comment and literal blanked,
/// so braces and words inside them never count.
fn live_code(src: &str) -> String {
    let chars: Vec<char> = src.chars().collect();
    let mut out = String::with_capacity(src.len());
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        let next = chars.get(i + 1).copied();
        if c == '/' && next == Some('/') {
            while i < chars.len() && chars[i] != '\n' {
                i += 1;
            }
        } else if c == '/' && next == Some('*') {
            i += 2;
            while i + 1 < chars.len() && !(chars[i] == '*' && chars[i + 1] == '/') {
                out.push(if chars[i] == '\n' { '\n' } else { ' ' });
                i += 1;
            }
            i += 2;
        } else if c == 'r' && (next == Some('"') || next == Some('#')) && !chars.get(i.wrapping_sub(1)).is_some_and(|p| p.is_alphanumeric() || *p == '_') {
            let mut j = i + 1;
            let mut hashes = 0;
            while chars.get(j) == Some(&'#') {
                hashes += 1;
                j += 1;
            }
            if chars.get(j) != Some(&'"') {
                out.push(c);
                i += 1;
                continue;
            }
            j += 1;
            loop {
                if j >= chars.len() {
                    break;
                }
                if chars[j] == '"' && (1..=hashes).all(|k| chars.get(j + k) == Some(&'#')) {
                    j += 1 + hashes;
                    break;
                }
                if chars[j] == '\n' {
                    out.push('\n');
                }
                j += 1;
            }
            out.push_str("\"\"");
            i = j;
        } else if c == '"' {
            i += 1;
            while i < chars.len() && chars[i] != '"' {
                if chars[i] == '\\' {
                    i += 1;
                }
                if chars.get(i) == Some(&'\n') {
                    out.push('\n');
                }
                i += 1;
            }
            out.push_str("\"\"");
            i += 1;
        } else if c == '\'' && next == Some('\\') {
            let end = (i + 3..chars.len()).find(|&k| chars[k] == '\'').unwrap_or(chars.len());
            out.push_str("' '");
            i = end + 1;
        } else if c == '\'' && chars.get(i + 2) == Some(&'\'') {
            out.push_str("' '");
            i += 3;
        } else {
            out.push(c);
            i += 1;
        }
    }
    // Drop each top-level test item (a `#[cfg(test)]` at the line start) whole.
    let mut kept = String::with_capacity(out.len());
    let mut lines = out.split('\n').peekable();
    while let Some(line) = lines.next() {
        if line.trim_end() != "#[cfg(test)]" || line.starts_with(' ') {
            kept.push_str(line);
            kept.push('\n');
            continue;
        }
        let mut depth = 0i32;
        let mut opened = false;
        for item in lines.by_ref() {
            kept.push('\n');
            for ch in item.chars() {
                match ch {
                    '{' => {
                        depth += 1;
                        opened = true;
                    }
                    '}' => depth -= 1,
                    _ => {}
                }
            }
            if (opened && depth <= 0) || (!opened && item.trim_end().ends_with(';')) {
                break;
            }
        }
    }
    kept
}

/// (enclosing fn, count) of `MessageStore::open` in `code`, called or passed as a
/// value, under its own name or a `MessageStore as <Alias>` import.
fn opens_by_fn(code: &str) -> BTreeMap<String, usize> {
    let is_ident = |c: char| c.is_alphanumeric() || c == '_';
    let mut names = vec!["MessageStore".to_string()];
    let mut rest = code;
    while let Some(at) = rest.find("MessageStore as ") {
        rest = &rest[at + "MessageStore as ".len()..];
        let alias: String = rest.chars().take_while(|c| is_ident(*c)).collect();
        if !alias.is_empty() {
            names.push(alias);
        }
    }
    let opens_in = |line: &str| -> usize {
        names
            .iter()
            .map(|name| {
                let needle = format!("{name}::open");
                line.match_indices(&needle)
                    .filter(|(at, _)| {
                        let before = line[..*at].chars().last();
                        let after = line[at + needle.len()..].chars().next();
                        before.is_none_or(|b| !is_ident(b)) && after.is_none_or(|a| !is_ident(a))
                    })
                    .count()
            })
            .sum()
    };
    let mut found = BTreeMap::new();
    let mut current = String::from("?");
    for line in code.split('\n') {
        let mut rest = line;
        while let Some(at) = rest.find("fn ") {
            let before = rest[..at].chars().last();
            let name: String = rest[at + 3..].chars().take_while(|c| is_ident(*c)).collect();
            if before.is_none_or(|b| !is_ident(b)) && !name.is_empty() {
                current = name;
            }
            rest = &rest[at + 3..];
        }
        let n = opens_in(line);
        if n > 0 {
            *found.entry(current.clone()).or_insert(0) += n;
        }
    }
    found
}

#[test]
fn the_scanner_sees_aliases_and_fn_values() {
    let src = "use crate::storage::MessageStore as Store;\nfn aliased() { Store::open(a, b); }\nfn as_value() { x.map(crate::storage::MessageStore::open); }\nfn other() { MessageStore::open_in_memory(); KeyStore::open(c); }\n";
    let got = opens_by_fn(&live_code(src));
    let want: BTreeMap<String, usize> = [("aliased".to_string(), 1), ("as_value".to_string(), 1)].into_iter().collect();
    assert_eq!(got, want);
}

#[test]
fn the_scanner_skips_tests_comments_and_literals() {
    let src = "fn live() {\n    MessageStore::open(a, b);\n    let s = \"MessageStore::open(\";\n    // MessageStore::open(\n    let r = r#\"{ MessageStore::open( \"#;\n}\n#[cfg(test)]\nmod tests {\n    fn t() { let _ = '{'; MessageStore::open(c, d); }\n}\nfn after() { MessageStore::open(e, f); }\n";
    let got = opens_by_fn(&live_code(src));
    let want: BTreeMap<String, usize> = [("live".to_string(), 1), ("after".to_string(), 1)].into_iter().collect();
    assert_eq!(got, want);
}

/// A floor, not a proof: it sees a direct open in `node/`, never one reached through a
/// helper called from the loop (`social::holds_accepted_friend` and the like).
#[test]
fn every_node_store_open_is_a_kept_site() {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/node");
    let mut seen: BTreeMap<(String, String), usize> = BTreeMap::new();
    for entry in std::fs::read_dir(&dir).unwrap().flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let test_only = ["test_harness.rs", "kill_vectors.rs", "resume_e2e.rs"].contains(&name.as_str()) || name.ends_with("_tests.rs");
        if !name.ends_with(".rs") || test_only || name == "store_open_floor.rs" {
            continue;
        }
        let text = std::fs::read_to_string(entry.path()).unwrap().replace("\r\n", "\n");
        for (func, n) in opens_by_fn(&live_code(&text)) {
            seen.insert((name.clone(), func), n);
        }
    }
    let mut kept: BTreeMap<(String, String), usize> = BTreeMap::new();
    for (f, func, n) in KEPT {
        *kept.entry((f.to_string(), func.to_string())).or_insert(0) += n;
    }
    let new: Vec<String> = seen
        .iter()
        .filter(|(k, n)| kept.get(*k) != Some(*n))
        .map(|((f, func), n)| format!("{f} {func}: {n} open(s), {} kept", kept.get(&(f.clone(), func.clone())).copied().unwrap_or(0)))
        .collect();
    let gone: Vec<String> = kept
        .keys()
        .filter(|k| !seen.contains_key(*k))
        .map(|(f, func)| format!("{f} {func}"))
        .collect();
    assert!(
        new.is_empty() && gone.is_empty(),
        "MessageStore::open outside the kept sites (a new open on the loop waits for the message-store actor): {new:?}; kept sites with no open left (drop them): {gone:?}"
    );
}
