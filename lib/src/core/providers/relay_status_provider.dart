import 'dart:convert';
import 'dart:io';

class RelayStatus {
  final bool licenseRequired;
  const RelayStatus({this.licenseRequired = false});
}

const _kRelayStatusUrl = 'https://relay.anonlisten.com/relay-status';

Future<RelayStatus> fetchRelayStatus() async {
  try {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 5);
    final request = await client.getUrl(Uri.parse(_kRelayStatusUrl));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    client.close();

    if (response.statusCode != 200) {
      return const RelayStatus();
    }

    final json = jsonDecode(body) as Map<String, dynamic>;
    return RelayStatus(
      licenseRequired: json['license_required'] == true,
    );
  } catch (_) {
    return const RelayStatus();
  }
}
