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
  final n = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
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
