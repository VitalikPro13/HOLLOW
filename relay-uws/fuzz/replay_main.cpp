// Runs a fuzz target over files and directories of inputs without libFuzzer, so the
// relay test suite (any compiler, plain or sanitized) replays every seed and every
// input that once crashed a target. A failing invariant aborts.
//   g++ -I../src fuzz_x.cpp replay_main.cpp -o fuzz_x_replay && ./fuzz_x_replay dir/ file

#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size);
// A target that needs no set-up defines none; a weak definition (not a weak reference)
// links on macOS as well as Linux, and a target's own definition replaces it.
extern "C" __attribute__((weak)) int LLVMFuzzerInitialize(int*, char***) { return 0; }

static bool replay(const std::filesystem::path& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    const std::string bytes((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    LLVMFuzzerTestOneInput(reinterpret_cast<const uint8_t*>(bytes.data()), bytes.size());
    return true;
}

int main(int argc, char** argv) {
    LLVMFuzzerInitialize(&argc, &argv);
    size_t n = 0;
    for (int i = 1; i < argc; i++) {
        const std::filesystem::path arg(argv[i]);
        if (std::filesystem::is_directory(arg)) {
            std::vector<std::filesystem::path> files;
            for (const auto& e : std::filesystem::directory_iterator(arg)) {
                if (e.is_regular_file()) files.push_back(e.path());
            }
            for (const auto& p : files) n += replay(p);
        } else if (std::filesystem::exists(arg)) {
            n += replay(arg);
        }
    }
    // Nothing replayed means a missing or empty seed directory, never a pass.
    if (n == 0) {
        printf("  FAIL replayed no inputs\n");
        return 1;
    }
    printf("  ok   replayed %zu inputs\n", n);
    return 0;
}
