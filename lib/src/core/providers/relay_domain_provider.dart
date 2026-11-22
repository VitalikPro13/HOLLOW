import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

const kDefaultRelayDomain = 'relay.anonlisten.com';
const _kSettingKey = 'relay_domain';
const _kListKey = 'relay_domain_list';

/// A relay switch waiting for the next launch. Kept apart from
/// [_kSettingKey], which the push fetch (iOS extension, a cold Android
/// process) dials, so a fetch reaches only the relay this install runs on,
/// the one holding its push token and buffers (HOL-SEC-204).
const kNextRelaySettingKey = 'relay_domain_next';

/// Where an invite waits out the relaunch a relay switch needs.
const String kPendingInviteAfterSwitchKey = 'pending_invite_after_switch';

class RelayDomainNotifier extends Notifier<String> {
  @override
  String build() => kDefaultRelayDomain;

  /// Loads the relay this launch runs on, first taking a switch saved for it
  /// by [saveForNextLaunch]. True when it took one.
  Future<bool> loadCached() async {
    final next = (await storage_api.loadSetting(key: kNextRelaySettingKey))
        ?.trim();
    if (next != null && next.isNotEmpty) {
      await storage_api.saveSetting(key: _kSettingKey, value: next);
      await storage_api.saveSetting(key: kNextRelaySettingKey, value: '');
      state = next;
      return true;
    }
    final cached = await storage_api.loadSetting(key: _kSettingKey);
    if (cached != null && cached.isNotEmpty) {
      state = cached;
    }
    return false;
  }

  Future<void> setDomain(String domain) async {
    state = domain;
    await storage_api.saveSetting(key: _kSettingKey, value: domain);
  }

  /// Saves [domain] for the next launch while this process, and the push
  /// fetch, stay on [state]. Saving [state] takes a waiting switch back, and
  /// the invite it parked with it.
  Future<void> saveForNextLaunch(String domain) async {
    final takeBack = domain == state;
    await storage_api.saveSetting(
        key: kNextRelaySettingKey, value: takeBack ? '' : domain);
    if (takeBack) {
      await storage_api.saveSetting(
          key: kPendingInviteAfterSwitchKey, value: '');
    }
    ref.read(pendingRelayProvider.notifier)._set(takeBack ? null : domain);
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
