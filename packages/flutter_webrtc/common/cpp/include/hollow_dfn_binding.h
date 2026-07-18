#ifndef HOLLOW_DFN_BINDING_HXX
#define HOLLOW_DFN_BINDING_HXX

// Hollow fork: runtime binding to the AI noise-suppression C ABI exported
// by hollow_core (rust/hollow_core/src/dfn_ffi.rs) — RNNoise by default,
// DFN3 behind engine id 1, both behind the Rust format adapter. The plugin
// never links hollow_core — the symbols are resolved from the
// ALREADY-LOADED library at the first enable:
//   - Windows: GetModuleHandleW(L"hollow_core.dll") (cargokit names the
//     cdylib exactly that; fallback LoadLibraryW for odd load orders).
//   - Linux: dlopen("libhollow_core.so") — Dart's own DynamicLibrary.open
//     uses RTLD_LOCAL, so dlsym(RTLD_DEFAULT) would NOT find the symbols;
//     glibc dedupes by inode so this maps the same object, and the
//     plugin's $ORIGIN rpath resolves the soname from bundle/lib/.
// An ABI-version handshake guards against symbol drift: on mismatch (or
// any resolution failure) the binding stays unbound and every call is a
// graceful no-op — AI NS silently unavailable, never broken audio.
//
// Threading: Bind()/CreateEngine() from background/platform threads only
// (a DFN3 create blocks 100-500 ms on the tract model load; RNNoise is
// instant). ProcessFrameEx() is audio-thread-safe (one relaxed pointer
// load; no locks).

namespace hollow_dfn {

// Engine ids — MUST match hollow_dfn::EngineKind in Rust.
constexpr int kEngineRnnoise = 0;
constexpr int kEngineDfn3 = 1;

// Idempotent; returns true when the ABI is resolved and version-matched.
bool Bind();
bool IsBound();

// Blocking engine create — NEVER on the audio thread. nullptr on failure.
void* CreateEngine(int engine);

// Denoise one 10 ms capture frame in place, whatever shape the APM
// delivered: `buf`/`len` cover the ENTIRE buffer (all bands and channels,
// planar, int16-scale floats). Returns 0 = processed; 4 = unsupported
// capture shape (frame untouched — latch formatOk, fall back to WebRTC
// NS); any other nonzero = engine error (frame possibly half-written —
// latch session bypass). Audio-thread safe.
int ProcessFrameEx(void* handle, float* buf, int len, int num_bands,
                   int rate, int channels);

// Voice probability of the LAST successfully processed frame (0..1), or
// -1.0 when unavailable (DFN3 engine, no frame yet, unbound). RNNoise
// computes it for free; the chain's gate/upward stage uses it as the
// speech-presence signal (breath discrimination), falling back to its own
// SNR+modulation gating on -1. Audio thread only, right after ProcessFrameEx
// returned 0 — no cross-thread synchronization.
float LastVad(void* handle);

// Lock-free parameter staging (applied by the audio thread next frame).
// DFN3-only tuning; RNNoise ignores both.
void SetAttenLim(void* handle, float db);
void SetPostFilterBeta(void* handle, float beta);

}  // namespace hollow_dfn

#endif  // HOLLOW_DFN_BINDING_HXX
