import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/app_lifecycle_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/relay_denial_provider.dart';
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

  /// A phone back from away (or just started) whose gate is open: until the relay
  /// handed over what our computers said meanwhile, flagged servers stay off the
  /// list, so a choice made while away never shows them for a moment. Ends on
  /// `AgeGateChanged`, a refused login, a relay settled offline, or
  /// [AgeGateNotifier.holdCap] on screen.
  final bool held;

  const AgeGateState({
    required this.allowedHere,
    this.phonesAllow = false,
    this.localAllow = false,
    this.asked = false,
    this.hidden = const {},
    this.held = false,
  });

  /// Whether a server flagged [isNsfw] may be listed now.
  bool lists(String serverId, {required bool isNsfw}) =>
      (allowedHere && !held) || (!isNsfw && !hidden.contains(serverId));

  AgeGateState withHeld(bool held) => AgeGateState(
        allowedHere: allowedHere,
        phonesAllow: phonesAllow,
        localAllow: localAllow,
        asked: asked,
        hidden: hidden,
        held: held,
      );
}

class AgeGateNotifier extends Notifier<AgeGateState> {
  @override
  AgeGateState build() {
    final desktop = ref.watch(ageGateModeProvider) == AgeGateMode.desktop;
    ref.onDispose(_stopCap);
    if (!desktop) _listenForTheEnd();
    final initial = AgeGateState(allowedHere: desktop, held: !desktop);
    if (initial.held && _onScreen) _startCap();
    return initial;
  }

  /// Rust ends the hold (`AgeGateChanged`) once the relay delivered what it kept
  /// for us; this is for a relay that never does.
  static const holdCap = Duration(seconds: 10);

  Timer? _cap;

  bool get _onScreen {
    final life = ref.read(appLifecycleProvider);
    return life == AppLifecycleState.resumed ||
        life == AppLifecycleState.inactive;
  }

  /// The cap counts only time on screen: the relay replays nothing to a phone
  /// that is away, so a cap running then would end the hold before the replay.
  void _listenForTheEnd() {
    ref.listen(appLifecycleProvider, (_, life) {
      if (life == AppLifecycleState.paused) {
        hold();
      } else if (life == AppLifecycleState.resumed) {
        if (state.held) _startCap();
      } else if (life.isBackground && life != AppLifecycleState.inactive) {
        _stopCap();
      }
    });
    // Nothing more can arrive from a relay that refuses us or that is gone.
    ref.listen(relayLoginDenialProvider, (_, denial) {
      if (denial != null && _onScreen) release();
    });
    ref.listen(
        connectionStatusProvider.select((s) => s.relayStatus), (_, status) {
      if (status == RelayConnectionStatus.disconnected && _onScreen) release();
    });
  }

  void _startCap() {
    _cap ??= Timer(holdCap, release);
  }

  void _stopCap() {
    _cap?.cancel();
    _cap = null;
  }

  /// A phone that can be closed by our computers goes away: hold flagged servers
  /// back until Rust says the relay delivered what they said meanwhile.
  void hold() {
    if (ref.read(ageGateModeProvider) == AgeGateMode.desktop) return;
    _stopCap();
    if (_ownToggleOpen(state)) return;
    state = state.withHeld(true);
  }

  void release() {
    _stopCap();
    if (state.held) state = state.withHeld(false);
  }

  /// A sideloaded phone's own toggle opens it whatever our computers say, so
  /// nothing they send can close it and there is nothing to hold for.
  bool _ownToggleOpen(AgeGateState s) =>
      ref.read(ageGateModeProvider) == AgeGateMode.phoneLocal && s.localAllow;

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
      final next = AgeGateState(
        allowedHere: status.allowedHere,
        phonesAllow: status.phonesAllow,
        localAllow: status.localAllow,
        asked: status.asked,
        hidden: hidden,
        held: state.held,
      );
      if (next.held && _ownToggleOpen(next)) {
        _stopCap();
        state = next.withHeld(false);
      } else {
        state = next;
      }
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
