import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable, mapEquals;
import 'package:hollow/src/rust/api/overlay.dart' show OverlayPersonFfi;

/// The look manifest and the OBS layout of the stream overlay (#97, plan 16.2
/// and 16.4). Rust is the authoritative parser: these classes read what Rust
/// returns and write what the editor changed, and Rust normalises it again.

/// One image slot of a look. Named apart from Flutter's `OverlayState`, which
/// every widget file imports.
enum OverlayLookState { idle, talking, muted, deafened, blink, loud }

const _talkingChoices = ['none', 'bounce', 'shake', 'pop', 'glow'];
const _idleChoices = ['none', 'dim', 'grayscale'];
const _transitionChoices = ['instant', 'crossfade'];
const _shadowChoices = ['none', 'soft', 'outline'];

final _hashShape = RegExp(r'^[0-9a-f]{64}$');

String _choice(Object? raw, List<String> allowed, String fallback) =>
    raw is String && allowed.contains(raw) ? raw : fallback;

int _whole(Object? raw, int lo, int hi, int fallback) {
  if (raw is! num || !raw.isFinite) return fallback;
  return raw.round().clamp(lo, hi);
}

double _fraction(Object? raw, double lo, double hi, double fallback) {
  final v = raw is num && raw.isFinite ? raw.toDouble() : fallback;
  return (v.clamp(lo, hi) * 100).roundToDouble() / 100;
}

bool _flag(Object? raw, bool fallback) => raw is bool ? raw : fallback;

/// A look's effects. In a LOCAL look (a streamer's picks for one person) a
/// null field means "not overridden"; a shared or effective look from Rust
/// carries every field.
@immutable
class OverlayEffects {
  final String? talking;
  final bool? scaleWithVoice;
  final String? idle;
  final String? transition;
  final int? holdMs;
  final int? blinkEverySec;
  final double? loudThreshold;
  final bool? mirror;
  final String? shadow;

  const OverlayEffects({
    this.talking,
    this.scaleWithVoice,
    this.idle,
    this.transition,
    this.holdMs,
    this.blinkEverySec,
    this.loudThreshold,
    this.mirror,
    this.shadow,
  });

  static const talkingChoices = _talkingChoices;
  static const idleChoices = _idleChoices;
  static const transitionChoices = _transitionChoices;
  static const shadowChoices = _shadowChoices;

  static const int holdMsMin = 0;
  static const int holdMsMax = 600;
  static const int blinkEverySecMin = 2;
  static const int blinkEverySecMax = 12;
  static const double loudThresholdMin = 0.50;
  static const double loudThresholdMax = 0.95;

  /// The manifest's own defaults, as `overlay_look::normalize` fills them.
  static const defaults = OverlayEffects(
    talking: 'bounce',
    scaleWithVoice: true,
    idle: 'none',
    transition: 'crossfade',
    holdMs: 250,
    blinkEverySec: 5,
    loudThreshold: 0.75,
    mirror: false,
    shadow: 'none',
  );

  /// Nothing overridden.
  static const none = OverlayEffects();

  /// Reads an effects object. A present key with a bad value takes the
  /// default and numbers are clamped, as Rust does; an absent key stays null.
  factory OverlayEffects.fromMap(Map<String, dynamic>? m) {
    if (m == null) return none;
    const d = defaults;
    T? has<T>(String key, T Function(Object?) read) =>
        m.containsKey(key) ? read(m[key]) : null;
    return OverlayEffects(
      talking: has('talking', (v) => _choice(v, _talkingChoices, d.talking!)),
      scaleWithVoice:
          has('scale_with_voice', (v) => _flag(v, d.scaleWithVoice!)),
      idle: has('idle', (v) => _choice(v, _idleChoices, d.idle!)),
      transition: has(
          'transition', (v) => _choice(v, _transitionChoices, d.transition!)),
      holdMs: has('hold_ms', (v) => _whole(v, holdMsMin, holdMsMax, d.holdMs!)),
      blinkEverySec: has('blink_every_s',
          (v) => _whole(v, blinkEverySecMin, blinkEverySecMax, d.blinkEverySec!)),
      loudThreshold: has(
          'loud_threshold',
          (v) => _fraction(
              v, loudThresholdMin, loudThresholdMax, d.loudThreshold!)),
      mirror: has('mirror', (v) => _flag(v, d.mirror!)),
      shadow: has('shadow', (v) => _choice(v, _shadowChoices, d.shadow!)),
    );
  }

  /// Only the fields that are set, in the manifest's key order.
  Map<String, dynamic> toMap() => {
        'talking': ?talking,
        'scale_with_voice': ?scaleWithVoice,
        'idle': ?idle,
        'transition': ?transition,
        'hold_ms': ?holdMs,
        'blink_every_s': ?blinkEverySec,
        'loud_threshold': ?loudThreshold,
        'mirror': ?mirror,
        'shadow': ?shadow,
      };

  bool get isEmpty => toMap().isEmpty;

  /// Every null field taken from [base] (the manifest defaults unless given).
  OverlayEffects filled([OverlayEffects base = defaults]) => OverlayEffects(
        talking: talking ?? base.talking,
        scaleWithVoice: scaleWithVoice ?? base.scaleWithVoice,
        idle: idle ?? base.idle,
        transition: transition ?? base.transition,
        holdMs: holdMs ?? base.holdMs,
        blinkEverySec: blinkEverySec ?? base.blinkEverySec,
        loudThreshold: loudThreshold ?? base.loudThreshold,
        mirror: mirror ?? base.mirror,
        shadow: shadow ?? base.shadow,
      );

  /// Sets fields; to clear one (back to "not overridden") use [without].
  OverlayEffects copyWith({
    String? talking,
    bool? scaleWithVoice,
    String? idle,
    String? transition,
    int? holdMs,
    int? blinkEverySec,
    double? loudThreshold,
    bool? mirror,
    String? shadow,
  }) =>
      OverlayEffects.fromMap({
        ...toMap(),
        'talking': ?talking,
        'scale_with_voice': ?scaleWithVoice,
        'idle': ?idle,
        'transition': ?transition,
        'hold_ms': ?holdMs,
        'blink_every_s': ?blinkEverySec,
        'loud_threshold': ?loudThreshold,
        'mirror': ?mirror,
        'shadow': ?shadow,
      });

  /// The same effects with the given manifest keys (`hold_ms`, `talking`...)
  /// unset.
  OverlayEffects without(Iterable<String> keys) {
    final m = toMap();
    for (final k in keys) {
      m.remove(k);
    }
    return OverlayEffects.fromMap(m);
  }

  @override
  bool operator ==(Object other) =>
      other is OverlayEffects && mapEquals(other.toMap(), toMap());

  @override
  int get hashCode => Object.hashAll(
      toMap().entries.map((e) => Object.hash(e.key, e.value)));
}

/// One image per state (a 64-hex rail hash, or "" for none) plus effects.
@immutable
class OverlayLook {
  /// Every state is present; "" = no image (or "not overridden" in a local
  /// look).
  final Map<OverlayLookState, String> states;
  final OverlayEffects effects;

  /// When the look last changed (ms); Rust bumps it on save.
  final int stamp;

  OverlayLook({
    Map<OverlayLookState, String> states = const {},
    this.effects = OverlayEffects.none,
    this.stamp = 0,
  }) : states = Map.unmodifiable({
          for (final s in OverlayLookState.values) s: states[s] ?? '',
        });

  /// Parses a look as Rust spells it. Throws [FormatException] on anything
  /// that is not an object, or on a state that is not empty or 64 lowercase
  /// hex (Rust refuses those too). Absent effect keys stay absent.
  factory OverlayLook.fromJson(String json) {
    final root = jsonDecode(json);
    if (root is! Map<String, dynamic>) {
      throw const FormatException('The look is not an object');
    }
    return OverlayLook.fromMap(root);
  }

  factory OverlayLook.fromMap(Map<String, dynamic> root) {
    final rawStates = root['states'];
    if (rawStates != null && rawStates is! Map) {
      throw const FormatException("The look's states are not an object");
    }
    final states = <OverlayLookState, String>{};
    for (final s in OverlayLookState.values) {
      final raw = (rawStates as Map?)?[s.name];
      if (raw == null) continue;
      if (raw is! String || !(raw.isEmpty || _hashShape.hasMatch(raw))) {
        throw FormatException('The ${s.name} image is not a hash');
      }
      states[s] = raw;
    }
    final rawEffects = root['effects'];
    final stamp = root['stamp'];
    return OverlayLook(
      states: states,
      effects: OverlayEffects.fromMap(rawEffects is Map
          ? Map<String, dynamic>.from(rawEffects)
          : null),
      stamp: stamp is num && stamp.isFinite && stamp > 0 ? stamp.toInt() : 0,
    );
  }

  /// A look with no images and nothing overridden.
  static OverlayLook empty() => OverlayLook();

  /// No image in any state and no effect set.
  bool get isEmpty => states.values.every((h) => h.isEmpty) && effects.isEmpty;

  String hashOf(OverlayLookState s) => states[s] ?? '';

  /// The image hashes the look names, each once.
  List<String> get hashes {
    final out = <String>[];
    for (final h in states.values) {
      if (h.isNotEmpty && !out.contains(h)) out.add(h);
    }
    return out;
  }

  Map<String, dynamic> toMap() => {
        'v': 1,
        'stamp': stamp,
        'states': {for (final s in OverlayLookState.values) s.name: hashOf(s)},
        'effects': effects.toMap(),
      };

  String toJson() => jsonEncode(toMap());

  OverlayLook copyWith({
    Map<OverlayLookState, String>? states,
    OverlayEffects? effects,
    int? stamp,
  }) =>
      OverlayLook(
        states: states ?? this.states,
        effects: effects ?? this.effects,
        stamp: stamp ?? this.stamp,
      );

  /// One state's image set ("" clears it).
  OverlayLook withState(OverlayLookState s, String hash) =>
      copyWith(states: {...states, s: hash});

  @override
  bool operator ==(Object other) =>
      other is OverlayLook &&
      other.stamp == stamp &&
      other.effects == effects &&
      mapEquals(other.states, states);

  @override
  int get hashCode => Object.hash(
      stamp, effects, Object.hashAll(OverlayLookState.values.map(hashOf)));
}

/// How the OBS page lays people out (plan 16.4). Kept on this computer.
@immutable
class OverlayLayout {
  final String direction;
  final String align;
  final int size;
  final int gap;
  final String names;
  final bool onlyTalking;
  final bool onlyAdded;

  /// Ourselves while not in a call and not listening: `idle` or `hidden`.
  final String selfWhenInactive;

  /// Effects for people shown with a plain avatar; every field set.
  final OverlayEffects defaults;

  static const directionChoices = ['row', 'column', 'grid'];
  static const alignChoices = ['start', 'center', 'end'];
  static const namesChoices = ['none', 'plain', 'pill'];
  static const selfWhenInactiveChoices = ['idle', 'hidden'];
  static const int sizeMin = 48;
  static const int sizeMax = 512;
  static const int gapMin = 0;
  static const int gapMax = 64;

  /// Plain avatars bounce when they talk and sit dimmed otherwise.
  static final OverlayEffects defaultAvatarEffects =
      OverlayEffects.defaults.copyWith(idle: 'dim');

  OverlayLayout({
    this.direction = 'row',
    this.align = 'center',
    this.size = 160,
    this.gap = 12,
    this.names = 'pill',
    this.onlyTalking = false,
    this.onlyAdded = false,
    this.selfWhenInactive = 'idle',
    OverlayEffects? defaults,
  }) : defaults = (defaults ?? defaultAvatarEffects).filled();

  /// Reads a saved or hand-made layout: bad choices take the default and
  /// numbers are clamped, like Rust's projection.
  factory OverlayLayout.fromJson(Map<String, dynamic> m) {
    final d = OverlayLayout();
    final rawDefaults = m['defaults'];
    return OverlayLayout(
      direction: _choice(m['direction'], directionChoices, d.direction),
      align: _choice(m['align'], alignChoices, d.align),
      size: _whole(m['size'], sizeMin, sizeMax, d.size),
      gap: _whole(m['gap'], gapMin, gapMax, d.gap),
      names: _choice(m['names'], namesChoices, d.names),
      onlyTalking: _flag(m['only_talking'], d.onlyTalking),
      onlyAdded: _flag(m['only_added'], d.onlyAdded),
      selfWhenInactive: _choice(
          m['self_when_inactive'], selfWhenInactiveChoices, d.selfWhenInactive),
      defaults: rawDefaults is Map
          ? OverlayEffects.fromMap(Map<String, dynamic>.from(rawDefaults))
              .filled(d.defaults)
          : d.defaults,
    );
  }

  /// [OverlayLayout.fromJson] over a JSON string; anything unreadable gives the
  /// default layout.
  factory OverlayLayout.decode(String? json) {
    if (json == null || json.isEmpty) return OverlayLayout();
    try {
      final m = jsonDecode(json);
      if (m is Map<String, dynamic>) return OverlayLayout.fromJson(m);
    } catch (_) {}
    return OverlayLayout();
  }

  Map<String, dynamic> toJson() => {
        'direction': direction,
        'align': align,
        'size': size,
        'gap': gap,
        'names': names,
        'only_talking': onlyTalking,
        'only_added': onlyAdded,
        'self_when_inactive': selfWhenInactive,
        'defaults': defaults.toMap(),
      };

  String encode() => jsonEncode(toJson());

  OverlayLayout copyWith({
    String? direction,
    String? align,
    int? size,
    int? gap,
    String? names,
    bool? onlyTalking,
    bool? onlyAdded,
    String? selfWhenInactive,
    OverlayEffects? defaults,
  }) =>
      OverlayLayout.fromJson({
        ...toJson(),
        'direction': ?direction,
        'align': ?align,
        'size': ?size,
        'gap': ?gap,
        'names': ?names,
        'only_talking': ?onlyTalking,
        'only_added': ?onlyAdded,
        'self_when_inactive': ?selfWhenInactive,
        if (defaults != null) 'defaults': defaults.toMap(),
      });

  @override
  bool operator ==(Object other) =>
      other is OverlayLayout && other.encode() == encode();

  @override
  int get hashCode => encode().hashCode;
}

/// Where a person's look comes from: their shared images, our own picks for
/// them, or nothing but their avatar.
enum OverlayLookSource { theirs, mine, avatar }

/// Someone on our overlay, as Rust keeps them (by MASTER id).
@immutable
class OverlayPerson {
  final String master;

  /// Stable from 1; their OBS link is `person_base + slot`.
  final int slot;

  /// Their signed field: "off" | "show" | "share".
  final String field;

  /// The look they shared with us, when we hold one.
  final OverlayLook? theirs;

  /// Our own picks for them; null fields and empty states are not overridden.
  final OverlayLook? local;

  /// What they are drawn with: [theirs] with [local] laid over it (Rust's).
  final OverlayLook effective;

  /// [effective] exactly as Rust spelled it, for the snapshot.
  final String effectiveJson;

  const OverlayPerson({
    required this.master,
    required this.slot,
    required this.field,
    required this.theirs,
    required this.local,
    required this.effective,
    required this.effectiveJson,
  });

  factory OverlayPerson.fromFfi(OverlayPersonFfi p) => OverlayPerson(
        master: p.master,
        slot: p.slot.toInt(),
        field: p.field,
        theirs: _tryLook(p.theirLookJson),
        local: _tryLook(p.localLookJson),
        effective: _tryLook(p.effectiveLookJson) ??
            OverlayLook(effects: OverlayEffects.defaults),
        effectiveJson: p.effectiveLookJson,
      );

  /// We picked an image or an effect for them on this computer.
  bool get hasOwnPicks => local != null && !local!.isEmpty;

  /// What their row's source chip says.
  OverlayLookSource get source => hasOwnPicks
      ? OverlayLookSource.mine
      : theirs != null
          ? OverlayLookSource.theirs
          : OverlayLookSource.avatar;

  @override
  bool operator ==(Object other) =>
      other is OverlayPerson &&
      other.master == master &&
      other.slot == slot &&
      other.field == field &&
      other.theirs == theirs &&
      other.local == local &&
      other.effectiveJson == effectiveJson;

  @override
  int get hashCode =>
      Object.hash(master, slot, field, theirs, local, effectiveJson);
}

OverlayLook? _tryLook(String? json) {
  if (json == null || json.isEmpty) return null;
  try {
    return OverlayLook.fromJson(json);
  } on FormatException {
    return null;
  }
}
