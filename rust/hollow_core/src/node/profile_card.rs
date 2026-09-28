//! The profile card: the name and avatar a person shows to someone it is not close
//! to (A28): either side of a pending friend request, the other people in a meeting,
//! the members of a server it asked to join. The rest of a profile goes only to our
//! own devices, friends and co-members.

use base64::Engine;

use crate::identity::native_identity::NativeKeypair;

use super::types::{SealedCard, SignedCard};

const SEAL_DOMAIN: &[u8] = b"hollow-card-seal1";

/// Our own card, signed now from the stored profile. `None` with no name to show.
pub(crate) fn own_card(master_keypair: &NativeKeypair, db_path: &str, db_passphrase: &str) -> Option<SignedCard> {
    let master = master_keypair.peer_id();
    let store = crate::storage::MessageStore::open(db_path, db_passphrase).ok()?;
    let profile = store.load_profile(&master).ok().flatten()?;
    if profile.display_name.trim().is_empty() {
        return None;
    }
    let avatar_hash = super::social::profile_blob_hash(profile.avatar_bytes.as_deref());
    let payload = super::crypto_handler::card_signing_payload(&master, profile.updated_at, &profile.display_name, &avatar_hash);
    let pk = base64::engine::general_purpose::STANDARD.encode(master_keypair.public_key_protobuf());
    let (Some(sig), Some(pk)) = super::crypto_handler::sign_message(master_keypair, &pk, &payload) else {
        return None;
    };
    Some(SignedCard { master, display_name: profile.display_name, avatar_hash, updated_at: profile.updated_at, sig, pk })
}

/// Our own avatar bytes, for a card pulled by someone who lacks them.
pub(crate) fn own_avatar(master: &str, db_path: &str, db_passphrase: &str) -> Option<Vec<u8>> {
    crate::storage::MessageStore::open(db_path, db_passphrase)
        .ok()?
        .load_profile(master)
        .ok()
        .flatten()?
        .avatar_bytes
        .filter(|b| !b.is_empty())
}

/// Whether `card` is its master's own, within the profile name limit.
pub(crate) fn card_holds(card: &SignedCard) -> bool {
    card.display_name.len() <= super::social::PROFILE_NAME_MAX_BYTES
        && (card.avatar_hash.is_empty() || crate::crdt::valid_emote_hash(&card.avatar_hash))
        && super::crypto_handler::verify_message_signature(
            &card.master,
            Some(&card.sig),
            Some(&card.pk),
            &super::crypto_handler::card_signing_payload(&card.master, card.updated_at, &card.display_name, &card.avatar_hash),
        )
}

fn seal_cipher(local_master: &str, other_master: &str) -> Option<aes_gcm::Aes256Gcm> {
    let key = super::dm_room::pair_key(local_master, other_master, SEAL_DOMAIN)?;
    <aes_gcm::Aes256Gcm as aes_gcm::KeyInit>::new_from_slice(key.as_slice()).ok()
}

fn seal_aad(requester: &str, target: &str, requested_at: i64) -> Vec<u8> {
    [SEAL_DOMAIN, b"\0", requester.as_bytes(), b"\0", target.as_bytes(), &requested_at.to_le_bytes()].concat()
}

/// Our card sealed to one friend-request target: only the two identities can open
/// it, so the relay that carries the request never reads the name.
pub(crate) fn seal_for(card: &SignedCard, target_master: &str, requested_at: i64) -> Option<SealedCard> {
    use aes_gcm::aead::{Aead, Payload};
    let plain = serde_json::to_vec(card).ok()?;
    let mut nonce = [0u8; 12];
    getrandom::fill(&mut nonce).ok()?;
    let aad = seal_aad(&card.master, target_master, requested_at);
    let ct = seal_cipher(&card.master, target_master)?
        .encrypt(aes_gcm::Nonce::from_slice(&nonce), Payload { msg: &plain, aad: &aad })
        .ok()?;
    let engine = base64::engine::general_purpose::STANDARD;
    Some(SealedCard { nonce: engine.encode(nonce), ct: engine.encode(ct) })
}

/// The card a friend request from `requester_master` sealed to us, if it opens and
/// is that requester's own.
pub(crate) fn open_from(sealed: &SealedCard, local_master: &str, requester_master: &str, requested_at: i64) -> Option<SignedCard> {
    use aes_gcm::aead::{Aead, Payload};
    let engine = base64::engine::general_purpose::STANDARD;
    let nonce: [u8; 12] = engine.decode(&sealed.nonce).ok()?.try_into().ok()?;
    let ct = engine.decode(&sealed.ct).ok()?;
    let aad = seal_aad(requester_master, local_master, requested_at);
    let plain = seal_cipher(local_master, requester_master)?
        .decrypt(aes_gcm::Nonce::from_slice(&nonce), Payload { msg: &ct, aad: &aad })
        .ok()?;
    let card: SignedCard = serde_json::from_slice(&plain).ok()?;
    (card.master == requester_master && card_holds(&card)).then_some(card)
}

/// Store a card that `card_holds` passed, with the avatar when its bytes hash to the
/// signed hash. Returns whether anything was written.
pub(crate) fn store_card(card: &SignedCard, avatar: Option<&[u8]>, db_path: &str, db_passphrase: &str) -> bool {
    let avatar = avatar
        .filter(|b| super::social::profile_blob_hash(Some(b)) == card.avatar_hash)
        .and_then(|b| {
            super::social::gated_profile_image(
                &card.master, "card avatar", super::image_convert::PROFILE_AVATAR_RECV_MAX_BYTES, Some(b),
            )
        });
    crate::storage::MessageStore::open(db_path, db_passphrase)
        .ok()
        .and_then(|st| st.save_profile_card(&card.master, &card.display_name, card.updated_at, &card.avatar_hash, avatar).ok())
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use aes_gcm::aead::{Aead, Payload};

    fn keypair(seed: u8) -> NativeKeypair {
        NativeKeypair::from_secret_bytes(&[seed; 32])
    }

    fn genuine_card(owner: &NativeKeypair, name: &str) -> SignedCard {
        let master = owner.peer_id();
        let payload = crate::node::crypto_handler::card_signing_payload(&master, 7, name, "");
        let pk = base64::engine::general_purpose::STANDARD.encode(owner.public_key_protobuf());
        let (Some(sig), Some(pk)) = crate::node::crypto_handler::sign_message(owner, &pk, &payload) else {
            panic!("signing never fails");
        };
        SignedCard { master, display_name: name.into(), avatar_hash: String::new(), updated_at: 7, sig, pk }
    }

    /// `card` sealed under the `sealer`/`target` pair secret, whoever the card names.
    fn seal_as(card: &SignedCard, sealer: &str, target: &str, ts: i64) -> SealedCard {
        let ct = seal_cipher(sealer, target)
            .expect("sealer registered")
            .encrypt(aes_gcm::Nonce::from_slice(&[9u8; 12]), Payload {
                msg: &serde_json::to_vec(card).unwrap(),
                aad: &seal_aad(sealer, target, ts),
            })
            .unwrap();
        let engine = base64::engine::general_purpose::STANDARD;
        SealedCard { nonce: engine.encode([9u8; 12]), ct: engine.encode(ct) }
    }

    #[test]
    fn a_sealed_card_naming_another_master_is_refused() {
        let (a, b, c) = (keypair(41), keypair(42), keypair(43));
        for k in [&a, &b, &c] {
            crate::node::dm_room::register(k);
        }
        let (a_id, b_id, c_id) = (a.peer_id(), b.peer_id(), c.peer_id());

        let own = seal_as(&genuine_card(&c, "Cee"), &c_id, &b_id, 100);
        assert!(open_from(&own, &b_id, &c_id, 100).is_some(), "the requester's own card opens");

        // C holds A's genuine signed card and seals it inside its own request to B.
        let borrowed = seal_as(&genuine_card(&a, "Ay"), &c_id, &b_id, 100);
        assert!(open_from(&borrowed, &b_id, &c_id, 100).is_none(), "C cannot show B someone else's card");
        assert!(open_from(&borrowed, &b_id, &a_id, 100).is_none(), "nor can it pass for a request from A");
    }
}
