//! A temporary nickname's claim, signed by the claimer's MASTER key. The relay kept
//! whatever master a claimer typed, and the client friended it without a word, so a
//! squatter (or the relay) chose whose inbox received our request, bundle and device
//! list. Now the relay stores only a claim the master signed for the device holding
//! the nickname, the resolver checks it again, and the person confirms before a
//! request goes out. Relay side: `nickname_claim_message` in relay-uws/src/validate.h.

use std::time::{Duration, Instant};

use base64::Engine;

use crate::identity::native_identity::NativeKeypair;

/// How old a resolved claim may be: the relay's ten minute nickname lifetime plus
/// clock skew between the two clients.
const MAX_CLAIM_AGE_MS: i64 = 11 * 60 * 1000;

/// How long after a claim it is made again, inside the relay's ten minute lifetime.
const RECLAIM_AFTER: Duration = Duration::from_secs(8 * 60);

/// The nickname the person holds this session. The relay forgets a claim when our
/// socket closes and ten minutes after it was made while the app still shows it, so
/// it is claimed again on every connect and before it lapses, until the person
/// releases it or the relay refuses it.
#[derive(Default)]
pub(crate) struct NickHold {
    wanted: Option<String>,
    /// When the last claim went out on the live socket; `None` while disconnected.
    claimed_at: Option<Instant>,
}

impl NickHold {
    pub fn want(&mut self, nickname: &str, now: Instant) {
        self.wanted = Some(nickname.to_string());
        self.claimed_at = Some(now);
    }

    pub fn release(&mut self) {
        *self = Self::default();
    }

    pub fn on_disconnected(&mut self) {
        self.claimed_at = None;
    }

    /// The nickname to claim on a fresh socket.
    pub fn on_connected(&mut self, now: Instant) -> Option<String> {
        self.claimed_at = self.wanted.as_ref().map(|_| now);
        self.wanted.clone()
    }

    /// The nickname to claim again because the relay's copy is about to lapse.
    pub fn due(&mut self, now: Instant) -> Option<String> {
        let at = self.claimed_at?;
        if now.saturating_duration_since(at) < RECLAIM_AFTER {
            return None;
        }
        self.claimed_at = Some(now);
        self.wanted.clone()
    }
}

/// What a claim carries besides the nickname, the device and the master.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct NickClaim {
    /// The master's public key, base64 of its protobuf encoding.
    pub master_key: String,
    pub ts_ms: i64,
    pub sig: String,
}

/// The exact bytes a claim signs. `nickname` is lowercase, as the relay keys it.
pub(crate) fn payload(nickname: &str, device: &str, master: &str, ts_ms: i64) -> String {
    format!("hollow-nick1\n{nickname}\n{device}\n{master}\n{ts_ms}")
}

pub(crate) fn sign(master: &NativeKeypair, nickname: &str, device: &str, ts_ms: i64) -> NickClaim {
    let bytes = payload(nickname, device, &master.peer_id(), ts_ms);
    NickClaim {
        master_key: base64::engine::general_purpose::STANDARD.encode(master.public_key_protobuf()),
        ts_ms,
        sig: base64::engine::general_purpose::STANDARD.encode(master.sign(bytes.as_bytes())),
    }
}

/// Claims `nickname` (lowercase) for `device` with the master's signature.
pub(crate) fn send_claim(
    ws_cmd_tx: &tokio::sync::mpsc::UnboundedSender<super::ws_client::WsCommand>,
    master: &NativeKeypair,
    device: &str,
    nickname: &str,
) {
    let claim = sign(master, nickname, device, super::types::now_ms());
    let _ = ws_cmd_tx.send(super::ws_client::WsCommand::ClaimNickname {
        nickname: nickname.to_string(),
        master: master.peer_id(),
        claim,
    });
}

/// The master a resolved nickname speaks for: only when that master signed a claim
/// for this nickname and the device holding it, recently.
pub(crate) fn verified_master(nickname: &str, device: &str, master: &str, claim: &NickClaim, now_ms: i64) -> Option<String> {
    if now_ms.abs_diff(claim.ts_ms) > MAX_CLAIM_AGE_MS as u64 {
        return None;
    }
    let key = base64::engine::general_purpose::STANDARD.decode(&claim.master_key).ok()?;
    if NativeKeypair::peer_id_from_pubkey_protobuf(&key)? != master {
        return None;
    }
    let sig = base64::engine::general_purpose::STANDARD.decode(&claim.sig).ok()?;
    let bytes = payload(nickname, device, master, claim.ts_ms);
    NativeKeypair::verify_peer_signature(&key, &sig, bytes.as_bytes())
        .unwrap_or(false)
        .then(|| master.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Pinned against relay-uws/test/test_relay_validators.cpp.
    #[test]
    fn nickname_claim_payload_matches_the_relays_pinned_vector() {
        assert_eq!(
            payload("vitalik_7", "12D3KooWDevice", "12D3KooWMaster", 1790000000000),
            "hollow-nick1\nvitalik_7\n12D3KooWDevice\n12D3KooWMaster\n1790000000000"
        );
    }

    #[test]
    fn a_nickname_resolves_only_to_the_master_that_signed_for_its_device() {
        let master = NativeKeypair::from_secret_bytes(&[3; 32]);
        let other = NativeKeypair::from_secret_bytes(&[4; 32]);
        let now = 1_790_000_000_000;
        let claim = sign(&master, "nick", "dev-a", now);
        assert_eq!(verified_master("nick", "dev-a", &master.peer_id(), &claim, now), Some(master.peer_id()));
        assert_eq!(verified_master("nick", "dev-b", &master.peer_id(), &claim, now), None, "another device");
        assert_eq!(verified_master("other", "dev-a", &master.peer_id(), &claim, now), None, "another nickname");
        assert_eq!(verified_master("nick", "dev-a", &other.peer_id(), &claim, now), None, "another master named");
        assert_eq!(verified_master("nick", "dev-a", &master.peer_id(), &claim, now + MAX_CLAIM_AGE_MS + 1), None, "stale");
        let squatter = NickClaim { master_key: claim.master_key.clone(), ..sign(&other, "nick", "dev-a", now) };
        assert_eq!(verified_master("nick", "dev-a", &master.peer_id(), &squatter, now), None, "signed by someone else");
        // A squatter's own key signing a claim that names the victim.
        let bytes = payload("nick", "dev-a", &master.peer_id(), now);
        let own_key = NickClaim {
            master_key: base64::engine::general_purpose::STANDARD.encode(other.public_key_protobuf()),
            ts_ms: now,
            sig: base64::engine::general_purpose::STANDARD.encode(other.sign(bytes.as_bytes())),
        };
        assert_eq!(verified_master("nick", "dev-a", &master.peer_id(), &own_key, now), None, "a key that is not the master's");
    }

    /// A held nickname goes back out on every new socket and before the relay's ten
    /// minutes run out, never while disconnected, and not at all once released.
    #[test]
    fn a_held_nickname_is_claimed_again_on_reconnect_and_before_it_lapses() {
        let t0 = Instant::now();
        let mut hold = NickHold::default();
        assert_eq!(hold.on_connected(t0), None, "nothing held, nothing claimed");

        hold.want("vitalik", t0);
        assert_eq!(hold.due(t0 + Duration::from_secs(60)), None, "fresh claim");
        let lapse = t0 + RECLAIM_AFTER;
        assert_eq!(hold.due(lapse), Some("vitalik".into()), "before the relay's ten minutes end");
        assert_eq!(hold.due(lapse + Duration::from_secs(30)), None, "once per window");
        assert!(RECLAIM_AFTER < Duration::from_millis(MAX_CLAIM_AGE_MS as u64 - 60_000));

        hold.on_disconnected();
        assert_eq!(hold.due(lapse + RECLAIM_AFTER * 2), None, "no claim on a dead socket");
        let back = lapse + RECLAIM_AFTER * 3;
        assert_eq!(hold.on_connected(back), Some("vitalik".into()), "the relay forgot it with the socket");
        assert_eq!(hold.due(back + Duration::from_secs(1)), None);

        hold.release();
        assert_eq!(hold.on_connected(back + RECLAIM_AFTER), None);
        assert_eq!(hold.due(back + RECLAIM_AFTER * 4), None);
    }

    /// The claim's stamp is read before its signature, so the extremes are refused
    /// rather than overflowing the age check (the class of C-OLM-04).
    #[test]
    fn a_claim_stamped_at_the_i64_extremes_is_refused() {
        let master = NativeKeypair::from_secret_bytes(&[3; 32]);
        let now: i64 = 1_790_000_000_000;
        for ts in [i64::MIN, i64::MAX, now.wrapping_add(i64::MIN)] {
            let claim = sign(&master, "nick", "dev-a", ts);
            assert_eq!(verified_master("nick", "dev-a", &master.peer_id(), &claim, now), None, "stamp {ts}");
        }
    }
}
