//! A temporary nickname's claim, signed by the claimer's MASTER key. The relay kept
//! whatever master a claimer typed, and the client friended it without a word, so a
//! squatter (or the relay) chose whose inbox received our request, bundle and device
//! list. Now the relay stores only a claim the master signed for the device holding
//! the nickname, the resolver checks it again, and the person confirms before a
//! request goes out. Relay side: `nickname_claim_message` in relay-uws/src/validate.h.

use base64::Engine;

use crate::identity::native_identity::NativeKeypair;

/// How old a resolved claim may be: the relay's ten minute nickname lifetime plus
/// clock skew between the two clients.
const MAX_CLAIM_AGE_MS: i64 = 11 * 60 * 1000;

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

/// The master a resolved nickname speaks for: only when that master signed a claim
/// for this nickname and the device holding it, recently.
pub(crate) fn verified_master(nickname: &str, device: &str, master: &str, claim: &NickClaim, now_ms: i64) -> Option<String> {
    if (now_ms - claim.ts_ms).abs() > MAX_CLAIM_AGE_MS {
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
}
