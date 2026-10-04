//! The profile card: the name and avatar a person shows to someone it is not close
//! to (A28): either side of a pending friend request, the other people in a meeting,
//! the members of a server it asked to join. The rest of a profile goes only to our
//! own devices, friends and co-members.

use base64::Engine;

use crate::identity::native_identity::NativeKeypair;

use super::types::{SealedCard, SenderCard, SignedCard};

const SEAL_DOMAIN: &[u8] = b"hollow-card-seal1";

/// The avatar bytes one guest sync answer may carry in all, and any one of them.
const GUEST_AVATARS_BUDGET: usize = 1024 * 1024;
const GUEST_AVATAR_MAX_BYTES: usize = 256 * 1024;

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

fn stored(card: &SignedCard) -> crate::storage::messages::StoredCard {
    crate::storage::messages::StoredCard {
        master: card.master.clone(),
        display_name: card.display_name.clone(),
        updated_at: card.updated_at,
        avatar_hash: card.avatar_hash.clone(),
        sig: card.sig.clone(),
        pk: card.pk.clone(),
    }
}

/// Keep `card` as `master`'s newest signed card, when it is that master's own. Only the
/// card: a co-member's full profile stays what decides how we show them.
pub(crate) fn keep_card(card: &SignedCard, master: &str, db_path: &str, db_passphrase: &str) -> bool {
    card.master == master
        && card_holds(card)
        && crate::storage::MessageStore::open(db_path, db_passphrase)
            .ok()
            .and_then(|st| st.save_signed_card(&stored(card)).ok())
            .unwrap_or(false)
}

/// For a guest, the signed card of each sender we have one for (our own we sign now),
/// with its avatar while the answer has room. Never a name a card does not sign (D6).
pub(crate) fn cards_for_guest<'a>(
    store: &crate::storage::MessageStore,
    senders: impl IntoIterator<Item = &'a str>,
    own: Option<&SignedCard>,
) -> std::collections::HashMap<String, SenderCard> {
    use base64::Engine;
    let mut budget = GUEST_AVATARS_BUDGET;
    let mut out = std::collections::HashMap::new();
    for sender in senders {
        let card = match own.filter(|c| c.master == sender) {
            Some(own) => own.clone(),
            None => match store.load_signed_card(sender) {
                Some(c) => SignedCard {
                    master: c.master, display_name: c.display_name, avatar_hash: c.avatar_hash,
                    updated_at: c.updated_at, sig: c.sig, pk: c.pk,
                },
                None => continue,
            },
        };
        let avatar = store
            .load_avatar(sender)
            .ok()
            .flatten()
            .filter(|b| b.len() <= GUEST_AVATAR_MAX_BYTES.min(budget))
            .filter(|b| !card.avatar_hash.is_empty() && super::social::profile_blob_hash(Some(b)) == card.avatar_hash);
        budget -= avatar.as_ref().map_or(0, Vec::len);
        let avatar_b64 = avatar.map(|b| base64::engine::general_purpose::STANDARD.encode(b)).unwrap_or_default();
        out.insert(sender.to_string(), SenderCard { card, avatar_b64 });
    }
    out
}

/// What a guest shows for `sender` from a card a member handed it: the name the card
/// signs and the avatar whose hash it signs, or nothing when the card is not the
/// sender's own.
pub(crate) fn guest_sender(sender: &str, given: SenderCard) -> Option<(String, Option<Vec<u8>>)> {
    use base64::Engine;
    let SenderCard { card, avatar_b64 } = given;
    if card.master != sender || !card_holds(&card) {
        return None;
    }
    let avatar = base64::engine::general_purpose::STANDARD
        .decode(&avatar_b64)
        .ok()
        .filter(|b| b.len() <= GUEST_AVATAR_MAX_BYTES && !card.avatar_hash.is_empty())
        .filter(|b| super::social::profile_blob_hash(Some(b)) == card.avatar_hash);
    Some((card.display_name, avatar))
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
        .and_then(|st| {
            let _ = st.save_signed_card(&stored(card));
            st.save_profile_card(&card.master, &card.display_name, card.updated_at, &card.avatar_hash, avatar).ok()
        })
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
        card_with(owner, name, "")
    }

    fn card_with(owner: &NativeKeypair, name: &str, avatar_hash: &str) -> SignedCard {
        let master = owner.peer_id();
        let payload = crate::node::crypto_handler::card_signing_payload(&master, 7, name, avatar_hash);
        let pk = base64::engine::general_purpose::STANDARD.encode(owner.public_key_protobuf());
        let (Some(sig), Some(pk)) = crate::node::crypto_handler::sign_message(owner, &pk, &payload) else {
            panic!("signing never fails");
        };
        SignedCard { master, display_name: name.into(), avatar_hash: avatar_hash.into(), updated_at: 7, sig, pk }
    }

    /// D6: a guest shows a sender's name only as the sender's own card signs it, and a
    /// picture only when its bytes hash to the card's.
    #[test]
    fn authz_a_guest_shows_only_what_the_senders_card_signs() {
        let b64 = |b: &[u8]| base64::engine::general_purpose::STANDARD.encode(b);
        let (owner, other) = (keypair(51), keypair(52));
        let face = b"the owner's face".to_vec();
        let own = card_with(&owner, "Owen", &crate::node::social::profile_blob_hash(Some(&face)));
        let given = |card: SignedCard, avatar: &[u8]| SenderCard { card, avatar_b64: b64(avatar) };

        assert_eq!(guest_sender(&owner.peer_id(), given(own.clone(), &face)), Some(("Owen".into(), Some(face.clone()))));
        assert_eq!(
            guest_sender(&owner.peer_id(), given(own.clone(), b"another face")),
            Some(("Owen".into(), None)),
            "a picture the card does not sign",
        );
        let renamed = SignedCard { display_name: "Not Owen".into(), ..own.clone() };
        assert!(guest_sender(&owner.peer_id(), given(renamed, &face)).is_none(), "a name the card does not sign");
        assert!(guest_sender(&owner.peer_id(), given(genuine_card(&other, "Owen"), b"")).is_none(), "another identity's card");
        let in_his_name = SignedCard { master: owner.peer_id(), ..genuine_card(&other, "Owen") };
        assert!(guest_sender(&owner.peer_id(), given(in_his_name, b"")).is_none(), "a card in his name, signed by another key");
    }

    /// D6: a member hands a guest only cards it holds signed, and keeps a card only for
    /// the identity that signed it.
    #[test]
    fn a_member_hands_a_guest_only_signed_cards() {
        let tmp = crate::test_tmp::tempdir().unwrap();
        let db = tmp.path().join("m.db").to_string_lossy().into_owned();
        let key = "ab".repeat(32);
        let (a, b, c) = (keypair(53), keypair(54), keypair(55));
        let a_card = genuine_card(&a, "Ay");
        assert!(!keep_card(&a_card, &c.peer_id(), &db, &key), "a card kept for someone else");
        assert!(keep_card(&a_card, &a.peer_id(), &db, &key));
        let store = crate::storage::MessageStore::open(&db, &key).unwrap();
        let own = genuine_card(&b, "Bee");
        let (a_id, b_id, c_id) = (a.peer_id(), b.peer_id(), c.peer_id());
        let cards = cards_for_guest(&store, [a_id.as_str(), b_id.as_str(), c_id.as_str()], Some(&own));
        assert_eq!(cards.len(), 2, "no card, no name");
        assert_eq!(cards[&a_id].card, a_card);
        assert_eq!(cards[&b_id].card, own, "our own, signed now");
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
