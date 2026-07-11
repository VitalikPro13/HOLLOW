#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  // Single instance: a second launch (e.g. clicking a hollow:// link) forwards
  // its command line to this primary instance via GApplication and re-fires
  // activate — present the existing window instead of building a second one.
  // The link itself reaches Dart through app_links (command-line/open signals).
  GList* windows = gtk_application_get_windows(GTK_APPLICATION(application));
  if (windows) {
    gtk_window_present(GTK_WINDOW(windows->data));
    return;
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gtk_window_set_title(window, "hollow");
  gtk_window_set_default_size(window, 1280, 720);

  // Give the window an RGBA (alpha-capable) visual so it can render with real
  // transparency. Required for the screen-annotation overlay: in that mode
  // Flutter paints a transparent scaffold and we want the apps BEHIND Hollow
  // (slides, browser, PDF) to show through. Without an RGBA visual GTK
  // composites Flutter's transparent pixels onto an opaque (black) window, so
  // annotation mode renders solid black instead of see-through.
  //
  // The visual must be assigned BEFORE the window is realized — an X11 window's
  // visual cannot be swapped after the fact, which is why this is set here at
  // creation rather than toggled at runtime (Windows/macOS toggle transparency
  // live; on Linux the window is always RGBA and transparency is controlled
  // purely by what Flutter paints — opaque in normal use, transparent in
  // annotation mode). Guarded on a compositor being present; falls back to the
  // default visual otherwise (the window just stays opaque, as before).
  GdkScreen* screen = gtk_window_get_screen(window);
  GdkVisual* rgba_visual = gdk_screen_get_rgba_visual(screen);
  if (rgba_visual != nullptr && gdk_screen_is_composited(screen)) {
    gtk_widget_set_visual(GTK_WIDGET(window), rgba_visual);
    gtk_widget_set_app_paintable(GTK_WIDGET(window), TRUE);
  }

  // Set window icon from bundled asset.
  g_autoptr(GError) icon_error = nullptr;
  g_autofree gchar* exe_path = g_file_read_link("/proc/self/exe", nullptr);
  if (exe_path) {
    g_autofree gchar* base_dir = g_path_get_dirname(exe_path);
    g_autofree gchar* icon_path = g_build_filename(base_dir, "data", "flutter_assets", "assets", "hollow_logo_rounded.png", nullptr);
    GdkPixbuf* icon = gdk_pixbuf_new_from_file(icon_path, &icon_error);
    if (icon) {
      gtk_window_set_icon(window, icon);
      g_object_unref(icon);
    }
  }

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Fully transparent FlView background (#00000000). With the RGBA window visual
  // set above, this lets Flutter control opacity per-pixel: the opaque Hollow
  // theme paints solid pixels in normal use, and the annotation overlay's
  // transparent scaffold lets the desktop behind show through. (Was opaque
  // "#000000", which forced a black backdrop and broke annotation transparency.)
  gdk_rgba_parse(&background_color, "#00000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  // FALSE (was TRUE): let GApplication keep processing the command line so a
  // hollow:// URI argument is forwarded to the primary instance and surfaced
  // through the command-line/open signals app_links listens on. Returning TRUE
  // here would swallow the arguments and deep links would never reach Dart.
  return FALSE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);
  g_set_application_name("Hollow");

  // HANDLES_COMMAND_LINE | HANDLES_OPEN (was NON_UNIQUE): required for
  // hollow:// deep links. The app is now D-Bus-unique — a second launch hands
  // its URI to the running instance (activate presents the existing window)
  // and exits, instead of spawning a duplicate that the Dart PID lock kills
  // with the link still unread.
  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_HANDLES_COMMAND_LINE |
                                         G_APPLICATION_HANDLES_OPEN,
                                     nullptr));
}
