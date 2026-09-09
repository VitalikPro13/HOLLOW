#include <hollow_pulse_devices.h>
#include <pulse/pulseaudio.h>
#include <pulse/simple.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <stdexcept>
#include <string>
#include <thread>

using namespace std::chrono_literals;
static void Check(bool ok, const char* message) {
  if (!ok) throw std::runtime_error(message);
}

struct Probe {
  pa_mainloop* loop = pa_mainloop_new();
  pa_context* context = pa_context_new(pa_mainloop_get_api(loop), "hollow-route-test");
  uint32_t module = PA_INVALID_INDEX;
  uint32_t sourceModule = PA_INVALID_INDEX;
  uint32_t sink = PA_INVALID_INDEX;
  uint32_t source = PA_INVALID_INDEX;
  std::map<std::string, uint32_t> streams;
  std::map<std::string, uint32_t> captures;

  Probe() {
    Check(pa_context_connect(context, nullptr, PA_CONTEXT_NOFLAGS, nullptr) == 0, "connect");
    Wait([&] { return pa_context_get_state(context) == PA_CONTEXT_READY; });
    Op(pa_context_load_module(context, "module-null-sink", "sink_name=hollow_route_test",
        [](pa_context*, uint32_t index, void* data) { static_cast<Probe*>(data)->module = index; }, this));
    Check(module != PA_INVALID_INDEX, "create isolated test sink");
    Op(pa_context_get_sink_info_by_name(context, "hollow_route_test",
        [](pa_context*, const pa_sink_info* info, int, void* data) {
          if (info) static_cast<Probe*>(data)->sink = info->index;
        }, this));
    Check(sink != PA_INVALID_INDEX, "find test sink");
  }

  ~Probe() {
    if (sourceModule != PA_INVALID_INDEX) {
      try { Op(pa_context_unload_module(context, sourceModule, nullptr, nullptr)); } catch (...) {}
    }
    if (module != PA_INVALID_INDEX) {
      try { Op(pa_context_unload_module(context, module, nullptr, nullptr)); } catch (...) {}
    }
    pa_context_disconnect(context);
    pa_context_unref(context);
    pa_mainloop_free(loop);
  }

  template<class F> void Wait(F done) {
    auto deadline = std::chrono::steady_clock::now() + 3s;
    while (!done()) {
      Check(std::chrono::steady_clock::now() < deadline, "PulseAudio operation timed out");
      pa_mainloop_iterate(loop, 0, nullptr);
      std::this_thread::sleep_for(5ms);
    }
  }

  void Op(pa_operation* op) {
    Check(op != nullptr, "PulseAudio request");
    try { Wait([&] { return pa_operation_get_state(op) != PA_OPERATION_RUNNING; }); }
    catch (...) { pa_operation_cancel(op); pa_operation_unref(op); throw; }
    pa_operation_unref(op);
  }

  void Refresh() {
    streams.clear();
    Op(pa_context_get_sink_input_info_list(context,
        [](pa_context*, const pa_sink_input_info* info, int, void* data) {
          if (!info) return;
          const char* name = pa_proplist_gets(info->proplist, PA_PROP_MEDIA_NAME);
          if (name) static_cast<Probe*>(data)->streams[name] = info->sink;
        }, this));
    captures.clear();
    Op(pa_context_get_source_output_info_list(context,
        [](pa_context*, const pa_source_output_info* info, int, void* data) {
          if (!info) return;
          const char* name = pa_proplist_gets(info->proplist, PA_PROP_MEDIA_NAME);
          if (name) static_cast<Probe*>(data)->captures[name] = info->source;
        }, this));
  }
};

static pa_simple* Playback(const char* name) {
  pa_sample_spec spec{PA_SAMPLE_S16LE, 48000, 1};
  int error = 0;
  auto* stream = pa_simple_new(nullptr, "hollow-route-test", PA_STREAM_PLAYBACK,
      nullptr, name, &spec, nullptr, nullptr, &error);
  Check(stream != nullptr, "create playback stream");
  return stream;
}

static pa_simple* Capture(const char* name, const char* source) {
  pa_sample_spec spec{PA_SAMPLE_S16LE, 48000, 1};
  auto* stream = pa_simple_new(nullptr, "hollow-route-test", PA_STREAM_RECORD,
      source, name, &spec, nullptr, nullptr, nullptr);
  Check(stream != nullptr, "create capture stream");
  return stream;
}

int main(int argc, char** argv) {
  if (argc > 1 && std::string(argv[1]) == "--stalled-server") {
    const auto path = "/tmp/hollow-pulse-stall-" + std::to_string(getpid());
    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    std::strncpy(address.sun_path, path.c_str(), sizeof(address.sun_path) - 1);
    if (server < 0 || bind(server, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0 ||
        listen(server, 1) != 0) return 1;
    setenv("PULSE_SERVER", ("unix:" + path).c_str(), 1);
    const auto start = std::chrono::steady_clock::now();
    std::vector<hollow_pulse::AudioDevice> inputs, outputs;
    const bool answered = hollow_pulse::EnumerateDevices(&inputs, &outputs);
    const auto elapsed = std::chrono::steady_clock::now() - start;
    close(server);
    unlink(path.c_str());
    if (answered || elapsed > 3s) return 1;
    std::puts("PASS: an unresponsive audio server times out within 3 seconds");
    return 0;
  }
  if (argc > 1 && std::string(argv[1]) == "--foreign") {
    setenv("PULSE_PROP_application.process.id", argv[2], 1);
    setenv("PULSE_PROP_hollow.instance", "another-flatpak-instance", 1);
    auto* foreign = Playback("hollow-foreign");
    sleep(20);
    pa_simple_free(foreign);
    return 0;
  }
  hollow_pulse::InitializeRouting();
  pa_simple* first = nullptr;
  pa_simple* future = nullptr;
  pa_simple* capture = nullptr;
  pa_simple* futureCapture = nullptr;
  pid_t child = -1;
  try {
    Probe probe;
    child = fork();
    if (child == 0) {
      const auto parentPid = std::to_string(getppid());
      execl(argv[0], argv[0], "--foreign", parentPid.c_str(), nullptr);
      _exit(127);
    }
    Check(child > 0, "spawn independent audio client");
    first = Playback("hollow-existing");
    probe.Wait([&] { probe.Refresh(); return probe.streams.count("hollow-foreign") > 0; });
    auto foreignSink = probe.streams.at("hollow-foreign");
    Check(foreignSink != probe.sink, "test sink must not be the default");
    Check(hollow_pulse::SelectDevice("hollow_route_test", false), "select test output");
    probe.Wait([&] { probe.Refresh(); return probe.streams["hollow-existing"] == probe.sink; });
    future = Playback("hollow-future");
    probe.Wait([&] { probe.Refresh(); return probe.streams["hollow-future"] == probe.sink; });
    Check(probe.streams.at("hollow-foreign") == foreignSink, "another process was rerouted");
    Check(!hollow_pulse::SelectDevice("hollow_missing_device", false), "missing device accepted");
    Check(hollow_pulse::SelectDevice("default", false), "restore default output");
    probe.Wait([&] { probe.Refresh(); return probe.streams["hollow-existing"] == foreignSink; });
    std::vector<hollow_pulse::AudioDevice> inputs, outputs;
    Check(hollow_pulse::EnumerateDevices(&inputs, &outputs) && !inputs.empty(), "real microphone available");
    const auto remap = "source_name=hollow_route_source master=" + inputs.front().id;
    probe.Op(pa_context_load_module(probe.context, "module-remap-source", remap.c_str(),
        [](pa_context*, uint32_t index, void* data) { static_cast<Probe*>(data)->sourceModule = index; }, &probe));
    Check(probe.sourceModule != PA_INVALID_INDEX, "create isolated microphone source");
    probe.Op(pa_context_get_source_info_by_name(probe.context, "hollow_route_source",
        [](pa_context*, const pa_source_info* info, int, void* data) {
          if (info) static_cast<Probe*>(data)->source = info->index;
        }, &probe));
    capture = Capture("hollow-mic-existing", inputs.front().id.c_str());
    Check(hollow_pulse::SelectDevice("hollow_route_source", true), "select microphone");
    probe.Wait([&] { probe.Refresh(); return probe.captures["hollow-mic-existing"] == probe.source; });
    futureCapture = Capture("hollow-mic-future", inputs.front().id.c_str());
    probe.Wait([&] { probe.Refresh(); return probe.captures["hollow-mic-future"] == probe.source; });
    pa_simple_free(capture); capture = nullptr;
    pa_simple_free(futureCapture); futureCapture = nullptr;
    pa_simple_free(first); first = nullptr;
    pa_simple_free(future); future = nullptr;
    kill(child, SIGTERM); waitpid(child, nullptr, 0); child = -1;
    std::puts("PASS: existing and future playback/capture routed; colliding foreign PID unchanged; invalid device refused; default restored");
  } catch (const std::exception& error) {
    if (first) pa_simple_free(first);
    if (future) pa_simple_free(future);
    if (capture) pa_simple_free(capture);
    if (futureCapture) pa_simple_free(futureCapture);
    if (child > 0) { kill(child, SIGTERM); waitpid(child, nullptr, 0); }
    std::fprintf(stderr, "FAIL: %s\n", error.what());
    return 1;
  }
}
