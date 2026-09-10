import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

class RelayStatus {
  final bool licenseRequired;

  /// Null on a relay too old to report the field, which is not the same as
  /// "no": every chip that reads these stays hidden while they are unknown.
  final String? version;
  final bool? turn;
  final bool? forwarder;

  const RelayStatus({
    this.licenseRequired = false,
    this.version,
    this.turn,
    this.forwarder,
  });

  factory RelayStatus.fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    final turn = json['turn'];
    final forwarder = json['forwarder'];
    return RelayStatus(
      licenseRequired: json['license_required'] == true,
      version: version is String && version.isNotEmpty ? version : null,
      turn: turn is bool ? turn : null,
      forwarder: forwarder is bool ? forwarder : null,
    );
  }
}

/// What the relay we are on said about itself at startup, or null before the
/// one fetch lands and on a relay that never answered.
class RelayStatusNotifier extends Notifier<RelayStatus?> {
  @override
  RelayStatus? build() => null;

  void set(RelayStatus status) => state = status;
}

final relayStatusProvider =
    NotifierProvider<RelayStatusNotifier, RelayStatus?>(
        RelayStatusNotifier.new);

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

      return RelayStatus.fromJson(jsonDecode(body) as Map<String, dynamic>);
    }()
        .timeout(const Duration(seconds: 6));
  } catch (_) {
    return const RelayStatus();
  } finally {
    client.close(force: true);
  }
}
