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

constexpr uint32_t kExpectedAbi = 1;

using AbiVersionFn = uint32_t (*)();
using CreateFn = void* (*)();
using ProcessFn = int32_t (*)(void*, float*, int32_t);
using SetF32Fn = void (*)(void*, float);

// Published once by Bind(); read with relaxed loads on the audio thread.
std::atomic<CreateFn> g_create{nullptr};
std::atomic<ProcessFn> g_process{nullptr};
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
  const auto create = reinterpret_cast<CreateFn>(ResolveSym("hollow_dfn_create"));
  const auto process =
      reinterpret_cast<ProcessFn>(ResolveSym("hollow_dfn_process"));
  const auto set_atten =
      reinterpret_cast<SetF32Fn>(ResolveSym("hollow_dfn_set_atten_lim"));
  const auto set_beta =
      reinterpret_cast<SetF32Fn>(ResolveSym("hollow_dfn_set_post_filter_beta"));
  if (!create || !process || !set_atten || !set_beta) {
    std::fprintf(stderr, "[hollow_dfn] incomplete symbol set — unavailable\n");
    return;
  }
  g_create.store(create, std::memory_order_relaxed);
  g_set_atten.store(set_atten, std::memory_order_relaxed);
  g_set_beta.store(set_beta, std::memory_order_relaxed);
  // process last, release: a relaxed audio-thread reader that sees it also
  // sees a fully-bound state.
  g_process.store(process, std::memory_order_release);
  g_bound.store(true, std::memory_order_release);
}

}  // namespace

bool Bind() {
  std::call_once(g_bind_once, BindImpl);
  return g_bound.load(std::memory_order_acquire);
}

bool IsBound() { return g_bound.load(std::memory_order_acquire); }

void* Create() {
  const auto fn = g_create.load(std::memory_order_relaxed);
  return fn ? fn() : nullptr;
}

int ProcessFrame(void* handle, float* frame, int len) {
  const auto fn = g_process.load(std::memory_order_relaxed);
  if (!fn || !handle) return 1;
  return fn(handle, frame, static_cast<int32_t>(len));
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
