#pragma once
#include <cstddef>
#include <string>
#include <string_view>
#include <unordered_set>

// How many people `/server-stats` counts online (#150): identities, never sockets. A
// device counts under the identity whose inbox the relay's roster fold lets it own; one
// the fold places nowhere counts as itself, so a socket logged in as a bare master key
// lands on that identity's own id and never adds a second person to it. The media
// forwarder, guests and hidden (inactive) sessions are nobody.
namespace online_people {

// One full socket the relay holds for a device.
struct Seat {
    const std::string& peer;
    bool guest = false;
    bool hidden = false;
    // The master whose inbox this device owns now; null when it owns none.
    const std::string* identity = nullptr;
};

class Tally {
   public:
    explicit Tally(const std::string& forwarder) : forwarder_(forwarder) {}

    void add(const Seat& s) {
        if (s.guest || s.hidden) return;
        if (!forwarder_.empty() && s.peer == forwarder_) return;
        keys_.insert(s.identity ? *s.identity : s.peer);
    }

    size_t people() const { return keys_.size(); }

   private:
    const std::string& forwarder_;
    // Views of the seats' strings, which outlive the tally (one count).
    std::unordered_set<std::string_view> keys_;
};

}  // namespace online_people
