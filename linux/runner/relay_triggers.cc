#include "relay_triggers.h"

struct _RelayTriggers {
  RelayTriggerFn fn;
  gpointer user_data;
  // GNetworkMonitor rather than NetworkManager's StateChanged: it also sees a
  // new default route while the state stays "connected", works without
  // NetworkManager, and goes through the portal inside the flatpak.
  GNetworkMonitor* monitor;
  gulong network_handler;
  GCancellable* cancellable;
  GDBusConnection* system_bus;
  guint sleep_subscription;
};

static void on_network_changed(GNetworkMonitor* monitor, gboolean available,
                               gpointer data) {
  auto* self = static_cast<RelayTriggers*>(data);
  if (available) {
    self->fn("network", self->user_data);
  }
}

static void on_prepare_for_sleep(GDBusConnection* bus, const gchar* sender,
                                 const gchar* path, const gchar* interface,
                                 const gchar* signal, GVariant* parameters,
                                 gpointer data) {
  auto* self = static_cast<RelayTriggers*>(data);
  if (!g_variant_is_of_type(parameters, G_VARIANT_TYPE("(b)"))) {
    return;
  }
  gboolean going_to_sleep = FALSE;
  g_variant_get(parameters, "(b)", &going_to_sleep);
  if (!going_to_sleep) {
    self->fn("wake", self->user_data);
  }
}

static void on_system_bus(GObject* source, GAsyncResult* result,
                          gpointer data) {
  g_autoptr(GError) error = nullptr;
  GDBusConnection* bus = g_bus_get_finish(result, &error);
  if (bus == nullptr) {
    // Cancelled means `data` is already freed.
    if (!g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) {
      g_warning("relay triggers: no system bus, wake not watched: %s",
                error->message);
    }
    return;
  }
  auto* self = static_cast<RelayTriggers*>(data);
  self->system_bus = bus;
  self->sleep_subscription = g_dbus_connection_signal_subscribe(
      bus, "org.freedesktop.login1", "org.freedesktop.login1.Manager",
      "PrepareForSleep", "/org/freedesktop/login1", nullptr,
      G_DBUS_SIGNAL_FLAGS_NONE, on_prepare_for_sleep, self, nullptr);
}

RelayTriggers* relay_triggers_start(RelayTriggerFn fn, gpointer user_data) {
  auto* self = g_new0(RelayTriggers, 1);
  self->fn = fn;
  self->user_data = user_data;
  self->monitor =
      G_NETWORK_MONITOR(g_object_ref(g_network_monitor_get_default()));
  self->network_handler = g_signal_connect(
      self->monitor, "network-changed", G_CALLBACK(on_network_changed), self);
  self->cancellable = g_cancellable_new();
  g_bus_get(G_BUS_TYPE_SYSTEM, self->cancellable, on_system_bus, self);
  return self;
}

void relay_triggers_stop(RelayTriggers* self) {
  if (self == nullptr) {
    return;
  }
  g_cancellable_cancel(self->cancellable);
  g_clear_object(&self->cancellable);
  if (self->sleep_subscription != 0) {
    g_dbus_connection_signal_unsubscribe(self->system_bus,
                                         self->sleep_subscription);
  }
  g_clear_object(&self->system_bus);
  g_signal_handler_disconnect(self->monitor, self->network_handler);
  g_clear_object(&self->monitor);
  g_free(self);
}
