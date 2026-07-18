#ifndef HOLLOW_DFN_BINDING_HXX
#define HOLLOW_DFN_BINDING_HXX

// Hollow fork: runtime binding to the DeepFilterNet3 C ABI exported by
// hollow_core (rust/hollow_core/src/dfn_ffi.rs). The plugin never links
// hollow_core — the symbols are resolved from the ALREADY-LOADED library at
// the first enable:
//   - Windows: GetModuleHandleW(L"hollow_core.dll") (cargokit names the
//     cdylib exactly that; fallback LoadLibraryW for odd load orders).
//   - Linux: dlopen("libhollow_core.so") — Dart's own DynamicLibrary.open
//     uses RTLD_LOCAL, so dlsym(RTLD_DEFAULT) would NOT find the symbols;
//     glibc dedupes by inode so this maps the same object, and the
//     plugin's $ORIGIN rpath resolves the soname from bundle/lib/.
// An ABI-version handshake guards against symbol drift: on mismatch (or
// any resolution failure) the binding stays unbound and every call is a
// graceful no-op — DFN silently unavailable, never broken audio.
//
// Threading: Bind()/Create() from background/platform threads only
// (Create blocks 100-500 ms on the tract model load). ProcessFrame() is
// audio-thread-safe (one relaxed pointer load; no locks).

namespace hollow_dfn {

// Idempotent; returns true when the ABI is resolved and version-matched.
bool Bind();
bool IsBound();

// Blocking model load — NEVER on the audio thread. nullptr on failure.
void* Create();

// Denoise 480 int16-scale float samples in place. 0 = processed; nonzero =
// frame untouched (unbound / bad handle / engine error). Audio-thread safe.
int ProcessFrame(void* handle, float* frame, int len);

// Lock-free parameter staging (applied by the audio thread next frame).
void SetAttenLim(void* handle, float db);
void SetPostFilterBeta(void* handle, float beta);

}  // namespace hollow_dfn

#endif  // HOLLOW_DFN_BINDING_HXX
