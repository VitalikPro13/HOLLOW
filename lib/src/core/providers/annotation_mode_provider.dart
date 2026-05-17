import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the screen-wide annotation overlay is currently active.
///
/// While active, the Hollow main window is reconfigured (transparent,
/// full-screen, always-on-top via the native side) and its chat UI is hidden
/// so the user sees their other apps (PowerPoint, browser, PDF) through it
/// and can draw on top — same paradigm as Zoom's annotation tool.
final annotationModeProvider = StateProvider<bool>((_) => false);
