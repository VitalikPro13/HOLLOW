/// Data models for the Hollow Help center, shaped
/// Manifest → Module → Lesson → Section.
///
/// Content ships bundled in `assets/help/manifest.json` and is loaded locally,
/// never over the network.
library;

/// One section of a lesson: an optional inline image and a markdown block.
class GuidesSection {
  /// Asset path for a small inline image; null for a text-only section.
  final String? media;

  final String text;

  const GuidesSection({this.media, required this.text});

  factory GuidesSection.fromJson(Map<String, dynamic> json) => GuidesSection(
        media: json['media'] as String?,
        text: json['text'] as String? ?? '',
      );
}

/// A single lesson: a titled page of stacked sections.
class GuidesLesson {
  /// Stable id, e.g. "1.1", used by search and deep links.
  final String id;
  final String title;
  final List<GuidesSection> sections;

  const GuidesLesson({
    required this.id,
    required this.title,
    required this.sections,
  });

  factory GuidesLesson.fromJson(Map<String, dynamic> json) => GuidesLesson(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        sections: (json['sections'] as List<dynamic>? ?? const [])
            .map((e) => GuidesSection.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// A titled group of lessons, shown as a help category.
class GuidesModule {
  final String id;
  final String title;
  final String? subtitle;
  final List<GuidesLesson> lessons;

  const GuidesModule({
    required this.id,
    required this.title,
    this.subtitle,
    required this.lessons,
  });

  factory GuidesModule.fromJson(Map<String, dynamic> json) => GuidesModule(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        subtitle: json['subtitle'] as String?,
        lessons: (json['lessons'] as List<dynamic>? ?? const [])
            .map((e) => GuidesLesson.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// The full help manifest.
class GuidesManifest {
  final int version;
  final String title;
  final List<GuidesModule> modules;

  const GuidesManifest({
    required this.version,
    required this.title,
    required this.modules,
  });

  factory GuidesManifest.fromJson(Map<String, dynamic> json) => GuidesManifest(
        version: json['version'] as int? ?? 1,
        title: json['title'] as String? ?? 'Help',
        modules: (json['modules'] as List<dynamic>? ?? const [])
            .map((e) => GuidesModule.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
