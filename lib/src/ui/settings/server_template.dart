import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:lucide_icons_flutter/lucide_icons.dart';

class ServerTemplate {
  final int version;
  final String? exportedAt;
  final String name;
  final String description;
  final String? iconBase64Webp;
  final List<TemplateChannel> channels;
  final List<Map<String, dynamic>> channelLayout;

  const ServerTemplate({
    required this.version,
    this.exportedAt,
    required this.name,
    required this.description,
    this.iconBase64Webp,
    required this.channels,
    required this.channelLayout,
  });

  factory ServerTemplate.fromJson(Map<String, dynamic> json) {
    final version = json['hollow_template_version'] as int? ?? 0;
    if (version > 1) {
      throw FormatException(
        'Template version $version is not supported by this version of Hollow.',
      );
    }
    final server = json['server'] as Map<String, dynamic>? ?? {};
    final channelsJson = json['channels'] as List<dynamic>? ?? [];
    final layoutJson = json['channel_layout'] as List<dynamic>? ?? [];

    return ServerTemplate(
      version: version,
      exportedAt: json['exported_at'] as String?,
      name: server['name'] as String? ?? '',
      description: server['description'] as String? ?? '',
      iconBase64Webp: server['icon_base64_webp'] as String?,
      channels: channelsJson
          .map((c) => TemplateChannel.fromJson(c as Map<String, dynamic>))
          .toList(),
      channelLayout: layoutJson.cast<Map<String, dynamic>>(),
    );
  }

  Map<String, dynamic> toJson() => {
        'hollow_template_version': version,
        'exported_at': exportedAt,
        'server': {
          'name': name,
          'description': description,
          'icon_base64_webp': iconBase64Webp,
        },
        'channels': channels.map((c) => c.toJson()).toList(),
        'channel_layout': channelLayout,
      };
}

class TemplateChannel {
  final String templateId;
  final String name;
  final String channelType; // "text" or "voice"
  final String? category;

  const TemplateChannel({
    required this.templateId,
    required this.name,
    required this.channelType,
    this.category,
  });

  factory TemplateChannel.fromJson(Map<String, dynamic> json) {
    return TemplateChannel(
      templateId: json['template_id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      channelType: json['channel_type'] as String? ?? 'text',
      category: json['category'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'template_id': templateId,
        'name': name,
        'channel_type': channelType,
        'category': category,
      };
}

class TemplateDiff {
  final String? nameChange;
  final String? descriptionChange;
  final bool iconChanged;
  final List<TemplateChannel> channelsToAdd;
  final List<ChannelInfo> channelsToRemove;
  final bool layoutChanged;

  /// template_id -> real channel_id for channels that already exist.
  final Map<String, String> matchedChannels;

  const TemplateDiff({
    this.nameChange,
    this.descriptionChange,
    this.iconChanged = false,
    this.channelsToAdd = const [],
    this.channelsToRemove = const [],
    this.layoutChanged = false,
    this.matchedChannels = const {},
  });

  bool get isEmpty =>
      nameChange == null &&
      descriptionChange == null &&
      !iconChanged &&
      channelsToAdd.isEmpty &&
      channelsToRemove.isEmpty &&
      !layoutChanged;
}

Future<void> exportServerTemplate(
  BuildContext context,
  ServerInfo server,
) async {
  try {
    final channelsFfi =
        await crdt_api.getServerChannels(serverId: server.serverId);

    final layoutRaw =
        await crdt_api.getChannelLayout(serverId: server.serverId);
    final layoutList = layoutRaw.isNotEmpty
        ? (jsonDecode(layoutRaw) as List<dynamic>)
            .cast<Map<String, dynamic>>()
        : <Map<String, dynamic>>[];

    String description = '';
    try {
      description = await crdt_api.getServerSetting(
          serverId: server.serverId, key: 'description');
    } catch (_) {}

    String? iconBase64;
    try {
      final val = await crdt_api.getServerSetting(
          serverId: server.serverId, key: 'server_avatar');
      if (val.isNotEmpty) iconBase64 = val;
    } catch (_) {}

    final idToTemplate = <String, String>{}; // channel_id -> template_id
    final templateChannels = <TemplateChannel>[];
    for (var i = 0; i < channelsFfi.length; i++) {
      final ch = channelsFfi[i];
      final tid = 't-$i';
      idToTemplate[ch.channelId] = tid;
      templateChannels.add(TemplateChannel(
        templateId: tid,
        name: ch.name,
        channelType: ch.channelType,
        category: ch.category,
      ));
    }

    final templateLayout = <Map<String, dynamic>>[];
    for (final item in layoutList) {
      final type = item['type'] as String?;
      if (type == 'channel') {
        final cid = item['channel_id'] as String?;
        final tid = cid != null ? idToTemplate[cid] : null;
        if (tid != null) {
          templateLayout.add({'type': 'channel', 'template_id': tid});
        }
        // Skip channels not in our list (stale layout entries).
      } else {
        templateLayout.add(Map<String, dynamic>.from(item));
      }
    }

    final template = ServerTemplate(
      version: 1,
      exportedAt: DateTime.now().toUtc().toIso8601String(),
      name: server.name,
      description: description,
      iconBase64Webp: iconBase64,
      channels: templateChannels,
      channelLayout: templateLayout,
    );

    final json = const JsonEncoder.withIndent('  ').convert(template.toJson());

    final safeName = server.name
        .replaceAll(RegExp(r'[^\w\s-]'), '')
        .replaceAll(RegExp(r'\s+'), '-')
        .toLowerCase();
    final defaultName = '$safeName-template.json';

    final jsonBytes = utf8.encode(json);

    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: 'Export server template',
      fileName: defaultName,
      type: FileType.custom,
      allowedExtensions: ['json'],
      bytes: (Platform.isAndroid || Platform.isIOS)
          ? Uint8List.fromList(jsonBytes)
          : null,
    );
    if (savePath == null) return;
    if (!Platform.isAndroid && !Platform.isIOS) {
      final path = savePath.endsWith('.json') ? savePath : '$savePath.json';
      await File(path).writeAsString(json);
    }

    if (context.mounted) {
      HollowToast.show(context, 'Template exported',
          type: HollowToastType.success);
    }
  } catch (e) {
    if (context.mounted) {
      HollowToast.show(context, 'Export failed: $e',
          type: HollowToastType.error);
    }
  }
}

Future<void> importServerTemplate(
  BuildContext context,
  WidgetRef ref,
  ServerInfo server,
) async {
  try {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Import server template',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;

    final contents = await File(path).readAsString();
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(contents) as Map<String, dynamic>;
    } catch (_) {
      if (context.mounted) {
        HollowToast.show(context, 'Invalid JSON file',
            type: HollowToastType.error);
      }
      return;
    }

    final ServerTemplate template;
    try {
      template = ServerTemplate.fromJson(json);
    } on FormatException catch (e) {
      if (context.mounted) {
        HollowToast.show(context, e.message, type: HollowToastType.error);
      }
      return;
    }

    if (template.name.isEmpty && template.channels.isEmpty) {
      if (context.mounted) {
        HollowToast.show(context, 'Template is empty',
            type: HollowToastType.error);
      }
      return;
    }

    if (template.iconBase64Webp != null) {
      try {
        final decoded = base64.decode(template.iconBase64Webp!);
        if (decoded.length > 1024 * 1024) {
          if (context.mounted) {
            HollowToast.show(context, 'Template icon is too large (>1MB)',
                type: HollowToastType.error);
          }
          return;
        }
      } catch (_) {
        // Invalid base64 — will skip icon during apply.
      }
    }

    final currentChannels =
        await crdt_api.getServerChannels(serverId: server.serverId);
    final currentChannelInfos = currentChannels
        .map((ch) => ChannelInfo(
              channelId: ch.channelId,
              name: ch.name,
              category: ch.category,
              channelType: ch.channelType == 'voice'
                  ? ChannelType.voice
                  : ChannelType.text,
            ))
        .toList();

    String currentDesc = '';
    try {
      currentDesc = await crdt_api.getServerSetting(
          serverId: server.serverId, key: 'description');
    } catch (_) {}

    String? currentIcon;
    try {
      final val = await crdt_api.getServerSetting(
          serverId: server.serverId, key: 'server_avatar');
      if (val.isNotEmpty) currentIcon = val;
    } catch (_) {}

    final diff = _computeDiff(
      template: template,
      currentName: server.name,
      currentDescription: currentDesc,
      currentIcon: currentIcon,
      currentChannels: currentChannelInfos,
    );

    if (!context.mounted) return;

    if (diff.isEmpty) {
      showHollowDialog(
        context: context,
        builder: (ctx) => HollowDialog(
          title: 'No changes needed',
          content: Text(
            'This template matches your current server structure.',
            style: HollowTypography.body.copyWith(
              color: HollowTheme.of(ctx).textSecondary,
            ),
          ),
          actions: [
            HollowButton.ghost(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    final confirmed = await _showConfirmationDialog(context, template, diff);
    if (confirmed != true || !context.mounted) return;

    // Non-dismissible: the apply runs channel deletes, creates and a polling
    // loop, so without this the UI sits silent until the terminal toast.
    unawaited(showHollowDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _TemplateApplyProgressDialog(),
    ));
    try {
      await _applyTemplate(context, ref, server.serverId, template, diff);
    } finally {
      if (context.mounted) Navigator.of(context).pop();
    }
  } catch (e) {
    if (context.mounted) {
      HollowToast.show(context, 'Import failed: $e',
          type: HollowToastType.error);
    }
  }
}

TemplateDiff _computeDiff({
  required ServerTemplate template,
  required String currentName,
  required String currentDescription,
  required String? currentIcon,
  required List<ChannelInfo> currentChannels,
}) {
  final unmatched = List<ChannelInfo>.from(currentChannels);
  final matched = <String, String>{}; // template_id -> channel_id
  final toAdd = <TemplateChannel>[];

  for (final tch in template.channels) {
    final idx = unmatched.indexWhere((c) =>
        c.name.toLowerCase() == tch.name.toLowerCase() &&
        (c.channelType == ChannelType.voice) == (tch.channelType == 'voice'));
    if (idx >= 0) {
      matched[tch.templateId] = unmatched[idx].channelId;
      unmatched.removeAt(idx);
    } else {
      toAdd.add(tch);
    }
  }

  bool layoutChanged = toAdd.isNotEmpty || unmatched.isNotEmpty;
  if (!layoutChanged && template.channelLayout.isNotEmpty) {
    final templateOrder = <String>[];
    for (final item in template.channelLayout) {
      if (item['type'] == 'channel') {
        final tid = item['template_id'] as String?;
        if (tid != null && matched.containsKey(tid)) {
          templateOrder.add(matched[tid]!);
        }
      }
    }
    final currentOrder =
        currentChannels.map((c) => c.channelId).toList();
    if (templateOrder.length != currentOrder.length ||
        !_listEquals(templateOrder, currentOrder)) {
      layoutChanged = true;
    }
  }

  return TemplateDiff(
    nameChange:
        template.name.isNotEmpty && template.name != currentName
            ? template.name
            : null,
    descriptionChange: template.description != currentDescription
        ? template.description
        : null,
    iconChanged: template.iconBase64Webp != null &&
        template.iconBase64Webp != currentIcon,
    channelsToAdd: toAdd,
    channelsToRemove: unmatched,
    layoutChanged: layoutChanged,
    matchedChannels: matched,
  );
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Blocking progress dialog shown while [_applyTemplate] runs.
class _TemplateApplyProgressDialog extends StatelessWidget {
  const _TemplateApplyProgressDialog();

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowDialog(
      title: 'Applying template',
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: hollow.accent),
          ),
          const SizedBox(width: HollowSpacing.md),
          Text(
            'Updating settings and channels…',
            style: HollowTypography.body.copyWith(color: hollow.textSecondary),
          ),
        ],
      ),
    );
  }
}

Future<void> _applyTemplate(
  BuildContext context,
  WidgetRef ref,
  String serverId,
  ServerTemplate template,
  TemplateDiff diff,
) async {
  try {
    final settingsFutures = <Future>[];
    if (diff.nameChange != null) {
      settingsFutures.add(crdt_api.renameServer(
        serverId: serverId,
        newName: diff.nameChange!,
      ));
    }
    if (diff.descriptionChange != null) {
      settingsFutures.add(crdt_api.updateServerSetting(
        serverId: serverId,
        key: 'description',
        value: diff.descriptionChange!,
      ));
    }
    if (diff.iconChanged && template.iconBase64Webp != null) {
      try {
        final decoded = base64.decode(template.iconBase64Webp!);
        settingsFutures.add(crdt_api.setServerAvatar(
          serverId: serverId,
          rawBytes: decoded,
        ));
      } catch (_) {
        // Skip invalid icon.
      }
    }
    await Future.wait(settingsFutures);

    for (final ch in diff.channelsToRemove) {
      await crdt_api.removeChannel(
          serverId: serverId, channelId: ch.channelId);
    }

    final newChannelMap = <String, String>{}; // template_id -> channel_id
    if (diff.channelsToAdd.isNotEmpty) {
      final existingIds =
          ref.read(channelListProvider).keys.toSet();

      for (final ch in diff.channelsToAdd) {
        await crdt_api.createChannel(
          serverId: serverId,
          name: ch.name,
          category: ch.category,
          channelType: ch.channelType,
        );
      }

      for (var attempt = 0; attempt < 50; attempt++) {
        await Future.delayed(const Duration(milliseconds: 100));
        final current = ref.read(channelListProvider);
        for (final ch in diff.channelsToAdd) {
          if (newChannelMap.containsKey(ch.templateId)) continue;
          final match = current.entries.firstWhereOrNull((e) =>
              !existingIds.contains(e.key) &&
              !newChannelMap.containsValue(e.key) &&
              e.value.name == ch.name);
          if (match != null) {
            newChannelMap[ch.templateId] = match.key;
          }
        }
        if (newChannelMap.length == diff.channelsToAdd.length) break;
      }
    }

    if (diff.layoutChanged && template.channelLayout.isNotEmpty) {
      final fullMap = <String, String>{
        ...diff.matchedChannels,
        ...newChannelMap,
      };

      final resolvedLayout = <Map<String, dynamic>>[];
      for (final item in template.channelLayout) {
        final type = item['type'] as String?;
        if (type == 'channel') {
          final tid = item['template_id'] as String?;
          final realId = tid != null ? fullMap[tid] : null;
          if (realId != null) {
            resolvedLayout.add({'type': 'channel', 'channel_id': realId});
          }
        } else {
          resolvedLayout.add(Map<String, dynamic>.from(item));
        }
      }

      await crdt_api.updateChannelLayout(
        serverId: serverId,
        layoutJson: jsonEncode(resolvedLayout),
      );
    }

    await ref.read(channelListProvider.notifier).loadForServer(serverId);
    await ref.read(channelLayoutProvider.notifier).loadForServer(serverId);
    ref.read(serverListProvider.notifier).onServerUpdated(serverId);

    if (context.mounted) {
      HollowToast.show(context, 'Template applied',
          type: HollowToastType.success);
    }
  } catch (e) {
    if (context.mounted) {
      HollowToast.show(context, 'Failed to apply template: $e',
          type: HollowToastType.error);
    }
  }
}

Future<bool?> _showConfirmationDialog(
  BuildContext context,
  ServerTemplate template,
  TemplateDiff diff,
) {
  return showHollowDialog<bool>(
    context: context,
    builder: (ctx) {
      final hollow = HollowTheme.of(ctx);
      return HollowDialog(
        title: 'Apply template',
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Apply "${template.name}" to this server?',
                style: HollowTypography.body
                    .copyWith(color: hollow.textPrimary),
              ),
              const SizedBox(height: HollowSpacing.sm),
              Text(
                'Removed channels will disappear from the sidebar, but their '
                'messages are never deleted \u2014 they remain in everyone\u2019s '
                'local database.',
                style: HollowTypography.caption
                    .copyWith(color: hollow.textSecondary),
              ),
              const SizedBox(height: HollowSpacing.lg),

              if (diff.nameChange != null ||
                  diff.descriptionChange != null ||
                  diff.iconChanged) ...[
                _sectionHeader(hollow, 'SETTINGS'),
                const SizedBox(height: HollowSpacing.xs),
                if (diff.nameChange != null)
                  _changeRow(hollow, LucideIcons.type,
                      'Name \u2192 ${diff.nameChange}'),
                if (diff.descriptionChange != null)
                  _changeRow(hollow, LucideIcons.alignLeft,
                      'Description will be updated'),
                if (diff.iconChanged)
                  _changeRow(
                      hollow, LucideIcons.image, 'Server icon will change'),
                const SizedBox(height: HollowSpacing.md),
              ],

              if (diff.channelsToAdd.isNotEmpty) ...[
                _sectionHeader(hollow, 'CHANNELS TO ADD'),
                const SizedBox(height: HollowSpacing.xs),
                for (final ch in diff.channelsToAdd)
                  _changeRow(
                    hollow,
                    ch.channelType == 'voice'
                        ? LucideIcons.volume2
                        : LucideIcons.hash,
                    ch.name,
                    color: hollow.accent,
                  ),
                const SizedBox(height: HollowSpacing.md),
              ],

              if (diff.channelsToRemove.isNotEmpty) ...[
                _sectionHeader(hollow, 'CHANNELS TO REMOVE'),
                const SizedBox(height: HollowSpacing.xs),
                for (final ch in diff.channelsToRemove)
                  _changeRow(
                    hollow,
                    ch.channelType == ChannelType.voice
                        ? LucideIcons.volume2
                        : LucideIcons.hash,
                    ch.name,
                    color: hollow.error,
                  ),
                const SizedBox(height: HollowSpacing.md),
              ],

              if (diff.layoutChanged &&
                  diff.channelsToAdd.isEmpty &&
                  diff.channelsToRemove.isEmpty)
                _changeRow(hollow, LucideIcons.layoutList,
                    'Channel ordering will be updated'),
            ],
          ),
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          // Filled, not danger: applying a template is not destructive, and red
          // misreads as "this will delete something".
          HollowButton.filled(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Apply template'),
          ),
        ],
      );
    },
  );
}

Widget _sectionHeader(HollowTheme hollow, String text) {
  return Text(
    text,
    style: HollowTypography.caption.copyWith(
      color: hollow.textSecondary,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.2,
    ),
  );
}

Widget _changeRow(HollowTheme hollow, IconData icon, String text,
    {Color? color}) {
  final c = color ?? hollow.textPrimary;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Icon(icon, size: 14, color: c),
        const SizedBox(width: HollowSpacing.sm),
        Expanded(
          child: Text(
            text,
            style: HollowTypography.body.copyWith(color: c, fontSize: 13),
          ),
        ),
      ],
    ),
  );
}

extension _IterableExt<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final element in this) {
      if (test(element)) return element;
    }
    return null;
  }
}
