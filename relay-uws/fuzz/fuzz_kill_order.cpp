// Destruction orders parked on the kill list (src/kill_order.h), judged the way
// judge_kill_blob and handle_kill_deposit judge them: the decoded blob read as client
// JSON, then the signature half against the roster the relay holds for the order's
// master, then each target. The input is a JSON object {"held": roster, "order":
// the blob's text (or the order object), "issued_at_ms", "targets"}. A proven slot
// may only go to an order its own identity's held roster stands behind, for a device
// that consented to that identity.

#include <string>

#include "client_json.h"
#include "fuzz_support.h"
#include "kill_order.h"
#include "roster_book.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    const nlohmann::json j = client_json::parse(fuzz::as_text(data, size));
    if (!j.is_object()) return 0;
    auto order_it = j.find("order");
    if (order_it == j.end()) return 0;
    const std::optional<kill_order::Order> order =
        order_it->is_string() ? kill_order::parse(order_it->get_ref<const std::string&>())
                              : kill_order::from_json(*order_it);
    if (!order) return 0;
    (void)kill_order::payload(*order);
    if (order->delegation) (void)kill_order::delegation_payload(order->master_peer_id, *order->delegation);

    // The held roster arrives the only way it can: shown on an inbox join.
    static const RosterCrypto crypto = fuzz::roster_crypto();
    const int64_t now_ms = 1800000000000;
    RosterBook book;
    auto held_it = j.find("held");
    if (held_it != j.end()) {
        if (auto shown = roster::from_json(*held_it)) book.show(shown->master, *shown, "", 1, now_ms, crypto);
    }
    const RosterBook::Held* held = book.get(order->master_peer_id);
    if (!held || held->roster.r_pub.empty()) return 0;

    int64_t issued_at_ms = order->issued_at_ms;
    if (auto it = j.find("issued_at_ms"); it != j.end() && it->is_number_integer()) issued_at_ms = it->get<int64_t>();
    roster::State members;
    if (order->delegation) members = book.fold(*held, now_ms, crypto);
    const kill_order::DerivePeerId derive = [](const std::string& key) { return key; };
    const bool authorised = kill_order::authorised(*order, issued_at_ms, held->roster, members, crypto, derive);
    if (authorised) {
        FUZZ_CHECK(order->master_peer_id == held->roster.master && order->issued_at_ms == issued_at_ms);
        for (const auto& t : order->targets) FUZZ_CHECK(is_peer_id_shape(t));
    }

    auto targets = j.find("targets");
    if (targets == j.end() || !targets->is_array()) return 0;
    size_t seen = 0;
    for (const auto& t : *targets) {
        if (++seen > 16 || !t.is_string()) break;
        const std::string& target = t.get_ref<const std::string&>();
        if (!kill_order::reaches(*order, target, held->roster)) continue;
        FUZZ_CHECK(held->roster.consented().count(target) == 1);
    }
    return 0;
}
