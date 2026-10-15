import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/overlay_runtime_provider.dart';
import 'package:hollow/src/rust/api/network.dart';

/// The five stream overlay events land in the providers wave 2 builds on.
void main() {
  late ProviderContainer c;
  setUp(() => c = ProviderContainer());
  tearDown(() => c.dispose());

  test('open streams follow the server', () {
    expect(applyOverlayEvent(c.read, const NetworkEvent.overlayStreamsChanged(open: 3)), isTrue);
    expect(c.read(overlayOpenStreamsProvider), 3);
    applyOverlayEvent(c.read, const NetworkEvent.overlayStreamsChanged(open: 0));
    expect(c.read(overlayOpenStreamsProvider), 0);
  });

  test('a moved port is kept for the warning', () {
    expect(c.read(overlayPortChangedProvider), isNull);
    applyOverlayEvent(c.read, const NetworkEvent.overlayPortChanged(port: 23456));
    expect(c.read(overlayPortChangedProvider), 23456);
  });

  test('looks, removals and fields refresh the people list', () {
    applyOverlayEvent(c.read, const NetworkEvent.overlayLookReceived(master: 'm1'));
    expect(c.read(overlayLookReceivedProvider), 'm1');
    expect(c.read(overlayPeopleRevisionProvider), 1);
    applyOverlayEvent(c.read, const NetworkEvent.overlayPersonRemoved(master: 'm1'));
    expect(c.read(overlayPeopleRevisionProvider), 2);
    applyOverlayEvent(c.read, const NetworkEvent.overlayFieldChanged(master: 'm2'));
    expect(c.read(overlayFieldRevisionProvider), 1);
    expect(c.read(overlayPeopleRevisionProvider), 3);
  });

  test('other events are not ours', () {
    expect(applyOverlayEvent(c.read, const NetworkEvent.licenseError(reason: 'x')), isFalse);
  });
}
