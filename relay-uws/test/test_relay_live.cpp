// Live tests of the relay's dispatch gates (src/ws_handler.cpp). The rules behind them
// have unit tests of their own; these fail when a handler stops asking them. The real
// relay runs on 127.0.0.1 (run_live.sh builds and starts it) and this drives it over TLS
// with throwaway identities, auth v2 for real. It runs against two builds: the four
// release-day switches on (the binary today) and off (once 0.12 ships).
//
//   test_relay_live <port> <auth domain> <on|off>
//
// A negative ("receives nothing") is read after a barrier, never a sleep: the sender
// and then the receiver each finish a round trip, and the relay handles one frame at a
// time, so whatever it sent the receiver for the sender's frame arrived before the
// receiver's answer. Never registers a push token: the relay would post to whatever
// listens on 127.0.0.1:3001.

#include "auth_frame.h"
#include "crypto.h"
#include "device_list.h"
#include "door_room.h"
#include "join_lock.h"
#include "json.hpp"
#include "ring_auth.h"
#include "roster.h"
#include "validate.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <openssl/ssl.h>
#include <poll.h>
#include <sodium.h>
#include <sys/socket.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <vector>

using json = nlohmann::json;

static int failures = 0;
static int g_port = 0;
static std::string g_domain;
static bool g_legacy = true;
static SSL_CTX* g_ctx = nullptr;
static int g_next_source = 0;
static int g_sync = 0;
static std::string g_tag;

// Generous for a sanitized relay; a positive check waits at most this long.
static constexpr int WAIT_MS = 5000;

static void check(const std::string& label, bool ok) {
    if (ok) {
        printf("  ok   %s\n", label.c_str());
    } else {
        printf("  FAIL %s\n", label.c_str());
        failures++;
    }
    fflush(stdout);
}

static std::string b64(const unsigned char* data, size_t len) {
    std::string out(sodium_base64_encoded_len(len, sodium_base64_VARIANT_ORIGINAL), '\0');
    sodium_bin2base64(out.data(), out.size(), data, len, sodium_base64_VARIANT_ORIGINAL);
    out.resize(strlen(out.c_str()));
    return out;
}

static int64_t wall_ms() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::system_clock::now().time_since_epoch())
        .count();
}

static int left_ms(std::chrono::steady_clock::time_point deadline) {
    auto left = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now());
    return left.count() > 0 ? static_cast<int>(left.count()) : 0;
}

struct Ident {
    unsigned char pk[crypto_sign_PUBLICKEYBYTES];
    unsigned char sk[crypto_sign_SECRETKEYBYTES];
    std::string pub_b64;  // the protobuf-wrapped key, as auth frames carry it
    std::string peer;

    Ident() {
        crypto_sign_keypair(pk, sk);
        unsigned char proto[36] = {0x08, 0x01, 0x12, 0x20};
        memcpy(proto + 4, pk, 32);
        pub_b64 = b64(proto, sizeof(proto));
        peer = derive_peer_id(pub_b64);
    }

    std::string sign(const std::string& msg) const {
        unsigned char sig[crypto_sign_BYTES];
        crypto_sign_detached(sig, nullptr, reinterpret_cast<const unsigned char*>(msg.data()), msg.size(), sk);
        return b64(sig, sizeof(sig));
    }
};

struct Door {
    unsigned char sk[32];
    std::string text;

    Door() {
        randombytes_buf(sk, sizeof(sk));
        DoorKey k;
        door_key_from(k, sk);
        text = k.text;
    }
};

struct Frame {
    bool text = false;
    std::string data;
};

// One TLS WebSocket to the relay, each from its own loopback address: the relay admits
// ten new connections a minute per address.
class Socket {
  public:
    std::deque<Frame> inbox;

    ~Socket() { drop(); }

    bool open() {
        fd_ = socket(AF_INET, SOCK_STREAM, 0);
        if (fd_ < 0) return false;
        const int n = g_next_source++;
        sockaddr_in src{};
        src.sin_family = AF_INET;
        src.sin_addr.s_addr = htonl(0x7f000000u | static_cast<uint32_t>(1 + n / 250) << 8 | static_cast<uint32_t>(2 + n % 250));
        sockaddr_in dst{};
        dst.sin_family = AF_INET;
        dst.sin_port = htons(static_cast<uint16_t>(g_port));
        dst.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(fd_, reinterpret_cast<sockaddr*>(&src), sizeof(src)) != 0) return false;
        if (connect(fd_, reinterpret_cast<sockaddr*>(&dst), sizeof(dst)) != 0) return false;
        int one = 1;
        setsockopt(fd_, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        ssl_ = SSL_new(g_ctx);
        SSL_set_fd(ssl_, fd_);
        if (SSL_connect(ssl_) != 1) return false;
        fcntl(fd_, F_SETFL, fcntl(fd_, F_GETFL) | O_NONBLOCK);

        unsigned char key[16];
        randombytes_buf(key, sizeof(key));
        write_all("GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                  "Sec-WebSocket-Key: " + b64(key, sizeof(key)) + "\r\nSec-WebSocket-Version: 13\r\n\r\n");
        auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(WAIT_MS);
        while (rbuf_.find("\r\n\r\n") == std::string::npos) {
            if (!fill(left_ms(deadline))) return false;
        }
        size_t end = rbuf_.find("\r\n\r\n");
        bool upgraded = rbuf_.compare(0, 12, "HTTP/1.1 101") == 0;
        rbuf_.erase(0, end + 4);
        return upgraded;
    }

    void send_frame(uint8_t opcode, const std::string& payload) {
        if (!ssl_ || closed_) return;
        std::string f(1, static_cast<char>(0x80 | opcode));
        if (payload.size() < 126) {
            f.push_back(static_cast<char>(0x80 | payload.size()));
        } else if (payload.size() <= 0xffff) {
            f.push_back(static_cast<char>(0x80 | 126));
            f.push_back(static_cast<char>(payload.size() >> 8));
            f.push_back(static_cast<char>(payload.size() & 0xff));
        } else {
            f.push_back(static_cast<char>(0x80 | 127));
            for (int i = 7; i >= 0; i--) f.push_back(static_cast<char>((static_cast<uint64_t>(payload.size()) >> (8 * i)) & 0xff));
        }
        unsigned char mask[4];
        randombytes_buf(mask, sizeof(mask));
        f.append(reinterpret_cast<const char*>(mask), 4);
        for (size_t i = 0; i < payload.size(); i++) f.push_back(static_cast<char>(payload[i] ^ mask[i % 4]));
        write_all(f);
    }

    // Reads until one more data frame is in `inbox`; false on timeout or close.
    bool pump(int timeout_ms) {
        auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
        for (;;) {
            size_t before = inbox.size();
            while (take_frame()) {
                if (inbox.size() > before) return true;
            }
            if (closed_) return false;
            int left = left_ms(deadline);
            if (left <= 0 || !fill(left)) return false;
        }
    }

    bool closed() const { return closed_; }

    // Close and wait for the relay's close frame: its close handler has run by then.
    bool close_clean() {
        send_frame(0x8, std::string("\x03\xe8", 2));
        auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(WAIT_MS);
        while (!closed_ && left_ms(deadline) > 0) pump(left_ms(deadline));
        bool ok = closed_;
        drop();
        return ok;
    }

  private:
    int fd_ = -1;
    SSL* ssl_ = nullptr;
    std::string rbuf_;
    std::string partial_;
    bool partial_text_ = false;
    bool closed_ = false;

    void drop() {
        if (ssl_) SSL_free(ssl_);
        ssl_ = nullptr;
        if (fd_ >= 0) close(fd_);
        fd_ = -1;
        closed_ = true;
    }

    void write_all(const std::string& data) {
        size_t off = 0;
        auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(WAIT_MS);
        while (off < data.size()) {
            int n = SSL_write(ssl_, data.data() + off, static_cast<int>(data.size() - off));
            if (n > 0) {
                off += static_cast<size_t>(n);
                continue;
            }
            int err = SSL_get_error(ssl_, n);
            if ((err != SSL_ERROR_WANT_WRITE && err != SSL_ERROR_WANT_READ) || left_ms(deadline) <= 0) {
                closed_ = true;
                return;
            }
            pollfd p{fd_, static_cast<short>(err == SSL_ERROR_WANT_READ ? POLLIN : POLLOUT), 0};
            poll(&p, 1, left_ms(deadline));
        }
    }

    bool fill(int timeout_ms) {
        if (!ssl_ || closed_) return false;
        auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
        for (;;) {
            char buf[65536];
            int n = SSL_read(ssl_, buf, sizeof(buf));
            if (n > 0) {
                rbuf_.append(buf, static_cast<size_t>(n));
                return true;
            }
            int err = SSL_get_error(ssl_, n);
            if (err != SSL_ERROR_WANT_READ && err != SSL_ERROR_WANT_WRITE) {
                closed_ = true;
                return false;
            }
            int left = left_ms(deadline);
            if (left <= 0) return false;
            pollfd p{fd_, static_cast<short>(err == SSL_ERROR_WANT_WRITE ? POLLOUT : POLLIN), 0};
            if (poll(&p, 1, left) <= 0) return false;
        }
    }

    // One whole frame off the buffer, if there is one; control frames are handled here.
    bool take_frame() {
        if (rbuf_.size() < 2) return false;
        const auto* b = reinterpret_cast<const unsigned char*>(rbuf_.data());
        const bool fin = (b[0] & 0x80) != 0;
        const uint8_t op = b[0] & 0x0f;
        uint64_t len = b[1] & 0x7f;
        size_t pos = 2;
        if (len == 126) {
            if (rbuf_.size() < 4) return false;
            len = (static_cast<uint64_t>(b[2]) << 8) | b[3];
            pos = 4;
        } else if (len == 127) {
            if (rbuf_.size() < 10) return false;
            len = 0;
            for (int i = 0; i < 8; i++) len = (len << 8) | b[2 + i];
            pos = 10;
        }
        if (rbuf_.size() < pos + len) return false;
        std::string payload = rbuf_.substr(pos, static_cast<size_t>(len));
        rbuf_.erase(0, pos + static_cast<size_t>(len));
        if (op == 0x8) {
            closed_ = true;
        } else if (op == 0x9) {
            send_frame(0xA, payload);
        } else if (op != 0xA) {
            if (op != 0x0) {
                partial_.clear();
                partial_text_ = op == 0x1;
            }
            partial_ += payload;
            if (fin) inbox.push_back({partial_text_, std::move(partial_)});
            partial_.clear();
        }
        return true;
    }
};

struct Peer {
    Ident id;
    std::string nonce;      // the challenge this socket logged in with
    std::string relay_key;  // the relay's door key, from that challenge
    bool ok = false;
    Socket ws;

    void send(const json& j) { ws.send_frame(0x1, j.dump()); }
    void send_bin(const std::string& b) { ws.send_frame(0x2, b); }
};

using Pred = std::function<bool(const Frame&)>;

static std::optional<json> as_json(const Frame& f) {
    if (!f.text) return std::nullopt;
    json j = json::parse(f.data, nullptr, false);
    if (j.is_discarded()) return std::nullopt;
    return j;
}

// The first frame matching `pred` within `timeout_ms`; the others stay in the inbox.
static std::optional<Frame> next(Peer& p, const Pred& pred, int timeout_ms = WAIT_MS) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    for (;;) {
        for (auto it = p.ws.inbox.begin(); it != p.ws.inbox.end(); ++it) {
            if (pred(*it)) {
                Frame f = std::move(*it);
                p.ws.inbox.erase(it);
                return f;
            }
        }
        if (left_ms(deadline) <= 0 || !p.ws.pump(left_ms(deadline))) {
            for (auto it = p.ws.inbox.begin(); it != p.ws.inbox.end(); ++it) {
                if (pred(*it)) {
                    Frame f = std::move(*it);
                    p.ws.inbox.erase(it);
                    return f;
                }
            }
            return std::nullopt;
        }
    }
}

static Pred json_where(const std::function<bool(const json&)>& pred) {
    return [pred](const Frame& f) {
        auto j = as_json(f);
        return j && pred(*j);
    };
}

static Pred typed(const std::string& type, const std::string& room = "") {
    return json_where([type, room](const json& j) {
        return j.value("type", "") == type && (room.empty() || j.value("room", "") == room);
    });
}

static Pred about(const std::string& type, const std::string& room, const std::string& peer) {
    return json_where([type, room, peer](const json& j) {
        return j.value("type", "") == type && j.value("room", "") == room && j.value("peer_id", "") == peer;
    });
}

static Pred bin(const std::string& expected) {
    return [expected](const Frame& f) { return !f.text && f.data == expected; };
}

static std::optional<json> next_json(Peer& p, const Pred& pred, int timeout_ms = WAIT_MS) {
    auto f = next(p, pred, timeout_ms);
    if (!f) return std::nullopt;
    return as_json(*f);
}

// A round trip on this socket: everything the relay sent it before is in the inbox.
static bool sync(Peer& p) {
    const std::string room = "sync." + std::to_string(++g_sync);
    p.send({{"type", "discover_peers"}, {"room", room}});
    return next(p, typed("discovered_peers", room)).has_value();
}

// The barrier for a negative: senders first, then receivers, in that order.
static void settle(std::initializer_list<Peer*> peers) {
    for (auto* p : peers) {
        if (!sync(*p)) check("barrier round trip", false);
    }
}

// Whether a frame matching `pred` arrived (after a barrier), taking it.
static bool got(Peer& p, const Pred& pred) {
    for (auto it = p.ws.inbox.begin(); it != p.ws.inbox.end(); ++it) {
        if (pred(*it)) {
            p.ws.inbox.erase(it);
            return true;
        }
    }
    return false;
}

static size_t count(Peer& p, const Pred& pred) {
    size_t n = 0;
    for (auto it = p.ws.inbox.begin(); it != p.ws.inbox.end();) {
        if (pred(*it)) {
            n++;
            it = p.ws.inbox.erase(it);
        } else {
            ++it;
        }
    }
    return n;
}

static std::unique_ptr<Peer> open_socket(const Ident& id) {
    auto p = std::make_unique<Peer>();
    p->id = id;
    if (!p->ws.open()) {
        printf("  FAIL cannot reach the relay on 127.0.0.1:%d\n", g_port);
        exit(1);
    }
    return p;
}

// A socket logged in with auth v2 as `id`, mode full, fetch or guest.
static std::unique_ptr<Peer> login(const Ident& id, const std::string& mode = "full") {
    auto p = open_socket(id);
    p->send({{"type", "auth_hello"}});
    auto ch = next_json(*p, typed("auth_challenge"));
    if (!ch) {
        check("the relay answers auth_hello with a challenge", false);
        return p;
    }
    p->nonce = ch->value("nonce", "");
    p->relay_key = ch->value("door_key", "");
    const uint64_t ts = now_unix_secs();
    json a = {{"type", "auth"}, {"v", 2}, {"peer_id", id.peer}, {"public_key", id.pub_b64}, {"timestamp", ts},
              {"nonce", p->nonce}, {"domain", g_domain},
              {"signature", id.sign(auth_v2_message(g_domain, p->nonce, id.peer, ts, mode, ""))}};
    if (mode == "guest") a["guest"] = true;
    if (mode == "fetch") a["fetch"] = true;
    p->send(a);
    auto r = next_json(*p, json_where([](const json& j) {
        return j.value("type", "") == "auth_ok" || j.value("type", "") == "auth_failed";
    }));
    p->ok = r && r->value("type", "") == "auth_ok";
    if (!p->ok) check("a v2 " + mode + " login is accepted", false);
    return p;
}

static std::string frame(uint8_t op, std::initializer_list<std::string> fields, const std::string& payload) {
    std::string f(1, static_cast<char>(op));
    for (const auto& x : fields) {
        f += x;
        f.push_back('\0');
    }
    return f + payload;
}

static std::string channel_frame(const std::string& room, const std::string& target, const std::string& channel,
                                 const std::string& payload) {
    return frame(0x09, {room, target, channel}, std::string(1, '\0') + payload);
}

static std::set<std::string> peers_of(const json& j) {
    std::set<std::string> out;
    for (const auto& p : j.value("peers", json::array())) {
        if (p.is_string()) out.insert(p.get<std::string>());
    }
    return out;
}

static std::optional<json> join(Peer& p, const std::string& room, const json& extra = json::object()) {
    json j = {{"type", "join"}, {"room", room}};
    for (auto it = extra.begin(); it != extra.end(); ++it) j[it.key()] = it.value();
    p.send(j);
    return next_json(p, typed("members", room));
}

static std::set<std::string> discover(Peer& p, const std::string& room) {
    p.send({{"type", "discover_peers"}, {"room", room}});
    auto r = next_json(p, typed("discovered_peers", room));
    return r ? peers_of(*r) : std::set<std::string>{"<no answer>"};
}

static std::set<std::string> online(Peer& p, const std::vector<std::string>& ids) {
    p.send({{"type", "check_peers"}, {"peers", ids}});
    auto r = next_json(p, typed("peer_status"));
    std::set<std::string> out;
    if (!r) return {"<no answer>"};
    for (const auto& x : r->value("online", json::array())) out.insert(x.get<std::string>());
    return out;
}

static std::string door_proof(const Peer& p, const std::string& room, const Door& door) {
    unsigned char relay_pk[32];
    size_t len = 0;
    if (sodium_base642bin(relay_pk, sizeof(relay_pk), p.relay_key.c_str(), p.relay_key.size(), nullptr, &len, nullptr,
                          sodium_base64_VARIANT_URLSAFE_NO_PADDING) != 0 || len != 32) {
        return "";
    }
    return door_proof_make(door.sk, relay_pk,
                           door_room::proof_message(auth_domain(g_domain), p.nonce, p.id.peer, room, door.text, p.relay_key));
}

// A one-link chain signed by its owner: a legacy (32-hex) server's carries no nonce.
static json base_link(const std::string& server, const Door& door, const Ident& change, const Ident& owner,
                      const std::string& nonce, bool genesis) {
    LockLink l;
    l.n = 1;
    l.door = door.text;
    l.change = change.pub_b64;
    l.owner = owner.pub_b64;
    l.has_owner = true;
    l.nonce = nonce;
    l.has_nonce = genesis;
    l.sig = owner.sign(join_lock::payload(server, l));
    return join_lock::links_to_json({l});
}

static json ring_control(const std::string& room, const std::string& owner, const std::vector<std::string>& channels,
                         const Ident& signer) {
    ring_auth::Control c;
    c.room = room;
    c.owner = owner;
    c.ts_ms = wall_ms();
    c.retention_secs = 3600;
    c.channels = channels;
    return {{"type", "set_topic_buffer"}, {"room", room},           {"owner", owner}, {"channels", channels},
            {"retention_secs", 3600},     {"clear", false},         {"ts", c.ts_ms},  {"sig", signer.sign(ring_auth::payload(c))}};
}

static json unsigned_ring_control(const std::string& room, const std::vector<std::string>& channels) {
    return {{"type", "set_topic_buffer"}, {"room", room}, {"channels", channels}, {"retention_secs", 3600}};
}

static json catchup(const std::string& room, const std::string& channel) {
    return {{"type", "topic_catchup"}, {"room", room}, {"channel", channel}};
}

static json signed_nickname(const std::string& nick, const Ident& device, const Ident& master) {
    const int64_t ts = wall_ms();
    return {{"type", "claim_nickname"}, {"nickname", nick},          {"master", master.peer},
            {"master_key", master.pub_b64}, {"ts", ts},
            {"sig", master.sign(nickname_claim_message(nick, device.peer, master.peer, ts))}};
}

// A legacy-base roster for `master` in which every device is a member.
static json legacy_roster(const Ident& master, const std::vector<const Ident*>& devices) {
    roster::Roster r = roster::Roster::named(master.peer);
    for (const auto* d : devices) {
        r.legacy.push_back({d->peer, master.sign(roster::legacy_payload(master.peer, d->peer))});
        r.consents.push_back({d->peer, d->sign(roster::consent_payload(master.peer, d->peer))});
    }
    return json::parse(roster::to_json(r).dump());
}

static json device_list_proof(const Ident& master, const std::vector<std::string>& devices) {
    return {{"master_pubkey_b64", master.pub_b64}, {"master_peer_id", master.peer}, {"devices", devices},
            {"revoked", json::array()},            {"version", 1},
            {"sig_b64", master.sign(device_list_signing_payload(master.peer, 1, devices, {}))}};
}

static std::string room_name(const std::string& kind) { return kind + "-" + g_tag; }

// ---------------------------------------------------------------------------

static void test_auth() {
    printf("auth (ACCEPT_AUTH_V1 %s)\n", g_legacy ? "on" : "off");
    Ident id;
    auto v1 = open_socket(id);
    const uint64_t ts = now_unix_secs();
    v1->send({{"type", "auth"}, {"peer_id", id.peer}, {"public_key", id.pub_b64}, {"timestamp", ts},
              {"signature", id.sign("hollow-ws-auth:" + id.peer + ":" + std::to_string(ts))}});
    auto r = next_json(*v1, json_where([](const json& j) {
        return j.value("type", "") == "auth_ok" || j.value("type", "") == "auth_failed";
    }));
    const bool accepted = r && r->value("type", "") == "auth_ok";
    if (g_legacy) {
        check("a v1 login (0.11 clients) is accepted while the switch is on", accepted);
        check("and the socket works", accepted && sync(*v1));
    } else {
        check("a v1 login is refused once the switch is off", r && !accepted);
        check("and the socket is closed", !next(*v1, typed("auth_ok"), 1000) && v1->ws.closed());
    }

    auto v2 = login(Ident());
    check("a v2 login is accepted in either build", v2->ok);

    Ident other;
    auto bad = open_socket(other);
    bad->send({{"type", "auth_hello"}});
    auto ch = next_json(*bad, typed("auth_challenge"));
    const std::string nonce = ch ? ch->value("nonce", "") : "";
    const uint64_t ts2 = now_unix_secs();
    bad->send({{"type", "auth"}, {"v", 2}, {"peer_id", other.peer}, {"public_key", other.pub_b64}, {"timestamp", ts2},
               {"nonce", nonce}, {"domain", "another.relay"},
               {"signature", other.sign(auth_v2_message("another.relay", nonce, other.peer, ts2, "full", ""))}});
    check("a v2 frame signed for another relay is refused", next(*bad, typed("auth_failed")).has_value());

    Ident unasked;
    auto cold = open_socket(unasked);
    const std::string made_up(64, 'a');
    cold->send({{"type", "auth"}, {"v", 2}, {"peer_id", unasked.peer}, {"public_key", unasked.pub_b64},
                {"timestamp", ts2}, {"nonce", made_up}, {"domain", g_domain},
                {"signature", unasked.sign(auth_v2_message(g_domain, made_up, unasked.peer, ts2, "full", ""))}});
    check("a v2 frame for a challenge never asked is refused", next(*cold, typed("auth_failed")).has_value());
}

static void test_nicknames() {
    printf("nicknames (ACCEPT_UNSIGNED_NICKNAME_CLAIMS %s)\n", g_legacy ? "on" : "off");
    auto a = login(Ident());
    const std::string plain = "n" + g_tag + "a";
    a->send({{"type", "claim_nickname"}, {"nickname", plain}});
    auto r = next_json(*a, json_where([](const json& j) {
        return j.value("type", "") == "nickname_claimed" || j.value("type", "") == "nickname_error";
    }));
    if (g_legacy) {
        check("an unsigned claim is taken while the switch is on", r && r->value("type", "") == "nickname_claimed");
    } else {
        check("an unsigned claim is refused once the switch is off",
              r && r->value("type", "") == "nickname_error" && r->value("error", "") == "invalid_claim");
    }

    Ident master;
    auto b = login(Ident());
    const std::string nick = "n" + g_tag + "b";
    b->send(signed_nickname(nick, b->id, master));
    check("a claim the named master signed is taken in either build", next(*b, typed("nickname_claimed")).has_value());
    a->send({{"type", "resolve_nickname"}, {"nickname", nick}});
    auto res = next_json(*a, typed("nickname_resolved"));
    check("and resolves with the master's signature", res && res->value("master_id", "") == master.peer &&
                                                           !res->value("sig", "").empty());

    Ident stranger;
    auto c = login(Ident());
    c->send(signed_nickname("n" + g_tag + "c", b->id, stranger));
    auto bad = next_json(*c, typed("nickname_error"));
    check("a claim signed for another device is refused", bad && bad->value("error", "") == "invalid_claim");
}

static void test_rings() {
    printf("rings (ACCEPT_UNSIGNED_RING_CONTROL %s)\n", g_legacy ? "on" : "off");
    const std::string room = room_name("ring");
    auto a = login(Ident());
    auto b = login(Ident());
    join(*a, room);
    join(*b, room);
    a->send(unsigned_ring_control(room, {"c1"}));
    a->send_bin(frame(0x07, {room, "c1"}, "ring-unsigned"));
    check("a topic frame reaches the room live", next(*b, bin(frame(0x08, {room, "c1", a->id.peer}, "ring-unsigned"))).has_value());
    auto late = login(Ident());
    join(*late, room);
    late->send(catchup(room, "c1"));
    settle({late.get()});
    const bool kept = got(*late, bin(frame(0x08, {room, "c1", a->id.peer}, "ring-unsigned")));
    if (g_legacy) {
        check("an unsigned control opens a ring while the switch is on", kept);
    } else {
        check("an unsigned control opens no ring once the switch is off", !kept);
    }

    // A legacy (32-hex) server: its ring topics carry the owner the control is signed for.
    Ident owner, change;
    Door door;
    const std::string server = random_hex(16);
    a->send({{"type", "lock_put"}, {"server", server}, {"owner", owner.peer},
             {"links", base_link(server, door, change, owner, "", false)}});
    auto put = next_json(*a, typed("lock_chain"));
    check("the relay takes a legacy server's lock", put && put->value("put", false));
    join(*a, server);
    join(*late, server);
    const std::string topic = owner.peer + ".c2";
    a->send(ring_control(server, owner.peer, {topic}, change));
    a->send_bin(frame(0x07, {server, topic}, "ring-signed"));
    const std::string forged = owner.peer + ".c3";
    a->send(ring_control(server, owner.peer, {forged}, owner));
    a->send_bin(frame(0x07, {server, forged}, "ring-forged"));
    settle({a.get(), late.get()});
    late->ws.inbox.clear();  // the live copies
    late->send(catchup(server, topic));
    late->send(catchup(server, forged));
    settle({late.get()});
    check("a control the change key signed opens a ring in either build",
          got(*late, bin(frame(0x08, {server, topic, a->id.peer}, "ring-signed"))));
    check("a control signed by another key opens none",
          !got(*late, bin(frame(0x08, {server, forged, a->id.peer}, "ring-forged"))));
}

// Every frame up to and including the first that matches `pred`, in arrival order.
static std::vector<Frame> through(Peer& p, const Pred& pred, int timeout_ms = WAIT_MS) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    for (;;) {
        for (size_t i = 0; i < p.ws.inbox.size(); i++) {
            if (pred(p.ws.inbox[i])) {
                std::vector<Frame> out(p.ws.inbox.begin(), p.ws.inbox.begin() + static_cast<long>(i) + 1);
                p.ws.inbox.erase(p.ws.inbox.begin(), p.ws.inbox.begin() + static_cast<long>(i) + 1);
                return out;
            }
        }
        if (left_ms(deadline) <= 0 || !p.ws.pump(left_ms(deadline))) return {};
    }
}

static void test_catchup_end_mark() {
    printf("catch-up end mark (HOL-SEC-121)\n");
    // A legacy (32-hex) server: its ring opens in either build.
    Ident owner, change;
    Door door;
    const std::string server = random_hex(16);
    auto a = login(Ident());
    a->send({{"type", "lock_put"}, {"server", server}, {"owner", owner.peer},
             {"links", base_link(server, door, change, owner, "", false)}});
    auto put = next_json(*a, typed("lock_chain"));
    check("the relay takes the server's lock", put && put->value("put", false));
    join(*a, server);
    const std::string topic = owner.peer + ".~join";
    a->send(ring_control(server, owner.peer, {topic}, change));
    a->send_bin(frame(0x07, {server, topic}, "mark-one"));
    a->send_bin(frame(0x07, {server, topic}, "mark-two"));
    auto late = login(Ident());
    join(*late, server);
    settle({a.get(), late.get()});
    late->ws.inbox.clear();

    const auto with_end = [](json j) {
        j["end"] = true;
        return j;
    };
    const auto marked = [&](const std::string& channel) {
        return json_where([server, channel](const json& j) {
            return j.value("type", "") == "topic_catchup_done" && j.value("room", "") == server &&
                   j.value("channel", "") == channel;
        });
    };
    late->send(with_end(catchup(server, topic)));
    const auto upto = through(*late, marked(topic));
    const auto has = [&](const std::string& payload) {
        const std::string want = frame(0x08, {server, topic, a->id.peer}, payload);
        for (size_t i = 0; i + 1 < upto.size(); i++) {
            if (!upto[i].text && upto[i].data == want) return true;
        }
        return false;
    };
    check("a catch-up that asks for its end gets the mark", !upto.empty());
    check("behind every frame of the replay", has("mark-one") && has("mark-two"));

    late->send(catchup(server, topic));
    settle({late.get()});
    check("a catch-up that does not ask gets the replay and no mark",
          got(*late, bin(frame(0x08, {server, topic, a->id.peer}, "mark-two"))) && !got(*late, typed("topic_catchup_done")));

    const std::string empty = owner.peer + ".none";
    late->send(with_end(catchup(server, empty)));
    check("a ring the relay never kept is marked too", next(*late, marked(empty)).has_value());

    json odd = catchup(server, topic);
    odd["end"] = "yes";
    late->send(odd);
    settle({late.get()});
    check("an end that is not true asks for nothing", !got(*late, typed("topic_catchup_done")));

    auto outsider = login(Ident());
    outsider->send(with_end(catchup(server, topic)));
    settle({outsider.get()});
    check("a socket outside the room is told nothing",
          !got(*outsider, typed("topic_catchup_done")) && !got(*outsider, bin(frame(0x08, {server, topic, a->id.peer}, "mark-one"))));
}

static void test_inbox_proof() {
    printf("inbox proof (ACCEPT_DEVICE_LIST_INBOX_PROOF %s)\n", g_legacy ? "on" : "off");
    Ident master, d1, d2;
    const std::string room = "inbox:" + master.peer;
    auto s = login(Ident());
    s->send_bin(frame(0x04, {room, master.peer}, "mail-d"));
    settle({s.get()});
    const std::string mail = frame(0x06, {room, s->id.peer}, "mail-d");

    auto a = login(d1);
    join(*a, room, {{"inbox_proof", device_list_proof(master, {d1.peer})}});
    settle({a.get()});
    const bool read = got(*a, bin(mail));
    if (g_legacy) {
        check("a master-signed device list opens the mailbox while the switch is on", read);
    } else {
        check("a master-signed device list opens nothing once the switch is off", !read);
    }

    auto other = login(Ident());
    join(*other, room, {{"inbox_proof", device_list_proof(master, {d1.peer})}});
    settle({other.get()});
    check("a list that does not name the socket's device opens nothing", !got(*other, bin(mail)));

    auto b = login(d2);
    auto m = join(*b, room, {{"inbox_roster", legacy_roster(master, {&d1, &d2})}});
    check("a roster opens the mailbox in either build", next(*b, bin(mail)).has_value());
    const bool sees = m && peers_of(*m).count(d1.peer) != 0;
    check(g_legacy ? "and the list-proved device is a co-owner" : "and the list-shown device is no owner",
          g_legacy ? sees : !sees);
}

static void test_inbox_audience() {
    printf("inbox rooms: a non-owner is nobody's co-member\n");
    Ident master, d1, d2;
    const std::string room = "inbox:" + master.peer;
    const json roster = legacy_roster(master, {&d1, &d2});
    auto s = login(Ident());
    s->send_bin(frame(0x04, {room, master.peer}, "mail-e"));
    settle({s.get()});
    const std::string mail = frame(0x06, {room, s->id.peer}, "mail-e");

    auto o1 = login(d1);
    auto m1 = join(*o1, room, {{"inbox_roster", roster}});
    check("an owner sees itself", m1 && peers_of(*m1) == std::set<std::string>{d1.peer});
    check("and reads the mailbox", next(*o1, bin(mail)).has_value());

    auto x = login(Ident());
    auto mx = join(*x, room, {{"inbox_roster", roster}});
    check("a roster that does not count the socket's device owns nothing",
          mx && peers_of(*mx) == std::set<std::string>{x->id.peer});
    auto n = login(Ident());
    auto mn = join(*n, room);
    check("a non-owner sees only itself", mn && peers_of(*mn) == std::set<std::string>{n->id.peer});
    auto o2 = login(d2);
    auto m2 = join(*o2, room, {{"inbox_roster", roster}});
    check("a second owner sees the first and not the non-owner",
          m2 && peers_of(*m2) == std::set<std::string>{d1.peer, d2.peer});
    check("the first owner is told of the second", next(*o1, about("peer_joined", room, d2.peer)).has_value());
    settle({o2.get(), o1.get(), n.get(), x.get()});
    check("the non-owner reads no mailbox", !got(*n, bin(mail)) && !got(*x, bin(mail)));
    check("the non-owner is announced to nobody", !got(*o1, about("peer_joined", room, n->id.peer)));
    check("and is told of no owner", !got(*n, about("peer_joined", room, d2.peer)));

    o1->send_bin(frame(0x03, {room}, "owner-bcast"));
    o1->send({{"type", "msg"}, {"room", room}, {"data", "owner-msg"}});
    o1->send_bin(frame(0x07, {room, "t"}, "owner-topic"));
    o1->send_bin(frame(0x04, {room, n->id.peer}, "to-nonowner"));
    o1->send_bin(frame(0x02, {room, n->id.peer}, "raw-to-nonowner"));
    o1->send({{"type", "direct"}, {"room", room}, {"target", n->id.peer}, {"data", "json-to-nonowner"}});
    o1->send_bin(frame(0x04, {room, d2.peer}, "to-owner"));
    o1->send_bin(frame(0x02, {room, d2.peer}, "raw-to-owner"));
    o1->send({{"type", "direct"}, {"room", room}, {"target", d2.peer}, {"data", "json-to-owner"}});
    check("an owner's broadcast reaches an owner", next(*o2, bin(frame(0x05, {room, d1.peer}, "owner-bcast"))).has_value());
    check("its message too", next(*o2, json_where([](const json& j) { return j.value("data", "") == "owner-msg"; })).has_value());
    check("its topic frame too", next(*o2, bin(frame(0x08, {room, "t", d1.peer}, "owner-topic"))).has_value());
    check("its directs too", next(*o2, bin(frame(0x06, {room, d1.peer}, "to-owner"))).has_value() &&
                                 next(*o2, bin(frame(0x02, {room, d1.peer}, "raw-to-owner"))).has_value() &&
                                 next(*o2, json_where([](const json& j) { return j.value("data", "") == "json-to-owner"; })).has_value());
    settle({o1.get(), n.get()});
    check("the non-owner hears no broadcast", !got(*n, bin(frame(0x05, {room, d1.peer}, "owner-bcast"))));
    check("no message", !got(*n, json_where([](const json& j) { return j.value("data", "") == "owner-msg"; })));
    check("no topic frame", !got(*n, bin(frame(0x08, {room, "t", d1.peer}, "owner-topic"))));
    check("no direct (0x04)", !got(*n, bin(frame(0x06, {room, d1.peer}, "to-nonowner"))));
    check("no direct (0x02)", !got(*n, bin(frame(0x02, {room, d1.peer}, "raw-to-nonowner"))));
    check("no direct (JSON)", !got(*n, json_where([](const json& j) { return j.value("data", "") == "json-to-nonowner"; })));

    join(*s, room);
    s->send_bin(frame(0x04, {room, master.peer}, "mail-live"));
    const std::string live = frame(0x06, {room, s->id.peer}, "mail-live");
    check("a deposit for the master reaches the owners live",
          next(*o1, bin(live)).has_value() && next(*o2, bin(live)).has_value());
    settle({s.get(), n.get()});
    check("and not the non-owner", !got(*n, bin(live)));

    check("discovery names nobody to the non-owner", discover(*n, room).empty());
    check("and only the other owner to an owner", discover(*o1, room) == std::set<std::string>{d2.peer});
    check("check_peers tells the non-owner of no owner", online(*n, {d1.peer, d2.peer}).empty());
    check("nor an owner of the non-owner", online(*o1, {n->id.peer, d2.peer}) == std::set<std::string>{d2.peer});
}

// A forwarder's room `fwd:{X}` serves viewers from every server: X sees and reaches all
// of them, each of them only X (HOL-SEC-126).
static void test_forwarder_rooms() {
    printf("forwarder rooms: a member meets only the forwarder\n");
    auto x = login(Ident());
    const std::string room = "fwd:" + x->id.peer;
    const std::string fwd = x->id.peer;
    auto mx = join(*x, room);
    check("the forwarder sees itself", mx && peers_of(*mx) == std::set<std::string>{fwd});
    auto a = login(Ident());
    auto ma = join(*a, room);
    check("a viewer sees the forwarder", ma && peers_of(*ma) == std::set<std::string>{fwd, a->id.peer});
    check("the forwarder is told of it", next(*x, about("peer_joined", room, a->id.peer)).has_value());
    auto s = login(Ident());
    auto ms = join(*s, room);
    check("a stranger sees the forwarder and not the viewer",
          ms && peers_of(*ms) == std::set<std::string>{fwd, s->id.peer});
    check("the forwarder is told of the stranger", next(*x, about("peer_joined", room, s->id.peer)).has_value());
    settle({s.get(), a.get()});
    check("the viewer is not", !got(*a, about("peer_joined", room, s->id.peer)));
    check("discovery names only the forwarder to a member", discover(*s, room) == std::set<std::string>{fwd});
    check("and every member to the forwarder", discover(*x, room) == std::set<std::string>{a->id.peer, s->id.peer});
    check("check_peers tells a member of no other member", online(*s, {a->id.peer, fwd}) == std::set<std::string>{fwd});
    check("and the forwarder of every member",
          online(*x, {a->id.peer, s->id.peer}) == std::set<std::string>{a->id.peer, s->id.peer});

    s->send_bin(frame(0x03, {room}, "s-bcast"));
    s->send({{"type", "msg"}, {"room", room}, {"data", "s-msg"}});
    s->send_bin(frame(0x07, {room, "t"}, "s-topic"));
    s->send_bin(frame(0x0A, {room}, "s-public"));
    check("a member's broadcast reaches the forwarder", next(*x, bin(frame(0x05, {room, s->id.peer}, "s-bcast"))).has_value());
    check("its message too", next(*x, json_where([](const json& j) { return j.value("data", "") == "s-msg"; })).has_value());
    check("its topic frame too", next(*x, bin(frame(0x08, {room, "t", s->id.peer}, "s-topic"))).has_value());
    check("its public frame too", next(*x, bin(frame(0x05, {room, s->id.peer}, "s-public"))).has_value());
    settle({s.get(), a.get()});
    check("no other member hears its broadcast", !got(*a, bin(frame(0x05, {room, s->id.peer}, "s-bcast"))));
    check("message", !got(*a, json_where([](const json& j) { return j.value("data", "") == "s-msg"; })));
    check("topic frame", !got(*a, bin(frame(0x08, {room, "t", s->id.peer}, "s-topic"))));
    check("or public frame", !got(*a, bin(frame(0x05, {room, s->id.peer}, "s-public"))));
    x->send_bin(frame(0x03, {room}, "x-bcast"));
    check("the forwarder's broadcast reaches every member",
          next(*a, bin(frame(0x05, {room, fwd}, "x-bcast"))).has_value() &&
              next(*s, bin(frame(0x05, {room, fwd}, "x-bcast"))).has_value());

    s->send_bin(frame(0x04, {room, a->id.peer}, "s-direct"));
    s->send_bin(frame(0x08, {room, a->id.peer}, "s-image"));
    s->send_bin(frame(0x02, {room, a->id.peer}, "s-raw"));
    s->send({{"type", "direct"}, {"room", room}, {"target", a->id.peer}, {"data", "s-json"}});
    s->send_bin(frame(0x04, {room, fwd}, "s-to-x"));
    x->send_bin(frame(0x04, {room, s->id.peer}, "x-to-s"));
    check("a member's direct reaches the forwarder", next(*x, bin(frame(0x06, {room, s->id.peer}, "s-to-x"))).has_value());
    check("the forwarder's reaches a member", next(*s, bin(frame(0x06, {room, fwd}, "x-to-s"))).has_value());
    settle({s.get(), a.get()});
    check("a member's direct reaches no other member (0x04)", !got(*a, bin(frame(0x06, {room, s->id.peer}, "s-direct"))));
    check("(0x08)", !got(*a, bin(frame(0x06, {room, s->id.peer}, "s-image"))));
    check("(0x02)", !got(*a, bin(frame(0x02, {room, s->id.peer}, "s-raw"))));
    check("(JSON)", !got(*a, json_where([](const json& j) { return j.value("data", "") == "s-json"; })));

    // Deposits for a member not in the room, and for one in a room nobody is in yet.
    Ident later, y;
    const std::string empty = "fwd:" + y.peer;
    s->send_bin(frame(0x04, {room, later.peer}, "s-deposit"));
    s->send({{"type", "direct"}, {"room", room}, {"target", later.peer}, {"data", "s-json-deposit"}});
    s->send_bin(channel_frame(room, later.peer, "c", "s-chan"));
    s->send_bin(frame(0x04, {empty, later.peer}, "s-empty-deposit"));
    s->send_bin(frame(0x04, {empty, y.peer}, "s-to-absent-forwarder"));
    x->send_bin(frame(0x04, {room, later.peer}, "x-deposit"));
    settle({s.get(), x.get()});
    auto l = login(later);
    join(*l, room);
    check("the forwarder's deposit waits for an absent member", next(*l, bin(frame(0x06, {room, fwd}, "x-deposit"))).has_value());
    join(*l, empty);
    auto yy = login(y);
    join(*yy, empty);
    check("a deposit for an absent forwarder waits for it",
          next(*yy, bin(frame(0x06, {empty, s->id.peer}, "s-to-absent-forwarder"))).has_value());
    settle({l.get()});
    check("another member's waits for nobody (0x04)", !got(*l, bin(frame(0x06, {room, s->id.peer}, "s-deposit"))));
    check("(JSON)", !got(*l, bin(frame(0x06, {room, s->id.peer}, "s-json-deposit"))));
    check("(0x09)", !got(*l, bin(frame(0x06, {room, s->id.peer}, "s-chan"))));
    check("(a room nobody was in)", !got(*l, bin(frame(0x06, {empty, s->id.peer}, "s-empty-deposit"))));

    s->send(unsigned_ring_control(room, {"fc"}));
    s->send_bin(frame(0x07, {room, "fc"}, "s-ring"));
    settle({s.get(), l.get()});
    l->ws.inbox.clear();  // a live copy is the fan-out's to refuse, not the ring's
    l->send(catchup(room, "fc"));
    settle({l.get()});
    check("a forwarder's room keeps no ring", !got(*l, bin(frame(0x08, {room, "fc", s->id.peer}, "s-ring"))));

    a->send({{"type", "leave"}, {"room", room}});
    check("a member's leave is told to the forwarder", next(*x, about("peer_left", room, a->id.peer)).has_value());
    settle({a.get(), s.get()});
    check("and to no other member", !got(*s, about("peer_left", room, a->id.peer)));
    x->send({{"type", "leave"}, {"room", room}});
    check("the forwarder's leave is told to every member", next(*s, about("peer_left", room, fwd)).has_value() &&
                                                                next(*l, about("peer_left", room, fwd)).has_value());
}

// In a locked server room a channel copy (0x09) and its wake come only from a socket
// that sees the room (HOL-SEC-127).
static void test_hidden_channel_copies() {
    printf("door rooms (D1): a hidden socket leaves no channel copy\n");
    Ident owner, change, target;
    Door door;
    const std::string nonce = random_hex(16);
    const std::string room = genesis_server_id(owner.peer, nonce);
    auto p = login(Ident());
    p->send({{"type", "lock_put"}, {"server", room}, {"owner", ""},
             {"links", base_link(room, door, change, owner, nonce, true)}});
    auto put = next_json(*p, typed("lock_chain"));
    check("the relay takes the server's first lock", put && put->value("put", false));
    auto mp = join(*p, room, {{"door_proof", door_proof(*p, room, door)}});
    check("a member proves the door", mp && mp->value("proved", false));
    auto h = login(Ident());
    auto mh = join(*h, room);
    check("a socket without a proof is hidden", mh && !mh->value("proved", true));
    h->send_bin(channel_frame(room, target.peer, "hc", "hidden-chan"));
    p->send_bin(channel_frame(room, target.peer, "hc", "prover-chan"));
    settle({h.get(), p.get()});
    auto t = login(target);
    join(*t, room);
    check("a prover's channel copy waits for its target",
          next(*t, bin(frame(0x06, {room, p->id.peer}, "prover-chan"))).has_value());
    settle({t.get()});
    check("a hidden socket's is never kept", !got(*t, bin(frame(0x06, {room, h->id.peer}, "hidden-chan"))));
}

static void test_guests() {
    printf("guests\n");
    const std::string room = room_name("guest");
    auto m = login(Ident());
    auto n = login(Ident());
    join(*m, room);
    join(*n, room);
    auto g = login(Ident(), "guest");
    auto mg = join(*g, room);
    check("a guest is shown the members", mg && peers_of(*mg) == std::set<std::string>{m->id.peer, n->id.peer});
    auto late = login(Ident());
    auto ml = join(*late, room);
    check("and is in no later member list", ml && peers_of(*ml).count(g->id.peer) == 0);
    check("nor in discovery", discover(*m, room).count(g->id.peer) == 0);
    settle({late.get(), m.get()});
    check("nor announced", !got(*m, about("peer_joined", room, g->id.peer)));

    Ident t_g, t_n;
    g->send_bin(frame(0x04, {room, m->id.peer}, "g-direct"));
    g->send_bin(frame(0x08, {room, m->id.peer}, "g-image"));
    g->send_bin(frame(0x07, {room, "t"}, "g-topic"));
    g->send_bin(channel_frame(room, t_g.peer, "c", "g-chan"));
    g->send({{"type", "direct"}, {"room", room}, {"target", m->id.peer}, {"data", "g-json"}});
    n->send_bin(frame(0x04, {room, m->id.peer}, "n-direct"));
    n->send_bin(frame(0x07, {room, "t"}, "n-topic"));
    n->send_bin(channel_frame(room, t_n.peer, "c", "n-chan"));
    n->send({{"type", "direct"}, {"room", room}, {"target", m->id.peer}, {"data", "n-json"}});
    check("a member's direct, topic frame and JSON direct arrive",
          next(*m, bin(frame(0x06, {room, n->id.peer}, "n-direct"))).has_value() &&
              next(*m, bin(frame(0x08, {room, "t", n->id.peer}, "n-topic"))).has_value() &&
              next(*m, json_where([](const json& j) { return j.value("data", "") == "n-json"; })).has_value());
    settle({g.get(), n.get(), m.get()});
    check("a guest's direct (0x04) is dropped", !got(*m, bin(frame(0x06, {room, g->id.peer}, "g-direct"))));
    check("its image direct (0x08) too", !got(*m, bin(frame(0x06, {room, g->id.peer}, "g-image"))));
    check("its topic frame (0x07) too", !got(*m, bin(frame(0x08, {room, "t", g->id.peer}, "g-topic"))));
    check("its JSON direct too", !got(*m, json_where([](const json& j) { return j.value("data", "") == "g-json"; })));
    auto tg = login(t_g);
    auto tn = login(t_n);
    join(*tg, room);
    join(*tn, room);
    check("a member's channel copy (0x09) waits for its target",
          next(*tn, bin(frame(0x06, {room, n->id.peer}, "n-chan"))).has_value());
    settle({tg.get()});
    check("a guest's is never kept", !got(*tg, bin(frame(0x06, {room, g->id.peer}, "g-chan"))));

    for (int i = 0; i < 12; i++) g->send_bin(frame(0x03, {room}, "g-bcast"));
    settle({g.get(), m.get()});
    check("a guest's broadcasts stop at ten a minute", count(*m, bin(frame(0x05, {room, g->id.peer}, "g-bcast"))) == 10);

    check("check_peers answers a guest nothing", online(*g, {m->id.peer}).empty());
    check("and a member about a co-member", online(*n, {m->id.peer}) == std::set<std::string>{m->id.peer});

    auto ask = [](Peer& p, const json& j, const std::string& reply) {
        p.send(j);
        return next_json(p, typed(reply));
    };
    auto turn_g = ask(*g, {{"type", "get_turn_credentials"}}, "turn_credentials");
    auto turn_n = ask(*n, {{"type", "get_turn_credentials"}}, "turn_credentials");
    check("no TURN credentials for a guest", turn_g && turn_g->value("error", "") == "auth required");
    check("a member gets them", turn_n && !turn_n->value("username", "").empty());
    auto fwd_g = ask(*g, {{"type", "get_media_forwarder"}}, "media_forwarder");
    check("no forwarder for a guest", fwd_g && fwd_g->value("error", "") == "auth required");
    auto fwd_n = ask(*n, {{"type", "get_media_forwarder"}}, "media_forwarder");
    check("a member is told none is configured", fwd_n && fwd_n->value("error", "") == "not configured");

    Ident kill_target, owner, change, master;
    Door door;
    const std::string server = random_hex(16);
    const json report = {{"type", "report"}, {"target", m->id.peer}, {"category", "spam"}};
    const json deposit = {{"type", "kill_deposit"}, {"blob", "AAAA"}, {"issued_at_ms", 1},
                          {"targets", json::array({kill_target.peer})}};
    const json lock_get = {{"type", "lock_get"},
                           {"locks", json::array({json{{"server", server}, {"owner", owner.peer}}})}};
    const json lock_put = {{"type", "lock_put"}, {"server", server}, {"owner", owner.peer}, {"links", json::array()}};
    const std::string code = "G" + g_tag.substr(0, 5);
    const std::string code2 = "N" + g_tag.substr(0, 5);
    std::string upper_code, upper_code2;
    for (char c : code) upper_code += static_cast<char>(toupper(static_cast<unsigned char>(c)));
    for (char c : code2) upper_code2 += static_cast<char>(toupper(static_cast<unsigned char>(c)));
    g->send(report);
    g->send(deposit);
    g->send(lock_get);
    g->send(lock_put);
    g->send(signed_nickname("g" + g_tag, g->id, master));
    g->send({{"type", "claim_link_code"}, {"code", upper_code}});
    n->send({{"type", "claim_link_code"}, {"code", upper_code2}});
    g->send({{"type", "resolve_link_code"}, {"code", upper_code2}});
    settle({n.get(), g.get()});
    check("a guest files no report", !got(*g, typed("report_ack")));
    check("parks no destroy signal", !got(*g, typed("kill_deposited")));
    check("reads no join lock", !got(*g, typed("lock_chain")));
    check("claims no nickname", !got(*g, typed("nickname_claimed")) && !got(*g, typed("nickname_error")));
    check("claims no link code", !got(*g, typed("link_code_claimed")));
    check("and resolves none", !got(*g, typed("link_code_resolved")) && !got(*g, typed("link_code_error")));
    check("a member files a report", ask(*n, report, "report_ack").has_value());
    check("parks a destroy signal", ask(*n, deposit, "kill_deposited").has_value());
    check("reads a join lock", ask(*n, lock_get, "lock_chain").has_value());
    check("and offers one", ask(*n, lock_put, "lock_chain").has_value());
    check("claims a nickname", ask(*n, signed_nickname("m" + g_tag, n->id, master), "nickname_claimed").has_value());
    check("claims a link code", next(*n, typed("link_code_claimed")).has_value());
    check("and resolves one", ask(*m, {{"type", "resolve_link_code"}, {"code", upper_code2}}, "link_code_resolved").has_value());

    // Rings in a legacy server room, where nothing hides its members.
    n->send({{"type", "lock_put"}, {"server", server}, {"owner", owner.peer},
             {"links", base_link(server, door, change, owner, "", false)}});
    auto put = next_json(*n, typed("lock_chain"));
    check("the relay takes a legacy server's lock", put && put->value("put", false));
    join(*n, server);
    join(*m, server);
    join(*g, server);
    const std::string kept = owner.peer + ".c4", refused = owner.peer + ".c5";
    n->send(ring_control(server, owner.peer, {kept}, change));
    g->send(ring_control(server, owner.peer, {refused}, change));
    settle({n.get(), g.get()});
    n->send_bin(frame(0x07, {server, kept}, "ring-kept"));
    n->send_bin(frame(0x07, {server, refused}, "ring-refused"));
    settle({n.get(), m.get(), g.get()});
    m->ws.inbox.clear();  // the live copies
    g->ws.inbox.clear();
    m->send(catchup(server, kept));
    m->send(catchup(server, refused));
    g->send(catchup(server, kept));
    settle({m.get(), g.get()});
    check("a member's ring catch-up replays", got(*m, bin(frame(0x08, {server, kept, n->id.peer}, "ring-kept"))));
    check("a guest's ring control opens no ring", !got(*m, bin(frame(0x08, {server, refused, n->id.peer}, "ring-refused"))));
    check("a guest's catch-up replays nothing", !got(*g, bin(frame(0x08, {server, kept, n->id.peer}, "ring-kept"))));

    join(*g, room_name("guest-x"));
    g->send({{"type", "join"}, {"room", room_name("guest-y")}});
    auto err = next_json(*g, typed("error"));
    check("a guest holds three rooms at most", err && err->value("error", "") == "Guest room limit reached");

    // A guest of an identity's own device still owns nothing of it.
    Ident mg_master, dg, df;
    const std::string inbox = "inbox:" + mg_master.peer;
    n->send_bin(frame(0x04, {inbox, mg_master.peer}, "mail-g"));
    settle({n.get()});
    const json roster = legacy_roster(mg_master, {&dg, &df});
    auto g2 = login(dg, "guest");
    join(*g2, inbox, {{"inbox_roster", roster}});
    auto full = login(df);
    join(*full, inbox, {{"inbox_roster", roster}});
    check("a device's full socket reads its mailbox", next(*full, bin(frame(0x06, {inbox, n->id.peer}, "mail-g"))).has_value());
    settle({g2.get()});
    check("its guest socket does not", !got(*g2, bin(frame(0x06, {inbox, n->id.peer}, "mail-g"))));

    // And proves no door.
    Ident lock_owner, lock_change;
    Door lock_door;
    const std::string nonce = random_hex(16);
    const std::string locked = genesis_server_id(lock_owner.peer, nonce);
    n->send({{"type", "lock_put"}, {"server", locked}, {"owner", ""},
             {"links", base_link(locked, lock_door, lock_change, lock_owner, nonce, true)}});
    auto lput = next_json(*n, typed("lock_chain"));
    check("the relay takes a server's lock", lput && lput->value("put", false));
    auto mp = join(*n, locked, {{"door_proof", door_proof(*n, locked, lock_door)}});
    check("a member proves the door", mp && mp->value("proved", false));
    auto gm = join(*g2, locked, {{"door_proof", door_proof(*g2, locked, lock_door)}});
    check("a guest's door proof proves nothing", gm && gm->contains("proved") && !gm->value("proved", true));
    n->send_bin(frame(0x03, {locked}, "locked-bcast"));
    settle({n.get(), g2.get()});
    check("and it hears no member's broadcast", !got(*g2, bin(frame(0x05, {locked, n->id.peer}, "locked-bcast"))));

    check("a guest's socket closes cleanly", g->ws.close_clean());
    settle({m.get()});
    check("and no member is told it left", !got(*m, about("peer_left", room, g->id.peer)));
}

static void test_fetch() {
    printf("fetch sockets\n");
    const std::string room = room_name("fetch");
    Ident d;
    auto m = login(Ident());
    auto f = login(d);
    join(*m, room);
    join(*f, room);
    auto x = login(d, "fetch");
    m->send_bin(frame(0x03, {room}, "after-fetch-auth"));
    check("a fetch login leaves the device's full socket in place",
          next(*f, bin(frame(0x05, {room, m->id.peer}, "after-fetch-auth"))).has_value() && !f->ws.closed());
    x->send({{"type", "join"}, {"room", room}});
    m->send_bin(frame(0x04, {room, d.peer}, "to-d"));
    check("a direct for the device reaches the full socket", next(*f, bin(frame(0x06, {room, m->id.peer}, "to-d"))).has_value());
    settle({m.get(), x.get()});
    check("never its fetch socket", !got(*x, bin(frame(0x06, {room, m->id.peer}, "to-d"))));
    check("which is told no roster", !got(*x, typed("members", room)));
    x->send({{"type", "leave"}, {"room", room}});
    settle({x.get()});
    m->send_bin(frame(0x03, {room}, "after-fetch-leave"));
    check("a fetch socket's leave keeps the full socket in the room",
          next(*f, bin(frame(0x05, {room, m->id.peer}, "after-fetch-leave"))).has_value());
    x->send({{"type", "join"}, {"room", room}});
    settle({x.get()});
    check("its close too", x->ws.close_clean());
    m->send_bin(frame(0x03, {room}, "after-fetch-close"));
    check("and the full socket still hears the room",
          next(*f, bin(frame(0x05, {room, m->id.peer}, "after-fetch-close"))).has_value());
    settle({m.get()});
    check("nobody was told the device left", !got(*m, about("peer_left", room, d.peer)));
    check("discovery still names the device", discover(*m, room) == std::set<std::string>{d.peer});

    const std::string room2 = room_name("fetch2");
    Ident e;
    join(*m, room2);
    auto y = login(e, "fetch");
    y->send({{"type", "join"}, {"room", room2}});
    settle({y.get(), m.get()});
    check("a fetch socket with no full socket is told no roster", !got(*y, typed("members", room2)));
    check("and is announced to nobody", !got(*m, about("peer_joined", room2, e.peer)));
    check("nor discovered", discover(*m, room2).empty());
    auto n = login(Ident());
    auto mn = join(*n, room2);
    check("nor listed to a later member", mn && peers_of(*mn) == std::set<std::string>{m->id.peer, n->id.peer});
    check("nor online to check_peers", online(*m, {e.peer, n->id.peer}) == std::set<std::string>{n->id.peer});
    m->send_bin(frame(0x04, {room2, e.peer}, "to-e"));
    check("it takes the device's directs while no full socket holds the slot",
          next(*y, bin(frame(0x06, {room2, m->id.peer}, "to-e"))).has_value());
    check("its close", y->ws.close_clean());
    settle({m.get()});
    check("tells nobody", !got(*m, about("peer_left", room2, e.peer)));

    // A fetch login for a device whose full socket is in a room must not wipe its rooms.
    const std::string room3 = room_name("fetch3");
    Ident d2;
    auto f2 = login(d2);
    join(*m, room3);
    join(*f2, room3);
    auto z = login(d2, "fetch");
    settle({z.get()});
    check("the full socket closes", f2->ws.close_clean());
    check("and the room is told it left", next(*m, about("peer_left", room3, d2.peer)).has_value());
    m->send_bin(frame(0x03, {room3}, "after-full-close"));
    check("its slot is gone", discover(*m, room3).empty());

    // A fetch socket that held a slot until the full socket took it closes without it.
    const std::string room4 = room_name("fetch4");
    Ident d3;
    join(*m, room4);
    auto v = login(d3, "fetch");
    v->send({{"type", "join"}, {"room", room4}});
    settle({v.get()});
    auto f3 = login(d3);
    join(*f3, room4);
    check("the full socket takes the slot", next(*m, about("peer_joined", room4, d3.peer)).has_value());
    check("the fetch socket closes", v->ws.close_clean());
    m->send_bin(frame(0x03, {room4}, "after-slot-taken"));
    check("and the full socket keeps the room",
          next(*f3, bin(frame(0x05, {room4, m->id.peer}, "after-slot-taken"))).has_value());
    settle({m.get()});
    check("nobody is told the device left", !got(*m, about("peer_left", room4, d3.peer)));

    // A fetch socket is a push isolate: it issues nothing.
    Ident owner, change, master, target;
    Door door;
    const std::string server = random_hex(16);
    auto w = login(Ident(), "fetch");
    w->send({{"type", "lock_put"}, {"server", server}, {"owner", owner.peer},
             {"links", base_link(server, door, change, owner, "", false)}});
    w->send({{"type", "kill_deposit"}, {"blob", "AAAA"}, {"issued_at_ms", 1}, {"targets", json::array({target.peer})}});
    w->send(signed_nickname("w" + g_tag, w->id, master));
    settle({w.get()});
    check("a fetch socket files no join lock", !got(*w, typed("lock_chain")));
    check("parks no destroy signal", !got(*w, typed("kill_deposited")));
    check("claims no nickname", !got(*w, typed("nickname_claimed")));
    m->send({{"type", "lock_put"}, {"server", server}, {"owner", owner.peer},
             {"links", base_link(server, door, change, owner, "", false)}});
    auto put = next_json(*m, typed("lock_chain"));
    check("a member files it", put && put->value("put", false));
    join(*m, server);
    w->send({{"type", "join"}, {"room", server}});
    const std::string topic = owner.peer + ".c6";
    w->send(ring_control(server, owner.peer, {topic}, change));
    settle({w.get()});
    m->send_bin(frame(0x07, {server, topic}, "fetch-ring"));
    settle({m.get()});
    auto late = login(Ident());
    join(*late, server);
    late->send(catchup(server, topic));
    settle({late.get()});
    check("and a fetch socket's ring control opens no ring", !got(*late, bin(frame(0x08, {server, topic, m->id.peer}, "fetch-ring"))));
}

static void test_door_rooms() {
    printf("door rooms (D1): only provers see a locked server's room\n");
    Ident owner, change;
    Door door, wrong;
    const std::string nonce = random_hex(16);
    const std::string room = genesis_server_id(owner.peer, nonce);
    auto p = login(Ident());
    p->send({{"type", "lock_put"}, {"server", room}, {"owner", ""},
             {"links", base_link(room, door, change, owner, nonce, true)}});
    auto put = next_json(*p, typed("lock_chain"));
    check("the relay takes the server's first lock", put && put->value("put", false));

    auto mp = join(*p, room, {{"door_proof", door_proof(*p, room, door)}});
    check("a prover is told so", mp && mp->value("proved", false) && peers_of(*mp) == std::set<std::string>{p->id.peer});
    auto q = login(Ident());
    auto mq = join(*q, room);
    check("a socket without a proof sees itself alone",
          mq && !mq->value("proved", true) && peers_of(*mq) == std::set<std::string>{q->id.peer});
    auto w = login(Ident());
    auto mw = join(*w, room, {{"door_proof", door_proof(*w, room, wrong)}});
    check("a proof for another door proves nothing", mw && !mw->value("proved", true));
    auto p2 = login(Ident());
    auto mp2 = join(*p2, room, {{"door_proof", door_proof(*p2, room, door)}});
    check("a second prover sees the first and nobody hidden",
          mp2 && mp2->value("proved", false) && peers_of(*mp2) == std::set<std::string>{p->id.peer, p2->id.peer});
    check("the first is told of the second", next(*p, about("peer_joined", room, p2->id.peer)).has_value());
    settle({p2.get(), p.get(), q.get(), w.get()});
    check("the hidden are announced to nobody",
          !got(*p, about("peer_joined", room, q->id.peer)) && !got(*p, about("peer_joined", room, w->id.peer)));
    check("and told of no prover", !got(*q, about("peer_joined", room, p2->id.peer)) &&
                                       !got(*w, about("peer_joined", room, p2->id.peer)));

    p->send(ring_control(room, "", {"dc"}, change));
    p->send_bin(frame(0x03, {room}, "door-bcast"));
    p->send({{"type", "msg"}, {"room", room}, {"data", "door-msg"}});
    p->send_bin(frame(0x07, {room, "dc"}, "door-topic"));
    p->send_bin(frame(0x0A, {room}, "door-public"));
    p->send_bin(frame(0x04, {room, q->id.peer}, "door-direct"));
    p->send_bin(channel_frame(room, q->id.peer, "dc", "door-chan"));
    check("a prover's broadcast reaches a prover", next(*p2, bin(frame(0x05, {room, p->id.peer}, "door-bcast"))).has_value());
    check("its message too", next(*p2, json_where([](const json& j) { return j.value("data", "") == "door-msg"; })).has_value());
    check("its topic frame too", next(*p2, bin(frame(0x08, {room, "dc", p->id.peer}, "door-topic"))).has_value());
    check("a public frame reaches the hidden", next(*q, bin(frame(0x05, {room, p->id.peer}, "door-public"))).has_value());
    check("a direct reaches the hidden", next(*q, bin(frame(0x06, {room, p->id.peer}, "door-direct"))).has_value());
    settle({p.get(), q.get(), w.get()});
    check("the hidden hear no broadcast", !got(*q, bin(frame(0x05, {room, p->id.peer}, "door-bcast"))) &&
                                              !got(*w, bin(frame(0x05, {room, p->id.peer}, "door-bcast"))));
    check("no message", !got(*q, json_where([](const json& j) { return j.value("data", "") == "door-msg"; })));
    check("no topic frame", !got(*q, bin(frame(0x08, {room, "dc", p->id.peer}, "door-topic"))));
    check("discovery names nobody to the hidden", discover(*q, room).empty());
    check("and only the other prover to a prover", discover(*p, room) == std::set<std::string>{p2->id.peer});
    check("check_peers tells the hidden of no prover", online(*q, {p->id.peer, p2->id.peer}).empty());
    check("nor a prover of the hidden", online(*p, {q->id.peer, p2->id.peer}) == std::set<std::string>{p2->id.peer});
    p2->send(catchup(room, "dc"));
    q->send(catchup(room, "dc"));
    settle({p2.get(), q.get()});
    check("a prover's catch-up replays the ring", got(*p2, bin(frame(0x08, {room, "dc", p->id.peer}, "door-topic"))));
    check("the hidden's replays nothing", !got(*q, bin(frame(0x08, {room, "dc", p->id.peer}, "door-topic"))));
    q->send_bin(frame(0x0A, {room}, "hidden-public"));
    check("a hidden socket's public frame reaches the provers",
          next(*p, bin(frame(0x05, {room, q->id.peer}, "hidden-public"))).has_value());
    settle({q.get(), w.get()});
    check("and no other hidden socket", !got(*w, bin(frame(0x05, {room, q->id.peer}, "hidden-public"))));

    auto again = join(*q, room, {{"door_proof", door_proof(*q, room, door)}});
    check("a hidden socket that proves sees the provers",
          again && again->value("proved", false) &&
              peers_of(*again) == std::set<std::string>{p->id.peer, p2->id.peer, q->id.peer});
    check("is announced to them", next(*p, about("peer_joined", room, q->id.peer)).has_value());
    check("and gets the channel copy it missed while hidden",
          next(*q, bin(frame(0x06, {room, p->id.peer}, "door-chan"))).has_value());
    w->send({{"type", "leave"}, {"room", room}});
    p2->send({{"type", "leave"}, {"room", room}});
    check("a prover's leave is told to the provers", next(*p, about("peer_left", room, p2->id.peer)).has_value() &&
                                                         next(*q, about("peer_left", room, p2->id.peer)).has_value());
    settle({w.get(), p.get()});
    check("a hidden socket's leave to nobody", !got(*p, about("peer_left", room, w->id.peer)));
}

static std::string nested(size_t depth) { return std::string(depth, '[') + std::string(depth, ']'); }

// Runs last: before the depth cap each of these frames overflowed the relay's stack
// (C-RP-01), a crash that skips the snapshot.
static void test_deep_json() {
    printf("deep JSON: one frame nested past any real one is refused, the relay stays up\n");
    constexpr size_t HOSTILE = 200000;
    Ident master;
    auto a = login(Ident());
    a->ws.send_frame(0x1, R"({"type":"join","room":"inbox:)" + master.peer + R"(","inbox_roster":{"x":)" +
                              nested(HOSTILE) + "}}");
    check("a roster nested 200,000 deep leaves the sender's socket served", sync(*a));
    auto b = login(Ident());
    b->send({{"type", "get_turn_credentials"}});
    check("and the relay serves a fresh login", next(*b, typed("turn_credentials")).has_value());

    a->ws.send_frame(0x1, R"({"type":"subscribe","room":"deep-)" + g_tag + R"(","topics":)" + nested(HOSTILE) + "}");
    check("subscription topics nested 200,000 deep leave the socket served", sync(*a));
    auto c = login(Ident());
    check("and the relay serves a fresh login", c->ok && sync(*c));

    const std::string room = room_name("deep");
    a->ws.send_frame(0x1, R"({"type":"join","room":")" + room + R"(","pad":)" + nested(16) + "}");
    check("a frame nested deeper than any real one, yet within the cap, still works",
          next(*a, typed("members", room)).has_value());

    Ident d;
    const std::string inbox = "inbox:" + master.peer;
    b->send_bin(frame(0x04, {inbox, master.peer}, "mail-pad"));
    settle({b.get()});
    json padded = legacy_roster(master, {&d});
    padded["pad"] = std::string(300 * 1024, 'x');
    auto o = login(d);
    join(*o, inbox, {{"inbox_roster", padded}});
    check("a roster is measured as the relay holds it: a field it drops does not count",
          next(*o, bin(frame(0x06, {inbox, b->id.peer}, "mail-pad"))).has_value());
}

int main(int argc, char** argv) {
    if (argc != 4 || (std::string(argv[3]) != "on" && std::string(argv[3]) != "off")) {
        fprintf(stderr, "usage: test_relay_live <port> <auth domain> <on|off>\n");
        return 2;
    }
    if (sodium_init() < 0) return 2;
    g_port = atoi(argv[1]);
    g_domain = argv[2];
    g_legacy = std::string(argv[3]) == "on";
    g_tag = random_hex(4);
    g_ctx = SSL_CTX_new(TLS_client_method());
    SSL_CTX_set_verify(g_ctx, SSL_VERIFY_NONE, nullptr);

    test_auth();
    test_nicknames();
    test_rings();
    test_catchup_end_mark();
    test_inbox_proof();
    test_inbox_audience();
    test_forwarder_rooms();
    test_hidden_channel_copies();
    test_guests();
    test_fetch();
    test_door_rooms();
    test_deep_json();

    SSL_CTX_free(g_ctx);
    if (failures) {
        printf("%d FAILED\n", failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
