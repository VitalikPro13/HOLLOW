// The operator denylist file (src/deny_list.h), read the way deny::load and
// --check-denylist read it: never a throw, all or nothing, and every entry it keeps is
// already in the form a refusal compares against, so reading it again changes nothing.

#include <string>

#include "deny_list.h"
#include "fuzz_support.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    const deny::Parsed p = deny::parse(fuzz::as_text(data, size));
    if (!p.list) {
        FUZZ_CHECK(!p.error.empty());
        return 0;
    }
    FUZZ_CHECK(p.error.empty());
    for (const auto& s : p.list->servers) FUZZ_CHECK(deny::server_key(s) == s);
    for (const auto& i : p.list->identities) FUZZ_CHECK(deny::identity_key(i) == i);
    for (const auto& n : p.list->networks) {
        FUZZ_CHECK(deny::network_key(n) == n);
        FUZZ_CHECK(ip_limit_key(n) == n);
    }
    deny::State st;
    st.list = *p.list;
    for (const auto& s : p.list->servers) FUZZ_CHECK(st.server_denied(s));
    return 0;
}
