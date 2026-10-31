// The repaired uSockets TLS layer (src/usockets_ssl.c) over real TLS 1.3 sessions: a
// socket whose full receive buffer is being handed over keeps the rest of its records,
// and everything OpenSSL writes while reading them (a KeyUpdate answer, an alert) reaches
// that socket where it lives now, whatever the hand-over wrote to, shut down or adopted.
// Run it under ASan: an answer written through a socket's old address is a use after free.
//   test_usockets_ssl <cert.pem> <key.pem>
#include "../src/usockets_ssl.c"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>

#if defined(__SANITIZE_ADDRESS__)
#define UNDER_ASAN 1
#elif defined(__has_feature)
#if __has_feature(address_sanitizer)
#define UNDER_ASAN 1
#endif
#endif

static int failures = 0;

static void check(const char *name, int ok) {
    printf("  %s %s\n", ok ? "ok  " : "FAIL", name);
    if (!ok) failures++;
}

// One TLS session: the relay's side is a uSockets socket on one end of a socket pair, the
// client a memory-BIO OpenSSL session on the other end.
struct peer {
    struct us_socket_t *s;
    int fd;
    SSL *ssl;
    BIO *in, *out;
};

// Kept in each relay-side socket's ext, so it survives an adoption.
struct tag {
    struct peer *peer;
    long plaintext;
};

enum hand_over { FORWARD, SHUT_DOWN_OTHER, ADOPT_SELF, ADOPT_OTHER };

// What the reader's first full hand-over does.
static struct {
    struct peer *reader, *other;
    enum hand_over action;
    int done;
    int moved;
} scene;

static struct us_loop_t *loop;
static struct us_socket_context_t *context;
static SSL_CTX *client_ctx;

static const char upgrade[] = "HTTP/1.1 101 Switching Protocols\r\n\r\n";

static void on_wakeup(struct us_loop_t *l) { (void) l; }
static void on_pre(struct us_loop_t *l) { (void) l; }
static void on_post(struct us_loop_t *l) { (void) l; }
static struct us_socket_t *on_open(struct us_socket_t *s, int is_client, char *ip, int ip_length) {
    (void) is_client;
    (void) ip;
    (void) ip_length;
    return s;
}
static struct us_socket_t *on_socket(struct us_socket_t *s) { return s; }
static struct us_socket_t *on_close(struct us_socket_t *s, int code, void *reason) {
    (void) code;
    (void) reason;
    return s;
}
static struct us_socket_t *on_connect_error(struct us_socket_t *s, int code) {
    (void) code;
    return s;
}

static struct us_socket_t *on_data(struct us_socket_t *s, char *data, int length) {
    (void) data;
    struct tag *t = (struct tag *) us_socket_ext(1, s);
    t->plaintext += length;
    if (t->peer != scene.reader || length != LIBUS_RECV_BUFFER_LENGTH || scene.done) return s;
    scene.done = 1;
    switch (scene.action) {
    case FORWARD:
        us_socket_write(1, scene.other->s, "fwd", 3, 0);
        break;
    case SHUT_DOWN_OTHER:
        us_socket_shutdown(1, scene.other->s);
        break;
    case ADOPT_SELF: {
        // As uWS's upgrade does: adopt into a larger ext, then answer through the new socket.
        // The block beside the socket keeps realloc from growing it in place.
        void *beside = malloc(64);
        struct us_socket_t *adopted = us_socket_context_adopt_socket(1, context, s, sizeof(struct tag) + 8192);
        free(beside);
        scene.moved = adopted != s;
        scene.reader->s = adopted;
        us_socket_write(1, adopted, upgrade, (int) sizeof upgrade - 1, 0);
        return adopted;
    }
    case ADOPT_OTHER:
        scene.other->s = us_socket_context_adopt_socket(1, context, scene.other->s, sizeof(struct tag) + 8192);
        break;
    }
    return s;
}

// Moves what the relay side wrote into the client's input.
static long pump(struct peer *p) {
    char buf[65536];
    long moved = 0;
    for (;;) {
        ssize_t n = read(p->fd, buf, sizeof buf);
        if (n <= 0) return moved;
        BIO_write(p->in, buf, (int) n);
        moved += n;
    }
}

struct bytes {
    char *data;
    long length;
};

// What the client has sent since the last call, as ciphertext.
static struct bytes sent(struct peer *p) {
    struct bytes b;
    b.length = BIO_pending(p->out);
    b.data = malloc(b.length + 1);
    BIO_read(p->out, b.data, (int) b.length);
    return b;
}

static void append(struct bytes *to, struct bytes from) {
    to->data = realloc(to->data, to->length + from.length + 1);
    memcpy(to->data + to->length, from.data, from.length);
    to->length += from.length;
    free(from.data);
}

// Hands ciphertext to the relay side as its loop would: what arrived so far, then the rest
// in one receive no larger than the receive buffer.
static void deliver(struct peer *p, struct bytes b) {
    long first = b.length < 16000 ? b.length : 16000;
    if (b.length - first > LIBUS_RECV_BUFFER_LENGTH) {
        check("(the second receive fits the receive buffer)", 0);
    }
    p->s = (struct us_socket_t *) ssl_on_data((struct us_internal_ssl_socket_t *) p->s, b.data, (int) first);
    if (b.length > first && !us_socket_is_closed(1, p->s)) {
        p->s = (struct us_socket_t *) ssl_on_data((struct us_internal_ssl_socket_t *) p->s, b.data + first,
                                                  (int) (b.length - first));
    }
    free(b.data);
}

struct reply {
    char data[512];
    int length;
    int error;
    unsigned long reason;
};

// Everything the client can read now, and how its read ended.
static struct reply client_reads(struct peer *p) {
    struct reply r;
    memset(&r, 0, sizeof r);
    pump(p);
    for (;;) {
        int n = SSL_read(p->ssl, r.data + r.length, (int) sizeof r.data - 1 - r.length);
        if (n > 0) {
            r.length += n;
            continue;
        }
        r.error = SSL_get_error(p->ssl, n);
        r.reason = ERR_GET_REASON(ERR_peek_error());
        ERR_clear_error();
        return r;
    }
}

static int peer_open(struct peer *p) {
    int fds[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) return 0;
    int big = 8 << 20;
    setsockopt(fds[0], SOL_SOCKET, SO_SNDBUF, &big, sizeof big);
    setsockopt(fds[1], SOL_SOCKET, SO_RCVBUF, &big, sizeof big);
    fcntl(fds[1], F_SETFL, O_NONBLOCK);
    p->fd = fds[1];
    p->s = us_adopt_accepted_socket(1, context, fds[0], sizeof(struct tag), NULL, 0);
    struct tag *t = (struct tag *) us_socket_ext(1, p->s);
    t->peer = p;
    t->plaintext = 0;
    p->ssl = SSL_new(client_ctx);
    p->in = BIO_new(BIO_s_mem());
    p->out = BIO_new(BIO_s_mem());
    SSL_set_bio(p->ssl, p->in, p->out);
    SSL_set_connect_state(p->ssl);
    for (int i = 0; i < 8 && !SSL_is_init_finished(p->ssl); i++) {
        SSL_do_handshake(p->ssl);
        struct bytes b = sent(p);
        if (b.length) {
            p->s = (struct us_socket_t *) ssl_on_data((struct us_internal_ssl_socket_t *) p->s, b.data, (int) b.length);
        }
        free(b.data);
        pump(p);
    }
    // The session tickets.
    client_reads(p);
    return SSL_is_init_finished(p->ssl) && !us_socket_is_closed(1, p->s);
}

static void peer_close(struct peer *p) {
    us_socket_close(1, p->s, 0, NULL);
    close(p->fd);
    SSL_free(p->ssl);
}

static long plaintext_of(struct peer *p) { return ((struct tag *) us_socket_ext(1, p->s))->plaintext; }

enum ending { KEEPS_TALKING, FORGES };

// Past the full receive buffer, a record OpenSSL has not pulled in yet when that buffer is
// handed over (it reads ahead about one record), sized so the second receive still fits.
#define LATER_RECORD 12000
static const long kept = LIBUS_RECV_BUFFER_LENGTH + LATER_RECORD + 4;

// The reader's client sends a full receive buffer and a later record, then asks for a
// KeyUpdate and sends "tail" under its new keys, or sends a record with a forged tag.
static void send_load(struct peer *p, enum ending ending) {
    static char plain[LIBUS_RECV_BUFFER_LENGTH];
    memset(plain, 'a', sizeof plain);
    SSL_write(p->ssl, plain, (int) sizeof plain);
    SSL_write(p->ssl, plain, LATER_RECORD);
    struct bytes b = sent(p);
    if (ending == KEEPS_TALKING) {
        SSL_key_update(p->ssl, SSL_KEY_UPDATE_REQUESTED);
        SSL_do_handshake(p->ssl);
        SSL_write(p->ssl, "tail", 4);
        append(&b, sent(p));
    } else {
        SSL_write(p->ssl, "bad", 3);
        struct bytes bad = sent(p);
        bad.data[bad.length - 1] ^= 0x55;
        append(&b, bad);
    }
    deliver(p, b);
}

// The reader's answer to the KeyUpdate reached its client in order: the relay side's next
// write, under its new keys, reads back.
static int answers_in_order(struct peer *p, const char *before) {
    us_socket_write(1, p->s, "pong", 4, 0);
    struct reply r = client_reads(p);
    char want[128];
    snprintf(want, sizeof want, "%spong", before);
    return r.error == SSL_ERROR_WANT_READ && r.length == (int) strlen(want) && memcmp(r.data, want, r.length) == 0;
}

// The reader still decrypts what its client sends next.
static int reads_on(struct peer *p, long before) {
    SSL_write(p->ssl, "more", 4);
    deliver(p, sent(p));
    return !us_socket_is_closed(1, p->s) && plaintext_of(p) == before + 4;
}

// The other socket saw only what the hand-over did to it.
static int other_untouched(enum hand_over action, struct peer *o) {
    if (action == ADOPT_OTHER) return pump(o) == 0 && !us_socket_is_closed(1, o->s);
    struct reply r = client_reads(o);
    if (action == SHUT_DOWN_OTHER) return r.error == SSL_ERROR_ZERO_RETURN && r.length == 0;
    return r.error == SSL_ERROR_WANT_READ && r.length == 3 && memcmp(r.data, "fwd", 3) == 0;
}

static void named_check(const char *what, const char *outcome, int ok) {
    char name[256];
    snprintf(name, sizeof name, "%s: %s", what, outcome);
    check(name, ok);
}

static void hand_over(enum hand_over action, enum ending ending, const char *what) {
    struct peer r, o;
    int two = action != ADOPT_SELF;
    if (!peer_open(&r) || (two && !peer_open(&o))) {
        named_check(what, "(TLS sessions)", 0);
        return;
    }
    memset(&scene, 0, sizeof scene);
    scene.reader = &r;
    scene.other = two ? &o : NULL;
    scene.action = action;
    send_load(&r, ending);
#ifdef UNDER_ASAN
    if (action == ADOPT_SELF) named_check(what, "(the adoption moved the socket)", scene.moved);
#endif
    const char *before = action == ADOPT_SELF ? upgrade : "";
    if (ending == KEEPS_TALKING) {
        named_check(what, "the reader keeps its records",
                    scene.done && !us_socket_is_closed(1, r.s) && plaintext_of(&r) == kept);
        named_check(what, "its KeyUpdate answer and next write reach it in order", answers_in_order(&r, before));
        named_check(what, "it decrypts on", reads_on(&r, kept));
    } else {
        struct reply rr = client_reads(&r);
        named_check(what, "a forged record later, its alert reaches the reader",
                    scene.done && us_socket_is_closed(1, r.s) && rr.length == (int) strlen(before) &&
                        memcmp(rr.data, before, rr.length) == 0 && rr.error == SSL_ERROR_SSL &&
                        rr.reason == SSL_R_SSLV3_ALERT_BAD_RECORD_MAC);
    }
    if (two) named_check(what, "the other socket saw only its own part", other_untouched(action, &o));
    peer_close(&r);
    if (two) peer_close(&o);
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: test_usockets_ssl <cert.pem> <key.pem>\n");
        return 2;
    }
    // A sanitizer report ends the process: the lines before it must be out.
    setvbuf(stdout, NULL, _IOLBF, 0);
    printf("uSockets TLS: a read handed over mid-buffer keeps its records and its answers reach it\n");
    loop = us_create_loop(0, on_wakeup, on_pre, on_post, 0);
    struct us_socket_context_options_t options;
    memset(&options, 0, sizeof options);
    options.cert_file_name = argv[1];
    options.key_file_name = argv[2];
    context = us_create_socket_context(1, loop, 0, options);
    client_ctx = SSL_CTX_new(TLS_client_method());
    if (!context || !client_ctx) {
        check("(a TLS context)", 0);
        return 1;
    }
    SSL_CTX_set_min_proto_version(client_ctx, TLS1_3_VERSION);
    us_socket_context_on_open(1, context, on_open);
    us_socket_context_on_data(1, context, on_data);
    us_socket_context_on_writable(1, context, on_socket);
    us_socket_context_on_close(1, context, on_close);
    us_socket_context_on_timeout(1, context, on_socket);
    us_socket_context_on_long_timeout(1, context, on_socket);
    us_socket_context_on_end(1, context, on_socket);
    us_socket_context_on_connect_error(1, context, on_connect_error);

    for (int e = KEEPS_TALKING; e <= FORGES; e++) {
        hand_over(FORWARD, e, "a write to another socket inside a full read");
        hand_over(SHUT_DOWN_OTHER, e, "a shutdown of another socket inside a full read");
        hand_over(ADOPT_SELF, e, "an upgrade (adopt, then write) inside a full read");
        hand_over(ADOPT_OTHER, e, "another socket adopted inside a full read");
    }

    us_internal_free_closed_sockets(loop);
    SSL_CTX_free(client_ctx);
    us_socket_context_free(1, context);
    us_loop_free(loop);
    if (failures) printf("%d FAILED\n", failures);
    return failures ? 1 : 0;
}
