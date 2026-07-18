#include "hollow_dfn_binding.h"

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <mutex>

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace hollow_dfn {
namespace {

constexpr uint32_t kExpectedAbi = 3;

using AbiVersionFn = uint32_t (*)();
using CreateEngineFn = void* (*)(int32_t);
using ProcessExFn =
    int32_t (*)(void*, float*, int32_t, int32_t, int32_t, int32_t);
using LastVadFn = float (*)(void*);
using SetF32Fn = void (*)(void*, float);

// Published once by Bind(); read with relaxed loads on the audio thread.
std::atomic<CreateEngineFn> g_create_engine{nullptr};
std::atomic<ProcessExFn> g_process_ex{nullptr};
std::atomic<LastVadFn> g_last_vad{nullptr};
std::atomic<SetF32Fn> g_set_atten{nullptr};
std::atomic<SetF32Fn> g_set_beta{nullptr};
std::once_flag g_bind_once;
std::atomic<bool> g_bound{false};

void* ResolveSym(const char* name) {
#ifdef _WIN32
  HMODULE mod = GetModuleHandleW(L"hollow_core.dll");
  if (!mod) {
    // Odd load order (enable raced ahead of FRB init): loading by name is
    // safe — the loader refcounts the already-mapped module or finds it
    // next to the runner exe where cargokit bundles it.
    mod = LoadLibraryW(L"hollow_core.dll");
  }
  if (!mod) return nullptr;
  return reinterpret_cast<void*>(GetProcAddress(mod, name));
#else
  // Dart's DynamicLibrary.open is RTLD_LOCAL — RTLD_DEFAULT cannot see the
  // symbols. dlopen the soname ourselves: glibc dedupes by dev/inode (same
  // mapped object, no duplicate statics) and the plugin's $ORIGIN rpath
  // resolves it from bundle/lib/.
  static void* mod = dlopen("libhollow_core.so", RTLD_LAZY | RTLD_LOCAL);
  if (!mod) return nullptr;
  return dlsym(mod, name);
#endif
}

void BindImpl() {
  const auto abi =
      reinterpret_cast<AbiVersionFn>(ResolveSym("hollow_dfn_abi_version"));
  if (!abi) {
    std::fprintf(stderr,
                 "[hollow_dfn] hollow_core symbols not found — AI noise "
                 "suppression unavailable\n");
    return;
  }
  const uint32_t v = abi();
  if (v != kExpectedAbi) {
    std::fprintf(stderr,
                 "[hollow_dfn] ABI mismatch (core %u, plugin expects %u) — "
                 "AI noise suppression unavailable\n",
                 v, kExpectedAbi);
    return;
  }
  const auto create_engine =
      reinterpret_cast<CreateEngineFn>(ResolveSym("hollow_dfn_create_engine"));
  const auto process_ex =
      reinterpret_cast<ProcessExFn>(ResolveSym("hollow_dfn_process_ex"));
  const auto last_vad =
      reinterpret_cast<LastVadFn>(ResolveSym("hollow_dfn_last_vad"));
  const auto set_atten =
      reinterpret_cast<SetF32Fn>(ResolveSym("hollow_dfn_set_atten_lim"));
  const auto set_beta =
      reinterpret_cast<SetF32Fn>(ResolveSym("hollow_dfn_set_post_filter_beta"));
  if (!create_engine || !process_ex || !last_vad || !set_atten || !set_beta) {
    std::fprintf(stderr, "[hollow_dfn] incomplete symbol set — unavailable\n");
    return;
  }
  g_create_engine.store(create_engine, std::memory_order_relaxed);
  g_last_vad.store(last_vad, std::memory_order_relaxed);
  g_set_atten.store(set_atten, std::memory_order_relaxed);
  g_set_beta.store(set_beta, std::memory_order_relaxed);
  // process last, release: a relaxed audio-thread reader that sees it also
  // sees a fully-bound state.
  g_process_ex.store(process_ex, std::memory_order_release);
  g_bound.store(true, std::memory_order_release);
}

}  // namespace

bool Bind() {
  std::call_once(g_bind_once, BindImpl);
  return g_bound.load(std::memory_order_acquire);
}

bool IsBound() { return g_bound.load(std::memory_order_acquire); }

void* CreateEngine(int engine) {
  const auto fn = g_create_engine.load(std::memory_order_relaxed);
  return fn ? fn(static_cast<int32_t>(engine)) : nullptr;
}

int ProcessFrameEx(void* handle, float* buf, int len, int num_bands, int rate,
                   int channels) {
  const auto fn = g_process_ex.load(std::memory_order_relaxed);
  if (!fn || !handle) return 1;
  return fn(handle, buf, static_cast<int32_t>(len),
            static_cast<int32_t>(num_bands), static_cast<int32_t>(rate),
            static_cast<int32_t>(channels));
}

float LastVad(void* handle) {
  const auto fn = g_last_vad.load(std::memory_order_relaxed);
  if (!fn || !handle) return -1.0f;
  return fn(handle);
}

void SetAttenLim(void* handle, float db) {
  const auto fn = g_set_atten.load(std::memory_order_relaxed);
  if (fn && handle) fn(handle, db);
}

void SetPostFilterBeta(void* handle, float beta) {
  const auto fn = g_set_beta.load(std::memory_order_relaxed);
  if (fn && handle) fn(handle, beta);
}

}  // namespace hollow_dfn
