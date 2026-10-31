// uSockets' OpenSSL layer (uSockets/src/crypto/openssl.c, compiled from here unchanged)
// with one repair. Every TLS socket of a loop reads through one shared input state, and
// the layer's write and shutdown clear it for good. When a read decrypts a full receive
// buffer with ciphertext still pending, the layer hands that buffer to the relay and then
// reads on; a write the relay made meanwhile (forwarding one of the frames, to anyone)
// lost the rest of the reader's records, so its next record failed its MAC and an honest
// sender was cut off, the alert for it written to whichever socket wrote last.
//
// Here a write or shutdown still hides the pending input from OpenSSL (a handshake in
// flight on the written socket must never read another socket's records), then hands it
// back with the socket the read writes to. An adoption (the HTTP to WebSocket upgrade,
// inside the read's own hand-over) moves the reading socket, so it moves that pointer
// too, or the read's next alert or KeyUpdate answer is written through freed memory.
// Adoption is uSockets' only move (us_poll_resize's one caller) and every TLS adoption
// passes this file's wrapper (context.c); wrapping it keeps crypto/openssl.c whole where
// re-pointing after each hand-over would need a patched copy of ssl_on_data.
// test/run_tests.sh pins both uSockets files, so an update re-checks this reasoning.
// Build this file in place of crypto/openssl.c; it must stay the only copy linked.
#include "libusockets.h"
#include "internal/internal.h"

#if (defined(LIBUS_USE_OPENSSL) || defined(LIBUS_USE_WOLFSSL))

// Declared static before the include, so nothing outside this file reaches the originals.
static int us_internal_ssl_socket_write_unrepaired(struct us_internal_ssl_socket_t *s, const char *data, int length,
                                                   int msg_more);
static void us_internal_ssl_socket_shutdown_unrepaired(struct us_internal_ssl_socket_t *s);
static struct us_internal_ssl_socket_t *us_internal_ssl_socket_context_adopt_socket_unrepaired(
    struct us_internal_ssl_socket_context_t *context, struct us_internal_ssl_socket_t *s, int ext_size);

#define us_internal_ssl_socket_write us_internal_ssl_socket_write_unrepaired
#define us_internal_ssl_socket_shutdown us_internal_ssl_socket_shutdown_unrepaired
#define us_internal_ssl_socket_context_adopt_socket us_internal_ssl_socket_context_adopt_socket_unrepaired
#include "crypto/openssl.c"
#undef us_internal_ssl_socket_write
#undef us_internal_ssl_socket_shutdown
#undef us_internal_ssl_socket_context_adopt_socket

// The relay names this in its start line and deploy/check-host.sh looks for it in the
// running binary; main.cpp's reference makes a relay built without this file fail to link.
const char hollow_tls_read_repair[] = "hollow-tls-read-repair 2";

// What the originals' write and shutdown overwrite: the pending input's length (its
// pointer and offset they leave alone) and the socket OpenSSL's output goes to.
struct ssl_read_state {
    struct loop_ssl_data *data;
    unsigned int length;
    struct us_socket_t *socket;
};

static struct loop_ssl_data *ssl_loop_data(struct us_internal_ssl_socket_t *s) {
    struct us_internal_ssl_socket_context_t *context = (struct us_internal_ssl_socket_context_t *) us_socket_context(0, &s->s);
    return (struct loop_ssl_data *) us_socket_context_loop(0, &context->sc)->data.ssl_data;
}

static struct ssl_read_state ssl_read_state_save(struct us_internal_ssl_socket_t *s) {
    struct loop_ssl_data *data = ssl_loop_data(s);
    struct ssl_read_state saved = {data, data->ssl_read_input_length, data->ssl_socket};
    return saved;
}

static void ssl_read_state_restore(const struct ssl_read_state *saved) {
    saved->data->ssl_read_input_length = saved->length;
    saved->data->ssl_socket = saved->socket;
}

int us_internal_ssl_socket_write(struct us_internal_ssl_socket_t *s, const char *data, int length, int msg_more) {
    struct ssl_read_state saved = ssl_read_state_save(s);
    int written = us_internal_ssl_socket_write_unrepaired(s, data, length, msg_more);
    ssl_read_state_restore(&saved);
    return written;
}

void us_internal_ssl_socket_shutdown(struct us_internal_ssl_socket_t *s) {
    struct ssl_read_state saved = ssl_read_state_save(s);
    us_internal_ssl_socket_shutdown_unrepaired(s);
    ssl_read_state_restore(&saved);
}

struct us_internal_ssl_socket_t *us_internal_ssl_socket_context_adopt_socket(struct us_internal_ssl_socket_context_t *context,
                                                                             struct us_internal_ssl_socket_t *s, int ext_size) {
    struct loop_ssl_data *data = ssl_loop_data(s);
    int reading = data->ssl_socket == &s->s;
    struct us_internal_ssl_socket_t *adopted = us_internal_ssl_socket_context_adopt_socket_unrepaired(context, s, ext_size);
    if (reading) {
        data->ssl_socket = &adopted->s;
    }
    return adopted;
}

#endif
