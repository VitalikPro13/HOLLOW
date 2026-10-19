/// Numeric dotted-version comparison for the updater.
///
/// Only a strictly newer `latest` counts as an update: a host replaying an old,
/// genuinely signed manifest must not be able to talk installs into downgrading
/// to a build with known bugs.
///
/// Returns true when [candidate] is strictly newer than [current]. Versions are
/// dot-separated integers; a missing part counts as 0, unparseable is never newer.
bool isNewerVersion(String candidate, String current) {
  final a = _parts(candidate);
  final b = _parts(current);
  if (a == null || b == null) return false;
  return _compareParts(a, b) > 0;
}

int _compareParts(List<int> a, List<int> b) {
  final n = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

List<int>? _parts(String v) {
  final trimmed = v.trim();
  if (trimmed.isEmpty) return null;
  final out = <int>[];
  for (final piece in trimmed.split('.')) {
    final n = int.tryParse(piece);
    if (n == null || n < 0) return null;
    out.add(n);
  }
  return out;
}

/// A release as the updater orders it: the three-part version, then the
/// quick-patch build on top of it (`0.12.2+1`; build 0 is the release itself).
class ReleaseId implements Comparable<ReleaseId> {
  final String version;
  final int build;
  final List<int> _numbers;

  const ReleaseId._(this.version, this.build, this._numbers);

  /// Null unless [version] is dotted integers and [build] is not negative.
  static ReleaseId? of(String version, [int build = 0]) {
    final parts = _parts(version);
    if (parts == null || build < 0) return null;
    return ReleaseId._(version.trim(), build, parts);
  }

  /// `0.12.2` or `0.12.2+1`, as a notice's `below` / `from` and a changelog
  /// header write it. Null for anything else.
  static ReleaseId? parse(String text) {
    var s = text.trim();
    if (s.startsWith('v')) s = s.substring(1);
    final plus = s.indexOf('+');
    if (plus < 0) return of(s);
    final build = int.tryParse(s.substring(plus + 1));
    if (build == null || s.substring(plus + 1).startsWith(RegExp(r'[+-]'))) {
      return null;
    }
    return of(s.substring(0, plus), build);
  }

  /// What a person reads: `0.12.2`, or `0.12.2+1` for a patch.
  String get display => build == 0 ? version : '$version+$build';

  /// What names a file on disk; never the same as the release it patches
  /// (mirrors `release_tag` in updater.rs).
  String get tag => build == 0 ? version : '$version-b$build';

  @override
  int compareTo(ReleaseId other) {
    final byVersion = _compareParts(_numbers, other._numbers);
    return byVersion != 0 ? byVersion : build.compareTo(other.build);
  }

  bool isNewerThan(ReleaseId other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is ReleaseId && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(Object.hashAll(_trimmed), build);

  List<int> get _trimmed {
    var end = _numbers.length;
    while (end > 0 && _numbers[end - 1] == 0) {
      end--;
    }
    return _numbers.sublist(0, end);
  }

  @override
  String toString() => display;
}
