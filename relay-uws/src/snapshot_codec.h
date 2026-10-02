#pragma once
#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

// Wire form of the relay state that outlives a service restart: the offline
// delivery buffers, the registrations an offline peer cannot re-send, push
// tokens, and the destroy signals parked for devices that are not connected.
// Header-only and independent of RelayState so the round trip is unit tested
// without a relay (test/test_snapshot_codec.cpp).
//
// Timestamps travel as AGES. steady_clock values belong to the process that
// took them; the reader rebuilds "at = now - age" on its own clock.
namespace snapshot {

// 2 added the parked destroy signals (`kills`), 3 the device-list version marks
// that keep a revoked device out of its master's mailbox (`marks`), 4 the join
// lock chains (`locks`), 5 each ring's owner binding and each ring frame's
// retention (`ring_meta`), 6 the address share every entry is charged to
// (`shares`, fair_share.h) and dropped the owner binding, 7 every identity's
// roster with when the relay first saw each pending join (`rosters`, design
// ID-1R). An older snapshot still decodes, without the newer fields, so a relay
// coming up on this build keeps the buffers the previous one handed over.
static constexpr uint32_t VERSION = 7;
static constexpr uint32_t MIN_VERSION = 1;
// One frame can never exceed the relay's maxPayloadLength, so a longer string
// is corruption, not data.
static constexpr uint32_t MAX_STRING_BYTES = 64u * 1024 * 1024;

// A share of NO_SHARE came from a snapshot older than version 6.
static constexpr uint64_t NO_SHARE = 0;

struct DmFrame {
    std::string room;
    std::string frame;
    std::string sender;
    uint32_t age_secs = 0;
    bool is_image = false;
    bool is_channel = false;
    uint64_t seq = 0;
    uint64_t share = NO_SHARE;  // v6
};
struct DmQueue {
    std::string target;
    std::vector<DmFrame> frames;
};
struct Optin {
    std::string peer;
    int64_t retention_secs = 0;
};
struct TopicFrame {
    std::string frame;
    std::string sender;
    uint32_t age_secs = 0;
    uint64_t seq = 0;
    int64_t retention_secs = 0;  // v5; 0 = unknown
    uint64_t share = NO_SHARE;   // v6
};
struct Topic {
    std::string key;
    bool accepting = true;
    int64_t retention_secs = 0;
    uint32_t registered_age_secs = 0;
    std::vector<TopicFrame> frames;
    uint64_t share = NO_SHARE;  // v6
};
struct PushToken {
    std::string peer;
    std::string token;
    std::string platform;
};
struct ChannelPref {
    std::string channel;
    std::string level;
};
struct ServerPref {
    std::string server;
    std::string level;
    std::vector<ChannelPref> channels;
};
struct PushPref {
    std::string peer;
    std::vector<ServerPref> servers;
};
struct Kill {
    std::string target;
    std::string issuer;
    std::string blob;
    int64_t issued_at_ms = 0;
    uint32_t age_secs = 0;
    uint64_t share = NO_SHARE;  // v6
};
struct Mark {
    std::string master;
    uint64_t version = 0;
    uint64_t share = NO_SHARE;  // v6
};
// The share an identity's registrations (push token, prefs, opt-in) are charged to.
struct Registration {
    std::string peer;
    uint64_t share = NO_SHARE;
};
// One join lock chain: its record key and the links as the JSON the wire carries.
struct Lock {
    std::string key;
    std::string links_json;
    uint64_t share = NO_SHARE;  // v6
};
// One identity's roster as the relay holds it (v7), and how long ago the relay first
// saw each pending join in it.
struct RosterSeen {
    std::string device;
    uint32_t age_secs = 0;
};
struct Roster {
    std::string master;
    std::string json;
    uint64_t share = NO_SHARE;
    std::vector<RosterSeen> seen;
};

struct Data {
    std::vector<DmQueue> dm;
    std::vector<Optin> optin;
    std::vector<Topic> topics;
    std::vector<PushToken> push_tokens;
    std::vector<PushPref> push_prefs;
    std::vector<Kill> kills;
    std::vector<Mark> marks;  // least recently used first, the eviction order
    std::vector<Lock> locks;  // least recently used first, the eviction order
    std::vector<Registration> registrations;  // v6; least recently used first
    std::vector<Roster> rosters;  // v7; least recently used first

    size_t dm_frames() const {
        size_t n = 0;
        for (const auto& q : dm) n += q.frames.size();
        return n;
    }
    size_t topic_frames() const {
        size_t n = 0;
        for (const auto& t : topics) n += t.frames.size();
        return n;
    }
};

namespace detail {

struct Writer {
    std::string out;
    void u8(uint8_t v) { out.push_back(static_cast<char>(v)); }
    void u32(uint32_t v) {
        for (int i = 0; i < 4; i++) out.push_back(static_cast<char>((v >> (8 * i)) & 0xff));
    }
    void u64(uint64_t v) {
        for (int i = 0; i < 8; i++) out.push_back(static_cast<char>((v >> (8 * i)) & 0xff));
    }
    void i64(int64_t v) { u64(static_cast<uint64_t>(v)); }
    void flag(bool b) { u8(b ? 1 : 0); }
    void str(const std::string& s) {
        u32(static_cast<uint32_t>(s.size()));
        out.append(s);
    }
    void count(size_t n) { u32(static_cast<uint32_t>(n)); }
};

// Every accessor answers false at the first byte that is not there or not
// what it must be, and the caller stops at the first false: a truncated or
// damaged snapshot yields "nothing", never a partial state.
struct Reader {
    std::string_view in;
    size_t pos = 0;

    size_t left() const { return in.size() - pos; }
    bool u8(uint8_t& v) {
        if (left() < 1) return false;
        v = static_cast<uint8_t>(in[pos++]);
        return true;
    }
    bool u32(uint32_t& v) {
        if (left() < 4) return false;
        v = 0;
        for (int i = 0; i < 4; i++) v |= static_cast<uint32_t>(static_cast<uint8_t>(in[pos + i])) << (8 * i);
        pos += 4;
        return true;
    }
    bool u64(uint64_t& v) {
        if (left() < 8) return false;
        v = 0;
        for (int i = 0; i < 8; i++) v |= static_cast<uint64_t>(static_cast<uint8_t>(in[pos + i])) << (8 * i);
        pos += 8;
        return true;
    }
    bool i64(int64_t& v) {
        uint64_t u;
        if (!u64(u)) return false;
        v = static_cast<int64_t>(u);
        return true;
    }
    bool flag(bool& b) {
        uint8_t v;
        if (!u8(v) || v > 1) return false;
        b = (v == 1);
        return true;
    }
    bool str(std::string& s) {
        uint32_t n;
        if (!u32(n)) return false;
        if (n > MAX_STRING_BYTES || n > left()) return false;
        s.assign(in.data() + pos, n);
        pos += n;
        return true;
    }
    // Every element costs at least one byte, so a count past the remaining
    // bytes is corruption. Refusing it here keeps a damaged length from
    // becoming a giant allocation.
    bool count(uint32_t& n) {
        if (!u32(n)) return false;
        return n <= left();
    }
    bool tag(const char* t) {
        if (left() < 4) return false;
        if (in.compare(pos, 4, t) != 0) return false;
        pos += 4;
        return true;
    }
};

}  // namespace detail

inline std::string encode(const Data& d) {
    detail::Writer w;
    w.out.append("HRSN", 4);
    w.u32(VERSION);

    w.count(d.dm.size());
    for (const auto& q : d.dm) {
        w.str(q.target);
        w.count(q.frames.size());
        for (const auto& f : q.frames) {
            w.str(f.room);
            w.str(f.frame);
            w.str(f.sender);
            w.u32(f.age_secs);
            w.flag(f.is_image);
            w.flag(f.is_channel);
            w.u64(f.seq);
        }
    }

    w.count(d.optin.size());
    for (const auto& o : d.optin) {
        w.str(o.peer);
        w.i64(o.retention_secs);
    }

    w.count(d.topics.size());
    for (const auto& t : d.topics) {
        w.str(t.key);
        w.flag(t.accepting);
        w.i64(t.retention_secs);
        w.u32(t.registered_age_secs);
        w.count(t.frames.size());
        for (const auto& f : t.frames) {
            w.str(f.frame);
            w.str(f.sender);
            w.u32(f.age_secs);
            w.u64(f.seq);
        }
    }

    w.count(d.push_tokens.size());
    for (const auto& p : d.push_tokens) {
        w.str(p.peer);
        w.str(p.token);
        w.str(p.platform);
    }

    w.count(d.push_prefs.size());
    for (const auto& p : d.push_prefs) {
        w.str(p.peer);
        w.count(p.servers.size());
        for (const auto& s : p.servers) {
            w.str(s.server);
            w.str(s.level);
            w.count(s.channels.size());
            for (const auto& c : s.channels) {
                w.str(c.channel);
                w.str(c.level);
            }
        }
    }

    w.count(d.kills.size());
    for (const auto& k : d.kills) {
        w.str(k.target);
        w.str(k.issuer);
        w.str(k.blob);
        w.i64(k.issued_at_ms);
        w.u32(k.age_secs);
    }

    w.count(d.marks.size());
    for (const auto& m : d.marks) {
        w.str(m.master);
        w.u64(m.version);
    }

    w.count(d.locks.size());
    for (const auto& l : d.locks) {
        w.str(l.key);
        w.str(l.links_json);
    }

    // ring_meta: one entry per topic above, in the same order.
    w.count(d.topics.size());
    for (const auto& t : d.topics) {
        w.count(t.frames.size());
        for (const auto& f : t.frames) w.i64(f.retention_secs);
    }

    // shares: every entry above that is charged to one, in the same order.
    for (const auto& q : d.dm) {
        for (const auto& f : q.frames) w.u64(f.share);
    }
    for (const auto& t : d.topics) {
        w.u64(t.share);
        for (const auto& f : t.frames) w.u64(f.share);
    }
    for (const auto& k : d.kills) w.u64(k.share);
    for (const auto& m : d.marks) w.u64(m.share);
    for (const auto& l : d.locks) w.u64(l.share);
    w.count(d.registrations.size());
    for (const auto& r : d.registrations) {
        w.str(r.peer);
        w.u64(r.share);
    }

    w.count(d.rosters.size());
    for (const auto& r : d.rosters) {
        w.str(r.master);
        w.str(r.json);
        w.u64(r.share);
        w.count(r.seen.size());
        for (const auto& s : r.seen) {
            w.str(s.device);
            w.u32(s.age_secs);
        }
    }

    w.out.append("HRSE", 4);
    return w.out;
}

// False for anything that is not exactly one snapshot of a version this build
// reads; `out` is untouched in that case.
inline bool decode(std::string_view bytes, Data& out) {
    detail::Reader r{bytes};
    Data d;
    uint32_t version = 0;
    if (!r.tag("HRSN") || !r.u32(version) || version < MIN_VERSION || version > VERSION) return false;

    uint32_t n = 0;
    if (!r.count(n)) return false;
    for (uint32_t i = 0; i < n; i++) {
        DmQueue q;
        uint32_t m = 0;
        if (!r.str(q.target) || !r.count(m)) return false;
        for (uint32_t j = 0; j < m; j++) {
            DmFrame f;
            if (!r.str(f.room) || !r.str(f.frame) || !r.str(f.sender) ||
                !r.u32(f.age_secs) || !r.flag(f.is_image) || !r.flag(f.is_channel) ||
                !r.u64(f.seq)) return false;
            q.frames.push_back(std::move(f));
        }
        d.dm.push_back(std::move(q));
    }

    if (!r.count(n)) return false;
    for (uint32_t i = 0; i < n; i++) {
        Optin o;
        if (!r.str(o.peer) || !r.i64(o.retention_secs)) return false;
        d.optin.push_back(std::move(o));
    }

    if (!r.count(n)) return false;
    for (uint32_t i = 0; i < n; i++) {
        Topic t;
        uint32_t m = 0;
        if (!r.str(t.key) || !r.flag(t.accepting) || !r.i64(t.retention_secs) ||
            !r.u32(t.registered_age_secs) || !r.count(m)) return false;
        for (uint32_t j = 0; j < m; j++) {
            TopicFrame f;
            if (!r.str(f.frame) || !r.str(f.sender) || !r.u32(f.age_secs) || !r.u64(f.seq)) return false;
            t.frames.push_back(std::move(f));
        }
        d.topics.push_back(std::move(t));
    }

    if (!r.count(n)) return false;
    for (uint32_t i = 0; i < n; i++) {
        PushToken p;
        if (!r.str(p.peer) || !r.str(p.token) || !r.str(p.platform)) return false;
        d.push_tokens.push_back(std::move(p));
    }

    if (!r.count(n)) return false;
    for (uint32_t i = 0; i < n; i++) {
        PushPref p;
        uint32_t m = 0;
        if (!r.str(p.peer) || !r.count(m)) return false;
        for (uint32_t j = 0; j < m; j++) {
            ServerPref s;
            uint32_t k = 0;
            if (!r.str(s.server) || !r.str(s.level) || !r.count(k)) return false;
            for (uint32_t l = 0; l < k; l++) {
                ChannelPref c;
                if (!r.str(c.channel) || !r.str(c.level)) return false;
                s.channels.push_back(std::move(c));
            }
            p.servers.push_back(std::move(s));
        }
        d.push_prefs.push_back(std::move(p));
    }

    if (version >= 2) {
        if (!r.count(n)) return false;
        for (uint32_t i = 0; i < n; i++) {
            Kill k;
            if (!r.str(k.target) || !r.str(k.issuer) || !r.str(k.blob) ||
                !r.i64(k.issued_at_ms) || !r.u32(k.age_secs)) return false;
            d.kills.push_back(std::move(k));
        }
    }

    if (version >= 3) {
        if (!r.count(n)) return false;
        for (uint32_t i = 0; i < n; i++) {
            Mark m;
            if (!r.str(m.master) || !r.u64(m.version)) return false;
            d.marks.push_back(std::move(m));
        }
    }

    if (version >= 4) {
        if (!r.count(n)) return false;
        for (uint32_t i = 0; i < n; i++) {
            Lock l;
            if (!r.str(l.key) || !r.str(l.links_json)) return false;
            d.locks.push_back(std::move(l));
        }
    }

    if (version >= 5) {
        if (!r.count(n) || n != d.topics.size()) return false;
        for (auto& t : d.topics) {
            uint32_t m = 0;
            std::string owner;
            if (version == 5 && !r.str(owner)) return false;
            if (!r.count(m) || m != t.frames.size()) return false;
            for (auto& f : t.frames) {
                if (!r.i64(f.retention_secs)) return false;
            }
        }
    }

    if (version >= 6) {
        for (auto& q : d.dm) {
            for (auto& f : q.frames) {
                if (!r.u64(f.share)) return false;
            }
        }
        for (auto& t : d.topics) {
            if (!r.u64(t.share)) return false;
            for (auto& f : t.frames) {
                if (!r.u64(f.share)) return false;
            }
        }
        for (auto& k : d.kills) {
            if (!r.u64(k.share)) return false;
        }
        for (auto& m : d.marks) {
            if (!r.u64(m.share)) return false;
        }
        for (auto& l : d.locks) {
            if (!r.u64(l.share)) return false;
        }
        if (!r.count(n)) return false;
        for (uint32_t i = 0; i < n; i++) {
            Registration g;
            if (!r.str(g.peer) || !r.u64(g.share)) return false;
            d.registrations.push_back(std::move(g));
        }
    }

    if (version >= 7) {
        if (!r.count(n)) return false;
        for (uint32_t i = 0; i < n; i++) {
            Roster ro;
            uint32_t m = 0;
            if (!r.str(ro.master) || !r.str(ro.json) || !r.u64(ro.share) || !r.count(m)) return false;
            for (uint32_t j = 0; j < m; j++) {
                RosterSeen s;
                if (!r.str(s.device) || !r.u32(s.age_secs)) return false;
                ro.seen.push_back(std::move(s));
            }
            d.rosters.push_back(std::move(ro));
        }
    }

    if (!r.tag("HRSE") || r.left() != 0) return false;
    out = std::move(d);
    return true;
}

}  // namespace snapshot
