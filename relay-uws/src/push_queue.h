#pragma once
// One persistent worker that drains a bounded job queue off the event loop.
#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <deque>
#include <mutex>
#include <thread>

template <typename Job>
class PushQueue {
public:
    using Deliver = void (*)(const Job&);

    PushQueue(size_t max_jobs, Deliver deliver) : max_jobs_(max_jobs), deliver_(deliver) {}

    // Past max_jobs the oldest job goes: a push is best-effort, the message
    // itself is already buffered.
    void enqueue(Job job) {
        bool expected = false;
        if (started_.compare_exchange_strong(expected, true)) {
            std::thread(&PushQueue::run, shared_, deliver_).detach();
        }
        {
            std::lock_guard<std::mutex> lock(shared_->mtx);
            if (shared_->jobs.size() >= max_jobs_) shared_->jobs.pop_front();
            shared_->jobs.push_back(std::move(job));
        }
        shared_->cv.notify_one();
    }

private:
    struct Shared {
        std::mutex mtx;
        std::condition_variable cv;
        std::deque<Job> jobs;
    };

    static void run(Shared* s, Deliver deliver) {
        for (;;) {
            Job job;
            {
                std::unique_lock<std::mutex> lock(s->mtx);
                s->cv.wait(lock, [s] { return !s->jobs.empty(); });
                job = std::move(s->jobs.front());
                s->jobs.pop_front();
            }
            deliver(job);
        }
    }

    size_t max_jobs_;
    Deliver deliver_;
    std::atomic<bool> started_{false};
    // Never freed: the detached worker still waits on it when exit() runs the
    // static destructors, and glibc blocks forever destroying a condition
    // variable that has a waiter (every relay stop after a push hung until
    // systemd's SIGKILL, 90 s later).
    Shared* shared_ = new Shared;
};
