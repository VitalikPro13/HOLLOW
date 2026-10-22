// Seeds for fuzz_snapshot_codec: the snapshots and old-version fixtures the codec's
// unit test pins, so the seeds follow every VERSION bump without a copy here.
//   gen_snapshot_seeds <out_dir>

#include <cstdio>
#include <string>

#define main snapshot_codec_test_main
#include "../test/test_snapshot_codec.cpp"
#undef main

static void write_seed(const std::string& dir, const std::string& name, const std::string& bytes) {
    const std::string path = dir + "/" + name;
    FILE* f = fopen(path.c_str(), "wb");
    if (!f) return;
    fwrite(bytes.data(), 1, bytes.size(), f);
    fclose(f);
}

int main(int argc, char** argv) {
    if (argc != 2) return 2;
    const std::string dir = argv[1];
    write_seed(dir, "current", snapshot::encode(sample()));
    write_seed(dir, "empty", snapshot::encode(snapshot::Data{}));
    write_seed(dir, "v1_fixture", std::string(reinterpret_cast<const char*>(V1_FIXTURE), sizeof(V1_FIXTURE)));
    write_seed(dir, "v2_fixture", std::string(reinterpret_cast<const char*>(V2_FIXTURE), sizeof(V2_FIXTURE)));
    return 0;
}
