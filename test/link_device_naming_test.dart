import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/device_link_sync_provider.dart';

void main() {
  test('a linking device is named by its kind, never its platform', () {
    expect(aDeviceOfKind('desktop'), 'A desktop');
    expect(aDeviceOfKind('phone'), 'A phone');
    expect(aDeviceOfKind('windows'), 'A device');
    expect(aDeviceOfKind(''), 'A device');
  });

  test('a device with no name of its own is called by its kind', () {
    expect(deviceKindName('desktop'), 'Desktop');
    expect(deviceKindName('phone'), 'Phone');
    expect(deviceKindName('DESKTOP-OL94Q8K'), isNull);
  });

  test('a link code is shown with its dash after the rendezvous part', () {
    expect(formatLinkCode('KQ5QJDBAVM'), 'KQ5QJD-BAVM');
    expect(formatLinkCode('KQ5'), 'KQ5');
  });
}
