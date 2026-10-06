#pragma once
#include <cstdint>

#include "state.h"

// Hand the state that must outlive a service restart (offline buffers, the
// registrations an offline peer cannot re-send, push tokens and prefs, resumable
// sessions) to systemd's fd store: memory to memory through a memfd, never a file,
// gone with the box. A no-op outside systemd. Call on the loop thread, before any
// socket closes.
void snapshot_to_fdstore(RelayState& state);

// Take back what the previous process of this service stored, if anything,
// and rebuild the buffers, the eviction index and the byte budget. Sessions come
// back in grace for `session_grace_secs`. Call before listening.
void restore_from_fdstore(RelayState& state, int64_t session_grace_secs);
