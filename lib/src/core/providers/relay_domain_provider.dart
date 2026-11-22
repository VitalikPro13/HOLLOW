import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

const kDefaultRelayDomain = 'relay.anonlisten.com';
const _kSettingKey = 'relay_domain';
const _kListKey = 'relay_domain_list';

class RelayDomainNotifier extends Notifier<String> {
  @override
  String build() => kDefaultRelayDomain;

  Future<void> loadCached() async {
    final cached = await storage_api.loadSetting(key: _kSettingKey);
    if (cached != null && cached.isNotEmpty) {
      state = cached;
    }
  }

  Future<void> setDomain(String domain) async {
    state = domain;
    await storage_api.saveSetting(key: _kSettingKey, value: domain);
  }

  /// Saves [domain] for the next launch while this process stays on [state]
  /// (iOS cannot end the app for a switch). Saving [state] again takes a
  /// waiting switch back.
  Future<void> saveForNextLaunch(String domain) async {
    await storage_api.saveSetting(key: _kSettingKey, value: domain);
    ref
        .read(pendingRelayProvider.notifier)
        ._set(domain == state ? null : domain);
  }
}

final relayDomainProvider =
    NotifierProvider<RelayDomainNotifier, String>(RelayDomainNotifier.new);

class SavedRelayListNotifier extends Notifier<List<String>> {
  @override
  List<String> build() => [kDefaultRelayDomain];

  Future<void> loadCached() async {
    final raw = await storage_api.loadSetting(key: _kListKey);
    if (raw != null && raw.isNotEmpty) {
      final domains = raw.split(',').where((d) => d.isNotEmpty).toList();
      if (!domains.contains(kDefaultRelayDomain)) {
        domains.insert(0, kDefaultRelayDomain);
      }
      state = domains;
    }
  }

  Future<void> addRelay(String domain) async {
    if (state.contains(domain)) return;
    state = [...state, domain];
    await _persist();
  }

  Future<void> removeRelay(String domain) async {
    if (domain == kDefaultRelayDomain) return;
    state = state.where((d) => d != domain).toList();
    await _persist();
  }

  Future<void> _persist() async {
    await storage_api.saveSetting(key: _kListKey, value: state.join(','));
  }
}

final savedRelayListProvider =
    NotifierProvider<SavedRelayListNotifier, List<String>>(SavedRelayListNotifier.new);

/// The relay the next launch connects to when it is not the one this process
/// runs on; null when no switch waits.
class PendingRelayNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void _set(String? domain) => state = domain;
}

final pendingRelayProvider =
    NotifierProvider<PendingRelayNotifier, String?>(PendingRelayNotifier.new);
