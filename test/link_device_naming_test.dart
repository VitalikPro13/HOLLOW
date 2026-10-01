import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/device_link_sync_provider.dart';

void main() {
  test('a label-less device is named with the right article', () {
    expect(aDeviceOn('ios'), 'An iOS device');
    expect(aDeviceOn('android'), 'An Android device');
    expect(aDeviceOn('windows'), 'A Windows device');
    expect(aDeviceOn('macos'), 'A macOS device');
    expect(aDeviceOn('linux'), 'A Linux device');
    expect(aDeviceOn(''), 'A device');
  });

  test('a link code is shown with its dash after the rendezvous part', () {
    expect(formatLinkCode('KQ5QJDBAVM'), 'KQ5QJD-BAVM');
    expect(formatLinkCode('KQ5'), 'KQ5');
  });
}
