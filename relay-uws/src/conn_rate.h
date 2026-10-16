#pragma once
// The per-address new-connection rate (MAX_NEW_CONNS_PER_MIN_PER_IP, or _PER_IDLE_IP for an
// address holding no socket): each address's window of recent admitted connects, and the bounded book of addresses that hold no
// socket but still have a window. RAM only, never persisted, never logged. Header-only
// so test/test_conn_rate.cpp drives it without a relay.
#include <arpa/inet.h>
#include <netinet/in.h>

#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <functional>
#include <set>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "fair_share.h"

namespace conn_rate {

using Clock = std::chrono::steady_clock;
constexpr auto WINDOW = std::chrono::seconds(60);

// Addresses holding no socket whose windows the book keeps. Real clients hold their
// sockets, so an idle window is a brief or failed connect within the last minute; past
// this many, one is forgotten, which only lets that address in sooner.
constexpr size_t MAX_IDLE = 65536;

// The last N admitted connects of one address, oldest first.
template <size_t N>
class Window {
    static_assert(N > 0 && N < 256, "a window counts in a byte");

public:
    // Forgets the connects more than WINDOW before `now`.
    void prune(Clock::time_point now) {
        while (n_ > 0 && now - at_[head_] > WINDOW) {
            head_ = static_cast<uint8_t>((head_ + 1) % N);
            n_--;
        }
    }
    void push(Clock::time_point t) {
        if (n_ == N) {
            head_ = static_cast<uint8_t>((head_ + 1) % N);
            n_--;
        }
        at_[(head_ + n_) % N] = t;
        n_++;
    }
    bool full() const { return n_ == N; }
    bool empty() const { return n_ == 0; }
    size_t size() const { return n_; }
    // When the window is empty again unless another connect comes; only while not empty.
    Clock::time_point ends() const { return at_[(head_ + n_ - 1) % N] + WINDOW; }

private:
    std::array<Clock::time_point, N> at_{};
    uint8_t head_ = 0;
    uint8_t n_ = 0;
};

// The block an idle window is charged to, exactly and without hashing: a v4 address,
// or the /48 of a v6 /64 key, as fair shares are kept everywhere else (ip_key.h
// share_block). The book holds the keys themselves already, so a hash would hide nothing.
inline uint64_t share_of_key(const std::string& ip_key) {
    struct in_addr v4;
    if (inet_pton(AF_INET, ip_key.c_str(), &v4) == 1) return (uint64_t{1} << 63) | ntohl(v4.s_addr);
    std::string addr = ip_key;
    if (addr.size() > 3 && addr.compare(addr.size() - 3, 3, "/64") == 0) addr.resize(addr.size() - 3);
    struct in6_addr v6;
    if (inet_pton(AF_INET6, addr.c_str(), &v6) == 1) {
        uint64_t block = 0;
        for (int i = 0; i < 6; i++) block = (block << 8) | v6.s6_addr[i];
        return block;
    }
    // ip_limit_key hands unparseable text back unchanged: a share of its own.
    return (uint64_t{1} << 62) | (std::hash<std::string>{}(ip_key) >> 2);
}

// Addresses that hold no socket but still have a window, up to `max`. A full book
// forgets the least recently idled address of the block holding the most (fair_share.h),
// so a flood from many /64s of one /48 forgets only its own.
class IdleBook {
public:
    explicit IdleBook(size_t max = MAX_IDLE) : max_(max) {}

    // `key` holds no socket and its window ends at `ends`. Returns the keys forgotten to
    // stay within the bound, `key` itself among them when its block holds the most.
    std::vector<std::string> put(const std::string& key, Clock::time_point ends) {
        remove(key);
        shares_.put(key, share_of_key(key), 1);
        by_end_.insert({ends, key});
        end_of_[key] = ends;
        std::vector<std::string> gone;
        while (shares_.size() > max_) {
            auto victim = shares_.victim();
            if (!victim) break;
            remove(*victim);
            gone.push_back(std::move(*victim));
        }
        return gone;
    }

    void remove(const std::string& key) {
        auto it = end_of_.find(key);
        if (it == end_of_.end()) return;
        by_end_.erase({it->second, key});
        end_of_.erase(it);
        shares_.remove(key);
    }

    // Takes out and returns the keys whose windows ended before `now`.
    std::vector<std::string> expired(Clock::time_point now) {
        std::vector<std::string> out;
        while (!by_end_.empty() && by_end_.begin()->first < now) {
            std::string key = by_end_.begin()->second;
            remove(key);
            out.push_back(std::move(key));
        }
        return out;
    }

    bool contains(const std::string& key) const { return end_of_.count(key) != 0; }
    size_t size() const { return end_of_.size(); }

private:
    size_t max_;
    FairShare<std::string> shares_;
    std::set<std::pair<Clock::time_point, std::string>> by_end_;
    std::unordered_map<std::string, Clock::time_point> end_of_;
};

}  // namespace conn_rate
