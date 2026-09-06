import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The fileId of the audio currently playing inline, or null.
///
/// Only one audio plays at a time. Cross-linked with
/// [currentlyPlayingVideoProvider]: starting audio stops any playing video.
final currentlyPlayingAudioProvider = StateProvider<String?>((ref) => null);
