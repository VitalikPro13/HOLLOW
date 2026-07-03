import 'dart:convert';
import 'dart:io';

class RelayStatus {
  final bool licenseRequired;
  const RelayStatus({this.licenseRequired = false});
}

Future<RelayStatus> fetchRelayStatus({required String domain}) async {
  final client = HttpClient();
  try {
    final url = 'https://$domain/relay-status';
    client.connectionTimeout = const Duration(seconds: 5);
    // TOTAL deadline, not just connect: `connectionTimeout` alone let a
    // connected-but-stalled response body block node start indefinitely.
    return await () async {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200) {
        return const RelayStatus();
      }

      final json = jsonDecode(body) as Map<String, dynamic>;
      return RelayStatus(
        licenseRequired: json['license_required'] == true,
      );
    }()
        .timeout(const Duration(seconds: 6));
  } catch (_) {
    return const RelayStatus();
  } finally {
    client.close(force: true);
  }
}
