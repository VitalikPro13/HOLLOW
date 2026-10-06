#ifndef RUNNER_RELAY_TRIGGERS_H_
#define RUNNER_RELAY_TRIGGERS_H_

#include <gio/gio.h>

// Network changes and wake from sleep for lib/src/core/services/relay_triggers.dart.
// `event` is "network" or "wake", delivered on the thread-default main context.
typedef void (*RelayTriggerFn)(const char* event, gpointer user_data);

typedef struct _RelayTriggers RelayTriggers;

RelayTriggers* relay_triggers_start(RelayTriggerFn fn, gpointer user_data);

void relay_triggers_stop(RelayTriggers* triggers);

#endif  // RUNNER_RELAY_TRIGGERS_H_
