#pragma once
#include <sys/stat.h>

#include <cstdint>
#include <string>

// What a reload timer compares an operator file by. Seconds alone missed a second edit
// inside the same second, and an atomic rename onto the path keeps the time an editor
// gave the new file, so the nanoseconds, the size and the inode all count.
struct FileStamp {
    bool exists = false;
    int64_t sec = 0;
    int64_t nsec = 0;
    int64_t size = 0;
    uint64_t ino = 0;
    uint64_t dev = 0;

    bool operator==(const FileStamp& o) const {
        return exists == o.exists && sec == o.sec && nsec == o.nsec && size == o.size && ino == o.ino && dev == o.dev;
    }
    bool operator!=(const FileStamp& o) const { return !(*this == o); }
};

inline FileStamp file_stamp(const std::string& path) {
    FileStamp s;
    struct stat st {};
    if (::stat(path.c_str(), &st) != 0) return s;
    s.exists = true;
#ifdef __APPLE__
    s.sec = static_cast<int64_t>(st.st_mtimespec.tv_sec);
    s.nsec = static_cast<int64_t>(st.st_mtimespec.tv_nsec);
#else
    s.sec = static_cast<int64_t>(st.st_mtim.tv_sec);
    s.nsec = static_cast<int64_t>(st.st_mtim.tv_nsec);
#endif
    s.size = static_cast<int64_t>(st.st_size);
    s.ino = static_cast<uint64_t>(st.st_ino);
    s.dev = static_cast<uint64_t>(st.st_dev);
    return s;
}
