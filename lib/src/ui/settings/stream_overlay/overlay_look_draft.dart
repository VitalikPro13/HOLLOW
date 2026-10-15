import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hollow/src/core/models/overlay_look.dart';

/// The look being edited, ahead of its save. OWN mode edits our whole look; LOCAL
/// mode edits our picks for one person, where an empty state or an unset
/// effect means "not overridden" and their own look shows through.
class OverlayLookDraft extends ChangeNotifier {
  OverlayLookDraft.own(OverlayLook saved)
      : local = false,
        theirs = null,
        _baseEffects = OverlayEffects.defaults,
        _saved = _ownShape(saved),
        _draft = _ownShape(saved);

  /// [theirs] is the look they shared with us, if we hold one; [avatarEffects]
  /// are the layout's effects for a person drawn with a plain avatar.
  OverlayLookDraft.local({
    required OverlayLook? saved,
    required this.theirs,
    required OverlayEffects avatarEffects,
  })  : local = true,
        _baseEffects = theirs == null
            ? avatarEffects.filled()
            : theirs.effects.filled(),
        _saved = saved ?? OverlayLook.empty(),
        _draft = saved ?? OverlayLook.empty();

  final bool local;
  final OverlayLook? theirs;
  final OverlayEffects _baseEffects;
  OverlayLook _saved;
  OverlayLook _draft;

  /// Images picked in this editor, by hash, with the file they came from: an
  /// unsaved image may be swept before its save and is then processed again.
  final Map<String, String> pickedPaths = {};

  static OverlayLook _ownShape(OverlayLook l) =>
      l.copyWith(effects: l.effects.filled());

  OverlayLook get draft => _draft;
  OverlayLook get saved => _saved;

  bool get dirty =>
      !mapEquals(_draft.states, _saved.states) ||
      _draft.effects != _saved.effects;

  /// What the preview draws: in LOCAL mode their look with our picks laid
  /// over it. Display only; the saved effective look is Rust's.
  OverlayLook get shown {
    if (!local) return _draft;
    return OverlayLook(
      states: {
        for (final s in OverlayLookState.values)
          s: _draft.hashOf(s).isNotEmpty
              ? _draft.hashOf(s)
              : (theirs?.hashOf(s) ?? ''),
      },
      effects: _draft.effects.filled(_baseEffects),
    );
  }

  /// The effects as the editor's controls show them.
  OverlayEffects get effects => shown.effects;

  /// Whether we chose [state]'s image here (LOCAL), or it has one (OWN).
  bool hasOwnImage(OverlayLookState state) => _draft.hashOf(state).isNotEmpty;

  /// LOCAL: whether we set the effect with this manifest key.
  bool overrides(String key) => _draft.effects.toMap().containsKey(key);

  void setImage(OverlayLookState state, String hash, {String? path}) {
    if (path != null && hash.isNotEmpty) pickedPaths[hash] = path;
    _set(_draft.withState(state, hash));
  }

  void clearImage(OverlayLookState state) => _set(_draft.withState(state, ''));

  void setEffects(OverlayEffects Function(OverlayEffects current) change) =>
      _set(_draft.copyWith(effects: change(_draft.effects)));

  /// LOCAL: back to "not overridden" for one effect.
  void resetEffect(String key) =>
      _set(_draft.copyWith(effects: _draft.effects.without([key])));

  /// LOCAL: every pick dropped, their look as it is.
  void resetAll() => _set(OverlayLook.empty());

  /// Saved: the canonical look Rust returned for [sent] becomes the baseline.
  /// An edit made while the save ran stays in the draft, still unsaved.
  void markSaved(OverlayLook canonical, {required OverlayLook sent}) {
    _saved = local ? canonical : _ownShape(canonical);
    if (_draft == sent) _draft = _saved;
    notifyListeners();
  }

  /// A newer saved look arrived from elsewhere (a sibling device). Taken only
  /// while nothing here is unsaved, so an edit in progress is never lost.
  void adopt(OverlayLook incoming) {
    final next = local ? incoming : _ownShape(incoming);
    if (dirty || next == _saved) return;
    _saved = next;
    _draft = next;
    notifyListeners();
  }

  void _set(OverlayLook next) {
    if (next == _draft) return;
    _draft = next;
    notifyListeners();
  }
}

/// Saves a draft shortly after each finished edit, one save at a time, so a
/// burst of edits costs one save (each own-look save is a signed announce).
class OverlayLookAutosave {
  OverlayLookAutosave({
    required this.draft,
    required this.save,
    this.onError,
    this.delay = const Duration(milliseconds: 300),
  });

  final OverlayLookDraft draft;

  /// Stores a look and returns it as stored.
  final Future<OverlayLook> Function(OverlayLook look) save;
  final void Function(Object error)? onError;
  final Duration delay;

  Timer? _timer;
  Future<void>? _running;
  OverlayLook? _inFlight;
  bool _closed = false;

  /// An edit is finished (a pick, a choice, a slider let go): save soon.
  void commit() {
    if (_closed) return;
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(flush()));
  }

  /// Saves now if anything is unsaved, after any save already running.
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    while (_running != null) {
      await _running;
    }
    if (_closed || !draft.dirty) return;
    final sent = draft.draft;
    final run = _store(sent, report: true);
    _running = run;
    try {
      await run;
    } finally {
      _running = null;
    }
  }

  Future<void> _store(OverlayLook sent, {required bool report}) async {
    _inFlight = sent;
    try {
      final stored = await save(sent);
      if (!_closed) draft.markSaved(stored, sent: sent);
    } catch (e) {
      if (report && !_closed) onError?.call(e);
    } finally {
      _inFlight = null;
    }
  }

  /// The editor is going away: whatever is unsaved is still saved, and the
  /// draft is never touched again, so its owner may dispose it at once.
  void close() {
    if (_closed) return;
    _timer?.cancel();
    _timer = null;
    final last = draft.dirty ? draft.draft : null;
    _closed = true;
    // A save of exactly this look already running finishes on its own.
    if (last == null || _inFlight == last) return;
    final before = _running;
    Future<void> after() async {
      if (before != null) await before;
      await _store(last, report: false);
    }

    unawaited(after());
  }
}
