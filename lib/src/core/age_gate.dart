import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/shop_availability.dart';
import 'package:hollow/src/rust/api/age_gate.dart' as age_api;

/// How this build treats age-restricted (18+) servers (Apple 1.2). The mode only
/// picks UI; Rust decides what is hidden and never widens on Dart's word.
enum AgeGateMode {
  /// Windows, Linux, macOS: always shown (the 18+ consent dialog is the gate), and
  /// the identity's choice for its phones is set here.
  desktop,

  /// iPhone, iPad, and Android installed from a store: hidden unless a computer of
  /// ours allowed them. No setting on the phone.
  phoneRemote,

  /// Android sideload: hidden by default, with this phone's own toggle.
  phoneLocal,
}

/// The build's [AgeGateMode], resolved once at startup like [ShopAvailability].
class AgeGate {
  AgeGate._();

  static AgeGateMode _mode = AgeGateMode.desktop;
  static bool _primed = false;

  static AgeGateMode get mode => _mode;

  /// Call once before `runApp`, after [ShopAvailability.prime].
  static Future<void> prime() async {
    if (_primed) return;
    _primed = true;
    if (kIsWeb) return;
    if (Platform.isIOS) {
      _mode = AgeGateMode.phoneRemote;
    } else if (Platform.isAndroid) {
      // The shop's verdict is the installer check: no shop = a store install.
      _mode = ShopAvailability.available
          ? AgeGateMode.phoneLocal
          : AgeGateMode.phoneRemote;
    }
  }

  @visibleForTesting
  static void debugSet(AgeGateMode mode) {
    _primed = true;
    _mode = mode;
  }
}

/// Watch this, never [AgeGate.mode], so a widget test can override it.
final ageGateModeProvider = Provider<AgeGateMode>((ref) => AgeGate.mode);

@immutable
class AgeGateState {
  /// Whether this device shows age-restricted servers. Closed on a phone until
  /// Rust says otherwise.
  final bool allowedHere;

  /// The identity's choice for its phones.
  final bool phonesAllow;

  /// This Android phone's own toggle.
  final bool localAllow;

  /// This computer already offered the choice after an 18+ join.
  final bool asked;

  /// Joined servers this device hides (age-restricted or not caught up yet).
  final Set<String> hidden;

  const AgeGateState({
    required this.allowedHere,
    this.phonesAllow = false,
    this.localAllow = false,
    this.asked = false,
    this.hidden = const {},
  });
}

class AgeGateNotifier extends Notifier<AgeGateState> {
  @override
  AgeGateState build() => AgeGateState(
      allowedHere: ref.watch(ageGateModeProvider) == AgeGateMode.desktop);

  /// Set once this process told Rust how Android was installed.
  static bool _installTold = false;

  /// Re-read the gate and the hidden set from Rust.
  Future<void> load() async {
    final mode = ref.read(ageGateModeProvider);
    try {
      // Once per start, so a later sideload gets its toggle back.
      if (!_installTold && !kIsWeb && Platform.isAndroid) {
        await age_api.setAgeGateStoreInstall(
            storeInstall: mode == AgeGateMode.phoneRemote);
        _installTold = true;
      }
      final status = await age_api.ageGateStatus();
      final hidden = mode == AgeGateMode.desktop
          ? const <String>{}
          : (await age_api.ageHiddenServers()).toSet();
      state = AgeGateState(
        allowedHere: status.allowedHere,
        phonesAllow: status.phonesAllow,
        localAllow: status.localAllow,
        asked: status.asked,
        hidden: hidden,
      );
    } catch (e) {
      debugPrint('[HOLLOW] Age gate status unavailable: $e');
    }
  }

  /// The desktop setting: the identity's choice for every phone of ours.
  Future<void> setForPhones(bool allow) async {
    await age_api.setAgeGateForPhones(allow: allow);
    await load();
  }

  /// The sideloaded Android toggle.
  Future<void> setOnThisPhone(bool allow) async {
    await age_api.setAgeGateOnThisPhone(allow: allow);
    await load();
  }

  Future<void> markAsked() async {
    await age_api.markAgeGateAsked();
    await load();
  }

  /// Whether `serverId` is kept off this device by the hidden set Rust last gave.
  /// Before the first load the set is empty; Rust's own filter on the server list
  /// keeps a hidden server off it meanwhile.
  bool hides(String serverId) => state.hidden.contains(serverId);
}

final ageGateProvider =
    NotifierProvider<AgeGateNotifier, AgeGateState>(AgeGateNotifier.new);

/// Whether a server is kept off this device: read this at every surface that
/// opens, names, counts or notifies for a server outside the server list.
final serverAgeHiddenProvider = Provider.family<bool, String>(
    (ref, serverId) => ref.watch(ageGateProvider).hidden.contains(serverId));

/// Stands in for the Rust verdict off a phone.
@visibleForTesting
Future<bool> Function(String serverId)? debugServerAgeHiddenNow;

/// The Rust verdict for one server, for code with no provider container (a push
/// isolate, a tap router before the app is up). Fails closed on a phone.
Future<bool> serverAgeHiddenNow(String serverId) async {
  final seam = debugServerAgeHiddenNow;
  if (seam != null) return seam(serverId);
  if (kIsWeb || (!Platform.isIOS && !Platform.isAndroid)) return false;
  try {
    return await age_api.serverAgeHidden(serverId: serverId) ?? true;
  } catch (_) {
    return true;
  }
}
