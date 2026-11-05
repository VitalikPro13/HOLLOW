/// Where a service's Windows share voice redirect stands. A voice that
/// arrives while the redirect arms is held and sent once the child is up,
/// else it would play from hollow.exe into the shared screen for the whole
/// share.
class VoiceRedirectArm<T> {
  int _generation = 0;
  bool _arming = false;
  bool _redirecting = false;
  List<T> _held = [];

  bool get redirecting => _redirecting;

  /// Starts an arm and returns its token for [finish].
  int begin() {
    _generation++;
    _arming = true;
    _redirecting = false;
    _held = [];
    return _generation;
  }

  /// Whether [voice] goes to the redirect now; while arming it is held.
  bool admit(T voice) {
    if (_redirecting) return true;
    if (_arming) _held.add(voice);
    return false;
  }

  /// Ends the arm [token] began. Returns the voices held meanwhile when it
  /// armed, an empty list when it did not, and null when a [reset] since
  /// made this arm stale (its call or share is gone).
  List<T>? finish(int token, {required bool armed}) {
    if (token != _generation) return null;
    _arming = false;
    _redirecting = armed;
    final held = _held;
    _held = [];
    return armed ? held : const [];
  }

  void reset() {
    _generation++;
    _arming = false;
    _redirecting = false;
    _held = [];
  }
}
