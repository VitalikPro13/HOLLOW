import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/version_compare.dart';

/// One release block of `changelog.txt`.
class ChangelogRelease {
  /// As written in the header, without the `v`: `0.11.1`, `0.11`, `0.12.2+1`.
  final String version;
  final String title;

  /// Free paragraphs before the first section (a BREAKING CHANGE note).
  final List<String> notes;
  final List<ChangelogSection> sections;

  const ChangelogRelease({
    required this.version,
    required this.title,
    required this.notes,
    required this.sections,
  });

  /// Whether this block describes [appVersion] exactly, build included;
  /// `0.11` and `0.11.0` match, `0.12.2` and `0.12.2+1` do not.
  bool describes(String appVersion) {
    final mine = ReleaseId.parse(version);
    final theirs = ReleaseId.parse(appVersion);
    return mine != null && mine == theirs;
  }
}

/// The block for the running build [appVersion] (`0.12.2+1`): its own block,
/// else the release it patches, else -1.
int changelogIndexFor(List<ChangelogRelease> releases, String appVersion) {
  final exact = releases.indexWhere((r) => r.describes(appVersion));
  if (exact >= 0) return exact;
  final running = ReleaseId.parse(appVersion);
  if (running == null || running.build == 0) return -1;
  return releases.indexWhere((r) => r.describes(running.version));
}

class ChangelogSection {
  /// Title Case, as a section header inside a dialog is written.
  final String name;
  final List<String> items;

  const ChangelogSection({required this.name, required this.items});
}

final _header = RegExp(r'^v(\d+(?:\.\d+)*(?:\+\d+)?)\s*-\s*(.*)$');
final _section = RegExp(r'^[A-Z0-9][A-Z0-9 &/,\-]+$');

/// Parses the whole file, newest release first, as the release flow writes it:
/// `vX.Y.Z - Title`, then ALL-CAPS section lines, `- ` bullets and free
/// paragraphs.
List<ChangelogRelease> parseChangelog(String text) {
  final releases = <ChangelogRelease>[];
  String? version;
  var title = '';
  var notes = <String>[];
  var sections = <ChangelogSection>[];
  String? sectionName;
  var items = <String>[];

  void closeSection() {
    if (sectionName != null && items.isNotEmpty) {
      sections.add(ChangelogSection(name: sectionName!, items: items));
    }
    sectionName = null;
    items = [];
  }

  void closeRelease() {
    closeSection();
    if (version != null) {
      releases.add(ChangelogRelease(
          version: version, title: title, notes: notes, sections: sections));
    }
    notes = [];
    sections = [];
  }

  for (final raw in text.split('\n')) {
    final line = raw.trimRight();
    if (line.isEmpty) continue;
    final header = _header.firstMatch(line);
    if (header != null) {
      closeRelease();
      version = header.group(1);
      title = header.group(2)!.trim();
      continue;
    }
    if (version == null) continue;
    if (line.startsWith('- ')) {
      items.add(line.substring(2).trim());
    } else if (_section.hasMatch(line)) {
      closeSection();
      sectionName = _titleCase(line);
    } else if (sectionName == null) {
      notes.add(line.trim());
    } else {
      items.add(line.trim());
    }
  }
  closeRelease();
  return releases;
}

/// `SERVERS & CHANNELS` to `Servers & Channels`, `SELF-HOSTING` to
/// `Self-Hosting`.
String _titleCase(String caps) => caps
    .toLowerCase()
    .replaceAllMapped(
        RegExp(r'(^|[\s\-/])([a-z])'),
        (m) => '${m[1]}${m[2]!.toUpperCase()}'); // design-ignore: data, not a label

/// The changelog shipped inside the app. Bundled rather than fetched, so it
/// always describes the build that is running, works offline, and costs no
/// request to anyone.
final changelogProvider = FutureProvider<List<ChangelogRelease>>((ref) async {
  try {
    return parseChangelog(await rootBundle.loadString('changelog.txt'));
  } catch (_) {
    return const [];
  }
});
