#include "flutter_common.h"
#include "task_runner.h"

#include <memory>

class MethodCallProxyImpl : public MethodCallProxy {
 public:
  explicit MethodCallProxyImpl(const MethodCall& method_call)
      : method_call_(method_call) {}

  ~MethodCallProxyImpl() {}

  // The name of the method being called.

  const std::string& method_name() const override {
    return method_call_.method_name();
  }

  // The arguments to the method call, or NULL if there are none.
  const EncodableValue* arguments() const override {
    return method_call_.arguments();
  }

 private:
  const MethodCall& method_call_;
};

std::unique_ptr<MethodCallProxy> MethodCallProxy::Create(
    const MethodCall& call) {
  return std::make_unique<MethodCallProxyImpl>(call);
}

class MethodResultProxyImpl : public MethodResultProxy {
 public:
  explicit MethodResultProxyImpl(std::unique_ptr<MethodResult> method_result)
      : method_result_(std::move(method_result)) {}
  ~MethodResultProxyImpl() {}

  // Reports success with no result.
  void Success() override { method_result_->Success(); }

  // Reports success with a result.
  void Success(const EncodableValue& result) override {
    method_result_->Success(result);
  }

  // Reports an error.
  void Error(const std::string& error_code,
             const std::string& error_message,
             const EncodableValue& error_details) override {
    method_result_->Error(error_code, error_message, error_details);
  }

  // Reports an error with a default error code and no details.
  void Error(const std::string& error_code,
             const std::string& error_message = "") override {
    method_result_->Error(error_code, error_message);
  }

  void NotImplemented() override { method_result_->NotImplemented(); }

 private:
  std::unique_ptr<MethodResult> method_result_;
};

std::unique_ptr<MethodResultProxy> MethodResultProxy::Create(
    std::unique_ptr<MethodResult> method_result) {
  return std::make_unique<MethodResultProxyImpl>(std::move(method_result));
}

// Shared state for the EventChannel stream handler. The on_listen/on_cancel
// lambdas registered with Flutter's EventChannel can be invoked ASYNCHRONOUSLY
// by the BinaryMessenger AFTER the owning EventChannelProxyImpl has been
// destroyed (rapid PeerConnection create/destroy churn — valgrind caught a
// 1-byte "Invalid write" in OnCancelInternal writing on_listen_called_ into a
// freed proxy, which smashed an adjacent heap chunk -> "corrupted size vs
// prev_size"). Holding the state in a shared_ptr that the lambdas capture by
// value means a late callback writes into still-live state instead of freed
// memory. The proxy resets the handler in its destructor so callbacks stop
// promptly, but this is the load-bearing safety net.
struct EventChannelState {
  std::shared_ptr<flutter::EventSink<flutter::EncodableValue>> sink;
  std::list<EncodableValue> event_queue;
  bool on_listen_called = false;
  TaskRunner* task_runner = nullptr;

  void PostEvent(const EncodableValue& event) {
    if (task_runner) {
      std::weak_ptr<EventSink> weak_sink = sink;
      task_runner->EnqueueTask([weak_sink, event]() {
        auto s = weak_sink.lock();
        if (s) {
          s->Success(event);
        }
      });
    } else if (sink) {
      sink->Success(event);
    }
  }
};

class EventChannelProxyImpl : public EventChannelProxy {
  public:
   EventChannelProxyImpl(BinaryMessenger* messenger,
                         TaskRunner* task_runner,
                         const std::string& channelName)
       : channel_(std::make_unique<EventChannel>(
             messenger,
             channelName,
             &flutter::StandardMethodCodec::GetInstance())),
         state_(std::make_shared<EventChannelState>()) {
     state_->task_runner = task_runner;
     std::shared_ptr<EventChannelState> state = state_;
     auto handler = std::make_unique<
         flutter::StreamHandlerFunctions<EncodableValue>>(
         [state](const EncodableValue* arguments,
             std::unique_ptr<flutter::EventSink<EncodableValue>>&& events)
             -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
           state->sink = std::move(events);
           for (auto& event : state->event_queue) {
            state->PostEvent(event);
           }
           state->event_queue.clear();
           state->on_listen_called = true;
           return nullptr;
         },
         [state](const EncodableValue* arguments)
             -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
           state->on_listen_called = false;
           state->sink = nullptr;
           return nullptr;
         });

     channel_->SetStreamHandler(std::move(handler));
   }

   virtual ~EventChannelProxyImpl() {
     // Explicitly unregister the stream handler WHILE the channel is still alive
     // so Flutter's EventChannel detaches its BinaryMessenger message handler in
     // an orderly way — then destroy the channel. Relying on channel_.reset()
     // alone left a window where the messenger could invoke a handler bound to a
     // half-destroyed EventChannel (valgrind: a residual 1-byte "Invalid write"
     // at shutdown in EventChannel::SetStreamHandler's lambda, after the engine
     // view was removed -> "set message handler on FlBinaryMessenger without an
     // engine"). The shared_ptr state outlives any in-flight callback regardless.
     if (channel_) {
       channel_->SetStreamHandler(nullptr);
     }
     channel_.reset();
   }

   void Success(const EncodableValue& event, bool cache_event = true) override {
     if (state_->on_listen_called) {
       state_->PostEvent(event);
     } else {
       if (cache_event) {
         state_->event_queue.push_back(event);
       }
     }
   }

  private:
   std::unique_ptr<EventChannel> channel_;
   std::shared_ptr<EventChannelState> state_;
 };

std::unique_ptr<EventChannelProxy> EventChannelProxy::Create(
    BinaryMessenger* messenger,
    TaskRunner* task_runner,
    const std::string& channelName) {
  return std::make_unique<EventChannelProxyImpl>(messenger, task_runner, channelName);
}