import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the right-side Help (resource center) panel is visible.
/// Toggled by the `?` button in the friends bar. Defaults to closed.
final helpPanelOpenProvider = StateProvider<bool>((ref) => false);
