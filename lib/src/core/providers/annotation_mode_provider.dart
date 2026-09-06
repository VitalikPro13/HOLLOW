import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the screen-wide annotation overlay is currently active.
///
/// While active the main window is transparent, full-screen and always-on-top
/// and the chat UI is hidden, so the user draws over their other apps.
final annotationModeProvider = StateProvider<bool>((_) => false);
