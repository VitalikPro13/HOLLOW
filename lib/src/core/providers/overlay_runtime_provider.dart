import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/network.dart';

/// Whether the loopback overlay server for OBS is running on this computer.
/// Listening outside a call needs it; turning it off stops the listening.
/// Written only by `overlayServerProvider`, from each status the server returns.
final overlayServerRunningProvider = StateProvider<bool>((ref) => false);

/// How many OBS pages hold a live event stream open right now. Above zero the
/// call level polls speed up so the page's bounce follows the voice closely.
final overlayOpenStreamsProvider = StateProvider<int>((ref) => 0);

/// The port the overlay moved to because its saved one was busy, this session;
/// null while it never moved. Every OBS link changed with it.
final overlayPortChangedProvider = StateProvider<int?>((ref) => null);

/// Bumped whenever the people list may read differently (a look arrived, a
/// person left the overlay, a field changed); readers of `overlayPeople()`
/// watch it.
final overlayPeopleRevisionProvider = StateProvider<int>((ref) => 0);

/// Bumped when someone's stream overlay field changed; whatever shows
/// `overlayFieldOf(master)` watches it.
final overlayFieldRevisionProvider = StateProvider<int>((ref) => 0);

/// The master whose look arrived last (theirs, or ours from a sibling).
final overlayLookReceivedProvider = StateProvider<String?>((ref) => null);

/// Applies one stream overlay event; false for any other event. [read] is a
/// `ref.read` or `container.read`.
bool applyOverlayEvent(
    T Function<T>(ProviderListenable<T> provider) read, NetworkEvent event) {
  switch (event) {
    case NetworkEvent_OverlayLookReceived(:final master):
      read(overlayLookReceivedProvider.notifier).state = master;
      read(overlayPeopleRevisionProvider.notifier).state++;
    case NetworkEvent_OverlayPersonRemoved():
      read(overlayPeopleRevisionProvider.notifier).state++;
    case NetworkEvent_OverlayFieldChanged():
      read(overlayFieldRevisionProvider.notifier).state++;
      read(overlayPeopleRevisionProvider.notifier).state++;
    case NetworkEvent_OverlayPortChanged(:final port):
      read(overlayPortChangedProvider.notifier).state = port;
    case NetworkEvent_OverlayStreamsChanged(:final open):
      read(overlayOpenStreamsProvider.notifier).state = open;
    default:
      return false;
  }
  return true;
}
