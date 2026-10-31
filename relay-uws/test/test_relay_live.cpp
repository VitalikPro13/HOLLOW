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
#include "door_room.h"
#include "presence_view.h"
#include "join_lock.h"
#include "json.hpp"
#include "ring_auth.h"
#include "roster.h"
#include "session.h"
#include "validate.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <openssl/err.h>
#include <openssl/ssl.h>
#include <poll.h>
#include <signal.h>
#include <sodium.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <vector>

using json = nlohmann::json;

static int failures = 0;
static int g_port = 0;
static std::string g_domain;
// The build under test accepts `hollow-ring1` ring control (ACCEPT_RING1_CONTROL).
static bool g_ring1 = true;
static SSL_CTX* g_ctx = nullptr;
static int g_next_source = 0;
// Non-negative: every new socket comes from this one source address (Socket::open).
static int g_pin_source = -1;
// Positive: every new socket asks the kernel for this receive buffer (Socket::open).
static int g_rcvbuf = 0;
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

// What one frame from the relay adds to a session client's count (section 9.3).
static uint64_t counts_as(const Frame& f) {
    if (!f.text) return 1;
    json j = json::parse(f.data, nullptr, false);
    if (j.is_discarded() || !j.is_object()) return 1;
    auto t = j.find("type");
    if (t == j.end() || !t->is_string()) return 1;
    const std::string type = t->get<std::string>();
    if (type == "gap") return j.value("n", static_cast<uint64_t>(0));
    return session::relay_type_counts(type) ? 1 : 0;
}

// One TLS WebSocket to the relay, each from its own loopback address: the relay admits
// ten new connections a minute per address.
class Socket {
  public:
    std::deque<Frame> inbox;
    // Stream frames read off the wire so far, as a session client counts them.
    uint64_t counted = 0;
    // The relay's close frame, once one arrived.
    int close_code = 0;
    std::string close_reason;

    ~Socket() { drop(); }

    // One plain HTTPS GET on its own connection: the body, or nothing.
    std::optional<std::string> get(const std::string& path) {
        if (!connect_tls()) return std::nullopt;
        write_all("GET " + path + " HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
        auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(WAIT_MS);
        for (;;) {
            size_t end = rbuf_.find("\r\n\r\n");
            if (end != std::string::npos) {
                size_t at = rbuf_.find("Content-Length: ");
                if (at != std::string::npos && at < end) {
                    size_t want = std::stoul(rbuf_.substr(at + 16));
                    if (rbuf_.size() >= end + 4 + want) return rbuf_.substr(end + 4, want);
                }
            }
            if (left_ms(deadline) <= 0 || !fill(left_ms(deadline))) return std::nullopt;
        }
    }

    bool connect_tls() {
        fd_ = socket(AF_INET, SOCK_STREAM, 0);
        if (fd_ < 0) return false;
        const int n = g_pin_source >= 0 ? g_pin_source : g_next_source++;
        sockaddr_in src{};
        src.sin_family = AF_INET;
        src.sin_addr.s_addr = htonl(0x7f000000u | static_cast<uint32_t>(1 + n / 250) << 8 | static_cast<uint32_t>(2 + n % 250));
        sockaddr_in dst{};
        dst.sin_family = AF_INET;
        dst.sin_port = htons(static_cast<uint16_t>(g_port));
        dst.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(fd_, reinterpret_cast<sockaddr*>(&src), sizeof(src)) != 0) return false;
        if (g_rcvbuf > 0) setsockopt(fd_, SOL_SOCKET, SO_RCVBUF, &g_rcvbuf, sizeof(g_rcvbuf));
        if (connect(fd_, reinterpret_cast<sockaddr*>(&dst), sizeof(dst)) != 0) return false;
        int one = 1;
        setsockopt(fd_, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        ssl_ = SSL_new(g_ctx);
        SSL_set_fd(ssl_, fd_);
        ERR_clear_error();
        if (SSL_connect(ssl_) != 1) return false;
        fcntl(fd_, F_SETFL, fcntl(fd_, F_GETFL) | O_NONBLOCK);
        return true;
    }

    bool open() {
        if (!connect_tls()) return false;

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
        write_all(encode(opcode, payload));
    }

    // Many frames in one write, the way a client in a hurry sends them.
    void send_frames(const std::vector<std::pair<uint8_t, std::string>>& frames) {
        if (!ssl_ || closed_) return;
        std::string all;
        for (const auto& [op, payload] : frames) all += encode(op, payload);
        write_all(all);
    }

    // The header and the first `sent` bytes of a binary frame of `declared` payload bytes,
    // the rest never sent: the relay holds the frame open.
    void send_partial(uint64_t declared, size_t sent) {
        if (!ssl_ || closed_) return;
        std::string f(1, static_cast<char>(0x82));
        f.push_back(static_cast<char>(0x80 | 127));
        for (int i = 7; i >= 0; i--) f.push_back(static_cast<char>((declared >> (8 * i)) & 0xff));
        f.append(4, '\0');  // a zero mask
        f.append(sent, 'p');
        write_all(f);
    }

    // Writes `data` from `off` one TLS record at a time until it is all written or the
    // kernel takes nothing for `stall_ms`: the offset reached. A later call from there
    // finishes it.
    size_t write_until_stalled(const std::string& data, size_t off, int stall_ms) {
        if (!ssl_ || closed_) return off;
        SSL_set_mode(ssl_, SSL_MODE_ENABLE_PARTIAL_WRITE);
        while (off < data.size()) {
            ERR_clear_error();
            int n = SSL_write(ssl_, data.data() + off, static_cast<int>(data.size() - off));
            if (n > 0) {
                off += static_cast<size_t>(n);
                continue;
            }
            int err = SSL_get_error(ssl_, n);
            if (err != SSL_ERROR_WANT_WRITE && err != SSL_ERROR_WANT_READ) {
                closed_ = true;
                break;
            }
            pollfd p{fd_, static_cast<short>(err == SSL_ERROR_WANT_READ ? POLLIN : POLLOUT), 0};
            if (poll(&p, 1, stall_ms) <= 0) break;
        }
        return off;
    }

    int local_port() const {
        sockaddr_in a{};
        socklen_t n = sizeof(a);
        return fd_ >= 0 && getsockname(fd_, reinterpret_cast<sockaddr*>(&a), &n) == 0 ? ntohs(a.sin_port) : -1;
    }

    static std::string encode(uint8_t opcode, const std::string& payload) {
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
        return f;
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

    // The connection dies the way a phone's does: no close frame, whatever the relay
    // wrote and the client never read lost with it.
    void abort() { drop(); }

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
        // A frame of megabytes gets a second more per megabyte on a loaded machine.
        auto deadline = std::chrono::steady_clock::now() +
                        std::chrono::milliseconds(WAIT_MS + static_cast<int64_t>(data.size() / 1024));
        while (off < data.size()) {
            ERR_clear_error();
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
            // The error queue is per thread: one socket's stale error turns another's
            // WANT_READ into SSL_ERROR_SSL.
            ERR_clear_error();
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
            if (payload.size() >= 2) {
                close_code = (static_cast<unsigned char>(payload[0]) << 8) | static_cast<unsigned char>(payload[1]);
                close_reason = payload.substr(2);
            }
        } else if (op == 0x9) {
            send_frame(0xA, payload);
        } else if (op != 0xA) {
            if (op != 0x0) {
                partial_.clear();
                partial_text_ = op == 0x1;
            }
            partial_ += payload;
            if (fin) {
                inbox.push_back({partial_text_, std::move(partial_)});
                counted += counts_as(inbox.back());
            }
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
    // Auth v3: the challenge, the relay's answer and the session this socket carries.
    json challenge;
    json answer;
    std::string sid;

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

// How far the test client's clock is off; login() and login3() sign with it.
static int64_t g_clock_skew_secs = 0;

static uint64_t client_now_secs() { return static_cast<uint64_t>(static_cast<int64_t>(now_unix_secs()) + g_clock_skew_secs); }

// A socket logged in with auth v2 as `id`, mode full, fetch or guest.
static std::unique_ptr<Peer> login(const Ident& id, const std::string& mode = "full") {
    auto p = open_socket(id);
    p->send({{"type", "auth_hello"}});
    auto ch = next_json(*p, typed("auth_challenge"));
    if (!ch) {
        check("the relay answers auth_hello with a challenge", false);
        return p;
    }
    p->challenge = *ch;
    p->nonce = ch->value("nonce", "");
    p->relay_key = ch->value("door_key", "");
    const uint64_t ts = client_now_secs();
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
    p->answer = r ? *r : json::object();
    if (!p->ok) check("a v2 " + mode + " login is accepted", false);
    return p;
}

// A socket logged in with auth v3 asking for `session` ("new", "none" or a sid) with
// the client's count `in_h`, which its own count continues from. `signed_session`
// replaces what the signature covers, to forge one.
static std::unique_ptr<Peer> login3(const Ident& id, const std::string& session, uint64_t in_h,
                                    const std::string& mode = "full", const std::string& signed_session = "") {
    auto p = open_socket(id);
    p->send({{"type", "auth_hello"}});
    auto ch = next_json(*p, typed("auth_challenge"));
    if (!ch) {
        check("the relay answers auth_hello with a challenge", false);
        return p;
    }
    p->challenge = *ch;
    p->nonce = ch->value("nonce", "");
    p->relay_key = ch->value("door_key", "");
    const uint64_t ts = client_now_secs();
    const std::string covered = signed_session.empty() ? session : signed_session;
    json a = {{"type", "auth"}, {"v", 3}, {"peer_id", id.peer}, {"public_key", id.pub_b64}, {"timestamp", ts},
              {"nonce", p->nonce}, {"domain", g_domain}, {"session", session}, {"in_h", in_h},
              {"signature", id.sign(auth_v3_message(g_domain, p->nonce, id.peer, ts, mode, "", covered, in_h))}};
    if (mode == "guest") a["guest"] = true;
    if (mode == "fetch") a["fetch"] = true;
    p->ws.counted = in_h;
    p->send(a);
    auto r = next_json(*p, json_where([](const json& j) {
        const std::string t = j.value("type", "");
        return t == "auth_ok" || t == "auth_failed" || t == "resumed";
    }));
    p->answer = r ? *r : json::object();
    const std::string t = p->answer.value("type", "");
    p->ok = t == "auth_ok" || t == "resumed";
    p->sid = t == "resumed" ? session : p->answer.value("sid", "");
    return p;
}

static bool is_sid(const std::string& s) { return session::is_sid_shape(s); }

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

// A door proof bound to the challenge `nonce`.
static std::string door_proof_for(const Peer& p, const std::string& nonce, const std::string& room, const Door& door) {
    unsigned char relay_pk[32];
    size_t len = 0;
    if (sodium_base642bin(relay_pk, sizeof(relay_pk), p.relay_key.c_str(), p.relay_key.size(), nullptr, &len, nullptr,
                          sodium_base64_VARIANT_URLSAFE_NO_PADDING) != 0 || len != 32) {
        return "";
    }
    return door_proof_make(door.sk, relay_pk,
                           door_room::proof_message(auth_domain(g_domain), nonce, p.id.peer, room, door.text, p.relay_key));
}

// A random 32 bytes as unpadded URL-safe base64: the shape of a door proof that opens nothing.
static std::string random_b64url32() {
    unsigned char b[32];
    randombytes_buf(b, sizeof(b));
    char out[64];
    sodium_bin2base64(out, sizeof(out), b, sizeof(b), sodium_base64_VARIANT_URLSAFE_NO_PADDING);
    return out;
}

static std::string door_proof(const Peer& p, const std::string& room, const Door& door) {
    return door_proof_for(p, p.nonce, room, door);
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

// A ring control signed as ring2 for `domain` (this relay's when empty), or as ring1.
static json ring_control(const std::string& room, const std::string& owner, const std::vector<std::string>& channels,
                         const Ident& signer, int version = 2, const std::string& domain = "") {
    ring_auth::Control c;
    c.room = room;
    c.owner = owner;
    c.ts_ms = wall_ms();
    c.retention_secs = 3600;
    c.channels = channels;
    const std::string payload = version == 2 ? ring_auth::payload_ring2(c, domain.empty() ? auth_domain(g_domain) : domain)
                                             : ring_auth::payload_ring1(c);
    json j = {{"type", "set_topic_buffer"}, {"room", room},           {"owner", owner}, {"channels", channels},
              {"retention_secs", 3600},     {"clear", false},         {"ts", c.ts_ms},  {"sig", signer.sign(payload)}};
    if (version == 2) j["v"] = 2;
    return j;
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

// The 0.11 master-signed device list a join once proved an inbox with (version 1,
// nothing revoked; `devices` sorted).
static json device_list_proof(const Ident& master, const std::vector<std::string>& devices) {
    std::string listed;
    for (const auto& d : devices) listed += (listed.empty() ? "" : ",") + d;
    const std::string payload = "hollow-devices:" + master.peer + ":1:" + listed + ":";
    return {{"master_pubkey_b64", master.pub_b64}, {"master_peer_id", master.peer}, {"devices", devices},
            {"revoked", json::array()},            {"version", 1},
            {"sig_b64", master.sign(payload)}};
}

static std::string room_name(const std::string& kind) { return kind + "-" + g_tag; }

// ---------------------------------------------------------------------------

static void test_auth() {
    printf("auth\n");
    Ident id;
    auto v1 = open_socket(id);
    const uint64_t ts = now_unix_secs();
    v1->send({{"type", "auth"}, {"peer_id", id.peer}, {"public_key", id.pub_b64}, {"timestamp", ts},
              {"signature", id.sign("hollow-ws-auth:" + id.peer + ":" + std::to_string(ts))}});
    auto r = next_json(*v1, json_where([](const json& j) {
        return j.value("type", "") == "auth_ok" || j.value("type", "") == "auth_failed";
    }));
    const bool accepted = r && r->value("type", "") == "auth_ok";
    check("a v1 login (0.11 clients) is refused", r && !accepted);
    check("and the socket is closed", !next(*v1, typed("auth_ok"), 1000) && v1->ws.closed());

    auto v2 = login(Ident());
    check("a v2 login is accepted", v2->ok);

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
    printf("nicknames\n");
    auto a = login(Ident());
    const std::string plain = "n" + g_tag + "a";
    a->send({{"type", "claim_nickname"}, {"nickname", plain}});
    auto r = next_json(*a, json_where([](const json& j) {
        return j.value("type", "") == "nickname_claimed" || j.value("type", "") == "nickname_error";
    }));
    check("an unsigned claim (0.11 clients) is refused",
          r && r->value("type", "") == "nickname_error" && r->value("error", "") == "invalid_claim");
    a->send({{"type", "resolve_nickname"}, {"nickname", plain}});
    auto unbound = next_json(*a, json_where([](const json& j) {
        return j.value("type", "") == "nickname_resolved" || j.value("type", "") == "nickname_error";
    }));
    check("and binds nothing", unbound && unbound->value("type", "") == "nickname_error");

    Ident master;
    auto b = login(Ident());
    const std::string nick = "n" + g_tag + "b";
    b->send(signed_nickname(nick, b->id, master));
    check("a claim the named master signed is taken", next(*b, typed("nickname_claimed")).has_value());
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
    printf("rings (ACCEPT_RING1_CONTROL %s)\n", g_ring1 ? "on" : "off");
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
    check("an unsigned control (0.11 clients) opens no ring", !kept);

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
    const std::string ring1 = owner.peer + ".c4";
    a->send(ring_control(server, owner.peer, {ring1}, change, 1));
    a->send_bin(frame(0x07, {server, ring1}, "ring-one"));
    const std::string elsewhere = owner.peer + ".c5";
    a->send(ring_control(server, owner.peer, {elsewhere}, change, 2, "another.relay"));
    a->send_bin(frame(0x07, {server, elsewhere}, "ring-elsewhere"));
    settle({a.get(), late.get()});
    late->ws.inbox.clear();  // the live copies
    late->send(catchup(server, topic));
    late->send(catchup(server, forged));
    late->send(catchup(server, ring1));
    late->send(catchup(server, elsewhere));
    settle({late.get()});
    check("a ring2 control the change key signed opens a ring",
          got(*late, bin(frame(0x08, {server, topic, a->id.peer}, "ring-signed"))));
    check("a control signed by another key opens none",
          !got(*late, bin(frame(0x08, {server, forged, a->id.peer}, "ring-forged"))));
    check("a ring2 control signed for another relay opens none",
          !got(*late, bin(frame(0x08, {server, elsewhere, a->id.peer}, "ring-elsewhere"))));
    const bool one = got(*late, bin(frame(0x08, {server, ring1, a->id.peer}, "ring-one")));
    if (g_ring1) {
        check("a ring1 control opens a ring while ACCEPT_RING1_CONTROL is on", one);
    } else {
        check("a ring1 control opens none once ACCEPT_RING1_CONTROL is off", !one);
    }
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
    printf("inbox proof (0.11 device lists)\n");
    Ident master, d1, d2;
    const std::string room = "inbox:" + master.peer;
    auto s = login(Ident());
    s->send_bin(frame(0x04, {room, master.peer}, "mail-d"));
    settle({s.get()});
    const std::string mail = frame(0x06, {room, s->id.peer}, "mail-d");

    auto a = login(d1);
    join(*a, room, {{"inbox_proof", device_list_proof(master, {d1.peer})}});
    settle({a.get()});
    check("a master-signed device list naming the device opens nothing", !got(*a, bin(mail)));

    auto other = login(Ident());
    join(*other, room, {{"inbox_proof", device_list_proof(master, {d1.peer})}});
    settle({other.get()});
    check("a list that does not name the socket's device opens nothing", !got(*other, bin(mail)));

    auto b = login(d2);
    auto m = join(*b, room, {{"inbox_roster", legacy_roster(master, {&d1, &d2})}});
    check("a roster opens the mailbox", next(*b, bin(mail)).has_value());
    check("and the list-shown device is no owner", m && peers_of(*m).count(d1.peer) == 0);
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
    json block_count = report;
    block_count["category"] = "blocked";
    check("and the count a block sends", ask(*n, block_count, "report_ack").has_value());
    json unknown = report;
    unknown["category"] = "muted";
    n->send(unknown);
    settle({n.get()});
    check("an unknown category files nothing", !got(*n, typed("report_ack")));
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

// A device's fetch socket is a push isolate, never a viewer: it hears no presence (G2 f).
static void test_fetch_hears_no_presence() {
    printf("fetch sockets: no presence\n");
    const std::string room = room_name("fetch-presence");
    Ident d;
    auto f = login(d, "fetch");
    f->send({{"type", "join"}, {"room", room}});
    settle({f.get()});
    auto a = login(Ident());
    join(*a, room);
    settle({f.get(), a.get()});
    check("fetch_socket_hears_no_presence: no peer_joined", !got(*f, about("peer_joined", room, a->id.peer)));
    a->ws.close_clean();
    settle({f.get()});
    check("fetch_socket_hears_no_presence: no peer_left", !got(*f, about("peer_left", room, a->id.peer)));
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

// What the relay's kernel holds unread of the connection from `client_port`
// (/proc/net/tcp), -1 when it cannot say.
static long relay_unread_from(int client_port) {
    FILE* f = fopen("/proc/net/tcp", "r");
    if (!f) return -1;
    char line[512];
    long unread = -1;
    while (fgets(line, sizeof(line), f)) {
        unsigned local_ip = 0, local_port = 0, remote_ip = 0, remote_port = 0, state = 0;
        unsigned long tx = 0, rx = 0;
        if (sscanf(line, " %*u: %x:%x %x:%x %x %lx:%lx", &local_ip, &local_port, &remote_ip, &remote_port, &state, &tx,
                   &rx) == 7 &&
            static_cast<int>(local_port) == g_port && static_cast<int>(remote_port) == client_port) {
            unread = static_cast<long>(rx);
        }
    }
    fclose(f);
    return unread;
}

// Stops the relay process for as long as it lives, waiting until the kernel says so.
struct StoppedRelay {
    pid_t pid;
    explicit StoppedRelay(pid_t p) : pid(p) {
        kill(pid, SIGSTOP);
        const std::string stat = "/proc/" + std::to_string(pid) + "/stat";
        for (int i = 0; i < 200; i++) {
            FILE* f = fopen(stat.c_str(), "r");
            if (!f) break;
            char line[512] = {};
            const bool read = fgets(line, sizeof(line), f) != nullptr;
            fclose(f);
            const char* paren = read ? strrchr(line, ')') : nullptr;
            if (paren && paren[1] == ' ' && paren[2] == 'T') return;
            usleep(5000);
        }
    }
    ~StoppedRelay() { kill(pid, SIGCONT); }
    StoppedRelay(const StoppedRelay&) = delete;
    StoppedRelay& operator=(const StoppedRelay&) = delete;
};

// uSockets reads every TLS socket of a loop through one shared input state
// (src/usockets_ssl.c). The relay is stopped while a sender queues over a MiB, so it reads
// two full chunks back to back: the second decrypts a whole receive buffer with records
// still pending, and what the frames in it make the relay write (a forward, an answer)
// happens in the middle of that read. The sender stays connected and every frame arrives
// once, in order. Each stop lets the relay read a whole window at once, which is what
// grows it, so a round that queued too little is followed by another.
static void test_tls_write_inside_full_read() {
    printf("TLS: a write the relay makes mid-read leaves the sender's pending records whole\n");
    const char* pid_text = getenv("RELAY_LIVE_PID");
    const pid_t relay = pid_text ? static_cast<pid_t>(atoi(pid_text)) : 0;
    if (relay <= 0) {
        check("(the client knows the relay's pid)", false);
        return;
    }
    const std::string room = room_name("tls-read");
    auto b = login(Ident());
    auto c = login(Ident());
    join(*b, room);
    join(*c, room);
    next(*b, about("peer_joined", room, c->id.peer));
    const std::string warm(1 << 20, 'w'), warm_end = warm + "end";
    for (int i = 0; i < 15; i++) b->send_bin(frame(0x04, {room, c->id.peer}, warm));
    b->send_bin(frame(0x04, {room, c->id.peer}, warm_end));
    through(*c, bin(frame(0x06, {room, b->id.peer}, warm_end)));

    // The relay must hold two full receive buffers of b at once: one TLS record past them.
    constexpr long ENOUGH = (1l << 20) + 16406;
    long held = -1;
    for (int round = 0; round < 8 && held < ENOUGH; round++) {
        // Everything b sent is read, so the burst starts on a record boundary.
        sync(*b);
        // 64 KiB frames, so several end inside every chunk the relay reads; every fourth
        // asks for an answer too.
        std::vector<std::string> arrived;
        std::string burst;
        for (int i = 0; i < 48; i++) {
            const std::string payload = std::to_string(round) + "." + std::to_string(i) + std::string(64 << 10, 'A' + i % 26);
            arrived.push_back(frame(0x06, {room, b->id.peer}, payload));
            burst += Socket::encode(0x2, frame(0x04, {room, c->id.peer}, payload));
            if (i % 4 == 3) burst += Socket::encode(0x1, json{{"type", "discover_peers"}, {"room", room}}.dump());
        }
        size_t off = 0;
        {
            StoppedRelay stopped(relay);
            off = b->ws.write_until_stalled(burst, 0, 300);
            held = relay_unread_from(b->ws.local_port());
        }
        off = b->ws.write_until_stalled(burst, off, WAIT_MS);
        const std::string r = "round " + std::to_string(round) + " (" + std::to_string(held) + " bytes queued): ";
        check(r + "the sender's burst is written whole", off == burst.size());
        check(r + "the sender stays connected", sync(*b) && !b->ws.closed());
        const auto upto = through(*c, bin(arrived.back()));
        std::vector<int> got, want;
        std::string list;
        for (const auto& f : upto) {
            for (size_t i = 0; i < arrived.size(); i++) {
                if (!f.text && f.data == arrived[i]) {
                    got.push_back(static_cast<int>(i));
                    list += " " + std::to_string(i);
                }
            }
        }
        for (int i = 0; i < 48; i++) want.push_back(i);
        check(r + "every frame of the burst arrives once, in order (got" + list + ")", got == want);
    }
    check("(a stopped relay held two receive buffers of b: " + std::to_string(held) + " bytes)", held >= ENOUGH);
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

// ---------------------------------------------------------------------------
// Resumable sessions (RESUMABLE_SESSIONS_PLAN.md section 9). A device drops the way a
// phone does (Socket::abort: no close frame), and comes back with auth v3 naming its
// sid and how many stream frames it read.

// The relay's grace, as its auth_ok says (run_live.sh builds it short).
static int64_t g_grace_secs = 0;

static json hb(Peer& p, uint64_t h) {
    p.send({{"type", "hb"}, {"h", h}});
    auto r = next_json(p, typed("hb_ack"));
    return r ? *r : json::object();
}

static std::string answer_type(const Peer& p) { return p.answer.value("type", ""); }

static bool resumed(const Peer& p) { return answer_type(p) == "resumed"; }

static std::string resume_failed(const Peer& p) { return p.answer.value("resume_failed", ""); }

// Waits for the relay to close the socket.
static bool closed_by_relay(Peer& p) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(WAIT_MS);
    while (!p.ws.closed() && left_ms(deadline) > 0) p.ws.pump(left_ms(deadline));
    return p.ws.closed();
}

static std::set<std::string> keys_of(const json& j) {
    std::set<std::string> out;
    for (auto it = j.begin(); it != j.end(); ++it) out.insert(it.key());
    return out;
}

static bool is_json(const Frame& f, const std::function<bool(const json&)>& pred) {
    auto j = as_json(f);
    return j && pred(*j);
}

static void sleep_ms(int ms) {
    pollfd none{-1, 0, 0};
    poll(&none, 0, ms);
}

// Issue #72: a client whose clock is off still logs in, and learns the relay's time.
static void test_clock() {
    printf("clock: the relay's time rides the challenge and heartbeats; a skewed clock logs in\n");
    const int64_t before = static_cast<int64_t>(now_unix_secs());
    auto plain = login(Ident());
    const int64_t after = static_cast<int64_t>(now_unix_secs());
    const json now = plain->challenge.value("now", json());
    check("auth_challenge carries the relay's unix seconds as `now`",
          now.is_number_unsigned() && now.get<int64_t>() >= before && now.get<int64_t>() <= after);

    for (int64_t skew : {-300, 300}) {
        g_clock_skew_secs = skew;
        const std::string off = std::to_string(skew) + " s";
        check("a v2 full login with a clock " + off + " off is accepted", login(Ident())->ok);
        check("a v2 fetch login with a clock " + off + " off is accepted", login(Ident(), "fetch")->ok);
        Ident ida;
        auto a = login3(ida, "new", 0);
        check("a v3 login with a clock " + off + " off gets a session", a->ok && is_sid(a->sid));
        const json ack = hb(*a, 0);
        check("hb_ack carries the relay's time", ack.value("now", json()).is_number_unsigned() &&
                                                     ack["now"].get<int64_t>() >= before);
        a->ws.abort();
        auto a2 = login3(ida, a->sid, a->ws.counted);
        check("a resume with a clock " + off + " off resumes", resumed(*a2));
    }
    g_clock_skew_secs = 0;
}

static void test_session_logins() {
    printf("sessions: auth v3 logins\n");
    auto a = login3(Ident(), "new", 0);
    check("the challenge offers sessions", a->challenge.value("session", 0) == 1);
    check("a fresh session is minted", a->ok && answer_type(*a) == "auth_ok" && is_sid(a->sid));
    check("with its grace and heartbeat", a->answer.value("grace_secs", 0) > 0 && a->answer.value("hb_secs", 0) == 15);
    check("and no resume to report", !a->answer.contains("resume_failed"));
    g_grace_secs = a->answer.value("grace_secs", 0);

    auto v2 = login(Ident());
    check("a v2 login is answered exactly as before", v2->answer == json{{"type", "auth_ok"}});
    auto f = login3(Ident(), "none", 0, "fetch");
    check("a fetch socket gets no session", f->ok && f->answer == json{{"type", "auth_ok"}});
    auto g = login3(Ident(), "none", 0, "guest");
    check("nor does a guest", g->ok && g->answer == json{{"type", "auth_ok"}});
    check("a full socket asking for none is refused", !login3(Ident(), "none", 0)->ok);
    check("a fetch socket asking for one is refused", !login3(Ident(), "new", 0, "fetch")->ok);
    check("a signature over another session is refused",
          !login3(Ident(), "new", 0, "full", "00112233445566778899aabbccddeeff")->ok);

    Ident x, y, z;
    auto unknown = login3(x, random_hex(16), 0);
    auto owner = login3(y, "new", 0);
    auto stranger = login3(z, owner->sid, 0);
    check("an unknown sid gets a fresh session on the same socket",
          answer_type(*unknown) == "auth_ok" && resume_failed(*unknown) == "unknown" && is_sid(unknown->sid));
    check("another device's sid is answered exactly the same",
          answer_type(*stranger) == "auth_ok" && resume_failed(*stranger) == "unknown" &&
              keys_of(stranger->answer) == keys_of(unknown->answer) && stranger->sid != owner->sid);
    auto back = login3(y, owner->sid, owner->ws.counted);
    check("and leaves the owner's session as it was", resumed(*back));
    auto wrong = login3(y, random_hex(16), 0);
    check("a device naming a sid that is not its own gets a fresh session",
          answer_type(*wrong) == "auth_ok" && resume_failed(*wrong) == "unknown" && wrong->sid != owner->sid);
}

static void test_session_resume() {
    printf("sessions: a resume replays what the device never read, in order\n");
    const std::string room = room_name("sess-resume");
    Ident ida;
    auto a = login3(ida, "new", 0);
    auto b = login(Ident());
    join(*a, room);
    join(*b, room);
    a->send_bin(frame(0x03, {room}, "from-a"));
    b->send_bin(frame(0x04, {room, ida.peer}, "r-1"));
    check("a direct arrives live", next(*a, bin(frame(0x06, {room, b->id.peer}, "r-1"))).has_value());
    const uint64_t read = a->ws.counted;
    // The relay writes these into a socket whose reader has stopped and is about to die.
    b->send_bin(frame(0x04, {room, ida.peer}, "r-2"));
    b->send({{"type", "direct"}, {"room", room}, {"target", ida.peer}, {"data", "r-3"}});
    b->send_bin(frame(0x03, {room}, "r-4"));
    settle({b.get()});
    a->ws.abort();
    check("presence follows the socket: the room sees it leave at once",
          next(*b, about("peer_left", room, ida.peer)).has_value());

    auto a2 = login3(ida, a->sid, read);
    check("the session resumes", resumed(*a2) && !a2->answer.value("gap", true) && !a2->answer.value("reprove", true));
    check("with the relay's count of what the device sent", a2->answer.value("h", 0) == 2);
    check("and its grace and heartbeat", a2->answer.value("grace_secs", 0) == g_grace_secs &&
                                             a2->answer.value("hb_secs", 0) == 15);
    const auto upto = through(*a2, bin(frame(0x05, {room, b->id.peer}, "r-4")));
    check("members first, then every frame after its count, in order",
          upto.size() == 4 && is_json(upto[0], [&](const json& j) { return j.value("type", "") == "members" && j.value("room", "") == room; }) &&
              bin(frame(0x06, {room, b->id.peer}, "r-2"))(upto[1]) &&
              is_json(upto[2], [](const json& j) { return j.value("type", "") == "direct" && j.value("data", "") == "r-3"; }));
    check("the room sees it come back", next(*b, about("peer_joined", room, ida.peer)).has_value());
    b->send_bin(frame(0x04, {room, ida.peer}, "r-5"));
    check("and its directs reach the new socket", next(*a2, bin(frame(0x06, {room, b->id.peer}, "r-5"))).has_value());
    check("nothing was rejoined: the device is listed once",
          discover(*b, room) == std::set<std::string>{ida.peer});
    a2->ws.abort();
    check("the device left again", next(*b, about("peer_left", room, ida.peer)).has_value());
    check("the count a resume named acked the ring", resume_failed(*login3(ida, a->sid, read - 1)) == "bad_h");
}

static void test_session_counting() {
    printf("sessions: both sides count the same frames\n");
    const std::string room = room_name("sess-count");
    Ident ida;
    auto a = login3(ida, "new", 0);
    join(*a, room);
    sync(*a);
    a->send_bin(frame(0x03, {room_name("sess-elsewhere")}, "gated"));
    a->ws.send_frame(0x1, "not json");
    a->send({{"type", "ack"}, {"h", 0}});
    a->send({{"type", "inactive"}});
    a->send({{"type", "active"}});
    check("every stream frame counts on arrival, one a gate refused too, and no control frame",
          hb(*a, a->ws.counted).value("h", 0) == 4);
    check("the relay's answers count, presence does not", a->ws.counted == 1);
    const uint64_t read = a->ws.counted;
    a->ws.abort();
    auto a2 = login3(ida, a->sid, read);
    check("a resume at the device's count replays nothing", resumed(*a2) && hb(*a2, read).value("h", 0) == 4);
    settle({a2.get()});
    check("(nothing but the members)", count(*a2, typed("discovered_peers")) == 0);

    // `in_h` above what the relay sent, and below what the device acked.
    Ident idd, ide, idf;
    auto d = login3(idd, "new", 0);
    sync(*d);
    const uint64_t d_read = d->ws.counted;
    d->ws.abort();
    auto d2 = login3(idd, d->sid, d_read + 1);
    check("a count above what the relay sent is bad_h", resume_failed(*d2) == "bad_h" && is_sid(d2->sid) && d2->sid != d->sid);
    auto e = login3(ide, "new", 0);
    sync(*e);
    sync(*e);
    e->send({{"type", "ack"}, {"h", e->ws.counted}});
    sync(*e);
    e->ws.abort();
    auto e2 = login3(ide, e->sid, 1);
    check("a count below what the device acked is bad_h", resume_failed(*e2) == "bad_h");
    Ident idh;
    auto h = login3(idh, "new", 0);
    sync(*h);
    sync(*h);
    hb(*h, h->ws.counted);
    h->ws.abort();
    check("a heartbeat's count acks too", resume_failed(*login3(idh, h->sid, 1)) == "bad_h");
    auto f = login3(idf, "new", 0);
    sync(*f);
    sync(*f);
    sync(*f);
    f->ws.abort();
    auto f2 = login3(idf, f->sid, 1);
    check("unacked, the same count resumes and replays the rest", resumed(*f2));
    settle({f2.get()});
    check("(the two answers after its count)", count(*f2, typed("discovered_peers")) == 2);
}

static void test_session_acks() {
    printf("sessions: acks both ways\n");
    Ident ida;
    auto a = login3(ida, "new", 0);
    // Seventeen at once: the first ack names 16, the seventeenth waits for the timer.
    const auto t0 = std::chrono::steady_clock::now();
    for (int i = 0; i < 17; i++) a->send({{"type", "discover_peers"}, {"room", room_name("ack") + std::to_string(i)}});
    auto ack = next_json(*a, typed("ack"));
    check("the relay acks after 16 stream frames", ack && ack->value("h", 0) == 16);
    auto late = next_json(*a, typed("ack"), 4500);
    const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
    check("and 2 s after one it has not acked", late && late->value("h", 0) == 17 && ms >= 1500);
    auto quiet = next_json(*a, typed("ack"), 2600);
    check("and not again with nothing new", !quiet.has_value());
    check("the heartbeat answer carries the count", hb(*a, 0).value("h", 0) == 17);
    // An `h` the relay never sent is ignored, so a later resume from 0 still works.
    a->send({{"type", "ack"}, {"h", 1000000}});
    a->send({{"type", "hb"}, {"h", 1000000}});
    sync(*a);
    a->ws.abort();
    auto a2 = login3(ida, a->sid, 0);
    check("an ack past what the relay sent acks nothing", resumed(*a2));
}

static void test_session_gap() {
    printf("sessions: what the ring cannot keep replays as a counted gap\n");
    const std::string room = room_name("sess-gap");
    Ident ida;
    auto a = login3(ida, "new", 0);
    auto b = login(Ident());
    join(*a, room);
    join(*b, room);
    const uint64_t read = a->ws.counted;
    a->ws.abort();
    check("the device left", next(*b, about("peer_left", room, ida.peer)).has_value());
    b->send_bin(frame(0x04, {room, ida.peer}, std::string(9 * 1024 * 1024, 'g')));
    b->send_bin(frame(0x04, {room, ida.peer}, "after-gap"));
    settle({b.get()});
    auto a2 = login3(ida, a->sid, read);
    check("the resume says its replay holds a gap", resumed(*a2) && a2->answer.value("gap", false));
    const auto upto = through(*a2, bin(frame(0x06, {room, b->id.peer}, "after-gap")));
    check("the frame too big for the ring comes back as one counted gap, then the rest",
          upto.size() == 3 && is_json(upto[1], [](const json& j) { return j.value("type", "") == "gap" && j.value("n", 0) == 1; }));
    check("and the device's count takes the gap in", a2->ws.counted == read + 2);
}

static void test_session_expiry() {
    printf("sessions: when grace runs out, its directs move to offline_buffer\n");
    const std::string room = room_name("sess-exp");
    Ident ida, master;
    auto a = login3(ida, "new", 0);
    auto b = login(Ident());
    join(*a, room);
    join(*b, room);
    const std::string nick = "s" + g_tag + "x";
    a->send(signed_nickname(nick, ida, master));
    check("the device claims a nickname", next(*a, typed("nickname_claimed")).has_value());
    const uint64_t read = a->ws.counted;
    a->ws.abort();
    check("the device left", next(*b, about("peer_left", room, ida.peer)).has_value());
    b->send_bin(frame(0x04, {room, ida.peer}, "exp-direct"));
    b->send_bin(frame(0x08, {room, ida.peer}, "exp-image"));
    b->send_bin(frame(0x03, {room}, "exp-bcast"));
    b->send_bin(frame(0x02, {room, ida.peer}, "exp-raw"));
    const json resolve = {{"type", "resolve_nickname"}, {"nickname", nick}};
    const auto answer = json_where([](const json& j) {
        return j.value("type", "") == "nickname_resolved" || j.value("type", "") == "nickname_error";
    });
    b->send(resolve);
    auto held = next_json(*b, answer);
    check("a nickname its session holds still resolves",
          held && held->value("type", "") == "nickname_resolved" && held->value("peer_id", "") == ida.peer);

    sleep_ms(static_cast<int>(g_grace_secs * 1000 + 1500));
    b->send(resolve);
    auto gone = next_json(*b, answer);
    check("once the grace is over it does not", gone && gone->value("type", "") == "nickname_error");
    settle({b.get()});
    check("and the room hears no second departure", !got(*b, about("peer_left", room, ida.peer)));
    auto a2 = login3(ida, a->sid, read);
    check("the session is gone", answer_type(*a2) == "auth_ok" && resume_failed(*a2) == "unknown");
    join(*a2, room);
    settle({a2.get()});
    check("its directs wait for the next join", got(*a2, bin(frame(0x06, {room, b->id.peer}, "exp-direct"))) &&
                                                     got(*a2, bin(frame(0x06, {room, b->id.peer}, "exp-image"))));
    check("its broadcasts and chunks do not", !got(*a2, bin(frame(0x05, {room, b->id.peer}, "exp-bcast"))) &&
                                                  !got(*a2, bin(frame(0x02, {room, b->id.peer}, "exp-raw"))));
}

static void test_session_transfer() {
    printf("sessions: a live session moves to the socket that resumes it\n");
    const std::string room = room_name("sess-move");
    Ident ida;
    auto a = login3(ida, "new", 0);
    auto b = login(Ident());
    join(*a, room);
    join(*b, room);
    b->send_bin(frame(0x04, {room, ida.peer}, "mv-1"));
    next(*a, bin(frame(0x06, {room, b->id.peer}, "mv-1")));
    auto a2 = login3(ida, a->sid, a->ws.counted);
    check("it resumes", resumed(*a2));
    check("the old socket closes as moved",
          closed_by_relay(*a) && a->ws.close_code == 1000 && a->ws.close_reason == "moved");
    check("the new one is told the room", next(*a2, typed("members", room)).has_value());
    settle({a2.get(), b.get()});
    check("and the room is told nothing", !got(*b, about("peer_left", room, ida.peer)) &&
                                              !got(*b, about("peer_joined", room, ida.peer)));
    b->send_bin(frame(0x04, {room, ida.peer}, "mv-2"));
    check("its directs reach the new socket", next(*a2, bin(frame(0x06, {room, b->id.peer}, "mv-2"))).has_value());
}

static void test_session_fresh_over_held() {
    printf("sessions: a fresh login ends the session the device held\n");
    const std::string room = room_name("sess-fresh");
    Ident ida;
    auto a = login3(ida, "new", 0);
    auto b = login(Ident());
    join(*a, room);
    join(*b, room);
    a->ws.abort();
    check("the device left", next(*b, about("peer_left", room, ida.peer)).has_value());
    b->send_bin(frame(0x04, {room, ida.peer}, "fr-1"));
    settle({b.get()});
    auto a2 = login3(ida, "new", 0);
    check("a fresh session", answer_type(*a2) == "auth_ok" && is_sid(a2->sid) && a2->sid != a->sid);
    join(*a2, room);
    check("the old ring's direct waits in offline_buffer for the fresh one",
          next(*a2, bin(frame(0x06, {room, b->id.peer}, "fr-1"))).has_value());
    settle({b.get()});
    check("its rooms were left silently", !got(*b, about("peer_left", room, ida.peer)));
    check("the new socket joined the room", next(*b, about("peer_joined", room, ida.peer)).has_value());

    auto a3 = login3(ida, "new", 0);
    check("over a live session too", answer_type(*a3) == "auth_ok" && a3->sid != a2->sid);
    check("whose socket is closed", closed_by_relay(*a2));
    settle({b.get()});
    check("silently", !got(*b, about("peer_left", room, ida.peer)));
}

static void test_session_inactive() {
    printf("sessions: an inactive session is spared presence\n");
    const std::string room = room_name("sess-idle");
    Ident ida;
    auto a = login3(ida, "new", 0);
    auto b = login(Ident());
    join(*a, room);
    join(*b, room);
    a->send({{"type", "inactive"}});
    sync(*a);
    auto c = login(Ident());
    join(*c, room);
    b->send_bin(frame(0x03, {room}, "idle-bcast"));
    check("stream frames still flow", next(*a, bin(frame(0x05, {room, b->id.peer}, "idle-bcast"))).has_value());
    settle({c.get(), a.get()});
    check("presence is withheld", !got(*a, about("peer_joined", room, c->id.peer)));
    a->send({{"type", "active"}});
    auto m = next_json(*a, typed("members", room));
    check("active sends a fresh members per room",
          m && peers_of(*m) == std::set<std::string>{ida.peer, b->id.peer, c->id.peer});
    c->send({{"type", "leave"}, {"room", room}});
    check("and presence flows again", next(*a, about("peer_left", room, c->id.peer)).has_value());
}

static void test_session_end() {
    printf("sessions: end hands off and closes\n");
    const std::string room = room_name("sess-end");
    Ident ida;
    auto a = login3(ida, "new", 0);
    auto b = login(Ident());
    join(*a, room);
    join(*b, room);
    b->send_bin(frame(0x04, {room, ida.peer}, "end-1"));
    next(*a, bin(frame(0x06, {room, b->id.peer}, "end-1")));
    a->send({{"type", "end"}});
    check("the relay closes the socket", closed_by_relay(*a) && a->ws.close_code == 1000);
    check("the room sees it leave", next(*b, about("peer_left", room, ida.peer)).has_value());
    auto a2 = login3(ida, a->sid, a->ws.counted);
    check("the session is gone", resume_failed(*a2) == "unknown");
    join(*a2, room);
    check("its unacked direct moved to offline_buffer", next(*a2, bin(frame(0x06, {room, b->id.peer}, "end-1"))).has_value());
}

static void test_session_fetch_in_grace() {
    printf("sessions: a fetch socket during grace gets its copy too\n");
    const std::string room = room_name("sess-fetch");
    Ident ida;
    auto a = login3(ida, "new", 0);
    auto b = login(Ident());
    join(*a, room);
    join(*b, room);
    const uint64_t read = a->ws.counted;
    a->ws.abort();
    check("the device left", next(*b, about("peer_left", room, ida.peer)).has_value());
    auto f = login3(ida, "none", 0, "fetch");
    f->send({{"type", "join"}, {"room", room}});
    settle({f.get()});
    b->send_bin(frame(0x04, {room, ida.peer}, "fg-1"));
    check("the fetch socket gets it live", next(*f, bin(frame(0x06, {room, b->id.peer}, "fg-1"))).has_value());
    auto a2 = login3(ida, a->sid, read);
    check("the session resumes", resumed(*a2));
    check("and its ring replays it too", next(*a2, bin(frame(0x06, {room, b->id.peer}, "fg-1"))).has_value());
    check("the room sees it come back", next(*b, about("peer_joined", room, ida.peer)).has_value());
    f->send({{"type", "leave"}, {"room", room}});
    settle({f.get()});
    b->send_bin(frame(0x04, {room, ida.peer}, "fg-2"));
    check("the fetch socket's leave keeps the resumed slot", next(*a2, bin(frame(0x06, {room, b->id.peer}, "fg-2"))).has_value());
}

static void test_session_doors_and_kills() {
    printf("sessions: kill signals first, door standing kept within the process\n");
    Ident owner, change, owner2, change2;
    Door door, door2;
    const std::string nonce = random_hex(16), nonce2 = random_hex(16);
    const std::string room = genesis_server_id(owner.peer, nonce);
    const std::string room2 = genesis_server_id(owner2.peer, nonce2);
    Ident ida;
    auto a = login3(ida, "new", 0);
    auto b = login(Ident());
    b->send({{"type", "lock_put"}, {"server", room}, {"owner", ""}, {"links", base_link(room, door, change, owner, nonce, true)}});
    b->send({{"type", "lock_put"}, {"server", room2}, {"owner", ""},
             {"links", base_link(room2, door2, change2, owner2, nonce2, true)}});
    check("the relay takes both locks", next(*b, typed("lock_chain")).has_value() && next(*b, typed("lock_chain")).has_value());
    auto ma = join(*a, room, {{"door_proof", door_proof(*a, room, door)}});
    auto mb = join(*b, room, {{"door_proof", door_proof(*b, room, door)}});
    check("both prove the door", ma && ma->value("proved", false) && mb && mb->value("proved", false));
    const uint64_t read = a->ws.counted;
    a->ws.abort();
    check("the device left", next(*b, about("peer_left", room, ida.peer)).has_value());
    b->send({{"type", "kill_deposit"}, {"blob", "AAAA"}, {"issued_at_ms", 7}, {"targets", json::array({ida.peer})}});
    check("a destroy signal waits for it", next(*b, typed("kill_deposited")).has_value());
    // Its fetch socket comes and goes meanwhile, taking none of the session's standing.
    auto f = login3(ida, "none", 0, "fetch");
    f->send({{"type", "join"}, {"room", room}});
    f->send({{"type", "leave"}, {"room", room}});
    settle({f.get()});
    check("its fetch socket closes", f->ws.close_clean());

    auto a2 = login3(ida, a->sid, read);
    check("the session resumes", resumed(*a2));
    const auto upto = through(*a2, typed("members", room));
    check("the waiting kill signal comes first", upto.size() == 2 && is_json(upto[0], [](const json& j) {
                                                     return j.value("type", "") == "kill_signal" && j.value("issued_at_ms", 0) == 7;
                                                 }));
    check("and the locked room is still proved", !upto.empty() && is_json(upto.back(), [&](const json& j) {
                                                     return j.value("proved", false) && peers_of(j).count(b->id.peer) != 0;
                                                 }));
    check("the provers see it come back", next(*b, about("peer_joined", room, ida.peer)).has_value());
    // The socket took the session's door nonce: a proof for its own challenge opens nothing.
    auto fresh = join(*a2, room2, {{"door_proof", door_proof_for(*a2, a2->nonce, room2, door2)}});
    check("a proof bound to the new socket's challenge proves nothing", fresh && !fresh->value("proved", true));
    auto kept = join(*a2, room2, {{"door_proof", door_proof_for(*a2, a->nonce, room2, door2)}});
    check("one bound to the session's nonce does", kept && kept->value("proved", false));
    a2->send({{"type", "kill_ack"}});
}

// A legacy-base roster in which `by` removed `gone`.
static json roster_removing(const Ident& master, const std::vector<const Ident*>& devices, const Ident& gone,
                            const Ident& by) {
    roster::Roster r = roster::Roster::named(master.peer);
    for (const auto* d : devices) {
        r.legacy.push_back({d->peer, master.sign(roster::legacy_payload(master.peer, d->peer))});
        r.consents.push_back({d->peer, d->sign(roster::consent_payload(master.peer, d->peer))});
    }
    roster::Removal x;
    x.base = roster::LEGACY_BASE;
    x.device = gone.peer;
    x.by = by.peer;
    x.sig = by.sign(roster::removal_payload(master.peer, roster::LEGACY_BASE, gone.peer, {}));
    r.removals.push_back(x);
    return json::parse(roster::to_json(r).dump());
}

static void test_session_inbox_recheck() {
    printf("sessions: an owner the roster drops during grace loses the inbox\n");
    Ident master, d1, d2;
    const std::string inbox = "inbox:" + master.peer;
    auto a = login3(d1, "new", 0);
    auto m1 = join(*a, inbox, {{"inbox_roster", legacy_roster(master, {&d1, &d2})}});
    check("the device owns the inbox", m1 && peers_of(*m1) == std::set<std::string>{d1.peer});
    auto b = login(d2);
    join(*b, inbox, {{"inbox_roster", legacy_roster(master, {&d1, &d2})}});
    const uint64_t read = a->ws.counted;
    a->ws.abort();
    check("its sibling sees it leave", next(*b, about("peer_left", inbox, d1.peer)).has_value());
    join(*b, inbox, {{"inbox_roster", roster_removing(master, {&d1, &d2}, d1, d2)}});
    auto s = login(Ident());
    join(*s, inbox);
    s->send_bin(frame(0x04, {inbox, master.peer}, "after-removal"));
    check("a deposit reaches the owner left", next(*b, bin(frame(0x06, {inbox, s->id.peer}, "after-removal"))).has_value());
    auto a2 = login3(d1, a->sid, read);
    check("the session resumes", resumed(*a2));
    auto m2 = next_json(*a2, typed("members", inbox));
    check("without the inbox: it sees only itself", m2 && peers_of(*m2) == std::set<std::string>{d1.peer});
    settle({a2.get(), b.get()});
    check("its ring kept nothing deposited after the removal",
          !got(*a2, bin(frame(0x06, {inbox, s->id.peer}, "after-removal"))));
    check("and the owner is not told it came back", !got(*b, about("peer_joined", inbox, d1.peer)));
}

// A gapped resume joins nothing, so a mailbox deposit that fell out of the ring would
// never reach the device: an inbox it owns replays its mailbox after the ring.
// AR-36: one socket reads the mailbox once. A re-join, a roster re-show or a resume
// sends only what this socket was not already sent from it; siblings still read it all.
static void test_mailbox_read_once() {
    printf("sessions: a socket reads its inbox's mailbox once\n");
    Ident master, d1, d2;
    const std::string inbox = "inbox:" + master.peer;
    const json roster = legacy_roster(master, {&d1, &d2});
    auto s = login(Ident());
    join(*s, inbox);
    s->send_bin(frame(0x04, {inbox, master.peer}, "mail-a"));
    settle({s.get()});
    const auto mail_a = bin(frame(0x06, {inbox, s->id.peer}, "mail-a"));
    const auto mail_b = bin(frame(0x06, {inbox, s->id.peer}, "mail-b"));
    const auto mail_c = bin(frame(0x06, {inbox, s->id.peer}, "mail-c"));

    auto a = login3(d1, "new", 0);
    join(*a, inbox, {{"inbox_roster", roster}});
    settle({a.get()});
    check("the first owning join reads the mailbox", count(*a, mail_a) == 1);
    join(*a, inbox, {{"inbox_roster", roster}});
    join(*a, inbox);
    settle({a.get()});
    check("a roster re-show or a plain re-join on the same socket reads nothing again", count(*a, mail_a) == 0);

    s->send_bin(frame(0x04, {inbox, master.peer}, "mail-b"));
    settle({s.get(), a.get()});
    check("a deposit reaches the owner live", count(*a, mail_b) == 1);
    join(*a, inbox, {{"inbox_roster", roster}});
    settle({a.get()});
    check("an older deposit is still not read again", count(*a, mail_a) == 0);
    count(*a, mail_b);  // a live deposit may come once more, never more
    join(*a, inbox, {{"inbox_roster", roster}});
    settle({a.get()});
    check("nor a live one past its one replay", count(*a, mail_a) == 0 && count(*a, mail_b) == 0);

    auto sib = login3(d2, "new", 0);
    join(*sib, inbox, {{"inbox_roster", roster}});
    settle({sib.get()});
    check("a sibling's own socket reads everything", count(*sib, mail_a) == 1 && count(*sib, mail_b) == 1);

    const uint64_t read = a->ws.counted;
    a->ws.abort();
    settle({s.get()});
    auto a2 = login3(d1, a->sid, read);
    check("(the session resumes without a gap)", resumed(*a2) && !a2->answer.value("gap", true));
    join(*a2, inbox, {{"inbox_roster", roster}});
    settle({a2.get()});
    check("a resumed session's re-join reads nothing it was already sent",
          count(*a2, mail_a) == 0 && count(*a2, mail_b) == 0);

    // The device's push isolate sits in the inbox unproved while the session is in
    // grace; a deposit then, and its proof later, still reads every older deposit.
    const uint64_t read2 = a2->ws.counted;
    a2->ws.abort();
    settle({s.get()});
    auto f = login(d1, "fetch");
    join(*f, inbox);
    s->send_bin(frame(0x04, {inbox, master.peer}, "mail-c"));
    settle({s.get(), f.get()});
    join(*f, inbox, {{"inbox_roster", roster}});
    settle({f.get()});
    check("a fetch socket that proves after a live deposit reads every older one",
          count(*f, mail_a) == 1 && count(*f, mail_b) == 1 && count(*f, mail_c) >= 1);
    join(*f, inbox, {{"inbox_roster", roster}});
    settle({f.get()});
    check("and reads them once", count(*f, mail_a) == 0 && count(*f, mail_b) == 0);
    (void)read2;
}

// A gap may swallow a deposit the socket was already sent (live and by a re-join), so
// a gapped resume replays the whole mailbox, whatever the socket's mark says.
static void test_mailbox_gap_after_read() {
    printf("sessions: a gapped resume replays mail the socket had already been sent\n");
    Ident master, d1;
    const std::string inbox = "inbox:" + master.peer;
    const std::string room = room_name("mail-gap-read");
    const json roster = legacy_roster(master, {&d1});
    auto a = login3(d1, "new", 0);
    join(*a, inbox, {{"inbox_roster", roster}});
    join(*a, room);
    auto s = login(Ident());
    join(*s, inbox);
    join(*s, room);
    settle({a.get()});
    const uint64_t read = a->ws.counted;
    // From here the device reads nothing: the deposit, live and from the re-join, sits
    // in its ring unread, and the flood after it pushes both into a gap.
    s->send_bin(frame(0x04, {inbox, master.peer}, "read-then-lost"));
    settle({s.get()});
    a->send({{"type", "join"}, {"room", inbox}, {"inbox_roster", roster}});
    for (int i = 0; i < 8; i++) s->send_bin(frame(0x03, {room}, std::string(1024 * 1024, 'g') + std::to_string(i)));
    settle({s.get()});
    a->ws.abort();
    check("the device left", next(*s, about("peer_left", room, d1.peer)).has_value());
    auto a2 = login3(d1, a->sid, read);
    check("the resume reports a gap", resumed(*a2) && a2->answer.value("gap", false));
    const auto mail = bin(frame(0x06, {inbox, s->id.peer}, "read-then-lost"));
    const auto upto = through(*a2, mail);
    check("the mail it had been sent before the gap comes again", !upto.empty() && mail(upto.back()));
}

static void test_session_gap_mailbox() {
    printf("sessions: a gapped resume replays the mailbox of an inbox it owns\n");
    Ident master, d1;
    const std::string inbox = "inbox:" + master.peer;
    const std::string room = room_name("sess-gapmail");
    auto a = login3(d1, "new", 0);
    auto m = join(*a, inbox, {{"inbox_roster", legacy_roster(master, {&d1})}});
    check("the device owns the inbox", m && peers_of(*m) == std::set<std::string>{d1.peer});
    join(*a, room);
    auto s = login(Ident());
    join(*s, inbox);
    join(*s, room);
    // Another identity's inbox the device sits in without owning it, mail waiting there.
    Ident other;
    const std::string not_mine = "inbox:" + other.peer;
    s->send_bin(frame(0x04, {not_mine, other.peer}, "not-mine"));
    settle({s.get()});
    join(*a, not_mine);
    const uint64_t read = a->ws.counted;
    a->ws.abort();
    check("the device left", next(*s, about("peer_left", room, d1.peer)).has_value());
    // The depositor fills the ring after its deposit, so its own oldest frame, the
    // deposit, is the first to become a gap.
    s->send_bin(frame(0x04, {inbox, master.peer}, "mail-in-gap"));
    for (int i = 0; i < 8; i++) s->send_bin(frame(0x03, {room}, std::string(1024 * 1024, 'f') + std::to_string(i)));
    settle({s.get()});
    const std::string mail = frame(0x06, {inbox, s->id.peer}, "mail-in-gap");
    auto a2 = login3(d1, a->sid, read);
    check("the resume reports a gap", resumed(*a2) && a2->answer.value("gap", false));
    const auto upto = through(*a2, bin(mail));
    bool gap_first = false;
    for (const auto& f : upto) {
        if (is_json(f, [](const json& j) { return j.value("type", "") == "gap"; })) {
            gap_first = true;
            break;
        }
        if (bin(mail)(f)) break;
    }
    check("the deposit that fell into the gap arrives from the mailbox, after the ring", !upto.empty() && gap_first);
    settle({a2.get()});
    const auto foreign = bin(frame(0x06, {not_mine, s->id.peer}, "not-mine"));
    check("an inbox it does not own replays nothing",
          std::none_of(upto.begin(), upto.end(), foreign) && !got(*a2, foreign));
    const uint64_t read2 = a2->ws.counted;
    a2->ws.abort();
    check("the device left again", next(*s, about("peer_left", room, d1.peer)).has_value());
    auto a3 = login3(d1, a->sid, read2);
    check("the mailbox replay was counted like any stream frame", resumed(*a3) && !a3->answer.value("gap", true));
    settle({a3.get()});
    check("a resume without a gap replays no mailbox", !got(*a3, bin(mail)));
}

// The relay posts a push to 127.0.0.1:3001. Only when this test holds that port does it
// register a token, so a real sidecar there never sees one.
static void test_session_push_in_grace() {
    printf("sessions: a direct into a ring in grace wakes the phone\n");
    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in at{};
    at.sin_family = AF_INET;
    at.sin_port = htons(3001);
    at.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int one = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (lfd < 0 || bind(lfd, reinterpret_cast<sockaddr*>(&at), sizeof(at)) != 0 || listen(lfd, 8) != 0) {
        if (lfd >= 0) close(lfd);
        printf("  skip push in grace (127.0.0.1:3001 is taken)\n");
        return;
    }
    // Only a post naming this run's token counts: another relay on the machine may post here.
    const std::string token = "token-" + g_tag;
    auto wake = [lfd, &token](int timeout_ms) {
        auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
        while (left_ms(deadline) > 0) {
            pollfd p{lfd, POLLIN, 0};
            if (poll(&p, 1, left_ms(deadline)) <= 0) break;
            int c = accept(lfd, nullptr, nullptr);
            if (c < 0) break;
            std::string req;
            char buf[4096];
            for (int i = 0; i < 20 && req.find("\r\n\r\n") == std::string::npos; i++) {
                pollfd q{c, POLLIN, 0};
                if (poll(&q, 1, 500) <= 0) break;
                ssize_t n = read(c, buf, sizeof(buf));
                if (n <= 0) break;
                req.append(buf, static_cast<size_t>(n));
            }
            pollfd q{c, POLLIN, 0};
            if (poll(&q, 1, 500) > 0) {
                ssize_t n = read(c, buf, sizeof(buf));
                if (n > 0) req.append(buf, static_cast<size_t>(n));
            }
            const std::string ok = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            (void)!write(c, ok.data(), ok.size());
            close(c);
            if (req.find(token) != std::string::npos) return req;
        }
        return std::string();
    };
    const std::string room = room_name("sess-push");
    Ident ida;
    auto a = login3(ida, "new", 0);
    auto b = login(Ident());
    join(*a, room);
    join(*b, room);
    a->send({{"type", "register_push_token"}, {"token", token}, {"platform", "android"}});
    check("the device registers a token", next(*a, typed("push_token_registered")).has_value());
    b->send_bin(frame(0x04, {room, ida.peer}, "push-live"));
    next(*a, bin(frame(0x06, {room, b->id.peer}, "push-live")));
    check("a live device is not woken", wake(1000).empty());
    const uint64_t read = a->ws.counted;
    a->ws.abort();
    check("the device left", next(*b, about("peer_left", room, ida.peer)).has_value());
    b->send_bin(frame(0x04, {room, ida.peer}, "push-grace"));
    const std::string req = wake(WAIT_MS);
    check("a device in grace is", req.find("\"sender\":\"" + b->id.peer + "\"") != std::string::npos);
    auto a2 = login3(ida, a->sid, read);
    check("and still gets the frame on resume", next(*a2, bin(frame(0x06, {room, b->id.peer}, "push-grace"))).has_value());
    a2->send({{"type", "unregister_push_token"}});
    sync(*a2);
    close(lfd);
}

// ---------------------------------------------------------------------------
// A device whose session said `inactive` is hidden from everyone's presence (plan section
// 8, decision 6): every room that saw it is told it left, no list or presence answer names
// it, nothing it does announces it, and `active` tells its rooms it is back. Delivery
// follows the session all the while.

// The relay's PRESENCE_PASS_MS (state.h): one socket's presence passes come no closer.
static constexpr int PRESENCE_PACE_MS = 2000;

// Holds 127.0.0.1:3001, where the relay posts pushes, waiting while another suite has it.
static int hold_push_port() {
    for (int attempt = 0; attempt < 40; attempt++) {
        int lfd = socket(AF_INET, SOCK_STREAM, 0);
        sockaddr_in at{};
        at.sin_family = AF_INET;
        at.sin_port = htons(3001);
        at.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        int one = 1;
        setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        if (lfd >= 0 && bind(lfd, reinterpret_cast<sockaddr*>(&at), sizeof(at)) == 0 && listen(lfd, 16) == 0) return lfd;
        if (lfd >= 0) close(lfd);
        sleep_ms(500);
    }
    return -1;
}

// Whether the relay posts a push naming `token` within `timeout_ms`; every post is
// answered so its worker moves on, since another relay on the machine may post here too.
static bool pushed(int lfd, const std::string& token, int timeout_ms) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    while (left_ms(deadline) > 0) {
        pollfd p{lfd, POLLIN, 0};
        if (poll(&p, 1, left_ms(deadline)) <= 0) return false;
        int c = accept(lfd, nullptr, nullptr);
        if (c < 0) return false;
        std::string req;
        char buf[4096];
        for (int i = 0; i < 4; i++) {
            pollfd q{c, POLLIN, 0};
            if (poll(&q, 1, 300) <= 0) break;
            ssize_t n = read(c, buf, sizeof(buf));
            if (n <= 0) break;
            req.append(buf, static_cast<size_t>(n));
        }
        const std::string ok = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        (void)!write(c, ok.data(), ok.size());
        close(c);
        if (req.find(token) != std::string::npos) return true;
    }
    return false;
}

static void test_hidden_presence() {
    printf("presence: an inactive device is hidden from every room, delivery goes on\n");
    const std::string r1 = room_name("hide-1"), r2 = room_name("hide-2"), r3 = room_name("hide-3");
    Ident ida;
    auto a = login3(ida, "new", 0);
    auto b = login(Ident());
    join(*b, r1);
    join(*b, r2);
    join(*b, r3);
    join(*a, r1);
    join(*a, r2);
    check("(the rooms see it come)", next(*b, about("peer_joined", r1, ida.peer)).has_value() &&
                                         next(*b, about("peer_joined", r2, ida.peer)).has_value());
    a->send({{"type", "inactive"}});
    check("inactive: every room that saw it is told it left",
          next(*b, about("peer_left", r1, ida.peer)).has_value() && next(*b, about("peer_left", r2, ida.peer)).has_value());
    auto c = login(Ident());
    auto mc = join(*c, r1);
    check("a newcomer's members leave it out", mc && peers_of(*mc) == std::set<std::string>{b->id.peer, c->id.peer});
    check("so does discover_peers", discover(*b, r1) == std::set<std::string>{c->id.peer});
    check("and check_peers counts it offline", online(*b, {ida.peer, c->id.peer}) == std::set<std::string>{c->id.peer});
    Ident ide;
    auto e = login3(ide, "new", 0);
    join(*e, r1);
    const uint64_t e_read = e->ws.counted;
    e->ws.abort();
    check("(another device drops)", next(*b, about("peer_left", r1, ide.peer)).has_value());
    auto e2 = login3(ide, e->sid, e_read);
    auto me = next_json(*e2, typed("members", r1));
    check("a resuming device's members leave it out",
          resumed(*e2) && me && peers_of(*me) == std::set<std::string>{b->id.peer, c->id.peer, ide.peer});

    b->send_bin(frame(0x04, {r1, ida.peer}, "hide-direct"));
    check("a direct to it still arrives live", next(*a, bin(frame(0x06, {r1, b->id.peer}, "hide-direct"))).has_value());
    c->send_bin(frame(0x03, {r1}, "hide-bcast"));
    check("and the room's broadcasts", next(*a, bin(frame(0x05, {r1, c->id.peer}, "hide-bcast"))).has_value());
    a->send_bin(frame(0x03, {r1}, "from-hidden"));
    check("and what it sends reaches the room", next(*b, bin(frame(0x05, {r1, ida.peer}, "from-hidden"))).has_value());
    join(*a, r3);
    a->send({{"type", "leave"}, {"room", r2}});
    settle({a.get(), b.get()});
    check("a room it joins while hidden is told nothing", !got(*b, about("peer_joined", r3, ida.peer)));
    check("nor one it leaves", !got(*b, about("peer_left", r2, ida.peer)));

    a->send({{"type", "active"}});
    check("active: each room it is in is told it is back",
          next(*b, about("peer_joined", r1, ida.peer)).has_value() &&
              next(*b, about("peer_joined", r3, ida.peer)).has_value() &&
              next(*c, about("peer_joined", r1, ida.peer)).has_value());
    settle({a.get(), b.get()});
    check("but not the one it left", !got(*b, about("peer_joined", r2, ida.peer)));
    auto d = login(Ident());
    auto md = join(*d, r1);
    check("and every list names it again", md && peers_of(*md).count(ida.peer) != 0 &&
                                               online(*b, {ida.peer}) == std::set<std::string>{ida.peer} &&
                                               discover(*b, r1).count(ida.peer) != 0);
}

static void test_hidden_session() {
    printf("presence: a hidden device's session drops, resumes and moves as before, shown to nobody\n");
    const std::string room = room_name("hide-sess");
    Ident ida;
    auto a = login3(ida, "new", 0);
    auto b = login(Ident());
    join(*b, room);
    join(*a, room);
    next(*b, about("peer_joined", room, ida.peer));
    a->send({{"type", "inactive"}});
    check("(it is hidden)", next(*b, about("peer_left", room, ida.peer)).has_value());
    const uint64_t read = a->ws.counted;
    a->ws.abort();
    // Nothing announces the close: give the relay a moment to read it.
    sleep_ms(300);
    b->send_bin(frame(0x04, {room, ida.peer}, "hide-grace"));
    settle({b.get()});
    check("its socket dropping tells the room nothing more", !got(*b, about("peer_left", room, ida.peer)));
    auto a2 = login3(ida, a->sid, read);
    check("the session resumes", resumed(*a2));
    check("its ring kept what came meanwhile", next(*a2, bin(frame(0x06, {room, b->id.peer}, "hide-grace"))).has_value());
    settle({a2.get(), b.get()});
    check("a resume while inactive announces nothing", !got(*b, about("peer_joined", room, ida.peer)));
    check("and it stays hidden", discover(*b, room).empty() && online(*b, {ida.peer}).empty());

    auto a3 = login3(ida, a->sid, a2->ws.counted);
    check("it moves to another socket", resumed(*a3) && closed_by_relay(*a2));
    settle({a3.get(), b.get()});
    check("hidden still, and nobody is told", !got(*b, about("peer_joined", room, ida.peer)) &&
                                                  !got(*b, about("peer_left", room, ida.peer)) &&
                                                  online(*b, {ida.peer}).empty());
    a3->send({{"type", "active"}});
    check("active on the new socket shows it", next(*b, about("peer_joined", room, ida.peer)).has_value());
    a3->send({{"type", "inactive"}});
    check("(hidden again)", next(*b, about("peer_left", room, ida.peer)).has_value());

    // The client tells a fresh session `inactive` before it replays its joins.
    auto a4 = login3(ida, "new", 0);
    a4->send({{"type", "inactive"}});
    join(*a4, room);
    settle({a4.get(), b.get()});
    check("a fresh session told inactive before its joins is never shown",
          !got(*b, about("peer_joined", room, ida.peer)) && !got(*b, about("peer_left", room, ida.peer)) &&
              discover(*b, room).empty());
    a4->send({{"type", "active"}});
    check("until it says active", next(*b, about("peer_joined", room, ida.peer)).has_value());

    a4->send({{"type", "inactive"}});
    check("(hidden once more)", next(*b, about("peer_left", room, ida.peer)).has_value());
    a4->send({{"type", "end"}});
    check("(it ends its session)", closed_by_relay(*a4));
    settle({b.get()});
    check("an end while hidden tells the room nothing more", !got(*b, about("peer_left", room, ida.peer)));
}

static void test_hidden_no_push() {
    printf("presence: a hidden device whose socket is live is never woken\n");
    const int lfd = hold_push_port();
    if (lfd < 0) {
        printf("  skip hidden push (127.0.0.1:3001 is taken)\n");
        return;
    }
    const std::string token = "hide-token-" + g_tag;
    const std::string room = room_name("hide-push"), server = room_name("hide-push-srv"),
                      elsewhere = room_name("hide-push-else");
    Ident ida;
    auto a = login3(ida, "new", 0);
    auto b = login(Ident());
    join(*b, room);
    join(*b, server);
    join(*b, elsewhere);
    join(*a, room);
    join(*a, server);
    check("(the rooms see it come)", next(*b, about("peer_joined", room, ida.peer)).has_value() &&
                                         next(*b, about("peer_joined", server, ida.peer)).has_value());
    a->send({{"type", "register_push_token"}, {"token", token}, {"platform", "android"}});
    check("(the device registers a token)", next(*a, typed("push_token_registered")).has_value());
    a->send({{"type", "inactive"}});
    check("(it is hidden)", next(*b, about("peer_left", room, ida.peer)).has_value());
    // What a sender that now counts it offline sends: a DM, a channel copy for an offline
    // member, a deposit in a room it is not in.
    b->send_bin(frame(0x04, {room, ida.peer}, "hp-direct"));
    b->send({{"type", "direct"}, {"room", room}, {"target", ida.peer}, {"data", "hp-json"}});
    b->send_bin(channel_frame(server, ida.peer, "chan", "hp-channel"));
    b->send_bin(frame(0x04, {elsewhere, ida.peer}, "hp-elsewhere"));
    check("its directs arrive live", next(*a, bin(frame(0x06, {room, b->id.peer}, "hp-direct"))).has_value() &&
                                         next(*a, json_where([](const json& j) {
                                             return j.value("type", "") == "direct" && j.value("data", "") == "hp-json";
                                         })).has_value());
    settle({b.get()});
    check("and nothing wakes it", !pushed(lfd, token, 1500));

    // The control: once its socket is gone, a member's direct does wake it.
    a->send({{"type", "active"}});
    check("(shown again)", next(*b, about("peer_joined", room, ida.peer)).has_value());
    const uint64_t read = a->ws.counted;
    a->ws.abort();
    check("(its socket drops)", next(*b, about("peer_left", room, ida.peer)).has_value());
    b->send_bin(frame(0x04, {room, ida.peer}, "hp-grace"));
    check("while a device in grace is woken as before", pushed(lfd, token, WAIT_MS));
    auto a2 = login3(ida, a->sid, read);
    check("(the session resumes)", resumed(*a2));
    a2->send({{"type", "unregister_push_token"}});
    sync(*a2);
    close(lfd);
}

static void test_hidden_pacing() {
    printf("presence: one socket's presence passes come at most one a pace\n");
    const std::string room = room_name("hide-pace");
    Ident ida;
    auto a = login3(ida, "new", 0);
    auto b = login(Ident());
    join(*b, room);
    join(*a, room);
    next(*b, about("peer_joined", room, ida.peer));
    const auto t0 = std::chrono::steady_clock::now();
    a->send({{"type", "inactive"}});
    a->send({{"type", "active"}});
    check("the first change is told at once", next(*b, about("peer_left", room, ida.peer)).has_value());
    settle({a.get(), b.get()});
    check("the next one waits", !got(*b, about("peer_joined", room, ida.peer)));
    auto back = next(*b, about("peer_joined", room, ida.peer));
    const auto waited =
        std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
    check("for the pace, then is told", back && waited >= PRESENCE_PACE_MS);

    std::vector<std::pair<uint8_t, std::string>> burst;
    for (int i = 0; i < 10; i++) {
        burst.push_back({0x1, R"({"type":"inactive"})"});
        burst.push_back({0x1, R"({"type":"active"})"});
    }
    a->ws.send_frames(burst);
    sleep_ms(PRESENCE_PACE_MS + 500);
    settle({a.get(), b.get()});
    check("a burst that ends where it began tells nobody anything",
          count(*b, about("peer_left", room, ida.peer)) == 0 && count(*b, about("peer_joined", room, ida.peer)) == 0);
    burst.clear();
    for (int i = 0; i < 10; i++) {
        burst.push_back({0x1, R"({"type":"active"})"});
        burst.push_back({0x1, R"({"type":"inactive"})"});
    }
    a->ws.send_frames(burst);
    check("one that ends hidden is told", next(*b, about("peer_left", room, ida.peer)).has_value());
    sleep_ms(PRESENCE_PACE_MS + 500);
    settle({a.get(), b.get()});
    check("once", count(*b, about("peer_left", room, ida.peer)) == 0 && count(*b, about("peer_joined", room, ida.peer)) == 0);

    // A pass owed when the session moves to another socket comes there, at the old pace.
    a->send({{"type", "active"}});
    check("(shown)", next(*b, about("peer_joined", room, ida.peer)).has_value());
    const auto t1 = std::chrono::steady_clock::now();
    a->send({{"type", "inactive"}});
    sync(*a);
    auto a2 = login3(ida, a->sid, a->ws.counted);
    check("(it moves)", resumed(*a2) && closed_by_relay(*a));
    auto owed = next(*b, about("peer_left", room, ida.peer));
    const auto owed_ms =
        std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t1).count();
    check("a pass owed across a move still comes, no sooner", owed && owed_ms >= PRESENCE_PACE_MS - 200);

    // An entry left queued by a socket that died never runs the next socket's pass early:
    // the show owed here goes with its socket, and the resume shows the device itself.
    a2->send({{"type", "active"}});
    sync(*a2);
    const uint64_t read = a2->ws.counted;
    a2->ws.abort();
    sleep_ms(300);
    auto a3 = login3(ida, a->sid, read);
    check("(it resumes, shown)", resumed(*a3) && next(*b, about("peer_joined", room, ida.peer)).has_value());
    const auto t2 = std::chrono::steady_clock::now();
    a3->send({{"type", "inactive"}});
    a3->send({{"type", "active"}});
    check("(hidden at once)", next(*b, about("peer_left", room, ida.peer)).has_value());
    auto late = next(*b, about("peer_joined", room, ida.peer));
    const auto late_ms =
        std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t2).count();
    check("the next socket's pass keeps its own pace", late && late_ms >= PRESENCE_PACE_MS);

    // Each socket's pace ends at its own time: a pass queued later may be due sooner. Here y's
    // show falls due about 1.7 s before the one a3 queued just ahead of it.
    sleep_ms(PRESENCE_PACE_MS);
    Ident idy;
    auto y = login3(idy, "new", 0);
    join(*y, room);
    check("(another device comes)", next(*b, about("peer_joined", room, idy.peer)).has_value());
    y->send({{"type", "inactive"}});
    check("(and hides)", next(*b, about("peer_left", room, idy.peer)).has_value());
    sleep_ms(PRESENCE_PACE_MS - 300);
    a3->send({{"type", "inactive"}});
    a3->send({{"type", "active"}});
    check("(a3 hides at once, its show queued)", next(*b, about("peer_left", room, ida.peer)).has_value());
    const auto t3 = std::chrono::steady_clock::now();
    y->send({{"type", "active"}});
    auto soon = next(*b, about("peer_joined", room, idy.peer));
    const auto soon_ms =
        std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t3).count();
    check("a pass due sooner never waits behind one queued before it", soon && soon_ms < PRESENCE_PACE_MS - 800);
}

// The relay's PRESENCE_PASS_US_PER_PEER (state.h): the gap after a pass grows with what it walked.
static constexpr int PRESENCE_US_PER_PEER = 250;

static void test_hidden_big_pass() {
    printf("presence: after a pass over many peers the next one waits longer\n");
    const int rooms = 4000;
    Ident ida;
    auto a = login3(ida, "new", 0);
    auto b = login(Ident());
    std::vector<std::pair<uint8_t, std::string>> joins;
    for (int i = 0; i < rooms; i++) {
        joins.push_back({0x1, json{{"type", "join"}, {"room", room_name("hide-big") + "-" + std::to_string(i)}}.dump()});
    }
    // Bursts are read whole and dropped before any barrier: `sync` parses its whole inbox again
    // for every frame that arrives.
    const auto drain = [](Peer& p) {
        while (p.ws.pump(500)) {
        }
        p.ws.inbox.clear();
        sync(p);
        p.ws.inbox.clear();
    };
    a->ws.send_frames(joins);
    drain(*a);
    b->ws.send_frames(joins);
    drain(*b);
    drain(*a);
    const auto of_a = [&](const char* type) {
        return [&ida, type](const json& j) { return j.value("type", "") == type && j.value("peer_id", "") == ida.peer; };
    };
    const auto t0 = std::chrono::steady_clock::now();
    a->send({{"type", "inactive"}});
    a->send({{"type", "active"}});
    // Read the burst whole, then judge it once: `next` would parse the inbox again per frame.
    while (b->ws.pump(300)) {
    }
    const auto told = std::count_if(b->ws.inbox.begin(), b->ws.inbox.end(),
                                    [&](const Frame& f) { return is_json(f, of_a("peer_left")); });
    check("(the hide is told in every room)", told == rooms);
    b->ws.inbox.clear();
    const bool shown = b->ws.pump(15000);
    const auto waited =
        std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
    // Each room walked counts once and once per peer in it: here the device and one other.
    check("the show waits a gap that grows with the peers walked",
          shown && is_json(b->ws.inbox.front(), of_a("peer_joined")) &&
              waited >= static_cast<int64_t>(rooms) * 3 * PRESENCE_US_PER_PEER / 1000);
    printf("  (the show came %lld ms after the hide)\n", static_cast<long long>(waited));
}

static json successor_link(const std::string& server, uint64_t n, const Door& door, const Ident& change,
                           const Ident& signer);

// `through_grace` waits out the 60 s door grace too (RELAY_LIVE_ONLY=door_grace).
static void test_hidden_door_rooms(bool through_grace) {
    printf("presence: a hidden device in a locked room is shown to no prover%s\n",
           through_grace ? ", through the door's grace" : "");
    Ident owner, change, change2;
    Door door, door2;
    const std::string nonce = random_hex(16);
    const std::string room = genesis_server_id(owner.peer, nonce);
    const json base = base_link(room, door, change, owner, nonce, true);
    auto b = login(Ident());
    b->send({{"type", "lock_put"}, {"server", room}, {"owner", ""}, {"links", base}});
    next(*b, typed("lock_chain"));
    join(*b, room, {{"door_proof", door_proof(*b, room, door)}});
    Ident ida, idd;
    auto a = login3(ida, "new", 0);
    join(*a, room, {{"door_proof", door_proof(*a, room, door)}});
    check("(a prover sees it come)", next(*b, about("peer_joined", room, ida.peer)).has_value());
    a->send({{"type", "inactive"}});
    check("(it is hidden)", next(*b, about("peer_left", room, ida.peer)).has_value());
    auto d = login3(idd, "new", 0);
    d->send({{"type", "inactive"}});
    auto md = join(*d, room, {{"door_proof", door_proof(*d, room, door2)}});
    auto c = login(Ident());
    auto mc = join(*c, room, {{"door_proof", door_proof(*c, room, door2)}});
    check("(two hold the next door before the lock does)",
          md && !md->value("proved", true) && mc && !mc->value("proved", true));
    json links = base;
    links.push_back(successor_link(room, 2, door2, change2, change));
    b->send({{"type", "lock_put"}, {"server", room}, {"owner", ""}, {"links", links}});
    auto put = next_json(*b, typed("lock_chain"));
    check("(the lock moves to it)", put && put->value("put", false));
    auto m = next_json(*c, typed("members", room));
    check("a device the move proves is shown the room without the hidden ones",
          m && m->value("proved", false) && peers_of(*m) == std::set<std::string>{b->id.peer, c->id.peer});
    check("the provers are told it came", next(*b, about("peer_joined", room, c->id.peer)).has_value());
    settle({b.get()});
    check("but not of the hidden one the move proved", !got(*b, about("peer_joined", room, idd.peer)));
    if (!through_grace) return;
    // Past the door grace and its 5 s sweep, every socket kept alive meanwhile: the old
    // door's grace ends for a, hidden, and for b, shown.
    const auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(door_room::GRACE_MS + 7000);
    while (left_ms(until) > 0) {
        sleep_ms(std::min(5000, left_ms(until)));
        for (Peer* p : {a.get(), b.get(), c.get(), d.get()}) sync(*p);
    }
    settle({b.get(), c.get()});
    check("a hidden device's door grace ends with nothing said", !got(*c, about("peer_left", room, ida.peer)));
    check("a shown one's with its departure", got(*c, about("peer_left", room, b->id.peer)));
}

static void test_hidden_inbox_owner() {
    printf("presence: an owner the roster drops while hidden leaves its siblings once\n");
    Ident master, d1, d2;
    const std::string inbox = "inbox:" + master.peer;
    auto a = login3(d1, "new", 0);
    auto b = login(d2);
    join(*b, inbox, {{"inbox_roster", legacy_roster(master, {&d1, &d2})}});
    join(*a, inbox, {{"inbox_roster", legacy_roster(master, {&d1, &d2})}});
    check("(its sibling sees it)", next(*b, about("peer_joined", inbox, d1.peer)).has_value());
    a->send({{"type", "inactive"}});
    check("a sibling is told it left too", next(*b, about("peer_left", inbox, d1.peer)).has_value());
    join(*b, inbox, {{"inbox_roster", roster_removing(master, {&d1, &d2}, d1, d2)}});
    settle({b.get()});
    check("the roster dropping it tells the sibling nothing more", !got(*b, about("peer_left", inbox, d1.peer)));
}

static void test_hidden() {
    test_hidden_presence();
    test_hidden_session();
    test_hidden_no_push();
    test_hidden_pacing();
    test_hidden_big_pass();
    test_hidden_door_rooms(false);
    test_hidden_inbox_owner();
}

// ---------------------------------------------------------------------------
// Hostile review of the resume handshake and the session's authority
// (RESUMABLE_SESSIONS_PLAN.md section 4, audit file rs_handshake_review.md). Each case is
// something a stranger, a sibling or a client with its own valid keys tries; each must be
// refused or change nothing.

// A fresh socket of `id` holding its challenge, not logged in.
static std::unique_ptr<Peer> challenged(const Ident& id) {
    auto p = open_socket(id);
    p->send({{"type", "auth_hello"}});
    auto ch = next_json(*p, typed("auth_challenge"));
    if (ch) {
        p->challenge = *ch;
        p->nonce = ch->value("nonce", "");
        p->relay_key = ch->value("door_key", "");
    }
    return p;
}

// A v3 auth frame with each field as given; the signature covers `signed_msg`.
static json auth3_frame(const Ident& id, const std::string& nonce, const json& session, const json& in_h,
                        uint64_t ts, const std::string& domain, const std::string& signed_msg) {
    return {{"type", "auth"},    {"v", 3},           {"peer_id", id.peer}, {"public_key", id.pub_b64},
            {"timestamp", ts},   {"nonce", nonce},   {"domain", domain},   {"session", session},
            {"in_h", in_h},      {"signature", id.sign(signed_msg)}};
}

static std::string v3_bytes(const Peer& p, const std::string& session, uint64_t in_h, uint64_t ts,
                            const std::string& mode = "full") {
    return auth_v3_message(g_domain, p.nonce, p.id.peer, ts, mode, "", session, in_h);
}

// The relay's answer to `auth` on `p`: "auth_ok", "auth_failed", "resumed", or "" for none.
static std::string answer_to(Peer& p, const json& auth, int timeout_ms = 3000) {
    p.send(auth);
    auto r = next_json(p, json_where([](const json& j) {
        const std::string t = j.value("type", "");
        return t == "auth_ok" || t == "auth_failed" || t == "resumed";
    }), timeout_ms);
    p.answer = r ? *r : json::object();
    return r ? r->value("type", "") : "";
}

static void hs_sids() {
    printf("handshake review: another device's sid opens nothing and costs its owner nothing\n");
    Ident d1, d2, stranger;
    const std::string room = room_name("hs-sid");
    auto a = login3(d1, "new", 0);
    auto sib = login3(d2, "new", 0);
    auto b = login(Ident());
    join(*a, room);
    join(*b, room);
    const uint64_t read = a->ws.counted;
    a->ws.abort();
    check("the device is in grace", next(*b, about("peer_left", room, d1.peer)).has_value());
    b->send_bin(frame(0x04, {room, d1.peer}, "hs-in-grace"));
    settle({b.get()});

    auto by_sibling = login3(d2, a->sid, read);
    check("a sibling naming the device's sid, signed with its own key, gets a fresh session of its own",
          answer_type(*by_sibling) == "auth_ok" && resume_failed(*by_sibling) == "unknown" &&
              is_sid(by_sibling->sid) && by_sibling->sid != a->sid);
    auto by_stranger = login3(stranger, a->sid, read);
    auto guess = login3(Ident(), random_hex(16), 0);
    check("a stranger naming it is answered exactly like a guess",
          resume_failed(*by_stranger) == "unknown" && keys_of(by_stranger->answer) == keys_of(guess->answer) &&
              keys_of(by_sibling->answer) == keys_of(guess->answer));

    // The device's id with another key: refused at the key binding, its session untouched.
    auto forged = challenged(d1);
    const uint64_t ts = now_unix_secs();
    json f = auth3_frame(stranger, forged->nonce, a->sid, read, ts, g_domain,
                         auth_v3_message(g_domain, forged->nonce, d1.peer, ts, "full", "", a->sid, read));
    f["peer_id"] = d1.peer;
    check("a resume claiming the device's id with another key is refused", answer_to(*forged, f) == "auth_failed");
    for (const std::string mode : {"full", "guest"}) {
        auto v2 = challenged(d1);
        json j = {{"type", "auth"},       {"v", 2},           {"peer_id", d1.peer}, {"public_key", stranger.pub_b64},
                  {"timestamp", ts},      {"nonce", v2->nonce}, {"domain", g_domain},
                  {"signature", stranger.sign(auth_v2_message(g_domain, v2->nonce, d1.peer, ts, mode, ""))}};
        if (mode == "guest") j["guest"] = true;
        check("so is a v2 " + mode + " login that would end its session", answer_to(*v2, j) == "auth_failed");
    }

    auto back = login3(d1, a->sid, read);
    check("the device still resumes its own session", resumed(*back));
    check("with the frame its ring took during grace",
          next(*back, bin(frame(0x06, {room, b->id.peer}, "hs-in-grace"))).has_value());
    b->send_bin(frame(0x04, {room, d1.peer}, "hs-after"));
    check("and its directs reach it", next(*back, bin(frame(0x06, {room, b->id.peer}, "hs-after"))).has_value());

    // The device's own push isolate holds no session: its session controls touch none.
    auto fetch = login3(d1, "none", 0, "fetch");
    fetch->send({{"type", "inactive"}});
    fetch->send({{"type", "end"}});
    check("its fetch socket's heartbeat names no session", hb(*fetch, 0).value("h", 1) == 0);
    auto c = login(Ident());
    join(*c, room);
    check("a fetch socket's inactive mutes nothing", next(*back, about("peer_joined", room, c->id.peer)).has_value());
    const uint64_t back_read = back->ws.counted;
    back->ws.abort();
    check("and its end ends nothing", resumed(*login3(d1, a->sid, back_read)));
}

static void hs_replays_and_shapes() {
    printf("handshake review: replayed, grafted and malformed v3 frames are refused\n");
    Ident id;
    auto a = login3(id, "new", 0);
    const uint64_t read = a->ws.counted;
    a->ws.abort();

    // A genuine resume frame, made for one socket's challenge, then shown to another.
    auto x = challenged(id);
    x->ws.counted = read;
    const uint64_t ts = now_unix_secs();
    const json genuine = auth3_frame(id, x->nonce, a->sid, read, ts, g_domain, v3_bytes(*x, a->sid, read, ts));
    auto y = challenged(id);
    check("a resume frame replayed on another socket is refused", answer_to(*y, genuine) == "auth_failed");
    check("and that socket is closed", closed_by_relay(*y));
    auto cold = open_socket(id);
    check("so is one sent to a socket that never asked for a challenge", answer_to(*cold, genuine) == "auth_failed");
    check("the session it named is untouched", answer_to(*x, genuine) == "resumed");
    check("one frame, one attempt: a second auth on a logged-in socket is not answered",
          answer_to(*x, genuine, 1000).empty() && !x->ws.closed());
    check("and the socket keeps its session", hb(*x, read).value("h", 1) == 0);
    const uint64_t x_read = x->ws.counted;
    x->ws.abort();

    struct Case {
        const char* what;
        std::function<void(json&, const Peer&)> edit;
    };
    const std::string sid = a->sid;
    // Signed over exactly what the frame says, so the shape rule alone has to refuse it
    // (a signature that also failed would hide a missing rule).
    auto signed_as_sent = [&](json& j, const Peer& p) {
        auto field = [&](const char* k) { auto it = j.find(k); return it == j.end() ? json() : *it; };
        const bool guest = field("guest").is_boolean() && field("guest").get<bool>();
        const bool fetch = field("fetch").is_boolean() && field("fetch").get<bool>();
        const std::string mode = guest ? "guest" : fetch ? "fetch" : "full";
        const std::string session = field("session").is_string() ? field("session").get<std::string>() : field("session").dump();
        const uint64_t in_h = field("in_h").is_number_unsigned() ? field("in_h").get<uint64_t>() : 0;
        j["signature"] = id.sign(auth_v3_message(g_domain, p.nonce, id.peer, ts, mode, "", session, in_h));
    };
    const std::vector<Case> shapes = {
        {"in_h as text", [&](json& j, const Peer&) { j["in_h"] = std::to_string(x_read); }},
        {"in_h negative", [&](json& j, const Peer&) { j["in_h"] = -1; }},
        {"in_h fractional", [&](json& j, const Peer&) { j["in_h"] = 1.5; }},
        {"in_h past 64 bits", [&](json& j, const Peer&) { j["in_h"] = 1e30; }},
        {"no in_h", [&](json& j, const Peer&) { j.erase("in_h"); }},
        {"no session", [&](json& j, const Peer&) { j.erase("session"); }},
        {"a null session", [&](json& j, const Peer&) { j["session"] = nullptr; }},
        {"a numeric session", [&](json& j, const Peer&) { j["session"] = 7; }},
        {"an uppercase sid", [&](json& j, const Peer&) { j["session"] = "00112233445566778899AABBCCDDEEFF"; }},
        {"a 31-character sid", [&](json& j, const Peer&) { j["session"] = std::string(31, 'a'); }},
        {"a 33-character sid", [&](json& j, const Peer&) { j["session"] = std::string(33, 'a'); }},
        {"a sid with a non-hex character", [&](json& j, const Peer&) { j["session"] = std::string(31, 'a') + "g"; }},
        {"\"new\" with a count", [&](json& j, const Peer&) { j["session"] = "new"; j["in_h"] = 1; }},
        {"\"none\" with a count", [&](json& j, const Peer&) { j["fetch"] = true; j["session"] = "none"; j["in_h"] = 1; }},
        {"a full socket asking for none", [&](json& j, const Peer&) { j["session"] = "none"; j["in_h"] = 0; }},
        {"a fetch socket asking to resume", [&](json& j, const Peer&) { j["fetch"] = true; }},
        {"a fetch socket asking for a new one", [&](json& j, const Peer&) { j["fetch"] = true; j["session"] = "new"; j["in_h"] = 0; }},
        {"a guest asking to resume", [&](json& j, const Peer&) { j["guest"] = true; }},
        {"a guest asking for a new one", [&](json& j, const Peer&) { j["guest"] = true; j["session"] = "new"; j["in_h"] = 0; }},
        {"a socket claiming fetch and guest", [&](json& j, const Peer&) { j["fetch"] = true; j["guest"] = true; j["session"] = "none"; j["in_h"] = 0; }},
        {"version 4", [&](json& j, const Peer&) { j["v"] = 4; }},
        {"version as text", [&](json& j, const Peer&) { j["v"] = "3"; }},
    };
    for (const auto& c : shapes) {
        auto p = challenged(id);
        json j = auth3_frame(id, p->nonce, sid, x_read, ts, g_domain, v3_bytes(*p, sid, x_read, ts));
        c.edit(j, *p);
        signed_as_sent(j, *p);
        check(std::string("refused by its shape: ") + c.what, answer_to(*p, j) == "auth_failed");
    }
    const std::vector<Case> refused = {
        {"signed for another relay",
         [&](json& j, const Peer& p) {
             j["domain"] = "another.relay";
             j["signature"] = id.sign(auth_v3_message("another.relay", p.nonce, id.peer, ts, "full", "", sid, x_read));
         }},
        // A clock off by minutes is no refusal since issue #72 (test_clock); the stamp
        // is still signed.
        {"a timestamp the signature does not cover", [&](json& j, const Peer&) { j["timestamp"] = ts - 120; }},
        {"a v3 frame signed with v2 bytes",
         [&](json& j, const Peer& p) { j["signature"] = id.sign(auth_v2_message(g_domain, p.nonce, id.peer, ts, "full", "")); }},
        {"a v2 frame signed with v3 bytes", [&](json& j, const Peer&) { j["v"] = 2; }},
        {"a count the signature does not cover", [&](json& j, const Peer&) { j["in_h"] = x_read + 1; }},
        {"a sid the signature does not cover", [&](json& j, const Peer&) { j["session"] = random_hex(16); }},
    };
    for (const auto& c : refused) {
        auto p = challenged(id);
        json j = auth3_frame(id, p->nonce, sid, x_read, ts, g_domain, v3_bytes(*p, sid, x_read, ts));
        c.edit(j, *p);
        check(std::string("refused: ") + c.what, answer_to(*p, j) == "auth_failed");
    }
    auto again = login3(id, sid, x_read);
    check("none of them touched the session", resumed(*again));

    // A v2 frame carrying session fields: the relay reads no session from it.
    Ident other;
    auto v = challenged(other);
    json v2 = {{"type", "auth"},  {"v", 2},           {"peer_id", other.peer}, {"public_key", other.pub_b64},
               {"timestamp", ts}, {"nonce", v->nonce}, {"domain", g_domain},    {"session", sid},
               {"in_h", 0},       {"signature", other.sign(auth_v2_message(g_domain, v->nonce, other.peer, ts, "full", ""))}};
    check("a v2 frame with session fields logs in without any session",
          answer_to(*v, v2) == "auth_ok" && v->answer == json{{"type", "auth_ok"}});
}

// A legacy-base roster for `master` with `devices` and each listed removal.
static json hs_roster(const Ident& master, const std::vector<const Ident*>& devices,
                      const std::vector<std::pair<const Ident*, const Ident*>>& removals) {
    roster::Roster r = roster::Roster::named(master.peer);
    for (const auto* d : devices) {
        r.legacy.push_back({d->peer, master.sign(roster::legacy_payload(master.peer, d->peer))});
        r.consents.push_back({d->peer, d->sign(roster::consent_payload(master.peer, d->peer))});
    }
    for (const auto& [gone, by] : removals) {
        roster::Removal x;
        x.base = roster::LEGACY_BASE;
        x.device = gone->peer;
        x.by = by->peer;
        x.sig = by->sign(roster::removal_payload(master.peer, roster::LEGACY_BASE, gone->peer, {}));
        r.removals.push_back(x);
    }
    return json::parse(roster::to_json(r).dump());
}

static void hs_removed_in_grace() {
    printf("handshake review: a device removed during grace keeps no inbox, gap or not\n");
    Ident master, d1, d2;
    const std::string inbox = "inbox:" + master.peer;
    const std::string room = room_name("hs-rm");
    auto a = login3(d1, "new", 0);
    auto m = join(*a, inbox, {{"inbox_roster", hs_roster(master, {&d1, &d2}, {})}});
    check("the device owns the inbox", m && peers_of(*m) == std::set<std::string>{d1.peer});
    join(*a, room);
    auto b = login(d2);
    join(*b, inbox, {{"inbox_roster", hs_roster(master, {&d1, &d2}, {})}});
    auto s = login(Ident());
    join(*s, inbox);
    join(*s, room);
    const uint64_t read = a->ws.counted;
    a->ws.abort();
    check("its sibling sees it go", next(*b, about("peer_left", inbox, d1.peer)).has_value());
    join(*b, inbox, {{"inbox_roster", hs_roster(master, {&d1, &d2}, {{&d1, &d2}})}});
    s->send_bin(frame(0x04, {inbox, master.peer}, "hs-mail-after-removal"));
    check("the deposit reaches the owner left", next(*b, bin(frame(0x06, {inbox, s->id.peer}, "hs-mail-after-removal"))).has_value());
    // Overflow the ring, so the resume reports a gap.
    for (int i = 0; i < 9; i++) s->send_bin(frame(0x03, {room}, std::string(1024 * 1024, 'r') + std::to_string(i)));
    settle({s.get()});
    auto a2 = login3(d1, a->sid, read);
    check("the session resumes with a gap", resumed(*a2) && a2->answer.value("gap", false));
    auto m2 = next_json(*a2, typed("members", inbox));
    check("seeing only itself in the inbox", m2 && peers_of(*m2) == std::set<std::string>{d1.peer});
    settle({a2.get()});
    check("its gapped resume replays no mailbox of the inbox it lost",
          !got(*a2, bin(frame(0x06, {inbox, s->id.peer}, "hs-mail-after-removal"))));
    auto stale = join(*a2, inbox, {{"inbox_roster", hs_roster(master, {&d1, &d2}, {})}});
    check("its own stale roster, shown again, makes it no owner", stale && peers_of(*stale) == std::set<std::string>{d1.peer});
    settle({a2.get()});
    check("and replays no mailbox", !got(*a2, bin(frame(0x06, {inbox, s->id.peer}, "hs-mail-after-removal"))));
    s->send_bin(frame(0x04, {inbox, master.peer}, "hs-mail-later"));
    check("a later deposit reaches the owner", next(*b, bin(frame(0x06, {inbox, s->id.peer}, "hs-mail-later"))).has_value());
    settle({s.get(), a2.get()});
    check("and not the removed device", !got(*a2, bin(frame(0x06, {inbox, s->id.peer}, "hs-mail-later"))));
    check("nor is it announced to the owner", !got(*b, about("peer_joined", inbox, d1.peer)));
}

// The phrase recovers the identity while the device sits in grace, keeping only its sibling.
static void hs_recovered_in_grace() {
    printf("handshake review: a recovery during grace that leaves the device out takes its inbox\n");
    Ident master, d1, d2, phrase;
    const std::string inbox = "inbox:" + master.peer;
    auto a = login3(d1, "new", 0);
    auto m = join(*a, inbox, {{"inbox_roster", hs_roster(master, {&d1, &d2}, {})}});
    check("the device owns the inbox", m && peers_of(*m) == std::set<std::string>{d1.peer});
    auto b = login(d2);
    join(*b, inbox, {{"inbox_roster", hs_roster(master, {&d1, &d2}, {})}});
    const uint64_t read = a->ws.counted;
    a->ws.abort();
    check("its sibling sees it go", next(*b, about("peer_left", inbox, d1.peer)).has_value());
    json recovered = hs_roster(master, {&d1, &d2}, {});
    const std::string r_pub = b64(phrase.pk, sizeof(phrase.pk));
    const int64_t at = wall_ms() - 1000;
    const std::string p = roster::recovery_payload(master.peer, r_pub, at, {d2.peer}, false);
    recovered["r_pub"] = r_pub;
    json recovery = {{"at_ms", at}, {"sig_r", phrase.sign(p)}, {"sig_m", master.sign(p)}};
    recovery["keep"] = json::array({d2.peer});
    recovered["recoveries"] = json::array({recovery});
    auto mb = join(*b, inbox, {{"inbox_roster", recovered}});
    check("the recovery keeps the sibling", mb && peers_of(*mb) == std::set<std::string>{d2.peer});
    auto s = login(Ident());
    join(*s, inbox);
    s->send_bin(frame(0x04, {inbox, master.peer}, "hs-mail-after-recovery"));
    check("a deposit reaches the sibling", next(*b, bin(frame(0x06, {inbox, s->id.peer}, "hs-mail-after-recovery"))).has_value());
    auto a2 = login3(d1, a->sid, read);
    check("the session resumes", resumed(*a2));
    auto m2 = next_json(*a2, typed("members", inbox));
    check("without the inbox", m2 && peers_of(*m2) == std::set<std::string>{d1.peer});
    settle({a2.get(), b.get()});
    check("and with nothing deposited after the recovery",
          !got(*a2, bin(frame(0x06, {inbox, s->id.peer}, "hs-mail-after-recovery"))));
    auto stale = join(*a2, inbox, {{"inbox_roster", hs_roster(master, {&d1, &d2}, {})}});
    check("its roster from before the recovery makes it no owner", stale && peers_of(*stale) == std::set<std::string>{d1.peer});
}

static void hs_moved_socket() {
    printf("handshake review: a socket the session moved away from acts on nothing\n");
    signal(SIGPIPE, SIG_IGN);
    const std::string room = room_name("hs-mv"), room2 = room_name("hs-mv2");
    Ident ida;
    auto a = login3(ida, "new", 0);
    auto b = login(Ident());
    join(*a, room);
    join(*b, room);
    b->send_bin(frame(0x04, {room, ida.peer}, "hs-mv-0"));
    next(*a, bin(frame(0x06, {room, b->id.peer}, "hs-mv-0")));
    auto a2 = login3(ida, a->sid, a->ws.counted);
    check("the session moves", resumed(*a2));
    // The old socket has not read its close yet and keeps writing.
    a->send_bin(frame(0x03, {room}, "hs-from-moved"));
    a->send({{"type", "msg"}, {"room", room}, {"data", "hs-moved-msg"}});
    a->send_bin(frame(0x04, {room, b->id.peer}, "hs-moved-direct"));
    a->send({{"type", "join"}, {"room", room2}});
    a->send({{"type", "leave"}, {"room", room}});
    a->send({{"type", "end"}});
    a->send({{"type", "hb"}, {"h", 0}});
    settle({a2.get(), b.get()});
    check("nothing it sends reaches the room", !got(*b, bin(frame(0x05, {room, ida.peer}, "hs-from-moved"))) &&
                                                   !got(*b, json_where([](const json& j) { return j.value("data", "") == "hs-moved-msg"; })) &&
                                                   !got(*b, bin(frame(0x06, {room, ida.peer}, "hs-moved-direct"))));
    check("its leave and end change nothing: the room still lists the device", discover(*b, room) == std::set<std::string>{ida.peer});
    b->send_bin(frame(0x04, {room, ida.peer}, "hs-mv-1"));
    check("the room slot stays the new socket's", next(*a2, bin(frame(0x06, {room, b->id.peer}, "hs-mv-1"))).has_value());
    auto m = join(*b, room2);
    check("its join took no room", m && peers_of(*m) == std::set<std::string>{b->id.peer});
    const uint64_t read = a2->ws.counted;
    a2->ws.abort();
    check("the session is still there to resume", resumed(*login3(ida, a->sid, read)));
}

static void hs_hostile_counts() {
    printf("handshake review: counts and acks a client lies about\n");
    Ident id;
    auto a = login3(id, "new", 0);
    const uint64_t base = hb(*a, 0).value("h", 99);
    for (const json& h : {json(-1), json(1.5), json("3"), json(nullptr), json(UINT64_MAX), json(1e30)}) {
        a->send({{"type", "ack"}, {"h", h}});
        a->send({{"type", "hb"}, {"h", h}});
    }
    a->send({{"type", "ack"}});
    a->send({{"type", "hb"}});
    size_t answers = 0;
    while (next(*a, typed("hb_ack"), 2000)) {
        if (++answers == 7) break;
    }
    check("every heartbeat is answered, malformed or not", answers == 7);
    a->send({{"type", "gap"}, {"n", 1000}});
    check("a gap frame from a client counts as one", hb(*a, 0).value("h", 0) == base + 1);
    const uint64_t read = a->ws.counted;
    a->ws.abort();
    auto big = login3(id, a->sid, UINT64_MAX);
    check("a count of 2^64-1 is bad_h, nothing worse", resume_failed(*big) == "bad_h" && is_sid(big->sid));
    check("(the earlier session is gone with it)", resume_failed(*login3(id, a->sid, read)) == "unknown");
}

// RED before HOL-SEC-164: one `active` frame made the relay build a members snapshot for
// every room the session holds, a CPU cost a client could ask for at will.
static void hs_active_costs_what_was_withheld() {
    printf("handshake review: active answers only for presence it withheld\n");
    const int rooms = 40;
    Ident ida;
    auto a = login3(ida, "new", 0);
    for (int i = 0; i < rooms; i++) a->send({{"type", "join"}, {"room", room_name("hs-act") + std::to_string(i)}});
    settle({a.get()});
    check("the device holds every room", count(*a, typed("members")) == static_cast<size_t>(rooms));
    const std::string watched = room_name("hs-act") + "7";
    auto b = login(Ident());
    join(*b, watched);
    next(*a, about("peer_joined", watched, b->id.peer));

    a->send({{"type", "active"}});
    settle({a.get()});
    check("active with nothing withheld sends no members", count(*a, typed("members")) == 0);
    a->send({{"type", "inactive"}});
    a->send({{"type", "active"}});
    settle({a.get()});
    check("nor does a toggle with nothing in between", count(*a, typed("members")) == 0);

    a->send({{"type", "inactive"}});
    sync(*a);
    auto c = login(Ident());
    join(*c, watched);
    settle({c.get(), a.get()});
    check("presence is withheld while inactive", !got(*a, about("peer_joined", watched, c->id.peer)));
    a->send({{"type", "active"}});
    settle({a.get()});
    size_t members = 0;
    bool right = false;
    for (auto it = a->ws.inbox.begin(); it != a->ws.inbox.end();) {
        auto j = as_json(*it);
        if (j && j->value("type", "") == "members") {
            members++;
            right = j->value("room", "") == watched &&
                    peers_of(*j) == std::set<std::string>{ida.peer, b->id.peer, c->id.peer};
            it = a->ws.inbox.erase(it);
        } else {
            ++it;
        }
    }
    check("active sends members for the one room whose presence it withheld", members == 1 && right);
    a->send({{"type", "inactive"}});
    a->send({{"type", "active"}});
    settle({a.get()});
    check("and owes nothing after it", count(*a, typed("members")) == 0);
    c->send({{"type", "leave"}, {"room", watched}});
    check("and presence flows again", next(*a, about("peer_left", watched, c->id.peer)).has_value());
}

// RED before HOL-SEC-165: a heartbeat resets the relay's ack window, and every frame after
// it queued another ack timer, one queue entry per (frame, hb) pair a client sends.
static void hs_one_ack_timer() {
    printf("handshake review: a reset ack window never queues a second timer\n");
    Ident id;
    auto a = login3(id, "new", 0);
    const auto t0 = std::chrono::steady_clock::now();
    a->send({{"type", "discover_peers"}, {"room", room_name("hs-ack0")}});
    next(*a, typed("discovered_peers"));
    hb(*a, a->ws.counted);
    // Late in the first window: a second timer would ack near 3.9 s, the first one by 2.25 s.
    sleep_ms(std::max(0, 1900 - static_cast<int>(std::chrono::duration_cast<std::chrono::milliseconds>(
                                                    std::chrono::steady_clock::now() - t0).count())));
    a->send({{"type", "discover_peers"}, {"room", room_name("hs-ack1")}});
    auto ack = next_json(*a, typed("ack"), 3500);
    const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
    check("the ack comes by the first frame's deadline", ack && ack->value("h", 0) == 2 && ms < 3000);
}

static void hs_push_reach() {
    printf("handshake review: grace gives a stranger no new way to wake a phone\n");
    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in at{};
    at.sin_family = AF_INET;
    at.sin_port = htons(3001);
    at.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int one = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (lfd < 0 || bind(lfd, reinterpret_cast<sockaddr*>(&at), sizeof(at)) != 0 || listen(lfd, 8) != 0) {
        if (lfd >= 0) close(lfd);
        printf("  skip push reach (127.0.0.1:3001 is taken)\n");
        return;
    }
    // Only a post naming this run's token counts: another relay on the machine may post here.
    const std::string token = "hs-token-" + g_tag;
    auto woken = [lfd, token](int timeout_ms) {
        auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
        while (left_ms(deadline) > 0) {
            pollfd p{lfd, POLLIN, 0};
            if (poll(&p, 1, left_ms(deadline)) <= 0) return false;
            int c = accept(lfd, nullptr, nullptr);
            if (c < 0) return false;
            std::string req;
            char buf[4096];
            for (int i = 0; i < 4; i++) {
                pollfd q{c, POLLIN, 0};
                if (poll(&q, 1, 300) <= 0) break;
                ssize_t n = read(c, buf, sizeof(buf));
                if (n <= 0) break;
                req.append(buf, static_cast<size_t>(n));
            }
            const std::string ok = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            (void)!write(c, ok.data(), ok.size());
            close(c);
            if (req.find(token) != std::string::npos) return true;
        }
        return false;
    };
    const std::string room = room_name("hs-push");
    Ident ida;
    auto a = login3(ida, "new", 0);
    auto b = login(Ident());
    join(*a, room);
    join(*b, room);
    a->send({{"type", "register_push_token"}, {"token", token}, {"platform", "android"}});
    next(*a, typed("push_token_registered"));
    const uint64_t read = a->ws.counted;
    a->ws.abort();
    check("the device is in grace", next(*b, about("peer_left", room, ida.peer)).has_value());
    auto s = login(Ident());
    s->send_bin(frame(0x04, {room, ida.peer}, "hs-outside"));
    s->send({{"type", "direct"}, {"room", room}, {"target", ida.peer}, {"data", "hs-outside-json"}});
    s->send_bin(frame(0x02, {room, ida.peer}, "hs-outside-chunk"));
    auto g = login(Ident(), "guest");
    join(*g, room);
    g->send_bin(frame(0x04, {room, ida.peer}, "hs-guest"));
    g->send({{"type", "direct"}, {"room", room}, {"target", ida.peer}, {"data", "hs-guest-json"}});
    settle({s.get(), g.get()});
    check("a stranger outside the room it holds, or a guest in it, wakes nothing", !woken(1000));
    b->send_bin(frame(0x04, {room, ida.peer}, "hs-member"));
    check("while a member's direct does", woken(WAIT_MS));
    auto a2 = login3(ida, a->sid, read);
    check("the session resumes", resumed(*a2));
    settle({a2.get()});
    check("and its ring took none of it",
          !got(*a2, bin(frame(0x06, {room, s->id.peer}, "hs-outside"))) &&
              !got(*a2, json_where([](const json& j) { return j.value("data", "").rfind("hs-", 0) == 0; })) &&
              !got(*a2, bin(frame(0x02, {room, s->id.peer}, "hs-outside-chunk"))) &&
              !got(*a2, bin(frame(0x06, {room, g->id.peer}, "hs-guest"))));
    a2->send({{"type", "unregister_push_token"}});
    sync(*a2);
    close(lfd);
}

// A push wakes the device while its session is in grace: its fetch socket's join reads the
// DMs that session's ring holds for that room, and only those, leaving them for the resume.
static void hs_fetch_reads_grace_dms() {
    printf("handshake review: a fetch socket woken during grace reads that room's ring DMs\n");
    Ident master, d1, other;
    const std::string room = room_name("hs-fg"), room2 = room_name("hs-fg2");
    const std::string inbox = "inbox:" + master.peer;
    auto a = login3(d1, "new", 0);
    auto b = login(Ident());
    join(*a, room);
    join(*a, room2);
    join(*a, inbox, {{"inbox_roster", hs_roster(master, {&d1}, {})}});
    join(*b, room);
    join(*b, room2);
    join(*b, inbox);
    // A channel copy parked for the device, replayed into its ring by its join and never
    // read: a kind offline_buffer takes, but not a DM.
    const std::string server = room_name("hs-fg-srv");
    join(*b, server);
    b->send_bin(channel_frame(server, d1.peer, "ch", "fg-chan"));
    settle({b.get()});
    const uint64_t read = a->ws.counted;
    join(*a, server);
    a->ws.abort();
    check("the device is in grace", next(*b, about("peer_left", room, d1.peer)).has_value());
    const std::string sender = b->id.peer;
    b->send_bin(frame(0x04, {room, d1.peer}, "fg-dm"));
    b->send_bin(frame(0x08, {room, d1.peer}, "fg-image"));
    b->send_bin(frame(0x03, {room}, "fg-bcast"));
    b->send({{"type", "direct"}, {"room", room}, {"target", d1.peer}, {"data", "fg-json"}});
    b->send_bin(frame(0x02, {room, d1.peer}, "fg-chunk"));
    b->send_bin(frame(0x04, {room2, d1.peer}, "fg-dm-elsewhere"));
    b->send_bin(frame(0x04, {inbox, d1.peer}, "fg-dm-inbox"));
    settle({b.get()});

    auto stranger = login3(other, "none", 0, "fetch");
    stranger->send({{"type", "join"}, {"room", room}});
    settle({stranger.get()});
    check("another device's fetch socket reads nothing of it",
          !got(*stranger, bin(frame(0x06, {room, sender}, "fg-dm"))) && stranger->ws.inbox.empty());

    auto f = login3(d1, "none", 0, "fetch");
    f->send({{"type", "join"}, {"room", room}});
    settle({f.get()});
    check("the device's fetch socket reads the DM", got(*f, bin(frame(0x06, {room, sender}, "fg-dm"))));
    check("and the inlined image", got(*f, bin(frame(0x06, {room, sender}, "fg-image"))));
    check("and nothing else of the ring: no broadcast, JSON direct or chunk",
          !got(*f, bin(frame(0x05, {room, sender}, "fg-bcast"))) &&
              !got(*f, json_where([](const json& j) { return j.value("data", "") == "fg-json"; })) &&
              !got(*f, bin(frame(0x02, {room, sender}, "fg-chunk"))));
    check("nor another room's DM", !got(*f, bin(frame(0x06, {room2, sender}, "fg-dm-elsewhere"))));
    f->send({{"type", "join"}, {"room", server}});
    settle({f.get()});
    check("nor a channel copy", !got(*f, bin(frame(0x06, {server, sender}, "fg-chan"))));
    f->send({{"type", "join"}, {"room", inbox}});
    settle({f.get()});
    check("an inbox it does not prove gives nothing", !got(*f, bin(frame(0x06, {inbox, sender}, "fg-dm-inbox"))));
    f->send({{"type", "join"}, {"room", inbox}, {"inbox_roster", hs_roster(master, {&d1}, {})}});
    settle({f.get()});
    check("one it proves gives its DM", got(*f, bin(frame(0x06, {inbox, sender}, "fg-dm-inbox"))));
    check("(the fetch socket is told no count)", !got(*f, typed("ack")) && hb(*f, 0).value("h", 1) == 0);

    auto a2 = login3(d1, a->sid, read);
    check("the session still resumes at the same count", resumed(*a2) && !a2->answer.value("gap", true));
    const auto upto = through(*a2, bin(frame(0x06, {inbox, sender}, "fg-dm-inbox")));
    check("and its ring still replays every frame the fetch socket read",
          std::any_of(upto.begin(), upto.end(), bin(frame(0x06, {room, sender}, "fg-dm"))) &&
              std::any_of(upto.begin(), upto.end(), bin(frame(0x06, {room, sender}, "fg-image"))) &&
              std::any_of(upto.begin(), upto.end(), bin(frame(0x05, {room, sender}, "fg-bcast"))) &&
              std::any_of(upto.begin(), upto.end(), bin(frame(0x06, {room2, sender}, "fg-dm-elsewhere"))));
}

// That read is one per fetch socket and room: a leave and a join are a few bytes, the ring up
// to 8 MiB. The next push wake opens a fresh socket, which reads the room once again.
static void hs_fetch_reads_grace_once() {
    printf("handshake review: a fetch socket reads a room's grace DMs once\n");
    Ident d1;
    const std::string room = room_name("hs-fo"), early = room_name("hs-fo-early");
    auto b = login(Ident());
    join(*b, room);
    join(*b, early);
    // A fetch socket that joined before the device had a session in grace read nothing then.
    auto pre = login3(d1, "none", 0, "fetch");
    pre->send({{"type", "join"}, {"room", early}});
    settle({pre.get()});
    auto a = login3(d1, "new", 0);
    join(*a, room);
    join(*a, early);
    const uint64_t read = a->ws.counted;
    a->ws.abort();
    check("the device is in grace", next(*b, about("peer_left", room, d1.peer)).has_value());
    const std::string sender = b->id.peer;
    b->send_bin(frame(0x04, {room, d1.peer}, "fo-dm"));
    b->send_bin(frame(0x04, {early, d1.peer}, "fo-early"));
    settle({b.get()});

    auto f = login3(d1, "none", 0, "fetch");
    f->send({{"type", "join"}, {"room", room}});
    settle({f.get()});
    check("a fetch socket's join reads the room's DM", count(*f, bin(frame(0x06, {room, sender}, "fo-dm"))) == 1);
    f->send({{"type", "leave"}, {"room", room}});
    f->send({{"type", "join"}, {"room", room}});
    f->send({{"type", "leave"}, {"room", room}});
    f->send({{"type", "join"}, {"room", room}});
    f->send({{"type", "join"}, {"room", room}});
    settle({f.get()});
    check("leaving and joining it again reads nothing more", f->ws.inbox.empty());

    auto f2 = login3(d1, "none", 0, "fetch");
    f2->send({{"type", "join"}, {"room", room}});
    settle({f2.get()});
    check("a fresh fetch socket reads it once", count(*f2, bin(frame(0x06, {room, sender}, "fo-dm"))) == 1);
    pre->send({{"type", "join"}, {"room", early}});
    settle({pre.get()});
    check("a join before the grace left the socket its read of the room",
          count(*pre, bin(frame(0x06, {early, sender}, "fo-early"))) == 1);

    // The record is bounded: a socket that read as many rooms as it may reads no further one.
    auto f3 = login3(d1, "none", 0, "fetch");
    std::vector<std::pair<uint8_t, std::string>> joins;
    for (size_t i = 0; i < session::FETCH_READ_ROOMS; i++) {
        joins.push_back({0x1, json{{"type", "join"}, {"room", room_name("hs-fo-" + std::to_string(i))}}.dump()});
    }
    joins.push_back({0x1, json{{"type", "join"}, {"room", room}}.dump()});
    f3->ws.send_frames(joins);
    settle({f3.get()});
    check("past its rooms a fetch socket reads nothing more", f3->ws.inbox.empty());

    auto a2 = login3(d1, a->sid, read);
    check("all inside the grace: the session resumes", resumed(*a2));
    const auto upto = through(*a2, bin(frame(0x06, {early, sender}, "fo-early")));
    check("and still replays the DMs its fetch sockets read",
          std::any_of(upto.begin(), upto.end(), bin(frame(0x06, {room, sender}, "fo-dm"))));
}

// Link `n` of a lock, signed by the change key of the link before it.
static json successor_link(const std::string& server, uint64_t n, const Door& door, const Ident& change,
                           const Ident& signer) {
    LockLink l;
    l.n = n;
    l.door = door.text;
    l.change = change.pub_b64;
    l.sig = signer.sign(join_lock::payload(server, l));
    return join_lock::links_to_json({l})[0];
}

// The door grace is 60 s and has no test override, so this needs a relay whose session
// grace outlasts it (RELAY_LIVE_ONLY=door_grace against one built with a longer test
// grace, about 70 s); against run_live.sh's 5 s grace it skips.
static void hs_door_moved_in_grace() {
    printf("handshake review: a door that moved during grace is not carried past its grace\n");
    Ident owner, change, change2;
    Door door, door2;
    const std::string nonce = random_hex(16);
    const std::string room = genesis_server_id(owner.peer, nonce);
    Ident ida;
    auto a = login3(ida, "new", 0);
    if (a->answer.value("grace_secs", 0) * 1000 <= door_room::GRACE_MS + 10000) {
        printf("  skip door moved in grace (the session grace is shorter than the door's)\n");
        return;
    }
    auto b = login(Ident());
    const json base = base_link(room, door, change, owner, nonce, true);
    b->send({{"type", "lock_put"}, {"server", room}, {"owner", ""}, {"links", base}});
    next(*b, typed("lock_chain"));
    auto ma = join(*a, room, {{"door_proof", door_proof(*a, room, door)}});
    auto mb = join(*b, room, {{"door_proof", door_proof(*b, room, door)}});
    check("both prove the door", ma && ma->value("proved", false) && mb && mb->value("proved", false));
    const uint64_t read = a->ws.counted;
    a->ws.abort();
    check("the device is in grace", next(*b, about("peer_left", room, ida.peer)).has_value());
    json links = base;
    links.push_back(successor_link(room, 2, door2, change2, change));
    b->send({{"type", "lock_put"}, {"server", room}, {"owner", ""}, {"links", links}});
    auto put = next_json(*b, typed("lock_chain"));
    check("the lock moves (a kick)", put && put->value("put", false));
    auto mb2 = join(*b, room, {{"door_proof", door_proof(*b, room, door2)}});
    check("the member left proves the new door", mb2 && mb2->value("proved", false));
    b->send_bin(frame(0x03, {room}, "hs-within-door-grace"));
    settle({b.get()});
    // Past the door grace and the 5 s sweep, the member's socket kept alive meanwhile.
    const auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(door_room::GRACE_MS + 7000);
    while (left_ms(until) > 0) {
        sleep_ms(std::min(5000, left_ms(until)));
        sync(*b);
    }
    b->send_bin(frame(0x03, {room}, "hs-after-door-grace"));
    b->send({{"type", "msg"}, {"room", room}, {"data", "hs-after-door-grace-msg"}});
    settle({b.get()});
    auto a2 = login3(ida, a->sid, read);
    check("the session resumes", resumed(*a2));
    auto m = next_json(*a2, typed("members", room));
    check("hidden in the room: not proved, sees only itself",
          m && !m->value("proved", true) && peers_of(*m) == std::set<std::string>{ida.peer});
    settle({a2.get(), b.get()});
    check("its ring kept what the room said within the door's grace, as a live member gets it",
          got(*a2, bin(frame(0x05, {room, b->id.peer}, "hs-within-door-grace"))));
    check("and nothing said after it", !got(*a2, bin(frame(0x05, {room, b->id.peer}, "hs-after-door-grace"))) &&
                                           !got(*a2, json_where([](const json& j) { return j.value("data", "") == "hs-after-door-grace-msg"; })));
    check("the provers are not told it came back", !got(*b, about("peer_joined", room, ida.peer)));
    b->send_bin(frame(0x03, {room}, "hs-after-resume"));
    settle({b.get(), a2.get()});
    check("nor does it hear the room now", !got(*a2, bin(frame(0x05, {room, b->id.peer}, "hs-after-resume"))));
    auto old = join(*a2, room, {{"door_proof", door_proof_for(*a2, a->nonce, room, door)}});
    check("the old door proves nothing", old && !old->value("proved", true));
    auto fresh = join(*a2, room, {{"door_proof", door_proof_for(*a2, a->nonce, room, door2)}});
    check("the new door, once it holds it, proves", fresh && fresh->value("proved", false));
}

static bool wait_for_file(const std::string& path, std::string& content, int timeout_ms) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    while (left_ms(deadline) > 0) {
        if (FILE* f = fopen(path.c_str(), "r")) {
            char buf[64] = {};
            size_t n = fread(buf, 1, sizeof(buf) - 1, f);
            fclose(f);
            content.assign(buf, n);
            if (!content.empty()) return true;
        }
        sleep_ms(50);
    }
    return false;
}

// Across a relay restart (test/run_restart.sh: SIGTERM, the snapshot handed over, a new
// process): the restored session comes back with no door standing, so until it proves
// its door again a locked room shows it nothing and nobody there sees it; an inbox the
// roster took away during the new process's grace is gone; kill signals still come first.
// fdstore_restart.py looks this peer up in the reports file.
static const char RESTART_REPORT_TARGET[] = "12D3KooWRestartReportTarget1111111111111111111111";

static void hs_restart(const std::string& dir) {
    printf("handshake review: a session restored from a snapshot proves its doors again\n");
    Ident owner, change, master, d1, d2;
    Door door;
    const std::string nonce = random_hex(16);
    const std::string locked = genesis_server_id(owner.peer, nonce);
    const std::string plain = room_name("rs-plain");
    const std::string inbox = "inbox:" + master.peer;
    Ident idb;
    auto a = login3(d1, "new", 0);
    auto b = login(idb);
    b->send({{"type", "lock_put"}, {"server", locked}, {"owner", ""}, {"links", base_link(locked, door, change, owner, nonce, true)}});
    check("the relay takes the lock", next(*b, typed("lock_chain")).has_value());
    auto ml = join(*a, locked, {{"door_proof", door_proof(*a, locked, door)}});
    join(*b, locked, {{"door_proof", door_proof(*b, locked, door)}});
    join(*a, plain);
    join(*b, plain);
    auto mi = join(*a, inbox, {{"inbox_roster", hs_roster(master, {&d1, &d2}, {})}});
    check("the device proves the door and owns the inbox",
          ml && ml->value("proved", false) && mi && peers_of(*mi) == std::set<std::string>{d1.peer});
    settle({a.get()});
    const uint64_t read = a->ws.counted;
    // A phone in the background: hidden from the room when the relay stops.
    Ident ide;
    auto e = login3(ide, "new", 0);
    join(*e, plain);
    e->send({{"type", "inactive"}});
    check("(a second device hides)", next(*b, about("peer_left", plain, ide.peer)).has_value());
    const uint64_t e_read = e->ws.counted;
    // A report before the restart; its repeat after it must not count again (fdstore_restart.py
    // reads the reports file the two relays share).
    b->send({{"type", "report"}, {"target", RESTART_REPORT_TARGET}, {"category", "spam"}});
    check("(the report is filed)", next(*b, typed("report_ack")).has_value());
    // Written into its socket and never read: they are in its ring when the relay stops.
    b->send_bin(frame(0x03, {plain}, "rs-plain-before"));
    b->send_bin(frame(0x03, {locked}, "rs-locked-before"));
    settle({b.get()});

    if (FILE* f = fopen((dir + "/ready").c_str(), "w")) {
        fputs("1", f);
        fclose(f);
    }
    std::string port;
    if (!wait_for_file(dir + "/port2", port, 30000)) {
        check("the relay came back", false);
        return;
    }
    g_port = atoi(port.c_str());

    auto b2 = login(idb);
    auto mb = join(*b2, locked, {{"door_proof", door_proof(*b2, locked, door)}});
    check("the lock survived the restart", mb && mb->value("proved", false));
    b2->send({{"type", "report"}, {"target", RESTART_REPORT_TARGET}, {"category", "spam"}});
    check("(the same report is filed again)", next(*b2, typed("report_ack")).has_value());
    join(*b2, plain);
    b2->send_bin(frame(0x03, {locked}, "rs-locked-after"));
    b2->send_bin(frame(0x03, {plain}, "rs-plain-after"));
    auto sib = login(d2);
    join(*sib, inbox, {{"inbox_roster", hs_roster(master, {&d1, &d2}, {{&d1, &d2}})}});
    auto s = login(Ident());
    join(*s, inbox);
    s->send_bin(frame(0x04, {inbox, master.peer}, "rs-mail-after-removal"));
    check("a deposit reaches the owner left", next(*sib, bin(frame(0x06, {inbox, s->id.peer}, "rs-mail-after-removal"))).has_value());
    b2->send({{"type", "kill_deposit"}, {"blob", "AAAA"}, {"issued_at_ms", 9}, {"targets", json::array({d1.peer})}});
    check("a destroy signal waits for it", next(*b2, typed("kill_deposited")).has_value());
    settle({b2.get(), s.get()});

    auto a2 = login3(d1, a->sid, read);
    check("the session resumes and must prove its doors again",
          resumed(*a2) && a2->answer.value("reprove", false) && !a2->answer.value("gap", true));
    const auto upto = through(*a2, bin(frame(0x05, {plain, idb.peer}, "rs-plain-after")));
    check("the waiting kill signal comes first", !upto.empty() && is_json(upto[0], [](const json& j) {
                                                    return j.value("type", "") == "kill_signal" && j.value("issued_at_ms", 0) == 9;
                                                }));
    auto members_in = [&](const std::string& room) -> std::optional<json> {
        for (const auto& f : upto) {
            auto j = as_json(f);
            if (j && j->value("type", "") == "members" && j->value("room", "") == room) return j;
        }
        return std::nullopt;
    };
    auto m_locked = members_in(locked);
    check("the locked room shows it nothing until it proves",
          m_locked && !m_locked->value("proved", true) && peers_of(*m_locked) == std::set<std::string>{d1.peer});
    auto m_inbox = members_in(inbox);
    check("the inbox the roster took away during grace is gone", m_inbox && peers_of(*m_inbox) == std::set<std::string>{d1.peer});
    check("what its ring held at the restart replays",
          std::any_of(upto.begin(), upto.end(), bin(frame(0x05, {plain, idb.peer}, "rs-plain-before"))) &&
              std::any_of(upto.begin(), upto.end(), bin(frame(0x05, {locked, idb.peer}, "rs-locked-before"))));
    settle({a2.get(), b2.get()});
    check("the locked room's broadcast from before the proof never reached its ring",
          std::none_of(upto.begin(), upto.end(), bin(frame(0x05, {locked, idb.peer}, "rs-locked-after"))) &&
              !got(*a2, bin(frame(0x05, {locked, idb.peer}, "rs-locked-after"))));
    check("nor did the deposit after its removal",
          std::none_of(upto.begin(), upto.end(), bin(frame(0x06, {inbox, s->id.peer}, "rs-mail-after-removal"))) &&
              !got(*a2, bin(frame(0x06, {inbox, s->id.peer}, "rs-mail-after-removal"))));
    check("the provers are not told it came back", !got(*b2, about("peer_joined", locked, d1.peer)));
    check("the plain room is", got(*b2, about("peer_joined", plain, d1.peer)));

    auto old = join(*a2, locked, {{"door_proof", door_proof_for(*a2, a->nonce, locked, door)}});
    check("a proof for the session's first challenge proves nothing now", old && !old->value("proved", true));
    auto fresh = join(*a2, locked, {{"door_proof", door_proof(*a2, locked, door)}});
    check("one for the resuming socket's challenge proves", fresh && fresh->value("proved", false) &&
                                                               peers_of(*fresh).count(idb.peer) != 0);
    check("and the provers see it", next(*b2, about("peer_joined", locked, d1.peer)).has_value());
    b2->send_bin(frame(0x03, {locked}, "rs-locked-proved"));
    check("it hears the room again", next(*a2, bin(frame(0x05, {locked, idb.peer}, "rs-locked-proved"))).has_value());
    a2->send({{"type", "kill_ack"}});
    sync(*a2);

    auto e2 = login3(ide, e->sid, e_read);
    check("a session restored inactive resumes", resumed(*e2));
    settle({e2.get(), b2.get()});
    check("hidden: the room is told nothing", !got(*b2, about("peer_joined", plain, ide.peer)) &&
                                                  discover(*b2, plain).count(ide.peer) == 0);
    e2->send({{"type", "active"}});
    check("until it says active", next(*b2, about("peer_joined", plain, ide.peer)).has_value());
}

// ---------------------------------------------------------------------------
// Presence digests (g13): what `discover_peers` with `digest` answers is the tag sum of
// exactly what the socket's rosters and presence frames named, read in arrival order.

// What one socket was told of each room, frame by frame in arrival order, as ws_client
// keeps it. `lose_joined` drops that many `peer_joined` frames, as a lost write would.
struct Told {
    std::string me;
    std::map<std::string, std::set<std::string>> rooms;
    int lose_joined = 0;

    void apply(const json& j) {
        const std::string t = j.value("type", ""), room = j.value("room", "");
        if (t == "members") {
            auto peers = peers_of(j);
            peers.erase(me);
            rooms[room] = peers;
        } else if (t == "peer_joined") {
            if (lose_joined > 0) {
                lose_joined--;
                return;
            }
            rooms[room].insert(j.value("peer_id", ""));
        } else if (t == "peer_left") {
            rooms[room].erase(j.value("peer_id", ""));
        }
    }

    presence::Digest digest(const std::string& room) const {
        presence::Digest d;
        auto it = rooms.find(room);
        if (it != rooms.end()) {
            for (const auto& p : it->second) d.add(presence::tag(p));
        }
        return d;
    }
};

enum class Audit { NoAnswer, Same, Differs, NotJoined };

// Reads every frame up to `p`'s next digest answer for `room` in order, presence into
// `told`, and compares at the answer. Other frames are dropped.
static Audit read_audit(Peer& p, Told& told, const std::string& room, int timeout_ms = WAIT_MS) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    for (;;) {
        while (!p.ws.inbox.empty()) {
            Frame f = std::move(p.ws.inbox.front());
            p.ws.inbox.pop_front();
            auto j = as_json(f);
            if (!j) continue;
            if (j->value("type", "") == "discovered_peers" && j->value("room", "") == room &&
                (j->contains("digest") || j->contains("joined"))) {
                if (!j->value("joined", true)) return Audit::NotJoined;
                if (!j->value("peers", json::array()).empty()) return Audit::Differs;
                const presence::Digest d = told.digest(room);
                return j->value("digest", uint64_t{0}) == d.sum && j->value("count", uint64_t{0}) == d.count ? Audit::Same
                                                                                                         : Audit::Differs;
            }
            told.apply(*j);
        }
        if (left_ms(deadline) <= 0 || !p.ws.pump(left_ms(deadline))) return Audit::NoAnswer;
    }
}

static Audit audit(Peer& p, Told& told, const std::string& room) {
    p.send({{"type", "discover_peers"}, {"room", room}, {"digest", true}});
    return read_audit(p, told, room);
}

// `p` joins `room` with `extra`; the members answer lands in `told` at the next audit.
static void told_join(Peer& p, const std::string& room, const json& extra = json::object()) {
    json j = {{"type", "join"}, {"room", room}};
    for (auto it = extra.begin(); it != extra.end(); ++it) j[it.key()] = it.value();
    p.send(j);
}

static void test_presence_digest() {
    printf("presence digest: the tag sum of what the socket was told\n");
    const std::string room = room_name("digest");
    Ident ido;
    auto o = login3(ido, "new", 0);
    Told told{ido.peer, {}, 0};
    auto a = login(Ident());
    join(*a, room);
    told_join(*o, room);
    check("a lone member's digest is of the others", audit(*o, told, room) == Audit::Same && told.rooms[room].size() == 1);
    o->send({{"type", "discover_peers"}, {"room", room}, {"digest", true}});
    auto raw = next_json(*o, typed("discovered_peers", room));
    check("the answer names nobody, as a u64 digest and a count",
          raw && (*raw)["peers"].is_array() && (*raw)["peers"].empty() && (*raw)["digest"].is_number_unsigned() &&
              raw->value("count", 0) == 1 && (*raw)["digest"].get<uint64_t>() == presence::tag(a->id.peer));
    auto b = login(Ident());
    join(*b, room);
    check("a join is in it", audit(*o, told, room) == Audit::Same && told.rooms[room].size() == 2);

    auto g = login(Ident(), "guest");
    join(*g, room);
    Ident idf;
    auto ff = login(idf);
    join(*ff, room);
    auto fx = login(idf, "fetch");
    fx->send({{"type", "join"}, {"room", room}});
    Ident idh;
    auto h = login3(idh, "new", 0);
    join(*h, room);
    h->send({{"type", "inactive"}});
    sync(*h);
    sleep_ms(PRESENCE_PACE_MS + 200);
    check("guests, fetch sockets and hidden sessions are not in it",
          audit(*o, told, room) == Audit::Same && told.rooms[room] == std::set<std::string>{a->id.peer, b->id.peer, idf.peer});
    h->send({{"type", "active"}});
    sleep_ms(200);
    check("a session shown again is", audit(*o, told, room) == Audit::Same && told.rooms[room].count(idh.peer));

    check("a room the socket is not in: not joined", audit(*o, told, room_name("digest-elsewhere")) == Audit::NotJoined);
    Ident idd;
    auto dfetch = login(idd, "fetch");
    dfetch->send({{"type", "join"}, {"room", room}});
    sync(*dfetch);
    auto dfull = login(idd);
    Told dtold{idd.peer, {}, 0};
    check("nor one its own fetch socket holds the slot of", audit(*dfull, dtold, room) == Audit::NotJoined);
    told_join(*dfull, room);
    check("joined, it is", audit(*dfull, dtold, room) == Audit::Same);

    // Old clients: a window of the same filter, never more than the cap.
    std::vector<std::unique_ptr<Peer>> crowd;
    const std::string big = room_name("digest-big");
    told_join(*o, big);
    for (int i = 0; i < 70; i++) {
        crowd.push_back(login(Ident()));
        join(*crowd.back(), big);
    }
    std::set<std::string> union_seen;
    bool capped = true;
    for (int i = 0; i < 40; i++) {
        auto ids = discover(*crowd[0], big);
        capped = capped && ids.size() <= presence::LEGACY_CAP;
        union_seen.insert(ids.begin(), ids.end());
    }
    check("an old client's answer is capped", capped && discover(*crowd[0], big).size() == presence::LEGACY_CAP);
    check("its windows cover the room", union_seen.size() == 70 && !union_seen.count(crowd[0]->id.peer));
    check("and the digest counts every member", audit(*o, told, big) == Audit::Same && told.rooms[big].size() == 70);
    crowd.clear();
    check("(they all left)", audit(*o, told, big) == Audit::Same && told.rooms[big].empty());

    // An inbox: a non-owner is told nobody, an owner the other owners.
    Ident master, d1, d2;
    const std::string inbox = "inbox:" + master.peer;
    auto s1 = login(d1);
    join(*s1, inbox, {{"inbox_roster", legacy_roster(master, {&d1, &d2})}});
    told_join(*o, inbox);
    check("a non-owner's inbox digest is empty", audit(*o, told, inbox) == Audit::Same && told.rooms[inbox].empty());
    auto s2 = login(d2);
    Told t2{d2.peer, {}, 0};
    told_join(*s2, inbox, {{"inbox_roster", legacy_roster(master, {&d1, &d2})}});
    check("an owner's names the other owner", audit(*s2, t2, inbox) == Audit::Same && t2.rooms[inbox] == std::set<std::string>{d1.peer});
    check("and the non-owner still nobody", audit(*o, told, inbox) == Audit::Same && told.rooms[inbox].empty());

    // A forwarder room pairs each member with the forwarder alone.
    auto x = login(Ident());
    const std::string fwd = "fwd:" + x->id.peer;
    join(*x, fwd);
    auto y = login(Ident());
    join(*y, fwd);
    told_join(*o, fwd);
    check("a forwarder room member's digest is the forwarder's",
          audit(*o, told, fwd) == Audit::Same && told.rooms[fwd] == std::set<std::string>{x->id.peer});

    // Churn: joins, leaves, hidden toggles and dropped sockets that resume, an audit
    // after each step; nothing may differ.
    std::vector<Ident> ids(6);
    std::vector<std::unique_ptr<Peer>> live(ids.size());
    int differs = 0, asked = 0;
    for (int step = 0; step < 48; step++) {
        const size_t i = static_cast<size_t>(step * 7 + step / 6) % ids.size();
        auto& p = live[i];
        switch (step % 4) {
            case 0:
                if (!p) {
                    p = login3(ids[i], "new", 0);
                    join(*p, room);
                } else {
                    p->send({{"type", "leave"}, {"room", room}});
                    sync(*p);
                    p.reset();
                }
                break;
            case 1:
                if (p) p->send({{"type", (step / 4) % 2 ? "active" : "inactive"}});
                break;
            case 2:
                if (p && !p->sid.empty()) {
                    const std::string sid = p->sid;
                    const uint64_t counted = p->ws.counted;
                    p->ws.abort();
                    sleep_ms(50);
                    p = login3(ids[i], sid, counted);
                }
                break;
            default:
                b->send_bin(frame(0x03, {room}, "churn"));
                break;
        }
        asked++;
        if (audit(*o, told, room) != Audit::Same) differs++;
    }
    check("under churn no audit differs (" + std::to_string(asked) + " asked)", differs == 0);

    // A lost peer_joined: exactly one difference, gone after a re-join.
    told.lose_joined = 1;
    auto late = login(Ident());
    join(*late, room);
    check("a lost frame shows as a difference", audit(*o, told, room) == Audit::Differs);
    check("and again until the socket re-joins", audit(*o, told, room) == Audit::Differs);
    told_join(*o, room);
    check("the re-join's members settle it", audit(*o, told, room) == Audit::Same && told.rooms[room].count(late->id.peer));

    // The socket drops with an ask in flight: the resume's members come before the
    // replayed answer, so a client voiding the ask on members never compares a stale one.
    o->send({{"type", "discover_peers"}, {"room", room}, {"digest", true}});
    sync(*b);
    o->ws.abort();
    late->send({{"type", "leave"}, {"room", room}});
    sync(*late);
    auto o2 = login3(ido, o->sid, o->ws.counted);
    check("(the observer resumes)", resumed(*o2));
    bool members_first = false, answer_seen = false;
    const auto upto = through(*o2, typed("discovered_peers", room));
    for (const auto& f : upto) {
        auto j = as_json(f);
        if (!j) continue;
        if (j->value("type", "") == "members" && j->value("room", "") == room && !answer_seen) members_first = true;
        if (j->value("type", "") == "discovered_peers") answer_seen = true;
        else told.apply(*j);
    }
    check("the replayed answer comes after the room's members", answer_seen && members_first);
    check("and a fresh audit matches", audit(*o2, told, room) == Audit::Same && !told.rooms[room].count(late->id.peer));
    // The resume's members obey the same filter: a non-owner of an inbox is told nobody.
    check("a resume tells an inbox non-owner nobody", audit(*o2, told, inbox) == Audit::Same && told.rooms[inbox].empty());
    check("nor a forwarder room member anyone but the forwarder",
          audit(*o2, told, fwd) == Audit::Same && told.rooms[fwd] == std::set<std::string>{x->id.peer});
}

// Locked rooms: a relock and, with `through_grace`, the door grace running out; the
// digest never runs ahead of the presence frames.
static void test_presence_digest_door(bool through_grace) {
    printf("presence digest: a locked room%s\n", through_grace ? ", through the door's grace" : "");
    Ident owner, change, change2;
    Door door, door2;
    const std::string nonce = random_hex(16);
    const std::string room = genesis_server_id(owner.peer, nonce);
    const json base = base_link(room, door, change, owner, nonce, true);
    auto b = login(Ident());
    b->send({{"type", "lock_put"}, {"server", room}, {"owner", ""}, {"links", base}});
    next(*b, typed("lock_chain"));
    join(*b, room, {{"door_proof", door_proof(*b, room, door)}});
    Ident ido;
    auto o = login(ido);
    Told told{ido.peer, {}, 0};
    told_join(*o, room, {{"door_proof", door_proof(*o, room, door)}});
    check("a prover's digest names the provers", audit(*o, told, room) == Audit::Same && told.rooms[room] == std::set<std::string>{b->id.peer});
    auto q = login(Ident());
    Told tq{q->id.peer, {}, 0};
    told_join(*q, room);
    check("a hidden socket's is empty", audit(*q, tq, room) == Audit::Same && tq.rooms[room].empty());
    check("and the prover's leaves it out", audit(*o, told, room) == Audit::Same && !told.rooms[room].count(q->id.peer));
    auto c = login(Ident());
    join(*c, room, {{"door_proof", door_proof(*c, room, door2)}});
    json links = base;
    links.push_back(successor_link(room, 2, door2, change2, change));
    b->send({{"type", "lock_put"}, {"server", room}, {"owner", ""}, {"links", links}});
    next(*b, typed("lock_chain"));
    check("after a relock the prover's digest matches", audit(*o, told, room) == Audit::Same && told.rooms[room].count(c->id.peer));
    check("so does the newly proved socket's", [&] {
        Told tc{c->id.peer, {}, 0};
        told_join(*c, room, {{"door_proof", door_proof(*c, room, door2)}});
        return audit(*c, tc, room) == Audit::Same;
    }());
    if (!through_grace) return;
    // The old door's grace runs out for o and b; the audit asked right then still matches
    // what they were told, however the sweep and the ask interleave.
    const auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(door_room::GRACE_MS + 7000);
    int differs = 0;
    while (left_ms(until) > 0) {
        sleep_ms(std::min(1000, left_ms(until)));
        if (audit(*o, told, room) != Audit::Same) differs++;
        sync(*b);
        sync(*c);
    }
    check("no audit differs while the grace runs out", differs == 0);
    check("and o, past its grace, is told nobody", told.rooms[room].empty());
}

// A write the relay drops past maxBackpressure: the socket closes on the next session
// tick (not 1008), so the session resumes from the client's own count, never shifted.
static void hs_dropped_write_resumes_cleanly() {
    printf("handshake review: a dropped write closes the socket, and the resume is not shifted\n");
    const std::string room = room_name("hs-dropped");
    Ident ida;
    auto a = login3(ida, "new", 0);
    auto b = login(Ident());
    join(*a, room);
    join(*b, room);
    next(*a, about("peer_joined", room, b->id.peer));
    sync(*a);
    const uint64_t read = a->ws.counted;
    // a reads nothing more: three 30 MiB directs fill the relay's buffer for it past
    // 64 MiB, so the markers behind them are dropped or never written.
    for (int i = 0; i < 3; i++) b->send_bin(frame(0x04, {room, ida.peer}, std::string(1, char('0' + i)) + std::string(30u << 20, 'x')));
    for (int i = 0; i < 3; i++) b->send_bin(frame(0x04, {room, ida.peer}, "marker-" + std::to_string(i)));
    check("the relay closes the socket at once: the room sees it leave",
          next(*b, about("peer_left", room, ida.peer), 8000).has_value());
    a->ws.abort();
    auto a2 = login3(ida, a->sid, read);
    check("the session resumes", resumed(*a2));
    const auto upto = through(*a2, bin(frame(0x06, {room, b->id.peer}, "marker-2")), 30000);
    std::vector<std::string> got_markers;
    bool dup = false;
    std::set<std::string> seen;
    for (const auto& f : upto) {
        if (f.text) continue;
        if (!seen.insert(f.data.substr(0, 160) + "#" + std::to_string(f.data.size())).second) dup = true;
        if (f.data.find("marker-") != std::string::npos) got_markers.push_back(f.data.substr(f.data.find("marker-")));
    }
    check("every marker after its count arrives once, in order",
          got_markers == std::vector<std::string>{"marker-0", "marker-1", "marker-2"});
    check("and nothing twice", !dup);
    b->send_bin(frame(0x04, {room, ida.peer}, "after"));
    check("the resumed socket takes new frames", next(*a2, bin(frame(0x06, {room, b->id.peer}, "after"))).has_value());
}

// Against a relay with a small send buffer (run_live.sh): after a dropped write the
// client drains everything written and a new frame comes before the session tick. A
// socket still writing would hand it that frame, counted in the dropped one's place, so
// its resume would repeat one frame and skip another. Rounds, because the tick may land
// first; at least one must see the drain finish before it. Every frame of a round is
// checked, across as many resumes as the small buffer takes.
static void hs_dropped_write_writes_nothing_more() {
    printf("handshake review: past a dropped write nothing more is written, even once the buffer drains\n");
    const char* bp = getenv("RELAY_LIVE_BACKPRESSURE");
    const size_t limit = bp ? strtoull(bp, nullptr, 10) : 0;
    if (limit == 0 || limit > (4u << 20)) {
        check("(the relay runs with a small send buffer)", false);
        return;
    }
    const std::string room = room_name("hs-drained");
    auto b = login(Ident());
    join(*b, room);
    int raced = 0;
    for (int round = 0; round < 5; round++) {
        Ident ida;
        g_rcvbuf = 64 << 10;
        auto a = login3(ida, "new", 0);
        g_rcvbuf = 0;
        join(*a, room);
        next(*b, about("peer_joined", room, ida.peer));
        sync(*a);
        const std::string m0 = "m0-" + std::to_string(round), m1 = "m1-" + std::to_string(round);
        const std::string f1 = frame(0x06, {room, b->id.peer}, m1);
        // Every frame b sends a, as a receives it, and the name it is reported by.
        std::vector<std::pair<std::string, std::string>> sent;
        for (int i = 0; i < 6; i++) {
            sent.emplace_back(frame(0x06, {room, b->id.peer}, std::string(limit, char('a' + i))), std::string(1, char('a' + i)));
        }
        sent.emplace_back(frame(0x06, {room, b->id.peer}, m0), m0);
        sent.emplace_back(f1, m1);
        std::vector<std::string> want, markers;
        for (const auto& [bytes, name] : sent) want.push_back(name);
        const auto note = [&](const Frame& f) {
            if (f.text) return;
            for (const auto& [bytes, name] : sent) {
                if (f.data == bytes) markers.push_back(name);
            }
        };
        // A small receive window keeps the kernel's share small: six buffers' worth while
        // a reads nothing overflow the relay's, and stay inside the session ring.
        for (int i = 0; i < 6; i++) b->send_bin(frame(0x04, {room, ida.peer}, std::string(limit, char('a' + i))));
        b->send_bin(frame(0x04, {room, ida.peer}, m0));
        sync(*b);
        while (a->ws.pump(20)) {}
        if (!a->ws.closed()) raced++;
        b->send_bin(frame(0x04, {room, ida.peer}, m1));
        while (a->ws.pump(50)) {}
        check("(the relay closes the socket)", closed_by_relay(*a) && next(*b, about("peer_left", room, ida.peer), 8000).has_value());
        for (const auto& f : a->ws.inbox) note(f);
        // The replay is several buffers too, so a resumed socket may drop a write of its own
        // and close in turn; the next resume goes on from what that socket counted.
        std::unique_ptr<Peer> last;
        uint64_t h = a->ws.counted;
        bool resumes = true;
        for (int hop = 0; hop < 8 && resumes; hop++) {
            auto r = login3(ida, a->sid, h);
            resumes = resumed(*r);
            auto upto = through(*r, bin(f1));
            const bool done = !upto.empty();
            if (done) sync(*r);
            upto.insert(upto.end(), r->ws.inbox.begin(), r->ws.inbox.end());
            for (const auto& f : upto) note(f);
            h = r->ws.counted;
            last = std::move(r);
            if (done || !closed_by_relay(*last)) break;
        }
        check("(the session resumes)", resumes);
        std::string got;
        for (const auto& m : markers) got += " " + m;
        check("round " + std::to_string(round) + ": each frame once, in order, live and resumed together (got" + got + ")",
              markers == want);
        if (last) last->ws.close_clean();
        next(*b, about("peer_left", room, ida.peer));
    }
    check("at least one round drained before the session tick (" + std::to_string(raced) + " of 5)", raced > 0);
}

static void test_handshake_review() {
    hs_sids();
    hs_replays_and_shapes();
    hs_removed_in_grace();
    hs_recovered_in_grace();
    hs_moved_socket();
    hs_hostile_counts();
    hs_active_costs_what_was_withheld();
    hs_one_ack_timer();
    hs_push_reach();
    hs_fetch_reads_grace_dms();
    hs_fetch_reads_grace_once();
    hs_door_moved_in_grace();
}

// --- Session bounds (rs_bounds_review.md) ---------------------------------------------
//
// The test build caps an address at three sockets (run_live.sh), so these fill one under
// its rate of ten new sockets a minute. Each case pins its sockets to an address of its own.

struct PinnedSource {
    explicit PinnedSource(int n) { g_pin_source = n; }
    ~PinnedSource() { g_pin_source = -1; }
};

// A login the relay turns away with ip_limit before any answer: the address is full and
// no session in grace there may give its slot up.
static bool refused_at_login(const Ident& id) {
    auto p = login3(id, "new", 0);
    return !p->ok && closed_by_relay(*p) && p->ws.close_code == 1008 && p->ws.close_reason == "ip_limit";
}

// A socket the relay closes at once: the address is full.
static bool refused_at_open(const Ident& id) {
    auto p = open_socket(id);
    p->send({{"type", "auth_hello"}});
    return closed_by_relay(*p) && p->ws.close_code == 1008 && p->ws.close_reason == "ip_limit";
}

static void test_bounds_full_address() {
    printf("bounds: a full address and the grace slots it holds\n");
    if (g_grace_secs == 0) g_grace_secs = login3(Ident(), "new", 0)->answer.value("grace_secs", 0);
    {
        PinnedSource pin(50001);
        const std::string room = room_name("full-own");
        auto x = login(Ident());
        auto y = login(Ident());
        Ident idd;
        auto d = login3(idd, "new", 0);
        join(*x, room);
        join(*d, room);
        const uint64_t read = d->ws.counted;
        d->ws.abort();
        check("(the device dropped)", next(*x, about("peer_left", room, idd.peer)).has_value());
        auto d2 = login3(idd, d->sid, read);
        check("a device coming back to its full address resumes its own session", resumed(*d2));
    }
    {
        PinnedSource pin(50002);
        const std::string room = room_name("full-two");
        auto x = login(Ident());
        join(*x, room);
        Ident i1, i2;
        auto d1 = login3(i1, "new", 0);
        auto d2 = login3(i2, "new", 0);
        join(*d1, room);
        join(*d2, room);
        const uint64_t r1 = d1->ws.counted, r2 = d2->ws.counted;
        d1->ws.abort();
        check("(the first dropped)", next(*x, about("peer_left", room, i1.peer)).has_value());
        d2->ws.abort();
        check("(the second dropped)", next(*x, about("peer_left", room, i2.peer)).has_value());
        auto back2 = login3(i2, d2->sid, r2);
        check("the later of two devices in grace comes back", resumed(*back2));
        auto back1 = login3(i1, d1->sid, r1);
        check("without costing the earlier one its session", resumed(*back1));
    }
    {
        PinnedSource pin(50003);
        const std::string room = room_name("full-new");
        auto x = login(Ident());
        auto y = login(Ident());
        Ident idd;
        auto d = login3(idd, "new", 0);
        join(*x, room);
        join(*d, room);
        const uint64_t read = d->ws.counted;
        d->ws.abort();
        check("(the device dropped)", next(*x, about("peer_left", room, idd.peer)).has_value());
        check("a newcomer cannot end a session in its first half of grace", refused_at_login(Ident()));
        sleep_ms(static_cast<int>(g_grace_secs * 1000 / 2 + 500));
        auto s = login(Ident());
        check("a newcomer to a full address gets the slot a session in grace held", s->ok);
        check("the address is full again", refused_at_open(Ident()));
        check("(the newcomer leaves)", s->ws.close_clean());
        auto d2 = login3(idd, d->sid, read);
        check("and that session is gone", answer_type(*d2) == "auth_ok" && resume_failed(*d2) == "unknown");
    }
    {
        // Three takeovers a minute per address; past them the newcomer waits, never the neighbour.
        PinnedSource pin(50007);
        std::vector<Ident> ids(3);
        std::vector<std::unique_ptr<Peer>> gone;
        for (auto& id : ids) gone.push_back(login3(id, "new", 0));
        for (auto& g : gone) g->ws.abort();
        sleep_ms(static_cast<int>(g_grace_secs * 1000 / 2 + 500));
        auto a = login(Ident());
        auto b = login(Ident());
        auto c = login(Ident());
        check("three newcomers take the three grace slots", a->ok && b->ok && c->ok);
        check("(one of them leaves)", c->ws.close_clean());
        Ident idw;
        auto w = login3(idw, "new", 0);
        const uint64_t wread = w->ws.counted;
        w->ws.abort();
        sleep_ms(static_cast<int>(g_grace_secs * 1000 / 2 + 500));
        check("a fourth takeover in the minute is refused", refused_at_login(Ident()));
        auto w2 = login3(idw, w->sid, wread);
        check("and the neighbour's session it would have ended resumes", resumed(*w2));
    }
    {
        // A device whose older socket at the full address is still open frees that slot by
        // logging in, fresh or by moving its session: it costs no neighbour anything.
        PinnedSource pin(50008);
        Ident idv, idd;
        auto v = login3(idv, "new", 0);
        const uint64_t vread = v->ws.counted;
        v->ws.abort();
        auto d = login3(idd, "new", 0);
        auto x = login(Ident());
        sleep_ms(200);
        auto fresh = login3(idd, "new", 0);
        check("a device logs in fresh beside its own open socket at a full address", fresh->ok);
        auto moved = login3(idd, fresh->sid, fresh->ws.counted);
        check("and moves its session there from its own open socket", resumed(*moved));
        auto v2 = login3(idv, v->sid, vread);
        check("neither cost the neighbour in grace its session", resumed(*v2));
    }
    {
        // A session resumed from another address is a newcomer here: the same minimum.
        Ident idr, idv;
        std::unique_ptr<Peer> r;
        uint64_t rread = 0;
        {
            PinnedSource elsewhere(50010);
            r = login3(idr, "new", 0);
            rread = r->ws.counted;
            r->ws.abort();
        }
        PinnedSource pin(50009);
        auto x = login(Ident());
        auto y = login(Ident());
        auto v = login3(idv, "new", 0);
        const uint64_t vread = v->ws.counted;
        v->ws.abort();
        sleep_ms(200);
        auto early = login3(idr, r->sid, rread);
        check("a resume from another address cannot end a session in its first half of grace",
              !early->ok && closed_by_relay(*early) && early->ws.close_code == 1008 &&
                  early->ws.close_reason == "ip_limit");
        sleep_ms(static_cast<int>(g_grace_secs * 1000 / 2 + 500));
        auto late = login3(idr, r->sid, rread);
        check("its session was left alone, and past the minimum it takes the slot", resumed(*late));
        (void)vread;
    }
    {
        PinnedSource pin(50004);
        auto x = login(Ident());
        auto y = login(Ident());
        auto z = login3(Ident(), "new", 0);
        check("an address full of live sockets refuses the next", refused_at_open(Ident()));
    }
}

static void test_bounds_active() {
    printf("bounds: active tells a session only the presence it was spared\n");
    const std::string r1 = room_name("act-1"), r2 = room_name("act-2");
    Ident ida;
    auto a = login3(ida, "new", 0);
    auto b = login(Ident());
    join(*a, r1);
    join(*a, r2);
    join(*b, r1);
    settle({a.get()});
    a->send({{"type", "active"}});
    settle({a.get()});
    check("active on a session that is active sends nothing", count(*a, typed("members")) == 0);
    a->send({{"type", "inactive"}});
    a->send({{"type", "active"}});
    settle({a.get()});
    check("inactive then active with nothing withheld sends nothing", count(*a, typed("members")) == 0);
    a->send({{"type", "inactive"}});
    sync(*a);
    auto c = login(Ident());
    join(*c, r1);
    settle({c.get(), a.get()});
    check("(presence is withheld)", !got(*a, about("peer_joined", r1, c->id.peer)));
    a->send({{"type", "active"}});
    auto m = next_json(*a, typed("members", r1));
    check("active sends a fresh members for the room whose presence was withheld",
          m && peers_of(*m) == std::set<std::string>{ida.peer, b->id.peer, c->id.peer});
    settle({a.get()});
    check("and none for a room where nothing was", count(*a, typed("members", r2)) == 0);
}

// The relay posts a push to 127.0.0.1:3001; held here, and only then is a token registered.
static void test_bounds_push_debounce() {
    printf("bounds: frames into a ring in grace wake the phone once per debounce\n");
    // Another suite on a shared machine may hold the port for a few seconds.
    int lfd = -1;
    for (int attempt = 0; attempt < 40 && lfd < 0; attempt++) {
        lfd = socket(AF_INET, SOCK_STREAM, 0);
        sockaddr_in at{};
        at.sin_family = AF_INET;
        at.sin_port = htons(3001);
        at.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        int one = 1;
        setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        if (lfd >= 0 && (bind(lfd, reinterpret_cast<sockaddr*>(&at), sizeof(at)) != 0 || listen(lfd, 16) != 0)) {
            close(lfd);
            lfd = -1;
            sleep_ms(500);
        }
    }
    if (lfd < 0) {
        printf("  skip push debounce (127.0.0.1:3001 is taken)\n");
        return;
    }
    // The pushes naming this run's token within `ms`, every post answered so the relay's
    // worker moves on: another relay on the machine may post here too.
    const std::string token = "burst-" + g_tag;
    auto pushes = [lfd, &token](int ms) {
        int n = 0;
        auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
        for (;;) {
            pollfd p{lfd, POLLIN, 0};
            if (poll(&p, 1, left_ms(deadline)) <= 0) return n;
            int c = accept(lfd, nullptr, nullptr);
            if (c < 0) return n;
            std::string req;
            char buf[4096];
            for (int i = 0; i < 4; i++) {
                pollfd q{c, POLLIN, 0};
                if (poll(&q, 1, 300) <= 0) break;
                ssize_t got_n = read(c, buf, sizeof(buf));
                if (got_n <= 0) break;
                req.append(buf, static_cast<size_t>(got_n));
            }
            const std::string ok = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            (void)!write(c, ok.data(), ok.size());
            close(c);
            if (req.find(token) != std::string::npos) n++;
        }
    };
    const std::string room = room_name("push-burst");
    Ident ida;
    auto a = login3(ida, "new", 0);
    auto b = login(Ident());
    join(*a, room);
    join(*b, room);
    a->send({{"type", "register_push_token"}, {"token", token}, {"platform", "android"}});
    check("(the device registers a token)", next(*a, typed("push_token_registered")).has_value());
    const uint64_t read = a->ws.counted;
    a->ws.abort();
    check("(the device left)", next(*b, about("peer_left", room, ida.peer)).has_value());
    for (int i = 0; i < 6; i++) b->send_bin(frame(0x04, {room, ida.peer}, "burst-" + std::to_string(i)));
    b->send({{"type", "direct"}, {"room", room}, {"target", ida.peer}, {"data", "burst-json"}});
    settle({b.get()});
    check("a burst into a ring in grace wakes the phone once", pushes(3000) == 1);
    auto a2 = login3(ida, a->sid, read);
    size_t got_all = 0;
    for (int i = 0; i < 6; i++) got_all += next(*a2, bin(frame(0x06, {room, b->id.peer}, "burst-" + std::to_string(i)))).has_value();
    check("and every frame still arrives on resume", resumed(*a2) && got_all == 6);
    a2->send({{"type", "unregister_push_token"}});
    sync(*a2);
    close(lfd);
}

// The relay's resident memory in KiB, from the pid run_live.sh passes; 0 when unknown.
static long relay_rss_kb() {
    const char* pid = getenv("RELAY_LIVE_PID");
    if (!pid) return 0;
    FILE* f = fopen(("/proc/" + std::string(pid) + "/status").c_str(), "r");
    if (!f) return 0;
    char line[256];
    long kb = 0;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "VmRSS:", 6) == 0) kb = atol(line + 6);
    }
    fclose(f);
    return kb;
}

// RELAY_LIVE_PROBE=acks: what a counted frame between heartbeats costs the relay in queued
// acks. Prints the growth; Session::count_in's unit test is the regression check.
static void probe_ack_queue() {
    printf("probe: a counted frame between heartbeats\n");
    const std::string beat = json{{"type", "hb"}, {"h", 0}}.dump();
    std::vector<std::pair<uint8_t, std::string>> frames;
    for (int i = 0; i < 500; i++) {
        frames.push_back({0x2, std::string(1, '\0')});
        frames.push_back({0x1, beat});
    }
    auto a = login3(Ident(), "new", 0);
    sync(*a);
    const long before = relay_rss_kb();
    const auto t0 = std::chrono::steady_clock::now();
    int rounds = 0;
    size_t beats = 0;
    for (; rounds < 400 && !a->ws.closed(); rounds++) {
        a->ws.send_frames(frames);
        while (a->ws.pump(2)) {
        }
        beats += count(*a, typed("hb_ack"));
    }
    // A loaded relay may still be working through the burst.
    for (int i = 0; i < 12 && !sync(*a); i++) {
    }
    beats += count(*a, typed("hb_ack"));
    const long ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
    const long after = relay_rss_kb();
    printf("  relay RSS %ld KiB, then %ld KiB after %d rounds of 500 counted frames each followed by a heartbeat in"
           " %ld ms (%+ld KiB; %zu answered, socket %s)\n",
           before, after, rounds, ms, after - before, beats, a->ws.closed() ? "closed" : "open");
}

// RELAY_LIVE_PROBE=active: what `inactive` then `active` costs the relay for a session in
// many rooms, read as how long another socket's round trip waits behind a burst of them.
static void probe_active_burst() {
    printf("probe: inactive then active for a session in many rooms\n");
    auto a = login3(Ident(), "new", 0);
    const int rooms = 5000;
    std::vector<std::pair<uint8_t, std::string>> joins;
    for (int i = 0; i < rooms; i++) {
        joins.push_back({0x1, json{{"type", "join"}, {"room", room_name("many") + "-" + std::to_string(i)}}.dump()});
    }
    a->ws.send_frames(joins);
    for (int i = 0; i < 12 && !sync(*a); i++) {
    }
    a->ws.inbox.clear();
    auto b = login(Ident());
    sync(*b);
    std::vector<std::pair<uint8_t, std::string>> toggles;
    for (int i = 0; i < 20; i++) {
        toggles.push_back({0x1, R"({"type":"inactive"})"});
        toggles.push_back({0x1, R"({"type":"active"})"});
    }
    const auto t0 = std::chrono::steady_clock::now();
    a->ws.send_frames(toggles);
    sleep_ms(5);
    bool through = false;
    for (int i = 0; i < 12 && !(through = sync(*b)); i++) {
    }
    const long ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
    size_t members = 0;
    while (a->ws.pump(500)) members += count(*a, typed("members"));
    members += count(*a, typed("members"));
    printf("  20 toggles from a session in %d rooms: another socket's round trip took %ld ms (%s);"
           " the session was sent %zu members frames\n",
           rooms, ms, through ? "answered" : "not answered", members);
}

// RELAY_LIVE_PROBE=hide: what one hide and one show pass cost the relay for a session in many
// rooms, each shared with one other socket, read as how long a third socket's round trip
// waits behind it; then a burst of toggles, which the pace folds into at most one more pass.
static void probe_hide_pass() {
    printf("probe: hide and show passes for a session in many rooms\n");
    const int rooms = 5000;
    auto a = login3(Ident(), "new", 0);
    auto b = login(Ident());
    std::vector<std::pair<uint8_t, std::string>> joins;
    for (int i = 0; i < rooms; i++) {
        joins.push_back({0x1, json{{"type", "join"}, {"room", room_name("hide-many") + "-" + std::to_string(i)}}.dump()});
    }
    a->ws.send_frames(joins);
    for (int i = 0; i < 12 && !sync(*a); i++) {
    }
    b->ws.send_frames(joins);
    for (int i = 0; i < 12 && !sync(*b); i++) {
    }
    while (a->ws.pump(200)) {
    }
    a->ws.inbox.clear();
    b->ws.inbox.clear();
    auto c = login(Ident());
    sync(*c);
    auto timed = [&](const char* type, const char* label) {
        const auto t0 = std::chrono::steady_clock::now();
        a->send({{"type", type}});
        sleep_ms(1);
        bool through = false;
        for (int i = 0; i < 12 && !(through = sync(*c)); i++) {
        }
        const long ms =
            std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
        size_t told = 0;
        while (b->ws.pump(300)) {
        }
        for (auto it = b->ws.inbox.begin(); it != b->ws.inbox.end(); it = b->ws.inbox.erase(it)) told++;
        printf("  %s pass over %d rooms: another socket's round trip took %ld ms (%s); %zu frames to the room's other socket\n",
               label, rooms, ms, through ? "answered" : "not answered", told);
    };
    timed("inactive", "hide");
    sleep_ms(PRESENCE_PACE_MS + 300);
    timed("active", "show");
    sleep_ms(PRESENCE_PACE_MS + 300);
    std::vector<std::pair<uint8_t, std::string>> toggles;
    for (int i = 0; i < 200; i++) {
        toggles.push_back({0x1, R"({"type":"inactive"})"});
        toggles.push_back({0x1, R"({"type":"active"})"});
    }
    toggles.push_back({0x1, R"({"type":"inactive"})"});
    const auto t0 = std::chrono::steady_clock::now();
    a->ws.send_frames(toggles);
    sleep_ms(PRESENCE_PACE_MS * 2 + 600);
    sync(*c);
    while (b->ws.pump(300)) {
    }
    size_t told = 0;
    for (auto it = b->ws.inbox.begin(); it != b->ws.inbox.end(); it = b->ws.inbox.erase(it)) told++;
    const long ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
    printf("  401 toggles in one write: the room's other socket was sent %zu frames in %ld ms\n", told, ms);
}

// Last of all: SIGTERM to the relay (its pid from run_live.sh), which then exits.
static void test_bounds_drain() {
    printf("bounds: on SIGTERM each session socket is told when to come back, then closed\n");
    const char* pid = getenv("RELAY_LIVE_PID");
    if (!pid) {
        printf("  skip drain (no relay pid)\n");
        return;
    }
    const std::string room = room_name("drain");
    auto a = login3(Ident(), "new", 0);
    auto b = login(Ident());
    join(*a, room);
    join(*b, room);
    settle({a.get(), b.get()});
    a->ws.inbox.clear();
    b->ws.inbox.clear();
    if (kill(static_cast<pid_t>(atoi(pid)), SIGTERM) != 0) {
        check("(the relay takes the signal)", false);
        return;
    }
    check("the session socket is closed", closed_by_relay(*a));
    check("and the one without a session", closed_by_relay(*b));
    size_t hints = 0, counted_after = 0;
    int64_t wait = -1;
    for (const auto& f : a->ws.inbox) {
        auto j = as_json(f);
        if (j && j->value("type", "") == "reconnect") {
            hints++;
            wait = j->value("after_ms", static_cast<int64_t>(-1));
        } else if (hints) {
            counted_after += counts_as(f);
        }
    }
    check("it was told once to come back after a wait in [2, 10] s", hints == 1 && wait >= 2000 && wait <= 10000);
    check("and nothing counted came after that", counted_after == 0);
    check("a socket without a session is told nothing", count(*b, typed("reconnect")) == 0);
}

// /server-stats keeps every field unless the operator sets PUBLIC_STATS=off
// (test_server_stats.cpp covers the off body).
static void test_public_stats() {
    printf("server stats: public by default\n");
    auto a = login(Ident());
    Socket s;
    const auto body = s.get("/server-stats");
    const json j = body ? json::parse(*body, nullptr, false) : json();
    check("the relay answers /server-stats", j.is_object());
    check("with the exact online count", j.is_object() && j.contains("online_users") && j["online_users"].is_number() &&
                                             j["online_users"].get<int64_t>() >= 1);
    check("and the activity fields", j.is_object() && j.contains("rx_mbps") && j.contains("tx_mbps") &&
                                         j.contains("fwd_delivered") && j.contains("send_dropped"));
    check("and the breaker's trip counts, in shadow mode",
          j.is_object() && j.contains("breaker") && j["breaker"].value("enforced", true) == false);
}

// --- New-connection rate (MAX_NEW_CONNS_PER_MIN_PER_IP) and HOLLOW_CONN_RATE_EXEMPT ---
//
// run_live.sh starts one more relay listing RATE_EXEMPT_SOURCE (127.0.241.3, written
// v4-mapped) and runs RELAY_LIVE_ONLY=rate_exempt against it.
static constexpr int RATE_EXEMPT_SOURCE = 60001;
static constexpr int RATE_PLAIN_SOURCE = 60002;
static constexpr int RATE_IDLE_SOURCE = 60003;

// A socket the relay lets in (it answers auth_hello), closed cleanly so its slot is back.
static bool let_in_and_closed() {
    auto p = open_socket(Ident());
    p->send({{"type", "auth_hello"}});
    const bool in = next_json(*p, typed("auth_challenge")).has_value();
    return p->ws.close_clean() && in;
}

static bool refused_for_rate() {
    auto p = open_socket(Ident());
    p->send({{"type", "auth_hello"}});
    return closed_by_relay(*p) && p->ws.close_code == 1008 && p->ws.close_reason == "rate_limit";
}

// A socket the relay let in, held open.
static std::unique_ptr<Peer> held_open() {
    auto p = open_socket(Ident());
    p->send({{"type", "auth_hello"}});
    if (!next_json(*p, typed("auth_challenge"))) check("(a held socket is let in)", false);
    return p;
}

static void test_rate_limit() {
    printf("rate: an address opens ten new sockets a minute\n");
    PinnedSource pin(RATE_PLAIN_SOURCE);
    auto first = held_open();
    bool all_in = true;
    for (int i = 0; i < 9; i++) all_in = let_in_and_closed() && all_in;
    check("an address opens ten sockets in a minute", all_in);
    check("the eleventh is refused with rate_limit", refused_for_rate());
}

// An address that closes each socket before it opens the next is counted all the same,
// at thirty a minute (MAX_NEW_CONNS_PER_MIN_PER_IDLE_IP): a phone opens one per push wake.
static void test_rate_limit_idle_address() {
    printf("rate: an address holding no socket keeps its window\n");
    PinnedSource pin(RATE_IDLE_SOURCE);
    bool all_in = true;
    for (int i = 0; i < 30; i++) all_in = let_in_and_closed() && all_in;
    check("an address opens thirty sockets in a minute, closing each", all_in);
    check("the thirty-first is refused with rate_limit while none is open", refused_for_rate());
}

static void test_rate_exempt() {
    printf("rate: a listed address skips the rate and only the rate\n");
    {
        PinnedSource pin(RATE_EXEMPT_SOURCE);
        std::vector<std::unique_ptr<Peer>> held;
        held.push_back(held_open());
        bool all_in = true;
        for (int i = 0; i < 14; i++) all_in = let_in_and_closed() && all_in;
        check("a listed address opens more than ten sockets in a minute", all_in);
        held.push_back(held_open());
        held.push_back(held_open());
        check("and still no more at once than any address", refused_at_open(Ident()));
    }
    test_rate_limit();
}

// --- The circuit breaker (breaker.h, phase G2) --------------------------------------------
//
// run_live.sh runs these against relays whose budgets and times are scaled down
// (HOLLOW_RELAY_TEST_BREAKER_W / _T below): its shadow build (RELAY_LIVE_ONLY=breaker_shadow)
// and one built with HOLLOW_BREAKER_ENFORCE=1 (=breaker_enforce), which also names the
// forwarder below. Each socket dials from an address of its own, so each is its own group
// and its own block.
static constexpr int64_t BRK_W = 100;
static constexpr int64_t BRK_T = 60;
static constexpr unsigned char BRK_FORWARDER_SEED = 0x42;

// One payer's buckets, as the test relay reports them (/breaker-test).
static json breaker_of(const std::string& peer) {
    Socket s;
    const auto body = s.get("/breaker-test?peer=" + peer);
    json j = body ? json::parse(*body, nullptr, false) : json();
    return j.is_object() ? j : json::object();
}

static int64_t spent_of(const std::string& peer) { return breaker_of(peer).value("spent", int64_t(-1)); }

// /server-stats' breaker counts. The relay keeps an answer for 5 s, so a caller comparing
// two reads waits that long in between.
static json breaker_counts() {
    Socket s;
    const auto body = s.get("/server-stats");
    const json j = body ? json::parse(*body, nullptr, false) : json();
    return j.is_object() && j.contains("breaker") ? j["breaker"] : json::object();
}

// Broadcasts "<tag>-<i>" into `room`, in batches, until the relay closes the socket or
// `max` went. How many were written.
static size_t flood(Peer& p, const std::string& room, const std::string& tag, size_t max) {
    size_t sent = 0;
    while (sent < max && !p.ws.closed()) {
        std::vector<std::pair<uint8_t, std::string>> frames;
        for (size_t i = 0; i < 100 && sent < max; i++, sent++) {
            frames.push_back({0x2, frame(0x03, {room}, tag + "-" + std::to_string(sent))});
        }
        p.ws.send_frames(frames);
        p.ws.pump(5);
    }
    return sent;
}

// The indices of "<tag>-<i>" broadcasts from `from` that `p` read, waiting for `last`.
static std::map<size_t, size_t> heard(Peer& p, const std::string& room, const std::string& from, const std::string& tag,
                                      size_t last, int timeout_ms = WAIT_MS) {
    std::map<size_t, size_t> seen;
    const std::string head = frame(0x05, {room, from}, tag + "-");
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    for (;;) {
        for (auto it = p.ws.inbox.begin(); it != p.ws.inbox.end();) {
            if (!it->text && it->data.compare(0, head.size(), head) == 0) {
                seen[std::stoul(it->data.substr(head.size()))]++;
                it = p.ws.inbox.erase(it);
            } else {
                ++it;
            }
        }
        if (seen.count(last) || left_ms(deadline) <= 0) return seen;
        p.ws.pump(std::min(left_ms(deadline), 200));
    }
}

static bool each_once(const std::map<size_t, size_t>& seen, size_t upto) {
    if (seen.size() != upto + 1) return false;
    for (size_t i = 0; i <= upto; i++) {
        auto it = seen.find(i);
        if (it == seen.end() || it->second != 1) return false;
    }
    return true;
}

static std::optional<json> breaker_hint(Peer& p) {
    return next_json(p, json_where([](const json& j) { return j.value("type", "") == "reconnect"; }));
}

static json lock_get_of(size_t n) {
    json locks = json::array();
    for (size_t i = 0; i < n; i++) locks.push_back({{"server", random_hex(20)}, {"owner", ""}});
    return {{"type", "lock_get"}, {"locks", locks}};
}

static void test_breaker_trip_resends() {
    printf("breaker (enforced): a trip closes 1013 with the hint, and the frame comes back once\n");
    const std::string room = room_name("brk-trip");
    Ident ida;
    auto a = login3(ida, "new", 0);
    auto b = login3(Ident(), "new", 0);
    check("a fresh session is told its start credit", a->answer.value("credit", int64_t(0)) == 400'000 / BRK_W);
    check("and that the relay enforces", a->answer.value("enforced", false));
    join(*a, room);
    join(*b, room);
    settle({a.get(), b.get()});
    const int64_t joined = spent_of(ida.peer);
    flood(*a, room, "t", 20'000);
    auto hint = breaker_hint(*a);
    check("the relay tells the device to come back, as the breaker",
          hint && hint->value("breaker", false) && hint->value("after_ms", int64_t(0)) > 0);
    check("and closes 1013, never 1008", closed_by_relay(*a) && a->ws.close_code == 1013);
    check("with one hint for the one close", count(*a, typed("reconnect")) == 0);
    const json paused = breaker_of(ida.peer);
    check("a first trip inside the honest budget is a pure pause",
          paused.value("session_paused_ms", int64_t(0)) > 0 && paused.value("cooldown_ms", int64_t(-1)) == 0);
    const int64_t at_trip = paused.value("spent", int64_t(-1));
    sleep_ms(static_cast<int>(hint ? hint->value("after_ms", int64_t(0)) : 0) + 100);
    auto a2 = login3(ida, a->sid, a->ws.counted);
    check("after the pause the session resumes", resumed(*a2));
    check("its resume says the relay enforces", a2->answer.value("enforced", false));
    check("and its pause left no long grace behind", !breaker_of(ida.peer).value("long_grace", true));
    const uint64_t h = a2->answer.value("h", uint64_t(0));
    // Counted before the flood: the join and the barrier's discover.
    check("with the tripping frame uncounted", h >= 3);
    const size_t k = static_cast<size_t>(h - 2);
    check("the trip and its close charged nothing past the frames handled", at_trip == joined + 2 * static_cast<int64_t>(k));
    check("the resume after a breaker pause is free", spent_of(ida.peer) == at_trip);
    a2->send_bin(frame(0x03, {room}, "t-" + std::to_string(k)));
    const auto seen = heard(*b, room, ida.peer, "t", k);
    check("every frame up to the resent one arrived exactly once", each_once(seen, k));
    // No barrier: the resumed session's bucket holds just what the resent frame cost.
    check("and nothing after it", heard(*b, room, ida.peer, "t", k + 1, 500).empty());
}

static void test_breaker_waits_before_binding() {
    printf("breaker (enforced): a paused device's logins wait, hb and ack never trip\n");
    const std::string room = room_name("brk-wait");
    Ident ida;
    auto a = login3(ida, "new", 0);
    auto b = login3(Ident(), "new", 0);
    join(*a, room);
    join(*b, room);
    flood(*a, room, "w", 20'000);
    auto hint = breaker_hint(*a);
    closed_by_relay(*a);
    sleep_ms(static_cast<int>(hint ? hint->value("after_ms", int64_t(0)) : 0) + 100);
    auto a2 = login3(ida, a->sid, a->ws.counted);
    check("the session is back, its bucket nearly empty", resumed(*a2) && breaker_of(ida.peer).value("w", 0) < 50);
    for (uint64_t i = 0; i < 20; i++) a2->send({{"type", "hb"}, {"h", a2->ws.counted}});
    a2->send({{"type", "ack"}, {"h", 0}});
    a2->send({{"type", "inactive"}});
    a2->send({{"type", "active"}});
    size_t acks = 0;
    while (next_json(*a2, typed("hb_ack"), 2000)) acks++;
    check("twenty heartbeats on an empty bucket are each answered", acks == 20 && !a2->ws.closed());
    a2->send(lock_get_of(30));
    auto hint2 = breaker_hint(*a2);
    const int64_t wait = hint2 ? hint2->value("after_ms", int64_t(0)) : 0;
    check("a frame its bucket cannot pay for pauses it as long as the refill takes",
          wait >= 3000 && closed_by_relay(*a2) && a2->ws.close_code == 1013);
    auto fresh = login3(ida, "new", 0);
    check("a fresh login during the pause is refused before it binds anything",
          fresh->answer.value("type", "") == "auth_failed" && fresh->answer.value("error", "") == "cooldown" &&
              fresh->answer.value("after_ms", int64_t(0)) > 0 && closed_by_relay(*fresh) && fresh->ws.close_code == 1013);
    auto early = login3(ida, a->sid, a2->ws.counted);
    check("so is the resume", early->answer.value("error", "") == "cooldown");
    check("and the session is still held", breaker_of(ida.peer).value("session_paused_ms", int64_t(0)) > 0);
    sleep_ms(static_cast<int>(breaker_of(ida.peer).value("session_paused_ms", int64_t(0))) + 200);
    auto a3 = login3(ida, a->sid, a2->ws.counted);
    check("once the pause is over it resumes", resumed(*a3));
}

static void test_breaker_fetch_cools_nothing() {
    printf("breaker (enforced): a fetch socket's trip closes it and cools nothing\n");
    const std::string room = room_name("brk-fetch");
    Ident d;
    auto m = login3(Ident(), "new", 0);
    join(*m, room);
    auto f = login(d, "fetch");
    f->send({{"type", "join"}, {"room", room}});
    for (int round = 0; round < 50 && !f->ws.closed(); round++) {
        std::vector<std::pair<uint8_t, std::string>> frames;
        for (int i = 0; i < 20; i++) frames.push_back({0x2, frame(0x04, {room, m->id.peer}, "fd")});
        f->ws.send_frames(frames);
        f->ws.pump(5);
    }
    auto hint = breaker_hint(*f);
    check("a fetch socket trips with a fixed pause",
          hint && hint->value("breaker", false) && hint->value("after_ms", int64_t(0)) == 30'000 / BRK_T);
    check("and closes 1013", closed_by_relay(*f) && f->ws.close_code == 1013);
    auto full = login3(d, "new", 0);
    check("its device's full login is not refused", full->ok && breaker_of(d.peer).value("cooldown_ms", int64_t(-1)) == 0);
}

static void test_breaker_forwarder_exempt() {
    printf("breaker (enforced): the configured forwarder pays nothing\n");
    Ident fwd;
    unsigned char seed[crypto_sign_SEEDBYTES];
    memset(seed, BRK_FORWARDER_SEED, sizeof(seed));
    crypto_sign_seed_keypair(fwd.pk, fwd.sk, seed);
    unsigned char proto[36] = {0x08, 0x01, 0x12, 0x20};
    memcpy(proto + 4, fwd.pk, 32);
    fwd.pub_b64 = b64(proto, sizeof(proto));
    fwd.peer = derive_peer_id(fwd.pub_b64);
    const std::string room = "fwd:" + fwd.peer;
    auto x = login3(fwd, "new", 0);
    auto v = login3(Ident(), "new", 0);
    join(*x, room);
    join(*v, room);
    flood(*x, room, "x", 6'000);
    check("its flood never trips", hb(*x, x->ws.counted).value("type", "") == "hb_ack" && !x->ws.closed());
}

static void test_breaker_audience() {
    printf("breaker (enforced): a post pays for the room's visible audience only\n");
    Ident owner, change;
    Door door;
    const std::string nonce = random_hex(16);
    const std::string room = genesis_server_id(owner.peer, nonce);
    auto p = login3(Ident(), "new", 0);
    p->send({{"type", "lock_put"}, {"server", room}, {"owner", ""},
             {"links", base_link(room, door, change, owner, nonce, true)}});
    next_json(*p, typed("lock_chain"));
    join(*p, room, {{"door_proof", door_proof(*p, room, door)}});
    auto p2 = login3(Ident(), "new", 0);
    join(*p2, room, {{"door_proof", door_proof(*p2, room, door)}});
    auto q = login3(Ident(), "new", 0);
    join(*q, room);
    auto w = login3(Ident(), "new", 0);
    join(*w, room);
    auto g = login(Ident(), "guest");
    g->send({{"type", "join"}, {"room", room}});
    settle({p.get(), p2.get(), q.get(), w.get(), g.get()});
    const int64_t before = spent_of(p->id.peer);
    p->send_bin(frame(0x03, {room}, "seen"));
    check("the prover hears it", next(*p2, bin(frame(0x05, {room, p->id.peer}, "seen"))).has_value());
    const int64_t after_bcast = spent_of(p->id.peer);
    check("hidden sockets in a door room cost the poster nothing", after_bcast - before == 2);
    p->send_bin(frame(0x0A, {room}, "public"));
    check("a public frame reaches a guest", next(*g, bin(frame(0x05, {room, p->id.peer}, "public"))).has_value());
    check("and the poster pays for the members alone, the room's allowance for the rest",
          spent_of(p->id.peer) - after_bcast == 2);
    // D1 lets a hidden socket's broadcast reach the provers (a door ask, a join ask, a
    // guest's sync ask: HOL-SEC-127), so it pays for each prover it reaches.
    const int64_t q_before = spent_of(q->id.peer);
    q->send_bin(frame(0x03, {room}, "hidden-ask"));
    check("a hidden socket's broadcast still reaches the provers",
          next(*p2, bin(frame(0x05, {room, q->id.peer}, "hidden-ask"))).has_value());
    check("and its sender pays for both of them", spent_of(q->id.peer) - q_before == 3);
}

// MED 5: proofs that open nothing (strangers' junk) are judged at every lock move, but
// the relay pays for them, never the moderator moving the lock: the same move costs the
// mover the same with twenty junk proofs stored as with none.
static int64_t breaker_move_cost(size_t junk) {
    Ident owner, change, change2;
    Door door, door2;
    const std::string nonce = random_hex(16);
    const std::string room = genesis_server_id(owner.peer, nonce);
    const json base = base_link(room, door, change, owner, nonce, true);
    auto m = login3(Ident(), "new", 0);
    m->send({{"type", "lock_put"}, {"server", room}, {"owner", ""}, {"links", base}});
    next_json(*m, typed("lock_chain"));
    join(*m, room, {{"door_proof", door_proof(*m, room, door)}});
    std::vector<std::unique_ptr<Peer>> strangers;
    for (size_t i = 0; i < junk; i++) {
        strangers.push_back(login3(Ident(), "new", 0));
        join(*strangers.back(), room, {{"door_proof", random_b64url32()}});
    }
    for (auto& p : strangers) settle({p.get()});
    settle({m.get()});
    const int64_t before = spent_of(m->id.peer);
    json links = base;
    links.push_back(successor_link(room, 2, door2, change2, change));
    m->send({{"type", "lock_put"}, {"server", room}, {"owner", ""}, {"links", links}});
    next_json(*m, typed("lock_chain"));
    settle({m.get()});
    return spent_of(m->id.peer) - before;
}

static void test_breaker_junk_proofs_do_not_cost_the_mover() {
    printf("breaker (enforced): junk door proofs do not cost the moderator who moves the lock\n");
    const int64_t clean = breaker_move_cost(0);
    const int64_t crowded = breaker_move_cost(20);
    printf("    a move costs %lld W, %lld W with twenty junk proofs stored\n", static_cast<long long>(clean),
           static_cast<long long>(crowded));
    check("twenty junk proofs add nothing to the mover's charge", clean > 0 && crowded == clean);
}

// MED 5: a guest in an unlocked room is paid for by the room's allowance, like one outside
// a locked room's audience: the poster pays for the member devices it can count.
static void test_breaker_unlocked_guest() {
    printf("breaker (enforced): a guest in an unlocked room is the room allowance's\n");
    const std::string room = room_name("brk-open");
    auto p = login3(Ident(), "new", 0);
    auto q = login3(Ident(), "new", 0);
    auto g = login(Ident(), "guest");
    join(*p, room);
    join(*q, room);
    g->send({{"type", "join"}, {"room", room}});
    settle({p.get(), q.get(), g.get()});
    const int64_t before = spent_of(p->id.peer);
    p->send_bin(frame(0x03, {room}, "open"));
    check("the member hears it", next(*q, bin(frame(0x05, {room, p->id.peer}, "open"))).has_value());
    check("so does the guest", next(*g, bin(frame(0x05, {room, p->id.peer}, "open"))).has_value());
    check("and the poster pays for the member alone", spent_of(p->id.peer) - before == 2);
}

// A fresh session counts its strangers from nothing, as its pacer does (the stranger book
// outlives a session): two sessions of 300 new strangers each stay under the scaled 500.
static void test_breaker_fresh_session_counts_strangers_afresh() {
    printf("breaker (enforced): a fresh session counts its strangers afresh\n");
    const std::string room = room_name("brk-strangers");
    Ident ida;
    auto deposit = [&](Peer& p, size_t n) {
        std::vector<std::pair<uint8_t, std::string>> frames;
        for (size_t i = 0; i < n; i++) frames.push_back({0x2, frame(0x04, {room, Ident().peer}, "x")});
        p.ws.send_frames(frames);
        p.ws.pump(50);
    };
    auto a = login3(ida, "new", 0);
    deposit(*a, 300);
    check("300 strangers pass", hb(*a, a->ws.counted).value("type", "") == "hb_ack");
    auto a2 = login3(ida, "new", 0);
    deposit(*a2, 300);
    check("and 300 more in a fresh session", hb(*a2, a2->ws.counted).value("type", "") == "hb_ack" && !breaker_hint(*a2));
}

static void test_breaker_pause_holds_no_slot() {
    printf("breaker (enforced): a paused session holds no per-IP slot\n");
    PinnedSource pin(50101);
    const std::string room = room_name("brk-slot");
    Ident ida;
    auto a = login3(ida, "new", 0);
    auto b = login3(Ident(), "new", 0);
    auto c = login(Ident());
    join(*a, room);
    join(*b, room);
    flood(*a, room, "slot", 20'000);
    auto hint = breaker_hint(*a);
    closed_by_relay(*a);
    sleep_ms(static_cast<int>(hint ? hint->value("after_ms", int64_t(0)) : 0) + 100);
    auto a2 = login3(ida, a->sid, a->ws.counted);
    check("the paused device resumes at its own address", resumed(*a2));
    a2->send(lock_get_of(30));
    auto hint2 = breaker_hint(*a2);
    check("a pause long enough to look at the address",
          hint2 && hint2->value("after_ms", int64_t(0)) >= 3000 && closed_by_relay(*a2));
    auto d = login(Ident());
    check("its full address takes a newcomer meanwhile: the pause holds no slot", d->ok);
    d->ws.close_clean();
    sleep_ms(static_cast<int>(breaker_of(ida.peer).value("session_paused_ms", int64_t(0))) + 200);
    auto a3 = login3(ida, a->sid, a2->ws.counted);
    check("and the device resumes once the pause is over", resumed(*a3));
}

// Sends `n` heartbeats (control frames: charged one W each, never tripped) and drains their acks.
static void hb_flood(Peer& p, size_t n) {
    const std::string hb_text = json{{"type", "hb"}, {"h", 0}}.dump();
    for (size_t sent = 0; sent < n && !p.ws.closed();) {
        std::vector<std::pair<uint8_t, std::string>> frames;
        for (size_t i = 0; i < 100 && sent < n; i++, sent++) frames.push_back({0x1, hb_text});
        p.ws.send_frames(frames);
        p.ws.pump(5);
    }
    while (next_json(p, typed("hb_ack"), 500)) {
    }
}

static void test_breaker_ladder_window() {
    printf("breaker (enforced): the ladder steps only for a window that overspent the honest budget\n");
    const std::string room = room_name("brk-ladder");
    // Scaled: start 4,000, cap 8,000, 10 W/s, a 10 s window worth 8,100.
    const size_t half = 6'500;
    Ident ida;
    auto a = login3(ida, "new", 0);
    join(*a, room);
    hb_flood(*a, half);
    sleep_ms(11'000);
    hb_flood(*a, half);
    check("two spends a window apart pass start + cap over the session's life",
          spent_of(ida.peer) > 3 * 400'000 / BRK_W);
    a->send_bin(frame(0x03, {room}, "late"));
    auto hint = breaker_hint(*a);
    check("its trip is a pure pause, the device not cooled",
          hint && closed_by_relay(*a) && breaker_of(ida.peer).value("cooldown_ms", int64_t(-1)) == 0);
    Ident idb;
    auto b = login3(idb, "new", 0);
    join(*b, room);
    hb_flood(*b, 2 * half);
    b->send_bin(frame(0x03, {room}, "over"));
    auto hint_b = breaker_hint(*b);
    check("a session that overspent inside one window cools its device",
          hint_b && closed_by_relay(*b) && breaker_of(idb.peer).value("cooldown_ms", int64_t(0)) > 0 &&
              hint_b->value("after_ms", int64_t(0)) >= 60'000 / BRK_T);
}

static void test_breaker_shadow() {
    printf("breaker (shadow): a flood is booked, counted and let through\n");
    const json counts0 = breaker_counts();
    check("the relay says it does not enforce", counts0.value("enforced", true) == false);
    const std::string room = room_name("brk-shadow");
    Ident ida;
    auto a = login3(ida, "new", 0);
    auto b = login3(Ident(), "new", 0);
    check("a fresh session is told its start credit", a->answer.value("credit", int64_t(0)) == 400'000 / BRK_W);
    check("but not that the relay enforces: a pacing client never waits", !a->answer.contains("enforced"));
    join(*a, room);
    join(*b, room);
    const size_t n = 3'500;
    flood(*a, room, "s", n);
    check("nothing is closed", hb(*a, a->ws.counted).value("type", "") == "hb_ack" && !a->ws.closed());
    check("nothing is held back", each_once(heard(*b, room, ida.peer, "s", n - 1, 20'000), n - 1));
    const json acct = breaker_of(ida.peer);
    check("the bucket went into debt, down to the floor at most",
          acct.value("tripped", false) && acct.value("w", 0) < 0 && acct.value("w", 0) >= -100'000 / BRK_W);
    a->ws.abort();
    sleep_ms(300);
    const int64_t before_resume = spent_of(ida.peer);
    auto a2 = login3(ida, a->sid, a->ws.counted);
    check("a resume in debt is let in", resumed(*a2));
    check("and is not told the relay enforces", !a2->answer.contains("enforced"));
    check("and costs its flat four W per room held", spent_of(ida.peer) == before_resume + 4);
    sleep_ms(5'200);
    const json counts = breaker_counts();
    check("the trips enforcement would have made are counted",
          counts.value("trips", 0) >= counts0.value("trips", 0) + 1);
    check("and the resume it would have refused", counts.value("refused", 0) >= counts0.value("refused", 0) + 1);
}

// /server-stats as a whole, read fresh (the relay keeps an answer for 5 s).
static json fresh_server_stats() {
    sleep_ms(5'500);
    Socket s;
    const auto body = s.get("/server-stats");
    const json j = body ? json::parse(*body, nullptr, false) : json();
    return j.is_object() ? j : json::object();
}

// The seam with the send budget: the breaker's trips above are its own, never a send
// budget trip or refusal (this relay runs the production budget).
static void test_breaker_trips_are_no_budget_trips() {
    printf("breaker (enforced): its trips are no send-budget trips\n");
    const json st = fresh_server_stats();
    check("the breaker tripped", st.value("breaker", json::object()).value("trips", 0) > 0);
    check("and the send budget counted no trip and no refusal of its own",
          st.value("fanout_tripped", -1) == 0 && st.value("fanout_refused", -1) == 0);
}

// The send-buffer memory budget (src/send_budget.h). uWebSockets keeps a full copy of
// every frame a socket has not drained, so unbounded, receivers that do not read grow the
// relay's buffers until the box is OOM-killed (no snapshot). These cases check honest
// behaviour and bounded effects against a relay built with a tiny budget and a short
// stall window (run_live.sh =oom); the fairness rules themselves are proven by
// test_send_budget.cpp. RSS is checked only where /proc is available.
static uint64_t env_u64(const char* name) {
    const char* v = getenv(name);
    return v ? strtoull(v, nullptr, 10) : 0;
}

static int oom_stall_ms() {
    const uint64_t v = env_u64("RELAY_LIVE_STALL_MS");
    return v ? static_cast<int>(v) : 5000;
}

static bool closed_within(Peer& p, int ms) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
    while (!p.ws.closed() && left_ms(deadline) > 0) {
        p.ws.pump(std::min(200, std::max(1, left_ms(deadline))));
        p.ws.inbox.clear();
    }
    return p.ws.closed();
}

static void drain_inbox(Peer& p) {
    while (p.ws.pump(2)) {}
    p.ws.inbox.clear();
}

// Honest traffic passes: a sender broadcasting into a room of receivers that never read
// is never tripped (their own address shares hold the bytes, so they give way), the
// reader gets every broadcast exactly once, the relay's RSS stays bounded and every
// non-reader is closed.
static void oom_honest_fanout_evicts_nonreaders() {
    printf("oom: a broadcast into non-reading receivers closes them, never the honest sender\n");
    const uint64_t budget = env_u64("RELAY_LIVE_SEND_BUDGET");
    if (budget == 0) {
        check("(the relay runs with a small send budget)", false);
        return;
    }
    const std::string room = room_name("oom");
    auto reader = login(Ident());
    join(*reader, room);
    // Each on its own address (the test build caps an address at three sockets), with a
    // tiny receive window so the kernel cannot drain it.
    std::vector<std::unique_ptr<Peer>> slow;
    for (int i = 0; i < 6; i++) {
        g_rcvbuf = 16 << 10;
        auto p = login(Ident());
        g_rcvbuf = 0;
        join(*p, room);
        next(*reader, about("peer_joined", room, p->id.peer));
        slow.push_back(std::move(p));
    }
    Ident sid;
    auto sender = login(sid);
    join(*sender, room);
    next(*reader, about("peer_joined", room, sid.peer));
    sync(*sender);

    const long rss0 = relay_rss_kb();
    const std::string chunk(2u << 20, 'x');
    constexpr int SENT = 12;  // 24 MiB into each non-reader: past its socket cap
    std::vector<std::string> expect;
    std::vector<int> copies(SENT, 0);
    // A non-reader's close is watched through the reader's presence, never by reading it.
    std::set<std::string> left;
    auto drain_reader = [&](int ms) {
        while (reader->ws.pump(ms)) {}
        for (const auto& f : reader->ws.inbox) {
            for (size_t i = 0; i < expect.size(); i++) {
                if (!f.text && f.data == expect[i]) copies[i]++;
            }
            if (auto j = as_json(f); j && j->value("type", "") == "peer_left" && j->value("room", "") == room) {
                left.insert(j->value("peer_id", ""));
            }
        }
        reader->ws.inbox.clear();
    };
    for (int i = 0; i < SENT; i++) {
        const std::string payload = "b" + std::to_string(i) + ":" + chunk;
        expect.push_back(frame(0x05, {room, sid.peer}, payload));
        sender->send_bin(frame(0x03, {room}, payload));
        drain_reader(20);
    }
    const bool sender_ok = sync(*sender) && !sender->ws.closed();
    drain_reader(500);
    check("the honest sender is never tripped", sender_ok);
    bool once = true;
    for (int c : copies) once = once && c == 1;
    check("the reader gets every broadcast exactly once", once);
    const long rss1 = relay_rss_kb();
    if (rss0 > 0 && rss1 > 0) {
        // ASan's quarantine keeps freed buffers resident (256 MiB by default): only a
        // sanitized relay gets that much more.
        const long asan_kb = env_u64("RELAY_LIVE_SANITIZED") == 1 ? 256 * 1024 : 0;
        const long bound_kb = static_cast<long>(budget / 1024) * 3 + 64 * 1024 + asan_kb;
        printf("  relay RSS %ld -> %ld KiB (+%ld; sent %d), bound %+ld\n", rss0, rss1, rss1 - rss0, SENT, bound_kb);
        check("the relay's RSS stays bounded by the budget, not by what was sent", rss1 - rss0 < bound_kb);
    }
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(oom_stall_ms() + 4000);
    while (left.size() < slow.size() && left_ms(deadline) > 0) drain_reader(100);
    bool all_left = true;
    for (auto& p : slow) all_left = all_left && left.count(p->id.peer);
    check("every receiver that never drains is closed", all_left);
    check("and the sender still syncs", sync(*sender));
}

// A sender whose address share holds the most, with the bytes on ANOTHER socket of that
// address (a co-tenant behind the same carrier address): that socket gives way, never the
// sender, which would otherwise trip, free nothing and trip again on every resume. The
// share is held by a partial inbound frame (charged by the once-a-second sweep).
static void oom_cotenant_gives_way_before_sender_trips() {
    printf("oom: a co-tenant's held bytes give way before the sender on its address trips\n");
    const uint64_t budget = env_u64("RELAY_LIVE_SEND_BUDGET");
    if (budget == 0) {
        check("(the relay runs with a small send budget)", false);
        return;
    }
    // With a 32 MiB budget: 6 MiB held, 3 x 9 MiB copies = 33 MiB > 32.
    const uint64_t hold = budget * 3 / 16, size = budget * 9 / 32;
    const std::string room = room_name("oom-cotenant");
    std::vector<std::unique_ptr<Peer>> readers;
    for (int i = 0; i < 3; i++) {
        readers.push_back(login(Ident()));
        join(*readers.back(), room);
    }
    g_pin_source = 60010;
    Ident sid;
    auto sender = login3(sid, "new", 0);
    join(*sender, room);
    sync(*sender);
    auto holder = login(Ident());
    g_pin_source = -1;
    holder->ws.send_partial(hold, 64 << 10);
    sleep_ms(1500);  // the sweep charges the held frame to the sender's share
    for (auto& r : readers) drain_inbox(*r);

    const std::string payload = "cotenant:" + std::string(size, 'k');
    const std::string expect = frame(0x05, {room, sid.peer}, payload);
    sender->send_bin(frame(0x03, {room}, payload));
    bool arrived = true;
    for (auto& r : readers) arrived = arrived && next(*r, bin(expect), 10000).has_value();
    check("the sender's frame reaches every receiver", arrived);
    check("the sender is not tripped", sync(*sender) && !sender->ws.closed());
    check("the co-tenant holding the bytes is closed at once, before the stall sweep",
          closed_within(*holder, 2000));
    bool once = true;
    for (auto& r : readers) {
        settle({r.get()});
        once = once && count(*r, bin(expect)) == 0;
    }
    check("and the frame arrives exactly once", once);
}

// A sender whose own unsent buffer holds the most trips when its fan-out does not fit: it
// is closed 1013 uncounted (which frees what it held), resumes, and its re-sent frame
// arrives exactly once.
static void oom_tripped_sender_resumes_frame_once() {
    printf("oom: a sender whose own buffer holds the most trips, resumes and its frame arrives once\n");
    const uint64_t budget = env_u64("RELAY_LIVE_SEND_BUDGET");
    if (budget == 0) {
        check("(the relay runs with a small send budget)", false);
        return;
    }
    // With a 32 MiB budget: a 14 MiB frame into the sender (under its 16 MiB socket cap,
    // about 10 MiB of it past the kernel), then 3 x 9 MiB copies: over 32 (a trip, not a
    // refusal).
    const uint64_t feed = budget * 7 / 16, size = budget * 9 / 32;
    const std::string room = room_name("oom-trip"), feed_room = room_name("oom-feed");
    std::vector<std::unique_ptr<Peer>> readers;
    for (int i = 0; i < 3; i++) {
        readers.push_back(login(Ident()));
        join(*readers.back(), room);
    }
    Ident sid;
    g_rcvbuf = 16 << 10;
    auto sender = login3(sid, "new", 0);
    g_rcvbuf = 0;
    join(*sender, room);
    join(*sender, feed_room);
    sync(*sender);
    auto feeder = login(Ident());
    join(*feeder, feed_room);
    for (auto& r : readers) drain_inbox(*r);
    feeder->send_bin(frame(0x03, {feed_room}, "feed:" + std::string(feed, 'f')));
    sync(*feeder);  // the relay has written the feed into the sender's buffer

    const std::string payload = "trip:" + std::string(size, 't');
    const std::string expect = frame(0x05, {room, sid.peer}, payload);
    sender->send_bin(frame(0x03, {room}, payload));
    check("the sender is closed by the breaker", closed_by_relay(*sender));
    const uint64_t read = sender->ws.counted;
    for (auto& r : readers) settle({r.get()});
    bool none = true;
    for (auto& r : readers) none = none && !got(*r, bin(expect));
    check("the tripping frame was not delivered", none);

    auto s2 = login3(sid, sender->sid, read);
    check("the tripped sender's session resumes", resumed(*s2));
    check("the tripping frame stayed uncounted (two joins and sync only)",
          s2->answer.value("h", static_cast<uint64_t>(0)) == 3);
    join(*s2, room);
    sync(*s2);
    s2->send_bin(frame(0x03, {room}, payload));
    bool arrived = true;
    for (auto& r : readers) arrived = arrived && next(*r, bin(expect), 10000).has_value();
    check("its re-sent frame reaches every receiver", arrived);
    check("(the resumed sender is not tripped again)", sync(*s2) && !s2->ws.closed());
    bool once = true;
    for (auto& r : readers) {
        settle({r.get()});
        once = once && count(*r, bin(expect)) == 0;
    }
    check("and arrives exactly once", once);
}

// N7: a fan-out larger than the WHOLE budget can never be held at once, so the relay
// refuses it ONCE (counting it, so the client drops it) and the sender does not reconnect
// forever. The frame itself fits a share; three copies do not fit the budget.
static void oom_unbufferable_fanout_refused_once() {
    printf("oom: a fan-out past the whole budget is refused once, never looped\n");
    const uint64_t budget = env_u64("RELAY_LIVE_SEND_BUDGET");
    if (budget == 0) {
        check("(the relay runs with a small send budget)", false);
        return;
    }
    const std::string room = room_name("oom-big");
    std::vector<std::unique_ptr<Peer>> readers;
    for (int i = 0; i < 3; i++) {
        readers.push_back(login(Ident()));
        join(*readers.back(), room);
    }
    Ident sid;
    auto sender = login3(sid, "new", 0);
    join(*sender, room);
    sync(*sender);
    for (auto& r : readers) drain_inbox(*r);

    const std::string big = "big:" + std::string(budget * 3 / 8, 'x');  // 3 copies > the budget
    sender->send_bin(frame(0x03, {room}, big));
    check("the sender is closed by the breaker (1013)", closed_by_relay(*sender) && sender->ws.close_code == 1013);
    const uint64_t read = sender->ws.counted;
    std::vector<json> hints;
    for (const auto& f : sender->ws.inbox) {
        if (auto j = as_json(f); j && j->value("type", "") == "reconnect") hints.push_back(*j);
    }
    check("with one plain reconnect hint, never the circuit breaker's pause",
          hints.size() == 1 && !hints[0].contains("breaker") && hints[0].value("after_ms", int64_t(0)) == 2000);
    const json books = breaker_of(sid.peer);
    check("and the breaker's books for the sender untouched: no trip, pause, cooldown or long grace",
          books.value("ready", false) && !books.value("tripped", true) && books.value("session_paused_ms", int64_t(-1)) == 0 &&
              books.value("cooldown_ms", int64_t(-1)) == 0 && !books.value("long_grace", true));

    auto s2 = login3(sid, sender->sid, read);
    check("the sender resumes (the refused frame was counted, so no reconnect loop)", resumed(*s2));
    check("the relay counted join, sync and the refused frame", s2->answer.value("h", static_cast<uint64_t>(0)) == 3);
    join(*s2, room);
    sync(*s2);
    s2->send_bin(frame(0x03, {room}, "small"));
    bool small = true;
    for (auto& r : readers) small = small && next(*r, bin(frame(0x05, {room, sid.peer}, "small")), 8000).has_value();
    check("a normal broadcast after the refusal is delivered", small);
    bool never = true;
    for (auto& r : readers) never = never && !got(*r, bin(frame(0x05, {room, sid.peer}, big)));
    check("the unbufferable frame was never delivered", never);
}

// The walk both judges share counts at most two receivers per address block (the test
// build's count; eight in production), so receivers piled behind one address cannot make
// an honest frame trip: two copies fit the budget, a third is that address's to refuse.
static void oom_piled_receivers_never_trip_the_sender() {
    printf("oom: receivers piled behind one address never trip the sender\n");
    const uint64_t budget = env_u64("RELAY_LIVE_SEND_BUDGET");
    if (budget == 0) {
        check("(the relay runs with a small send budget)", false);
        return;
    }
    const std::string room = room_name("oom-pile");
    std::vector<std::unique_ptr<Peer>> pile;
    {
        PinnedSource pin(60040);
        for (int i = 0; i < 3; i++) {
            g_rcvbuf = 16 << 10;
            pile.push_back(login(Ident()));
            g_rcvbuf = 0;
            join(*pile.back(), room);
        }
    }
    Ident sid;
    auto sender = login3(sid, "new", 0);
    join(*sender, room);
    sync(*sender);
    for (auto& p : pile) drain_inbox(*p);
    // With a 32 MiB budget: two 12 MiB copies fit, three do not.
    sender->send_bin(frame(0x03, {room}, "pile:" + std::string(budget * 3 / 8, 'p')));
    check("three receivers behind one address count as two: the sender is not tripped",
          sync(*sender) && !sender->ws.closed());
    for (auto& p : pile) p->ws.abort();
    sleep_ms(500);
}

// The seam with the circuit breaker: the send budget's trips and refusals above are no
// breaker trips. The breaker (shadow, at full size here) counted none, stepped no ladder
// and cools no device, while the budget counted its own.
static void oom_trips_are_no_breaker_trips() {
    printf("oom: the send budget's trips are no circuit-breaker trips\n");
    const json st = fresh_server_stats();
    const json b = st.value("breaker", json::object());
    // The trip case can also end by the sweep closing the sender, so only the refusal is sure.
    printf("  send budget: %d tripped, %d refused\n", st.value("fanout_tripped", 0), st.value("fanout_refused", 0));
    check("the budget counted its refusal", st.value("fanout_refused", 0) >= 1);
    check("the breaker counted no trip, ladder step or refusal and cools no device",
          b.value("trips", -1) == 0 && b.value("ladder_steps", -1) == 0 && b.value("refused", -1) == 0 &&
              b.value("cooling_devices", -1) == 0);
}

// C1: the budget reads a text msg before the handler's try. A field of the wrong type
// there once threw into uSockets and killed the relay (no snapshot).
static void oom_malformed_msg_relay_answers() {
    printf("oom: a malformed msg leaves the relay answering\n");
    const std::string room = room_name("oom-msg");
    auto a = login(Ident());
    join(*a, room);
    auto b = login(Ident());
    join(*b, room);
    a->send({{"type", "msg"}, {"room", 1}});
    a->send({{"type", "msg"}, {"room", room}, {"data", json::object()}});
    a->send({{"type", "msg"}, {"room", room}, {"data", nullptr}});
    a->send({{"type", "msg"}, {"data", "x"}});
    auto g = login(Ident(), "guest");
    g->send({{"type", "msg"}, {"room", 1}});
    check("the relay still answers the sender", sync(*a));
    a->send({{"type", "msg"}, {"room", room}, {"data", "after"}});
    check("a well-formed msg is still delivered", next(*b, typed("msg", room)).has_value());
    auto c = login(Ident());
    check("and a new login is served", c->ok && sync(*c));
}

// uWS end() runs the close handler at once, which drops the socket's charge, while the
// socket keeps its unsent buffer until it drains (a trickle keeps it for good): a stranger
// re-logging in as its own non-reader would hold that memory outside the budget. The close
// handler releases such a buffer instead, so the old socket gets only what the kernel had.
static void oom_ended_socket_buffer_released() {
    printf("oom: a superseded socket's unsent buffer is released, not kept\n");
    const std::string room = room_name("oom-end");
    auto reader = login(Ident());
    join(*reader, room);
    Ident slow_id;
    g_rcvbuf = 16 << 10;
    auto slow = login(slow_id);
    g_rcvbuf = 0;
    join(*slow, room);
    next(*reader, about("peer_joined", room, slow_id.peer));
    auto sender = login(Ident());
    join(*sender, room);
    sync(*sender);

    // 14 MiB into the non-reader (under the test's 16 MiB socket cap), inside the stall
    // window so the sweep has not closed it.
    const auto t0 = std::chrono::steady_clock::now();
    const std::string chunk(2u << 20, 'e');
    for (int i = 0; i < 7; i++) {
        sender->send_bin(frame(0x03, {room}, chunk));
        drain_inbox(*reader);
    }
    sync(*sender);
    auto again = login(slow_id);
    const auto setup_ms =
        std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
    check("(the buffer was filled and superseded inside the stall window)", setup_ms < oom_stall_ms() - 1000);

    uint64_t received = 0;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
    while (!slow->ws.closed() && std::chrono::steady_clock::now() < deadline) {
        slow->ws.pump(200);
        for (const auto& f : slow->ws.inbox) received += f.data.size();
        slow->ws.inbox.clear();
    }
    printf("  the superseded socket received %llu bytes of 14 MiB\n", static_cast<unsigned long long>(received));
    check("the superseded socket is gone", slow->ws.closed());
    check("its unsent buffer was released, not delivered", received < (6u << 20));
    check("the new login is served", again->ok && sync(*again));
}

// A broadcast that meets a sessionless receiver at its socket cap refuses that one write
// and dooms the socket for the next sweep: closing it inside the fan-out would erase it
// from the room the loop is walking. The sender is never tripped by someone else's buffer.
static void oom_full_receiver_closed_after_fanout() {
    printf("oom: a receiver at its socket cap is closed after the fan-out, not inside it\n");
    const std::string room = room_name("oom-cap");
    auto reader = login(Ident());
    join(*reader, room);
    g_rcvbuf = 16 << 10;
    auto slow = login(Ident());
    g_rcvbuf = 0;
    join(*slow, room);
    next(*reader, about("peer_joined", room, slow->id.peer));
    auto sender = login(Ident());
    join(*sender, room);
    sync(*sender);

    // 2 MiB each, 28 MiB in all: past the test's 16 MiB socket cap plus the 4 MiB the
    // kernel takes, while the 32 MiB budget never matters.
    const std::string chunk(2u << 20, 'c');
    constexpr int SENT = 14;
    uint64_t delivered = 0;
    // Its close is watched through the reader's presence (the kernel still holds
    // megabytes the client has not read).
    bool closed = false;
    auto drain_reader = [&](int ms) {
        while (reader->ws.pump(ms)) {}
        for (const auto& f : reader->ws.inbox) {
            delivered += f.text ? 0 : 1;
            if (auto j = as_json(f); j && j->value("type", "") == "peer_left" && j->value("peer_id", "") == slow->id.peer) {
                closed = true;
            }
        }
        reader->ws.inbox.clear();
    };
    for (int i = 0; i < SENT; i++) {
        sender->send_bin(frame(0x03, {room}, chunk));
        drain_reader(20);
    }
    const bool sender_ok = sync(*sender) && !sender->ws.closed();
    drain_reader(300);
    check("the sender is not tripped by another socket's full buffer", sender_ok);
    check("the reader got every broadcast", delivered == SENT);

    // The refused write dooms it; the next sweep closes it.
    for (int i = 0; i < 10 && !closed; i++) drain_reader(300);
    check("the receiver a write was refused on is closed", closed);
    check("and the room still serves the sender", sync(*sender));
}

// uWS answers every ping with a pong outside write_raw, so a client that floods pings and
// never reads would buffer pongs the budget never saw. The ping handler charges them, so
// such a socket is counted and the stall sweep closes it.
static void oom_ping_flood_counted() {
    printf("oom: pongs a non-reader provokes are charged and swept\n");
    g_rcvbuf = 16 << 10;
    auto p = login(Ident());
    g_rcvbuf = 0;
    // 125 bytes is the largest control frame: 80,000 pings ask for about 10 MiB of pongs,
    // more than the kernel's send buffer takes.
    const std::vector<std::pair<uint8_t, std::string>> batch(400, {0x9, std::string(125, 'p')});
    for (int i = 0; i < 200 && !p->ws.closed(); i++) p->ws.send_frames(batch);
    sleep_ms(oom_stall_ms() + 1500);  // past the stall window, reading nothing
    check("a ping flooder that never reads is closed by the stall sweep", closed_by_relay(*p));
}

int main(int argc, char** argv) {
    if (argc != 4 || (std::string(argv[3]) != "on" && std::string(argv[3]) != "off")) {
        fprintf(stderr, "usage: test_relay_live <port> <auth domain> <on|off>\n");
        return 2;
    }
    if (sodium_init() < 0) return 2;
    g_port = atoi(argv[1]);
    g_domain = argv[2];
    g_ring1 = std::string(argv[3]) == "on";
    g_tag = random_hex(4);
    g_ctx = SSL_CTX_new(TLS_client_method());
    SSL_CTX_set_verify(g_ctx, SSL_VERIFY_NONE, nullptr);

    // RELAY_LIVE_RESTART=<dir>: the restart case alone, driven by test/run_restart.sh.
    if (const char* restart = getenv("RELAY_LIVE_RESTART")) {
        hs_restart(restart);
        SSL_CTX_free(g_ctx);
        if (failures) printf("%d FAILED\n", failures);
        return failures ? 1 : 0;
    }
    // RELAY_LIVE_ONLY=sessions runs the session cases alone, =bounds the bounds cases alone
    // (the mutation passes), =probe only the RELAY_LIVE_PROBE probes and the drain.
    const char* only = getenv("RELAY_LIVE_ONLY");
    if (only && std::string(only) == "door_grace") {
        hs_door_moved_in_grace();
        test_hidden_door_rooms(true);
        test_presence_digest_door(true);
        SSL_CTX_free(g_ctx);
        if (failures) printf("%d FAILED\n", failures);
        return failures ? 1 : 0;
    }
    // =fetch_presence: a fetch socket hears no presence (the mutation pass).
    if (only && std::string(only) == "fetch_presence") {
        test_fetch_hears_no_presence();
        SSL_CTX_free(g_ctx);
        if (failures) printf("%d FAILED\n", failures);
        return failures ? 1 : 0;
    }
    // =breaker_enforce / =breaker_shadow: the circuit breaker against a scaled-down relay.
    if (only && std::string(only).rfind("breaker_", 0) == 0) {
        signal(SIGPIPE, SIG_IGN);
        if (std::string(only) == "breaker_enforce") {
            test_breaker_trip_resends();
            test_breaker_waits_before_binding();
            test_breaker_fetch_cools_nothing();
            test_breaker_forwarder_exempt();
            test_breaker_audience();
            test_breaker_junk_proofs_do_not_cost_the_mover();
            test_breaker_unlocked_guest();
            test_breaker_fresh_session_counts_strangers_afresh();
            test_breaker_pause_holds_no_slot();
            test_breaker_ladder_window();
            test_breaker_trips_are_no_budget_trips();
        } else {
            test_breaker_shadow();
        }
        SSL_CTX_free(g_ctx);
        if (failures) printf("%d FAILED\n", failures);
        return failures ? 1 : 0;
    }
    // =stats: what /server-stats tells anyone.
    if (only && std::string(only) == "stats") {
        test_public_stats();
        SSL_CTX_free(g_ctx);
        if (failures) printf("%d FAILED\n", failures);
        return failures ? 1 : 0;
    }
    // =mailbox: the inbox mailbox reads.
    if (only && std::string(only) == "mailbox") {
        test_mailbox_read_once();
        test_mailbox_gap_after_read();
        test_session_gap_mailbox();
        SSL_CTX_free(g_ctx);
        if (failures) printf("%d FAILED\n", failures);
        return failures ? 1 : 0;
    }
    // =fetch_grace: what a fetch socket reads of a session in grace.
    if (only && std::string(only) == "fetch_grace") {
        test_session_fetch_in_grace();
        hs_fetch_reads_grace_dms();
        hs_fetch_reads_grace_once();
        SSL_CTX_free(g_ctx);
        if (failures) printf("%d FAILED\n", failures);
        return failures ? 1 : 0;
    }
    // =dropped_write: the dropped-write case for this relay's send buffer, the small one
    // run_live.sh starts a relay with or the real 64 MiB.
    if (only && std::string(only) == "dropped_write") {
        if (getenv("RELAY_LIVE_BACKPRESSURE") && *getenv("RELAY_LIVE_BACKPRESSURE")) {
            hs_dropped_write_writes_nothing_more();
        } else {
            hs_dropped_write_resumes_cleanly();
        }
        SSL_CTX_free(g_ctx);
        if (failures) printf("%d FAILED\n", failures);
        return failures ? 1 : 0;
    }
    // =oom: the send-buffer memory budget (run_live.sh starts a relay with a tiny budget
    // and a short stall window). On a box without /proc the RSS check is skipped.
    if (only && std::string(only) == "oom") {
        oom_malformed_msg_relay_answers();
        oom_honest_fanout_evicts_nonreaders();
        oom_cotenant_gives_way_before_sender_trips();
        oom_tripped_sender_resumes_frame_once();
        oom_unbufferable_fanout_refused_once();
        oom_ended_socket_buffer_released();
        oom_full_receiver_closed_after_fanout();
        oom_ping_flood_counted();
        oom_piled_receivers_never_trip_the_sender();
        oom_trips_are_no_breaker_trips();
        SSL_CTX_free(g_ctx);
        if (failures) printf("%d FAILED\n", failures);
        return failures ? 1 : 0;
    }
    // =digest: the presence digest cases and the dropped-write close.
    if (only && std::string(only) == "digest") {
        test_presence_digest();
        test_presence_digest_door(false);
        hs_dropped_write_resumes_cleanly();
        SSL_CTX_free(g_ctx);
        if (failures) printf("%d FAILED\n", failures);
        return failures ? 1 : 0;
    }
    // =presence: the hidden-presence cases and the inactive/active ones beside them.
    if (only && std::string(only) == "presence") {
        test_session_inactive();
        hs_active_costs_what_was_withheld();
        test_bounds_active();
        test_hidden();
        SSL_CTX_free(g_ctx);
        if (failures) printf("%d FAILED\n", failures);
        return failures ? 1 : 0;
    }
    // =tls_read: a write the relay makes in the middle of a full TLS read (the mutation pass).
    if (only && std::string(only) == "tls_read") {
        test_tls_write_inside_full_read();
        SSL_CTX_free(g_ctx);
        if (failures) printf("%d FAILED\n", failures);
        return failures ? 1 : 0;
    }
    // =rate: the new-connection rate alone; =rate_exempt against the relay that lists one.
    if (only && (std::string(only) == "rate" || std::string(only) == "rate_exempt")) {
        if (std::string(only) == "rate") {
            test_rate_limit();
            test_rate_limit_idle_address();
        } else {
            test_rate_exempt();
        }
        SSL_CTX_free(g_ctx);
        if (failures) printf("%d FAILED\n", failures);
        return failures ? 1 : 0;
    }
    const std::string only_cases = only ? only : "";
    const bool probe_only = only_cases == "probe";
    const bool bounds_only = only_cases == "bounds" || probe_only;
    const bool all = only_cases != "sessions" && !bounds_only;
    if (all) {
        test_public_stats();
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
        test_fetch_hears_no_presence();
        test_door_rooms();
        test_rate_limit();
        test_rate_limit_idle_address();
    }
    if (!bounds_only) {
        test_session_logins();
        test_clock();
        test_session_resume();
        test_session_counting();
        test_session_acks();
        test_session_gap();
        test_session_transfer();
        test_session_fresh_over_held();
        test_session_inactive();
        test_session_end();
        test_session_fetch_in_grace();
        test_session_doors_and_kills();
        test_session_inbox_recheck();
        test_session_gap_mailbox();
        test_mailbox_read_once();
        test_mailbox_gap_after_read();
        test_session_push_in_grace();
        test_session_expiry();
        test_handshake_review();
        test_hidden();
        test_presence_digest();
        test_presence_digest_door(false);
        hs_dropped_write_resumes_cleanly();
    }
    if (!probe_only) {
        test_bounds_full_address();
        test_bounds_active();
        test_bounds_push_debounce();
    }
    if (all) {
        test_tls_write_inside_full_read();
        test_deep_json();
    }
    const char* probe = getenv("RELAY_LIVE_PROBE");
    if (probe && std::string(probe) == "acks") probe_ack_queue();
    if (probe && std::string(probe) == "active") probe_active_burst();
    if (probe && std::string(probe) == "hide") probe_hide_pass();
    test_bounds_drain();

    SSL_CTX_free(g_ctx);
    if (failures) {
        printf("%d FAILED\n", failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
