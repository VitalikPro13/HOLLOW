import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The messageId of the video currently playing inline, or null.
///
/// Only one video plays at a time: a bubble entering the playing state sets
/// this, and the previous one watches it change and tears down its player.
final currentlyPlayingVideoProvider = StateProvider<String?>((ref) => null);
