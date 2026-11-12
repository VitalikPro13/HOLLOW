#pragma once
// Every open socket of the relay, charged to its address share (socket_share), against one
// budget sized from RAM (conn_limits.h CONNECTED_LIMIT). Past it the share holding the most
// sockets gives way, never an identity and never by age across shares: its oldest socket
// that has not logged in, else its oldest that holds no session (fetch, guest, a full socket
// without one), else its oldest session socket, which resumes. A newcomer whose own share
// holds the most is refused instead. RAM only, never logged.
//
// Header-only so test/test_conn_book.cpp drives it without a relay.
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <set>
#include <unordered_map>
#include <utility>

namespace conn_book {

using Key = uintptr_t;

enum class Class : uint8_t { Pending = 0, Loose = 1, Held = 2 };

struct Shed {
    Key key;
    Class cls;
    // The newcomer itself: refused rather than another socket shed.
    bool refused;
};

class Book {
public:
    explicit Book(size_t max) : max_(max) {}

    void set_max(size_t max) { max_ = max; }
    size_t max() const { return max_; }
    size_t size() const { return entries_.size(); }
    size_t held(uint64_t share) const {
        auto it = shares_.find(share);
        return it == shares_.end() ? 0 : it->second.n;
    }

    // `key` opens from `share`, not logged in yet. Past the budget, what gives way, already
    // taken out of the book (the newcomer too when it is refused).
    std::optional<Shed> open(Key key, uint64_t share) {
        if (entries_.count(key)) return std::nullopt;
        add(key, share, Class::Pending);
        if (entries_.size() <= max_) return std::nullopt;
        const auto top = by_n_.rbegin();
        if (held(share) >= top->first) {
            remove(key);
            return Shed{key, Class::Pending, true};
        }
        Share& s = shares_.at(top->second);
        for (Class c : {Class::Pending, Class::Loose, Class::Held}) {
            auto& order = s.by_class[static_cast<size_t>(c)];
            if (order.empty()) continue;
            const Key victim = order.begin()->second;
            remove(victim);
            return Shed{victim, c, false};
        }
        return std::nullopt;
    }

    // `key` logged in (Loose or Held), or its session came or went.
    void reclass(Key key, Class c) {
        auto it = entries_.find(key);
        if (it == entries_.end() || it->second.cls == c) return;
        Share& s = shares_.at(it->second.share);
        s.by_class[static_cast<size_t>(it->second.cls)].erase({it->second.tick, key});
        it->second.cls = c;
        s.by_class[static_cast<size_t>(c)].insert({it->second.tick, key});
    }

    void close(Key key) { remove(key); }
    bool contains(Key key) const { return entries_.count(key) != 0; }

private:
    struct Entry {
        uint64_t share;
        Class cls;
        uint64_t tick;
    };
    struct Share {
        size_t n = 0;
        std::array<std::set<std::pair<uint64_t, Key>>, 3> by_class;
    };

    void add(Key key, uint64_t share, Class c) {
        const uint64_t tick = ++tick_;
        entries_.emplace(key, Entry{share, c, tick});
        Share& s = shares_[share];
        if (s.n) by_n_.erase({s.n, share});
        s.n++;
        by_n_.insert({s.n, share});
        s.by_class[static_cast<size_t>(c)].insert({tick, key});
    }

    void remove(Key key) {
        auto it = entries_.find(key);
        if (it == entries_.end()) return;
        const Entry e = it->second;
        entries_.erase(it);
        auto sit = shares_.find(e.share);
        Share& s = sit->second;
        s.by_class[static_cast<size_t>(e.cls)].erase({e.tick, key});
        by_n_.erase({s.n, e.share});
        if (--s.n == 0) {
            shares_.erase(sit);
        } else {
            by_n_.insert({s.n, e.share});
        }
    }

    size_t max_;
    uint64_t tick_ = 0;
    std::unordered_map<Key, Entry> entries_;
    std::unordered_map<uint64_t, Share> shares_;
    std::set<std::pair<size_t, uint64_t>> by_n_;
};

}  // namespace conn_book
