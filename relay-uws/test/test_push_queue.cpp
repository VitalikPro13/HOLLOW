// Unit tests for the push worker queue (src/push_queue.h): jobs reach the worker
// in order, a full queue drops its oldest job, and a process whose worker is
// parked still exits. The last one is the test that matters: a relay stop that
// hangs is a relay that is down until systemd's SIGKILL 90 s later.
// run_tests.sh runs every test under a timeout, so a hang is a failure.
//
// Build + run from relay-uws/test:
//   g++ -std=c++17 -pthread -I../src test_push_queue.cpp -o test_push_queue && ./test_push_queue

#include "push_queue.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

static int failures = 0;

static void check(const std::string& label, bool ok) {
    if (ok) {
        printf("  ok   %s\n", label.c_str());
    } else {
        printf("  FAIL %s\n", label.c_str());
        failures++;
    }
}

struct Job {
    int n = 0;
};

static std::mutex seen_mtx;
static std::vector<int> seen;
static std::atomic<bool> hold{false};
static std::atomic<bool> holding{false};

static void deliver(const Job& job) {
    while (hold.load()) {
        holding = true;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    holding = false;
    std::lock_guard<std::mutex> lock(seen_mtx);
    seen.push_back(job.n);
}

static std::vector<int> delivered() {
    std::lock_guard<std::mutex> lock(seen_mtx);
    return seen;
}

static bool wait_until(size_t count) {
    for (int i = 0; i < 2000; i++) {
        if (delivered().size() >= count) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return false;
}

// Namespace scope, like the relay's: exit() destroys it while the worker waits.
static PushQueue<Job> queue(3, deliver);

int main() {
    queue.enqueue(Job{1});
    check("a job reaches the worker", wait_until(1) && delivered() == std::vector<int>{1});

    queue.enqueue(Job{2});
    queue.enqueue(Job{3});
    check("jobs arrive in the order they were queued",
          wait_until(3) && delivered() == std::vector<int>({1, 2, 3}));

    // The worker is held inside job 4, so 5..8 pile up behind a cap of three.
    hold = true;
    queue.enqueue(Job{4});
    for (int i = 0; i < 2000 && !holding.load(); i++) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    for (int n = 5; n <= 8; n++) queue.enqueue(Job{n});
    hold = false;
    check("a full queue drops its oldest job, never the newest",
          wait_until(7) && delivered() == std::vector<int>({1, 2, 3, 4, 6, 7, 8}));

    // Returning with the worker parked on the queue is the exit test itself.
    printf("%s\n", failures ? "FAILED" : "all passed");
    return failures ? 1 : 0;
}
