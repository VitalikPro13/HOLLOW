// Unit tests for the restart snapshot codec (src/snapshot_codec.h): what the
// relay hands to systemd's fd store on SIGTERM and reads back on start.
//
// The property that matters is "exactly one snapshot or nothing": a round trip
// is byte-for-byte faithful, and every truncation, every bad byte and every
// foreign version is refused outright, because a partial restore would look
// like a relay that silently lost messages.
//
// Build + run from relay-uws/test (no uWebSockets, no libsodium):
//   g++ -std=c++17 -I../src test_snapshot_codec.cpp -o test_snapshot_codec && ./test_snapshot_codec

#include "snapshot_codec.h"

#include <cstdio>
#include <string>

static int failures = 0;

static void check(const std::string& label, bool ok) {
    if (ok) {
        printf("  ok   %s\n", label.c_str());
    } else {
        printf("  FAIL %s\n", label.c_str());
        failures++;
    }
}

static snapshot::Data sample() {
    snapshot::Data d;
    snapshot::DmQueue q;
    q.target = "12D3KooWTargetOne";
    q.frames.push_back({"dmroom", std::string("\x06\x00" "binary" "\x00" "frame", 14), "12D3KooWSenderA", 120, false, false, 7, 101});
    q.frames.push_back({"dmroom", "img", "12D3KooWSenderB", 3600, true, false, 9, 102});
    q.frames.push_back({"srv:abc", "chan", "12D3KooWSenderA", 0, false, true, 11, 101});
    d.dm.push_back(q);
    snapshot::DmQueue q2;
    q2.target = "12D3KooWTargetTwo";
    q2.frames.push_back({"dmroom2", std::string(1000, 'x'), "12D3KooWSenderB", 42, false, false, 8, 1ull << 63});
    d.dm.push_back(q2);

    d.optin.push_back({"12D3KooWTargetOne", 259200});
    d.optin.push_back({"12D3KooWTargetTwo", 3600});

    snapshot::Topic t;
    t.key = std::string("srv:abc\0general", 15);
    t.accepting = false;
    t.retention_secs = 86400;
    t.registered_age_secs = 5;
    t.frames.push_back({"f1", "12D3KooWSenderA", 10, 6, 3600, 103});
    t.frames.push_back({"f2", "12D3KooWSenderB", 20, 10, 86400, 104});
    t.share = 105;
    d.topics.push_back(t);
    snapshot::Topic empty;
    empty.key = std::string("srv:abc\0quiet", 13);
    empty.retention_secs = 3600;
    d.topics.push_back(empty);

    d.push_tokens.push_back({"12D3KooWTargetOne", "fcm-token-xyz", "android"});
    d.push_tokens.push_back({"12D3KooWTargetTwo", "apns-token", "ios"});

    snapshot::PushPref p;
    p.peer = "12D3KooWTargetOne";
    snapshot::ServerPref s;
    s.server = "srv:abc";
    s.level = "mentions";
    s.channels.push_back({"general", "all"});
    s.channels.push_back({"noisy", "nothing"});
    p.servers.push_back(s);
    d.push_prefs.push_back(p);

    d.kills.push_back({"12D3KooWTargetOne", "12D3KooWSenderA", "Y2lwaGVy", 1757000000000, 900, 106});
    d.kills.push_back({"12D3KooWTargetTwo", "12D3KooWSenderA", std::string(2048, 'k'), 1757000001000, 0, 107});

    d.marks.push_back({"12D3KooWMasterOne", 7, 108});
    d.marks.push_back({"12D3KooWMasterTwo", 1ull << 40, 109});
    d.locks.push_back({"0123456789abcdef0123456789abcdef|12D3KooWOwner", R"([{"n":1,"door":"d","change":"c","sig":"s","owner":"o"}])", 110});
    d.locks.push_back({"8ef8bc89d3891dca86ff72c6783e396351aed5ba", "[]", 111});
    d.registrations.push_back({"12D3KooWTargetOne", 112});
    d.registrations.push_back({"12D3KooWTargetTwo", 113});
    return d;
}

// A byte-exact VERSION 1 snapshot, written by the encoder before `kills`
// existed. It is what a relay restarting onto this build takes back from the
// fd store, so it has to keep decoding.
// 358 bytes, VERSION 1
static const unsigned char V1_FIXTURE[] = {
    0x48, 0x52, 0x53, 0x4e, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x15, 0x00, 0x00, 0x00, 0x31, 0x32, 0x44, 0x33, 0x4b, 0x6f, 0x6f, 0x57,
    0x46, 0x69, 0x78, 0x74, 0x75, 0x72, 0x65, 0x54, 0x61, 0x72, 0x67, 0x65,
    0x74, 0x01, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x64, 0x6d, 0x72,
    0x6f, 0x6f, 0x6d, 0x05, 0x00, 0x00, 0x00, 0x06, 0x00, 0x70, 0x61, 0x79,
    0x15, 0x00, 0x00, 0x00, 0x31, 0x32, 0x44, 0x33, 0x4b, 0x6f, 0x6f, 0x57,
    0x46, 0x69, 0x78, 0x74, 0x75, 0x72, 0x65, 0x53, 0x65, 0x6e, 0x64, 0x65,
    0x72, 0x3c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x15, 0x00, 0x00, 0x00, 0x31,
    0x32, 0x44, 0x33, 0x4b, 0x6f, 0x6f, 0x57, 0x46, 0x69, 0x78, 0x74, 0x75,
    0x72, 0x65, 0x54, 0x61, 0x72, 0x67, 0x65, 0x74, 0x10, 0x0e, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x0f, 0x00, 0x00, 0x00,
    0x73, 0x72, 0x76, 0x3a, 0x66, 0x69, 0x78, 0x00, 0x67, 0x65, 0x6e, 0x65,
    0x72, 0x61, 0x6c, 0x01, 0x80, 0x51, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x0c, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00,
    0x72, 0x69, 0x6e, 0x67, 0x15, 0x00, 0x00, 0x00, 0x31, 0x32, 0x44, 0x33,
    0x4b, 0x6f, 0x6f, 0x57, 0x46, 0x69, 0x78, 0x74, 0x75, 0x72, 0x65, 0x53,
    0x65, 0x6e, 0x64, 0x65, 0x72, 0x1e, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x15, 0x00, 0x00,
    0x00, 0x31, 0x32, 0x44, 0x33, 0x4b, 0x6f, 0x6f, 0x57, 0x46, 0x69, 0x78,
    0x74, 0x75, 0x72, 0x65, 0x54, 0x61, 0x72, 0x67, 0x65, 0x74, 0x0b, 0x00,
    0x00, 0x00, 0x66, 0x63, 0x6d, 0x2d, 0x66, 0x69, 0x78, 0x74, 0x75, 0x72,
    0x65, 0x07, 0x00, 0x00, 0x00, 0x61, 0x6e, 0x64, 0x72, 0x6f, 0x69, 0x64,
    0x01, 0x00, 0x00, 0x00, 0x15, 0x00, 0x00, 0x00, 0x31, 0x32, 0x44, 0x33,
    0x4b, 0x6f, 0x6f, 0x57, 0x46, 0x69, 0x78, 0x74, 0x75, 0x72, 0x65, 0x54,
    0x61, 0x72, 0x67, 0x65, 0x74, 0x01, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00,
    0x00, 0x73, 0x72, 0x76, 0x3a, 0x66, 0x69, 0x78, 0x08, 0x00, 0x00, 0x00,
    0x6d, 0x65, 0x6e, 0x74, 0x69, 0x6f, 0x6e, 0x73, 0x01, 0x00, 0x00, 0x00,
    0x07, 0x00, 0x00, 0x00, 0x67, 0x65, 0x6e, 0x65, 0x72, 0x61, 0x6c, 0x03,
    0x00, 0x00, 0x00, 0x61, 0x6c, 0x6c, 0x48, 0x52, 0x53, 0x45,
};

// A byte-exact VERSION 2 snapshot, written by the encoder before `marks` existed.
// 226 bytes, VERSION 2
static const unsigned char V2_FIXTURE[] = {
    0x48, 0x52, 0x53, 0x4e, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x15, 0x00, 0x00, 0x00, 0x31, 0x32, 0x44, 0x33, 0x4b, 0x6f, 0x6f, 0x57,
    0x46, 0x69, 0x78, 0x74, 0x75, 0x72, 0x65, 0x54, 0x61, 0x72, 0x67, 0x65,
    0x74, 0x01, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x64, 0x6d, 0x72,
    0x6f, 0x6f, 0x6d, 0x05, 0x00, 0x00, 0x00, 0x06, 0x00, 0x70, 0x61, 0x79,
    0x15, 0x00, 0x00, 0x00, 0x31, 0x32, 0x44, 0x33, 0x4b, 0x6f, 0x6f, 0x57,
    0x46, 0x69, 0x78, 0x74, 0x75, 0x72, 0x65, 0x53, 0x65, 0x6e, 0x64, 0x65,
    0x72, 0x3c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x15, 0x00, 0x00, 0x00, 0x31,
    0x32, 0x44, 0x33, 0x4b, 0x6f, 0x6f, 0x57, 0x46, 0x69, 0x78, 0x74, 0x75,
    0x72, 0x65, 0x54, 0x61, 0x72, 0x67, 0x65, 0x74, 0x10, 0x0e, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x15, 0x00, 0x00, 0x00,
    0x31, 0x32, 0x44, 0x33, 0x4b, 0x6f, 0x6f, 0x57, 0x46, 0x69, 0x78, 0x74,
    0x75, 0x72, 0x65, 0x54, 0x61, 0x72, 0x67, 0x65, 0x74, 0x15, 0x00, 0x00,
    0x00, 0x31, 0x32, 0x44, 0x33, 0x4b, 0x6f, 0x6f, 0x57, 0x46, 0x69, 0x78,
    0x74, 0x75, 0x72, 0x65, 0x53, 0x65, 0x6e, 0x64, 0x65, 0x72, 0x04, 0x00,
    0x00, 0x00, 0x62, 0x32, 0x73, 0x3d, 0x00, 0x62, 0x5c, 0x15, 0x99, 0x01,
    0x00, 0x00, 0x1e, 0x00, 0x00, 0x00, 0x48, 0x52, 0x53, 0x45,
};

// The same state, as this build models it.
static snapshot::Data v2_sample() {
    snapshot::Data d;
    snapshot::DmQueue q;
    q.target = "12D3KooWFixtureTarget";
    q.frames.push_back({"dmroom", std::string("\x06\x00pay", 5), "12D3KooWFixtureSender", 60, false, false, 3});
    d.dm.push_back(q);
    d.optin.push_back({"12D3KooWFixtureTarget", 3600});
    d.kills.push_back({"12D3KooWFixtureTarget", "12D3KooWFixtureSender", "b2s=", 1757000000000, 30});
    return d;
}

// The same state, as this build models it.
static snapshot::Data v1_sample() {
    snapshot::Data d;
    snapshot::DmQueue q;
    q.target = "12D3KooWFixtureTarget";
    q.frames.push_back({"dmroom", std::string("\x06\x00pay", 5), "12D3KooWFixtureSender", 60, false, false, 3});
    d.dm.push_back(q);
    d.optin.push_back({"12D3KooWFixtureTarget", 3600});
    snapshot::Topic t;
    t.key = std::string("srv:fix\0general", 15);
    t.accepting = true;
    t.retention_secs = 86400;
    t.registered_age_secs = 12;
    t.frames.push_back({"ring", "12D3KooWFixtureSender", 30, 4});
    d.topics.push_back(t);
    d.push_tokens.push_back({"12D3KooWFixtureTarget", "fcm-fixture", "android"});
    snapshot::PushPref p;
    p.peer = "12D3KooWFixtureTarget";
    snapshot::ServerPref s;
    s.server = "srv:fix";
    s.level = "mentions";
    s.channels.push_back({"general", "all"});
    p.servers.push_back(s);
    d.push_prefs.push_back(p);
    return d;
}

static bool same(const snapshot::Data& a, const snapshot::Data& b) {
    if (a.dm.size() != b.dm.size()) return false;
    for (size_t i = 0; i < a.dm.size(); i++) {
        if (a.dm[i].target != b.dm[i].target) return false;
        if (a.dm[i].frames.size() != b.dm[i].frames.size()) return false;
        for (size_t j = 0; j < a.dm[i].frames.size(); j++) {
            const auto& x = a.dm[i].frames[j];
            const auto& y = b.dm[i].frames[j];
            if (x.room != y.room || x.frame != y.frame || x.sender != y.sender ||
                x.age_secs != y.age_secs || x.is_image != y.is_image ||
                x.is_channel != y.is_channel || x.seq != y.seq || x.share != y.share) return false;
        }
    }
    if (a.optin.size() != b.optin.size()) return false;
    for (size_t i = 0; i < a.optin.size(); i++) {
        if (a.optin[i].peer != b.optin[i].peer || a.optin[i].retention_secs != b.optin[i].retention_secs) return false;
    }
    if (a.topics.size() != b.topics.size()) return false;
    for (size_t i = 0; i < a.topics.size(); i++) {
        const auto& x = a.topics[i];
        const auto& y = b.topics[i];
        if (x.key != y.key || x.accepting != y.accepting || x.retention_secs != y.retention_secs ||
            x.registered_age_secs != y.registered_age_secs || x.frames.size() != y.frames.size() ||
            x.share != y.share) return false;
        for (size_t j = 0; j < x.frames.size(); j++) {
            if (x.frames[j].frame != y.frames[j].frame || x.frames[j].sender != y.frames[j].sender ||
                x.frames[j].age_secs != y.frames[j].age_secs || x.frames[j].seq != y.frames[j].seq ||
                x.frames[j].retention_secs != y.frames[j].retention_secs ||
                x.frames[j].share != y.frames[j].share) return false;
        }
    }
    if (a.push_tokens.size() != b.push_tokens.size()) return false;
    for (size_t i = 0; i < a.push_tokens.size(); i++) {
        if (a.push_tokens[i].peer != b.push_tokens[i].peer || a.push_tokens[i].token != b.push_tokens[i].token ||
            a.push_tokens[i].platform != b.push_tokens[i].platform) return false;
    }
    if (a.push_prefs.size() != b.push_prefs.size()) return false;
    for (size_t i = 0; i < a.push_prefs.size(); i++) {
        const auto& x = a.push_prefs[i];
        const auto& y = b.push_prefs[i];
        if (x.peer != y.peer || x.servers.size() != y.servers.size()) return false;
        for (size_t j = 0; j < x.servers.size(); j++) {
            if (x.servers[j].server != y.servers[j].server || x.servers[j].level != y.servers[j].level ||
                x.servers[j].channels.size() != y.servers[j].channels.size()) return false;
            for (size_t k = 0; k < x.servers[j].channels.size(); k++) {
                if (x.servers[j].channels[k].channel != y.servers[j].channels[k].channel ||
                    x.servers[j].channels[k].level != y.servers[j].channels[k].level) return false;
            }
        }
    }
    if (a.kills.size() != b.kills.size()) return false;
    for (size_t i = 0; i < a.kills.size(); i++) {
        const auto& x = a.kills[i];
        const auto& y = b.kills[i];
        if (x.target != y.target || x.issuer != y.issuer || x.blob != y.blob ||
            x.issued_at_ms != y.issued_at_ms || x.age_secs != y.age_secs || x.share != y.share) return false;
    }
    if (a.marks.size() != b.marks.size()) return false;
    for (size_t i = 0; i < a.marks.size(); i++) {
        if (a.marks[i].master != b.marks[i].master || a.marks[i].version != b.marks[i].version ||
            a.marks[i].share != b.marks[i].share) return false;
    }
    if (a.locks.size() != b.locks.size()) return false;
    for (size_t i = 0; i < a.locks.size(); i++) {
        if (a.locks[i].key != b.locks[i].key || a.locks[i].links_json != b.locks[i].links_json ||
            a.locks[i].share != b.locks[i].share) return false;
    }
    if (a.registrations.size() != b.registrations.size()) return false;
    for (size_t i = 0; i < a.registrations.size(); i++) {
        if (a.registrations[i].peer != b.registrations[i].peer ||
            a.registrations[i].share != b.registrations[i].share) return false;
    }
    return true;
}

// The bytes of the `ring_meta` section this build writes for `d`.
static size_t ring_meta_bytes(const snapshot::Data& d) {
    size_t n = 4;
    for (const auto& t : d.topics) n += 4 + 8 * t.frames.size();
    return n;
}

// The bytes of the v6 `shares` section.
static size_t shares_bytes(const snapshot::Data& d) {
    size_t n = 8 * (d.dm_frames() + d.topics.size() + d.topic_frames() + d.kills.size() + d.marks.size() +
                    d.locks.size());
    n += 4;
    for (const auto& r : d.registrations) n += 4 + r.peer.size() + 8;
    return n;
}

// `d` without what v6 added, as a v5 build held it.
static snapshot::Data without_shares(snapshot::Data d) {
    for (auto& q : d.dm) {
        for (auto& f : q.frames) f.share = snapshot::NO_SHARE;
    }
    for (auto& t : d.topics) {
        t.share = snapshot::NO_SHARE;
        for (auto& f : t.frames) f.share = snapshot::NO_SHARE;
    }
    for (auto& k : d.kills) k.share = snapshot::NO_SHARE;
    for (auto& m : d.marks) m.share = snapshot::NO_SHARE;
    for (auto& l : d.locks) l.share = snapshot::NO_SHARE;
    d.registrations.clear();
    return d;
}

// `d` without what v5 and v6 added, as a v4 build held it.
static snapshot::Data without_ring_meta(snapshot::Data d) {
    d = without_shares(std::move(d));
    for (auto& t : d.topics) {
        for (auto& f : t.frames) f.retention_secs = 0;
    }
    return d;
}

// The snapshot a v5 build writes for `d`: this build's bytes up to the ring
// metadata, then v5's form of it, which carried each ring's owner binding.
static std::string as_v5(const snapshot::Data& d, const std::string& owner) {
    std::string bytes = snapshot::encode(d);
    snapshot::detail::Writer w;
    w.out = bytes.substr(0, bytes.size() - 4 - shares_bytes(d) - ring_meta_bytes(d));
    w.out[4] = 5;
    w.count(d.topics.size());
    for (const auto& t : d.topics) {
        w.str(owner);
        w.count(t.frames.size());
        for (const auto& f : t.frames) w.i64(f.retention_secs);
    }
    w.out.append("HRSE", 4);
    return w.out;
}

int main() {
    printf("snapshot codec\n");

    // Round trip: everything comes back, including embedded NULs and the
    // empty ring.
    {
        snapshot::Data in = sample();
        std::string bytes = snapshot::encode(in);
        snapshot::Data out;
        check("decode succeeds", snapshot::decode(bytes, out));
        check("round trip is faithful", same(in, out));
        check("frame counts", out.dm_frames() == 4 && out.topic_frames() == 2);
        check("kill entries survive", out.kills.size() == 2 &&
                                      out.kills[0].blob == "Y2lwaGVy" &&
                                      out.kills[0].issuer == "12D3KooWSenderA" &&
                                      out.kills[1].blob.size() == 2048 &&
                                      out.kills[1].issued_at_ms == 1757000001000);
        check("device-list marks survive, in order", out.marks.size() == 2 &&
                                                     out.marks[0].master == "12D3KooWMasterOne" &&
                                                     out.marks[1].version == (1ull << 40));
        check("join lock chains survive, in order", out.locks.size() == 2 &&
                                                   out.locks[0].key == "0123456789abcdef0123456789abcdef|12D3KooWOwner" &&
                                                   out.locks[1].links_json == "[]");
        check("frame retentions survive", out.topics[0].frames[0].retention_secs == 3600 &&
                                          out.topics[0].frames[1].retention_secs == 86400);
        check("every entry keeps its share", out.dm[1].frames[0].share == (1ull << 63) &&
                                             out.topics[0].share == 105 && out.kills[1].share == 107 &&
                                             out.marks[1].share == 109 && out.locks[1].share == 111 &&
                                             out.registrations[1].share == 113);
        check("re-encode is byte-identical", snapshot::encode(out) == bytes);
    }

    // The relay that charges entries to shares takes back what the v5 build
    // running before it handed over, owner bindings and all, with no shares.
    {
        snapshot::Data in = sample();
        snapshot::Data out;
        check("a v5 snapshot decodes under this reader", snapshot::decode(as_v5(in, "12D3KooWOwner"), out));
        check("and carries its retentions but no shares", same(without_shares(in), out));
        check("a ring without an owner decodes too", snapshot::decode(as_v5(in, ""), out));
    }

    // What a v4 build handed over: the same bytes, less the ring metadata and the
    // shares, under version 4.
    {
        snapshot::Data in = sample();
        std::string bytes = snapshot::encode(in);
        size_t meta = ring_meta_bytes(in) + shares_bytes(in);
        std::string v4 = bytes.substr(0, bytes.size() - 4 - meta) + bytes.substr(bytes.size() - 4);
        v4[4] = 4;
        snapshot::Data out;
        check("a v4 snapshot decodes under this reader", snapshot::decode(v4, out));
        check("and its rings carry no owner or frame retention", same(without_ring_meta(in), out));
    }

    // The relay that introduces the join locks takes back what a v3 build handed
    // over: the same bytes, less the lock count and the ring metadata, under version 3.
    {
        snapshot::Data in = sample();
        in.locks.clear();
        std::string bytes = snapshot::encode(in);
        size_t meta = ring_meta_bytes(in) + shares_bytes(in);
        std::string v3 = bytes.substr(0, bytes.size() - 8 - meta) + bytes.substr(bytes.size() - 4);
        v3[4] = 3;
        snapshot::Data out;
        check("a v3 snapshot decodes under this reader", snapshot::decode(v3, out));
        check("and carries no join locks", out.locks.empty() && same(without_ring_meta(in), out));
    }

    // A ring_meta that does not match the rings it describes is corruption.
    {
        snapshot::Data in = sample();
        std::string bytes = snapshot::encode(in);
        size_t meta = ring_meta_bytes(in) + shares_bytes(in);
        std::string bad = bytes;
        bad[bytes.size() - 4 - meta] = 3;  // claims three rings where there are two
        snapshot::Data out;
        check("ring metadata for the wrong number of rings is refused", !snapshot::decode(bad, out));
    }

    // An empty relay is a valid snapshot too.
    {
        snapshot::Data in;
        std::string bytes = snapshot::encode(in);
        snapshot::Data out;
        check("empty snapshot decodes", snapshot::decode(bytes, out));
        check("empty snapshot is empty", out.dm.empty() && out.optin.empty() && out.topics.empty() &&
                                         out.push_tokens.empty() && out.push_prefs.empty() &&
                                         out.kills.empty() && out.marks.empty());
    }

    // Every proper prefix is refused and leaves `out` untouched.
    {
        std::string bytes = snapshot::encode(sample());
        bool all_refused = true;
        bool untouched = true;
        for (size_t n = 0; n < bytes.size(); n++) {
            snapshot::Data out;
            out.optin.push_back({"sentinel", 1});
            if (snapshot::decode(std::string_view(bytes).substr(0, n), out)) all_refused = false;
            if (out.optin.size() != 1 || out.optin[0].peer != "sentinel") untouched = false;
        }
        check("every truncation is refused", all_refused);
        check("a refused decode leaves the output untouched", untouched);
    }

    // Trailing bytes, a foreign version, a bad magic, a bad flag byte and an
    // impossible count are all refused.
    {
        std::string bytes = snapshot::encode(sample());
        snapshot::Data out;
        check("trailing garbage is refused", !snapshot::decode(bytes + "x", out));

        std::string wrong_version = bytes;
        wrong_version[4] = static_cast<char>(snapshot::VERSION + 1);
        check("a foreign version is refused", !snapshot::decode(wrong_version, out));

        std::string bad_magic = bytes;
        bad_magic[0] = 'X';
        check("a bad magic is refused", !snapshot::decode(bad_magic, out));

        // The first DM frame's is_image flag sits right after its age field;
        // locate it by searching for the sender that precedes the age.
        std::string bad_flag = bytes;
        size_t sender_at = bad_flag.find("12D3KooWSenderA");
        size_t flag_at = sender_at + std::string("12D3KooWSenderA").size() + 4;
        bad_flag[flag_at] = 2;
        check("a flag byte other than 0/1 is refused", !snapshot::decode(bad_flag, out));

        // Corrupt the top-level DM queue count to something larger than the
        // whole snapshot.
        std::string bad_count = bytes;
        bad_count[8] = static_cast<char>(0xff);
        bad_count[9] = static_cast<char>(0xff);
        bad_count[10] = static_cast<char>(0xff);
        bad_count[11] = static_cast<char>(0x7f);
        check("a count past the end is refused", !snapshot::decode(bad_count, out));
    }

    // A string length past the ceiling is refused before any allocation.
    {
        std::string bytes = snapshot::encode(sample());
        // First string is the first DM target: its length field is at offset 12.
        bytes[12] = static_cast<char>(0x01);
        bytes[13] = static_cast<char>(0x00);
        bytes[14] = static_cast<char>(0x00);
        bytes[15] = static_cast<char>(0x08);  // 128 MB + 1
        snapshot::Data out;
        check("a string past the ceiling is refused", !snapshot::decode(bytes, out));
    }

    // A snapshot written by the PREVIOUS build still restores, with no kills:
    // the deploy that introduces this version must not empty the buffers the
    // running relay hands over.
    {
        std::string_view v1(reinterpret_cast<const char*>(V1_FIXTURE), sizeof(V1_FIXTURE));
        snapshot::Data out;
        check("the v1 fixture decodes under this reader", snapshot::decode(v1, out));
        check("a v1 snapshot carries no kills", out.kills.empty());
        check("every other v1 field is unchanged", same(v1_sample(), out));

        std::string rewritten = snapshot::encode(out);
        snapshot::Data again;
        check("a restored v1 snapshot is written back at this version",
              rewritten != std::string(v1) && snapshot::decode(rewritten, again) &&
              same(v1_sample(), again));

        std::string zero_version(v1);
        zero_version[4] = 0;
        snapshot::Data untouched;
        check("a version below the floor is refused", !snapshot::decode(zero_version, untouched));
    }

    // I10: the relay that introduces the marks takes back what the previous
    // build handed over.
    {
        std::string_view v2(reinterpret_cast<const char*>(V2_FIXTURE), sizeof(V2_FIXTURE));
        snapshot::Data out;
        check("the v2 fixture decodes under this reader", snapshot::decode(v2, out));
        check("a v2 snapshot carries no marks", out.marks.empty());
        check("every v2 field is unchanged", same(v2_sample(), out));
    }

    if (failures) {
        printf("%d FAILURE(S)\n", failures);
        return 1;
    }
    printf("all ok\n");
    return 0;
}
