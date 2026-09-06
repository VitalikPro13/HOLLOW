# Vendored OpenSSL for the Android SQLCipher build

`libsqlite3-sys` (rusqlite, feature `bundled-sqlcipher`) compiles SQLCipher's
OpenSSL crypto provider for the Android targets and links `libcrypto`
statically. SQLCipher 4.6 and newer call the OpenSSL 3 `EVP_MAC` API, so the
1.1.1w build that lived here until 2026-09-06 no longer compiles (the 0.11
release caught it: cargokit failed, Gradle packaged 0.10.1's `.so` anyway).

Contents:

- `include/openssl/` headers from the aarch64 build, shared by every ABI. The
  only per-ABI differences are `configuration.h`'s big-number word width
  (`SIXTY_FOUR_BIT_LONG` / `THIRTY_TWO_BIT` / `BN_LLONG`) and `RC4_INT`,
  which SQLCipher's provider never touches. The per-ABI originals are kept in
  `include-per-arch/<abi>/configuration.h` for reference.
- `lib/<aarch64|armv7|x86_64|i686>/libcrypto.a`, static, one per ABI.

Built on the Linux release VM from the official `openssl-3.5.8.tar.gz`
(SHA-256 verified against the published `.sha256`) with NDK r27c:

```
./Configure <android-arm64|android-arm|android-x86_64|android-x86> \
    -D__ANDROID_API__=21 no-shared no-module no-tests no-apps no-docs
make build_libs && make install_dev
```

How it reaches the build: the patched cargokit
(`rust_builder/cargokit/build_tool/lib/src/android_environment.dart`) reads the
SYSTEM environment variables `HOLLOW_ANDROID_OPENSSL_INCLUDE` (this `include/`
dir) and `HOLLOW_ANDROID_OPENSSL_LIB` (this `lib/` dir, ABI subfolder appended).
`.cargo/config.toml`'s `[env]` block is only seen by bare `cargo` runs inside
`rust/hollow_core`, never by cargokit, whose working directory is elsewhere.
