//! A floor against `MessageStore::open` in `node/`: a fresh SQLCipher connection
//! re-parses the whole schema under a shared lock, and on the event loop that stalls
//! every peer. Node code leases (`MessageStore::lease`, warm connections while a loop
//! runs); the harness test `g13w3_no_event_loop_opens_the_store_itself` catches an open
//! reached through a helper in any module, which this scan cannot see.

use std::collections::BTreeMap;

/// The only `MessageStore::open` left in `node/` outside tests, by (file, enclosing fn).
const KEPT: &[(&str, &str, usize)] = &[
    // The CrdtStore actor's own long-lived connection.
    ("crdt_store.rs", "open", 1),
    // The push fetch node: one short pass in its own process, with no event loop.
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
    // A guest's in-memory store lives exactly as long as this one connection.
    ("guest_view.rs", "enter", 1),
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

/// A floor, not a proof: it sees a direct open in `node/` only.
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
        "MessageStore::open outside the kept sites (node code uses MessageStore::lease): {new:?}; kept sites with no open left (drop them): {gone:?}"
    );
}

