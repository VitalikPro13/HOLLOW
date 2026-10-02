# Design D1: door-proof server rooms

Session 28 (2026-10-02). Decision D1 of the phase B re-check (`tmp4.txt` section 1, Vitalik:
"protect servers from plain outsiders"). Finding HOL-SEC-091.

## The problem in one paragraph

A server's relay room is named by its id, and anyone holding the id can join it. The relay
then hands the joiner the room's roster (every member device online), tells it of every
join and leave (online times), and fans it every broadcast with its sender's device id. Nothing
sealed or MLS leaks, but a device id is the same in every room, so a crawler that collects
server ids from the internet can follow one device across servers and know when it is
online, and a post in any public channel ties that device to its master.

## The design

1. **The relay already holds each 0.12 server's join lock** (`join_lock.h`, record key = the
   40-hex id). Its newest door's public half is the test: a socket that proves the door's
   secret is a prover; a room whose id has a lock record is LOCKED. A legacy (32-hex) room,
   a meeting or a 40-hex room with no lock stays as today (fail open, AR like AR-10).
2. **The proof** (`door_proof`, pinned in Rust `ws_client::door_proof` and C++
   `door_room::proof_message` + `crypto.cpp`): the relay mints an X25519 key at start (RAM
   only) and hands its public half out in `auth_challenge` (`door_key`). The join carries
   `HMAC-SHA256(X25519(door, relay), "hollow-door1\n{domain}\n{nonce}\n{peer}\n{room}\n{door}\n{relay key}")`,
   bound to the socket's auth nonce, so it opens nothing on another socket, relay or room.
3. **In a locked room only provers see**: the roster, `peer_joined`/`peer_left`, discover,
   check_peers, room broadcasts (0x03, JSON msg), topic fan-out (0x07) and ring catch-up.
   A non-prover is listed to nobody and is told only itself, with `"proved": false`.
   Directs still reach it: a member chooses to address a joiner, a guest or a stale member.
4. **Public frames**: a new opcode 0x0A is a room broadcast that also reaches non-provers
   (delivered as the usual 0x05). Members send public-channel traffic on it, so guests keep
   live public posts; a non-prover's 0x0A counts as a plain 0x03.
5. **A lock move keeps everyone who could see for a grace (60 s)**: at the move nobody but
   the mover holds the new door, and the op carrying it must still reach the members. A
   member re-proves as soon as its state holds the new door; whoever has not by the end
   (the removed member) drops out: the provers see it leave, it is told `proved: false`
   with only itself listed. A lock appearing on an open room (first lock, a put-back after
   eviction) works the same way, and a stored proof that verifies against the new door
   (a put-back) keeps its socket a prover at once.
6. **A member whose door is stale gets back in by asking**: on `proved: false` for a server
   it is a member of, it first proves with the newest door its state holds; failing that it
   broadcasts `DoorAsk` (provers hear non-provers' broadcasts). Up to three online members
   that place it (a roster device of a current, unbanned member) answer with `DoorGrant`, the
   newest door sealed to its device key, as a direct. It takes a grant only if its door is
   the newest lock of a chain it verified to the owner (`lock_keeper`), then proves.
7. **A joiner** sees nobody, so it also sends its sealed request as a room broadcast;
   members answer it by direct as before, and once admitted it holds the door and proves.
   An empty room no longer looks empty to it, so it parks on the full window (15 s),
   never the 3 s "nobody is here" one: telling it otherwise is the presence D1 hides.
8. **Reply routes** (`door_room::note_heard`, a table per node loop): a node remembers the
   room a hidden sender spoke from, so key exchange, carried frames and file streams can
   answer it, only where answering a stranger is the point: a server with a public
   channel, a room we browse as a guest, a server we are joining. A guest asks the poster
   it heard; an admitting member's first key request goes into the server's room.
9. **The socket always proves the newest door the node holds**: `DoorRooms::sync` runs on
   every turn of the node loop (cheap: it compares door ids and decodes only on change),
   so a door that reaches the state proves itself before anything else goes out.
10. **No new state survives a restart**: proofs are per socket and the relay key changes on
   restart; clients prove again on reconnect. No snapshot codec change.

## What it does not stop (AR)

- Anyone who joins through an open invite is a member like any other (Vitalik).
- Someone who already knows a device id can address it in a room and learn from a reply
  that it is there; in a server without public channels no hidden peer gets a reply.
- A removed member keeps presence for up to the grace after its removal.
- A lock record evicted under the fair-share budget leaves its room open until a member
  puts the chain back (phase G: address-block floods).
- Legacy (32-hex) servers and meetings stay as today.
