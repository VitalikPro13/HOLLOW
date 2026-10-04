// Unit tests for the relay's judgement of a parked destruction order (src/kill_order.h,
// decision D5). The vectors in kill_vectors.json come from the Rust code
// (node/kill_vectors.rs): every case is one deposit, and this relay must hold as proven
// exactly the orders the apps would accept from the target identity's phrase. If they
// drift, junk earns the slot nothing evicts, or a real order loses it. Change both or
// neither.
//
// Build + run from relay-uws/test (libsodium, and OpenSSL for crypto.cpp):
//   g++ -std=c++17 -I../src test_kill_order.cpp ../src/crypto.cpp -lsodium -lcrypto
//       -o test_kill_order && ./test_kill_order

#include "kill_order.h"
#include "roster_crypto.h"

#include <sodium.h>

#include <cstdio>
#include <fstream>
#include <sstream>
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

using json = nlohmann::json;

// The signature half alone, which decides the proven slot whatever the target.
static std::optional<bool> authorised_alone(const json& c, const RosterCrypto& crypto) {
    std::string text;
    if (!base64_decode(c["blob"].get<std::string>(), text)) return std::nullopt;
    auto order = kill_order::parse(text);
    if (!order || c["held"].is_null()) return std::nullopt;
    auto held = roster::from_json(c["held"]);
    if (!held) return std::nullopt;
    auto state = held->fold([](const std::string&) -> std::optional<int64_t> { return std::nullopt; },
                            c["now_ms"].get<int64_t>(), crypto);
    return kill_order::authorised(*order, c["issued_at_ms"].get<int64_t>(), *held, state, crypto, derive_peer_id);
}

// The relay's flow on one deposit (ws_handler.cpp handle_kill_deposit).
static std::optional<bool> judge(const json& c, const RosterCrypto& crypto) {
    std::string text;
    if (!base64_decode(c["blob"].get<std::string>(), text)) return std::nullopt;
    auto order = kill_order::parse(text);
    if (!order) return std::nullopt;
    if (c["held"].is_null()) return false;
    auto held = roster::from_json(c["held"]);
    if (!held) return std::nullopt;
    const std::string base = held->base(crypto);
    const json& seen = c["seen"];
    auto state = held->fold(
        [&](const std::string& d) -> std::optional<int64_t> {
            auto it = seen.find(base + "|" + d);
            if (it == seen.end()) return std::nullopt;
            return it->get<int64_t>();
        },
        c["now_ms"].get<int64_t>(), crypto);
    return kill_order::authorised(*order, c["issued_at_ms"].get<int64_t>(), *held, state, crypto, derive_peer_id) &&
           kill_order::reaches(*order, c["target"].get<std::string>(), *held);
}

int main() {
    if (sodium_init() < 0) return 1;
    printf("kill order\n");
    const RosterCrypto crypto = roster_crypto();

    // The vectors the Rust code wrote.
    {
        std::ifstream f("kill_vectors.json");
        std::stringstream ss;
        ss << f.rdbuf();
        json v = json::parse(ss.str(), nullptr, false);
        check("the vectors load", v.is_object() && v["cases"].is_array() && v["cases"].size() >= 25);
        size_t ok = 0, total = 0, proven = 0;
        for (const auto& c : v["cases"]) {
            total++;
            auto got = judge(c, crypto);
            const bool want = c["proven"].get<bool>();
            if (got && *got == want) {
                ok++;
                proven += want;
            } else {
                printf("  FAIL vector %s: want %s, got %s\n", c["name"].get<std::string>().c_str(),
                       want ? "proven" : "opaque", !got ? "unreadable" : (*got ? "proven" : "opaque"));
                failures++;
            }
        }
        check("every vector lands where the Rust code does (" + std::to_string(ok) + "/" + std::to_string(total) + ")",
              ok == total && total > 0);
        check("the vectors prove some and refuse the rest", proven >= 8 && total - proven >= 15);

        // Targets join with ',' under the signature, so a re-split order verifies under
        // the old rule; only the shape check keeps it off the proven slot.
        for (const char* name : {"targets-re-split-after-signing", "every-device-signed-as-a-blank-target"}) {
            bool found = false;
            for (const auto& c : v["cases"]) {
                if (c["name"].get<std::string>() != name) continue;
                found = true;
                auto got = authorised_alone(c, crypto);
                check(std::string(name) + ": the signature half refuses it", got && !*got);
            }
            check(std::string(name) + ": the vector exists", found);
        }
    }

    // An order's JSON is read as strictly as serde reads it.
    {
        check("unknown fields are ignored", kill_order::from_json(json::parse(R"({"master_peer_id":"x","extra":1})")).has_value());
        check("missing fields default", kill_order::from_json(json::parse("{}")).has_value());
        check("a null delegation is none", !kill_order::from_json(json::parse(R"({"delegation":null})"))->delegation);
        check("a wrong type refuses the order", !kill_order::from_json(json::parse(R"({"issued_at_ms":"1"})")));
        check("a float stamp refuses the order", !kill_order::from_json(json::parse(R"({"issued_at_ms":1.5})")));
        check("a non-string target refuses the order", !kill_order::from_json(json::parse(R"({"targets":[1]})")));
        check("a delegation of the wrong shape refuses the order",
              !kill_order::from_json(json::parse(R"({"delegation":[]})")) &&
                  !kill_order::from_json(json::parse(R"({"delegation":{"at_ms":"x"}})")));
        check("a non-object refuses the order", !kill_order::from_json(json::parse("[]")));
        const std::string deep = std::string(client_json::MAX_DEPTH, '[') + std::string(client_json::MAX_DEPTH, ']');
        check("an order nested past the depth cap is no order, one within it is",
              !kill_order::parse(R"({"master_peer_id":"x","extra":)" + deep + "}") &&
                  kill_order::parse(R"({"master_peer_id":"x","extra":[[1]]})").has_value());
        std::string out;
        check("base64 that is not base64 is refused", !base64_decode("not base64!", out));
        check("base64 decodes", base64_decode("aGk=", out) && out == "hi");
    }

    // The payload is byte for byte the client's: targets sorted, never deduped.
    {
        kill_order::Order o;
        o.master_peer_id = "M";
        o.issued_at_ms = 7;
        o.targets = {"b", "a", "b"};
        check("the payload sorts the targets", kill_order::payload(o) == "hollow-destroy2:M:7:a,b,b:false");
        o.notify_friends = true;
        o.targets.clear();
        check("an empty target list and a notify flag", kill_order::payload(o) == "hollow-destroy2:M:7::true");
    }

    if (failures) {
        printf("%d FAILURE(S)\n", failures);
        return 1;
    }
    printf("all ok\n");
    return 0;
}
