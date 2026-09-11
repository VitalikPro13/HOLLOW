#include "snapshot.h"
#include "snapshot_codec.h"
#include "sd_fdstore.h"
#include "ws_handler.h"

#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cstdio>
#include <limits>

using Clock = std::chrono::steady_clock;

static constexpr const char* FD_NAME = "snapshot";
// Nothing legitimate is this big: the byte budget bounds a snapshot far below.
static constexpr off_t MAX_SNAPSHOT_BYTES = 16ll * 1024 * 1024 * 1024;

static uint32_t age_secs(Clock::time_point at, Clock::time_point now) {
    auto s = std::chrono::duration_cast<std::chrono::seconds>(now - at).count();
    if (s < 0) return 0;
    if (s > static_cast<int64_t>(std::numeric_limits<uint32_t>::max()))
        return std::numeric_limits<uint32_t>::max();
    return static_cast<uint32_t>(s);
}

static Clock::time_point at_from_age(uint32_t age, Clock::time_point now) {
    return now - std::chrono::seconds(age);
}

static snapshot::Data capture(const RelayState& st, Clock::time_point now) {
    snapshot::Data d;
    for (const auto& [target, q] : st.offline_buffer) {
        if (q.empty()) continue;
        snapshot::DmQueue sq;
        sq.target = target;
        for (const auto& m : q) {
            sq.frames.push_back({m.room, m.frame, m.sender, age_secs(m.at, now),
                                 m.is_image, m.is_channel, m.seq});
        }
        d.dm.push_back(std::move(sq));
    }
    for (const auto& [peer, retention] : st.offline_optin) d.optin.push_back({peer, retention});
    for (const auto& [key, tb] : st.topic_buffers) {
        snapshot::Topic t;
        t.key = key;
        t.accepting = tb.accepting;
        t.retention_secs = tb.retention_secs;
        t.registered_age_secs = age_secs(tb.last_registered, now);
        for (const auto& f : tb.frames) {
            t.frames.push_back({f.frame, f.sender, age_secs(f.at, now), f.seq});
        }
        d.topics.push_back(std::move(t));
    }
    for (const auto& [peer, tok] : st.push_tokens) d.push_tokens.push_back({peer, tok.token, tok.platform});
    for (const auto& [target, e] : st.kill_list.entries) {
        d.kills.push_back({target, e.issuer, e.blob, e.issued_at_ms, age_secs(e.stored_at, now)});
    }
    for (const auto& [peer, servers] : st.push_prefs) {
        snapshot::PushPref p;
        p.peer = peer;
        for (const auto& [server, pref] : servers) {
            snapshot::ServerPref s;
            s.server = server;
            s.level = pref.level;
            for (const auto& [cid, level] : pref.channels) s.channels.push_back({cid, level});
            p.servers.push_back(std::move(s));
        }
        d.push_prefs.push_back(std::move(p));
    }
    return d;
}

// Only meaningful on an empty state: a fresh process, before it listens.
static void apply(RelayState& st, snapshot::Data&& d, Clock::time_point now) {
    for (auto& o : d.optin) st.offline_optin[o.peer] = o.retention_secs;
    for (auto& p : d.push_tokens) st.push_tokens[p.peer] = {std::move(p.token), std::move(p.platform)};
    for (auto& p : d.push_prefs) {
        auto& servers = st.push_prefs[p.peer];
        for (auto& s : p.servers) {
            RelayState::ServerPushPref pref;
            pref.level = std::move(s.level);
            for (auto& c : s.channels) pref.channels[c.channel] = std::move(c.level);
            servers[s.server] = std::move(pref);
        }
    }

    // Deposit order decides which entry a full kill list evicts first, so the
    // oldest goes back in first.
    std::sort(d.kills.begin(), d.kills.end(),
              [](const snapshot::Kill& a, const snapshot::Kill& b) { return a.age_secs > b.age_secs; });
    for (auto& k : d.kills) {
        st.kill_list.restore(k.target, k.issuer, k.blob, k.issued_at_ms, at_from_age(k.age_secs, now));
    }

    // The eviction index must see every frame in the order the old process
    // admitted it, DM and topic interleaved, so frames are placed first and
    // stamped afterwards in ascending old-seq order.
    struct Stamp {
        uint64_t old_seq;
        bool is_topic;
        std::string key;
        size_t idx;
    };
    std::vector<Stamp> stamps;
    size_t total = 0;

    for (auto& sq : d.dm) {
        if (sq.frames.empty()) continue;
        auto& q = st.offline_buffer[sq.target];
        for (auto& f : sq.frames) {
            total += f.frame.size();
            q.push_back({std::move(f.room), std::move(f.frame), std::move(f.sender),
                         at_from_age(f.age_secs, now), f.is_image, f.is_channel, 0});
            stamps.push_back({f.seq, false, sq.target, q.size() - 1});
        }
    }
    for (auto& t : d.topics) {
        auto& tb = st.topic_buffers[t.key];
        tb.accepting = t.accepting;
        tb.retention_secs = t.retention_secs;
        tb.last_registered = at_from_age(t.registered_age_secs, now);
        tb.bytes = 0;
        for (auto& f : t.frames) {
            total += f.frame.size();
            tb.bytes += f.frame.size();
            tb.frames.push_back({std::move(f.frame), std::move(f.sender),
                                 at_from_age(f.age_secs, now), 0});
            stamps.push_back({f.seq, true, t.key, tb.frames.size() - 1});
        }
    }

    std::sort(stamps.begin(), stamps.end(),
              [](const Stamp& a, const Stamp& b) { return a.old_seq < b.old_seq; });
    for (const auto& s : stamps) {
        if (s.is_topic) {
            st.topic_buffers[s.key].frames[s.idx].seq = st.buffer_index.stamp_topic(s.key);
        } else {
            auto& q = st.offline_buffer[s.key];
            q[s.idx].seq = st.buffer_index.stamp_dm(s.key, q[s.idx].sender);
        }
    }
    st.buffer_total_bytes = total;
}

void snapshot_to_fdstore(RelayState& st) {
    if (!fdstore::available()) {
        fprintf(stderr, "[snapshot] no fd store (not under systemd): buffers end with this process\n");
        return;
    }
    auto now = Clock::now();
    snapshot::Data d = capture(st, now);
    std::string bytes = snapshot::encode(d);

    int fd = memfd_create("hollow-relay-snapshot", MFD_CLOEXEC);
    if (fd < 0) {
        perror("[snapshot] memfd_create");
        return;
    }
    size_t off = 0;
    while (off < bytes.size()) {
        ssize_t n = write(fd, bytes.data() + off, bytes.size() - off);
        if (n <= 0) {
            perror("[snapshot] write");
            close(fd);
            return;
        }
        off += static_cast<size_t>(n);
    }
    // A stale entry under the same name would make the store refuse this one.
    fdstore::remove(FD_NAME);
    bool ok = fdstore::store(fd, FD_NAME);
    close(fd);
    // Counts only: no key, room or peer id is ever printed.
    fprintf(stderr,
            "[snapshot] %s: %zu DM frames in %zu queues, %zu topic frames in %zu rings, "
            "%zu opt-ins, %zu push tokens, %zu push prefs, %zu kill entries, %zu bytes\n",
            ok ? "handed to the fd store" : "fd store REFUSED (buffers end with this process)",
            d.dm_frames(), d.dm.size(), d.topic_frames(), d.topics.size(),
            d.optin.size(), d.push_tokens.size(), d.push_prefs.size(), d.kills.size(),
            bytes.size());
}

void restore_from_fdstore(RelayState& st) {
    int fd = fdstore::take(FD_NAME);
    if (fd < 0) return;
    // Dropped from the store BEFORE it is parsed: a snapshot that crashes the
    // reader must not come back on the next restart.
    fdstore::remove(FD_NAME);

    struct stat sb {};
    if (fstat(fd, &sb) != 0 || sb.st_size <= 0 || sb.st_size > MAX_SNAPSHOT_BYTES) {
        close(fd);
        fprintf(stderr, "[snapshot] discarded a stored snapshot with an unusable size\n");
        return;
    }
    std::string bytes;
    bytes.resize(static_cast<size_t>(sb.st_size));
    // The store's duplicate shares the file offset the writer left at the end.
    lseek(fd, 0, SEEK_SET);
    size_t off = 0;
    while (off < bytes.size()) {
        ssize_t n = read(fd, bytes.data() + off, bytes.size() - off);
        if (n <= 0) break;
        off += static_cast<size_t>(n);
    }
    close(fd);
    if (off != bytes.size()) {
        fprintf(stderr, "[snapshot] discarded a short stored snapshot (%zu of %zu bytes)\n", off, bytes.size());
        return;
    }

    snapshot::Data d;
    if (!snapshot::decode(bytes, d)) {
        fprintf(stderr, "[snapshot] discarded an unreadable stored snapshot (%zu bytes)\n", bytes.size());
        return;
    }
    std::string().swap(bytes);

    size_t dm_frames = d.dm_frames(), dm_queues = d.dm.size();
    size_t topic_frames = d.topic_frames(), rings = d.topics.size();
    size_t optins = d.optin.size(), tokens = d.push_tokens.size(), prefs = d.push_prefs.size();
    size_t kills = d.kills.size();
    apply(st, std::move(d), Clock::now());
    // Whatever aged out while the service was down, and whatever a smaller
    // budget in this build no longer admits.
    sweep_offline_buffer(st);
    enforce_buffer_budget(st);
    st.kill_list.sweep(Clock::now());
    fprintf(stderr,
            "[snapshot] restored %zu DM frames in %zu queues, %zu topic frames in %zu rings, "
            "%zu opt-ins, %zu push tokens, %zu push prefs, %zu kill entries; "
            "%zu frames live after expiry, %zu kill entries live\n",
            dm_frames, dm_queues, topic_frames, rings, optins, tokens, prefs, kills,
            st.buffer_index.live, st.kill_list.size());
}
