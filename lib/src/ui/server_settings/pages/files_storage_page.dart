import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_settings_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/storage_provider.dart';
import 'package:hollow/src/core/providers/vault_status_provider.dart';
import 'package:hollow/src/core/services/disk_space.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/components/hollow_skeleton.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The smallest pledge a member can make, in MB.
const kMinPledgeMb = 512;

/// Below this many members every member keeps a full copy; from it on, files
/// are split so a few members online can rebuild them.
const _kSplitFromMembers = 6;

const _kMb = 1024 * 1024;

/// The pledge slider's stops, in MB.
const _pledgeStopsMb = [
  512,
  1024,
  2048,
  5120,
  10240,
  20480,
  51200,
  102400,
  204800,
  512000,
];

const _retentionOptions = [
  ('permanent', 'Forever'),
  ('30d', '30 days'),
  ('90d', '90 days'),
  ('180d', '180 days'),
  ('365d', '365 days'),
];

/// This server's pledges and use, as the CRDT and the vault table hold them.
final serverStorageStatsProvider = FutureProvider.autoDispose
    .family<crdt_api.StorageStatsFfi, String>(
      (ref, serverId) => crdt_api.getStorageStats(serverId: serverId),
    );

/// Free space on the drive holding the data root; null where it cannot be
/// read (iOS).
final _dataDriveFreeProvider = FutureProvider.autoDispose<int?>(
  (ref) => freeBytesAt(hollowDataDir),
);

String _mbLabel(int mb) {
  if (mb < 1024) return '$mb MB';
  final gb = mb / 1024;
  return gb == gb.roundToDouble()
      ? '${gb.round()} GB'
      : '${gb.toStringAsFixed(1)} GB';
}

/// A server's files: what it keeps on this device, how the server keeps them,
/// and for how long. Every member sees it; retention is admin-only.
class FilesStoragePage extends ConsumerWidget {
  final String serverId;
  const FilesStoragePage({super.key, required this.serverId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final serverName =
        ref.watch(serverListProvider)[serverId]?.name ?? 'this server';
    return SettingsPage(
      title: 'Files & storage',
      intro:
          "Files shared in $serverName live on its members' devices. This "
          'is your share of them, and how the server keeps them safe.',
      children: [
        _OnThisDevice(serverId: serverId, serverName: serverName),
        _WholeServer(serverId: serverId),
        _Retention(serverId: serverId),
      ],
    );
  }
}

/// Bytes this device holds for the server, split by kind.
class _Usage {
  final int downloads;
  final int kept;
  const _Usage(this.downloads, this.kept);
  int get total => downloads + kept;
}

class _OnThisDevice extends ConsumerWidget {
  final String serverId;
  final String serverName;
  const _OnThisDevice({required this.serverId, required this.serverName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final touch = SettingsDensity.touchOf(context);
    final where = touch ? 'this phone' : 'this computer';
    final stats = ref.watch(serverStorageStatsProvider(serverId));
    final breakdown = ref.watch(storageBreakdownProvider);
    final free = ref.watch(_dataDriveFreeProvider).valueOrNull;

    final downloads = breakdown.valueOrNull?.contexts
        .where(
          (c) =>
              c.contextType == 'channel' &&
              c.contextId.startsWith('$serverId:'),
        )
        .fold<int>(0, (sum, c) => sum + c.bytesDb.toInt());
    final kept = stats.valueOrNull?.myUsedBytes.toInt();
    final usage = downloads == null || kept == null
        ? null
        : _Usage(downloads, kept);
    final failed = stats.hasError || breakdown.hasError;

    Widget summary;
    if (usage != null) {
      summary = _UsageSummary(
        usage: usage,
        where: where,
        serverName: serverName,
        free: free,
      );
    } else if (failed) {
      summary = Text(
        "Couldn't read what $serverName keeps on $where.",
        style: HollowTypography.bodySmall.copyWith(color: hollow.error),
      );
    } else {
      summary = _UsageSkeleton(where: where, serverName: serverName);
    }

    return SettingsSection(
      title: touch ? 'On this phone' : 'On this computer',
      children: [
        summary,
        const SizedBox(height: HollowSpacing.sm),
        _PledgeRow(serverId: serverId, where: where, free: free),
        _AutoDownloadRow(serverId: serverId),
        _DownloadedFilesRow(
          serverId: serverId,
          serverName: serverName,
          downloads: downloads,
        ),
      ],
    );
  }
}

class _Segment {
  final String label;
  final int bytes;
  final Color color;
  const _Segment(this.label, this.bytes, this.color);
}

class _UsageSummary extends StatelessWidget {
  final _Usage usage;
  final String where;
  final String serverName;
  final int? free;
  const _UsageSummary({
    required this.usage,
    required this.where,
    required this.serverName,
    required this.free,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    // Emote and sticker images are cached across every server at once, so
    // there is no honest per-server figure for them here.
    final segments = [
      _Segment('Downloads', usage.downloads, hollow.categorical[0]),
      _Segment('Kept for the server', usage.kept, hollow.categorical[1]),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: usage.total == 0
                    ? 'Nothing yet'
                    : formatBytes(usage.total),
                style: HollowTypography.heading.copyWith(
                  color: hollow.textPrimary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              TextSpan(
                text: usage.total == 0
                    ? ' from $serverName on $where'
                    : ' of $serverName on $where',
                style: HollowTypography.body.copyWith(
                  color: hollow.textSecondary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: HollowSpacing.md),
        _Bar(segments: segments, total: usage.total),
        const SizedBox(height: HollowSpacing.md),
        Wrap(
          spacing: HollowSpacing.xl,
          runSpacing: HollowSpacing.sm,
          children: [for (final s in segments) _Legend(segment: s)],
        ),
        if (free != null) ...[
          const SizedBox(height: HollowSpacing.sm),
          Text(
            '${formatBytes(free!)} free on this drive',
            style: HollowTypography.caption.copyWith(
              color: hollow.textTertiary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ],
    );
  }
}

/// The summary's final geometry while the figures load: never a false "0 B".
class _UsageSkeleton extends StatelessWidget {
  final String where;
  final String serverName;
  const _UsageSkeleton({required this.where, required this.serverName});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const HollowSkeleton(
              width: 72,
              height: HollowSpacing.lg + HollowSpacing.xs,
            ),
            const SizedBox(width: HollowSpacing.sm),
            Flexible(
              child: Text(
                'of $serverName on $where',
                style: HollowTypography.body.copyWith(
                  color: hollow.textSecondary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.md),
        const HollowSkeleton(height: HollowSpacing.xs),
        const SizedBox(height: HollowSpacing.md),
        const Wrap(
          spacing: HollowSpacing.xl,
          runSpacing: HollowSpacing.sm,
          children: [
            HollowSkeleton(width: 120, height: HollowSpacing.lg),
            HollowSkeleton(width: 160, height: HollowSpacing.lg),
          ],
        ),
      ],
    );
  }
}

/// A 4 px measure: each segment's share of [total].
class _Bar extends StatelessWidget {
  final List<_Segment> segments;
  final int total;
  const _Bar({required this.segments, required this.total});

  int get _rest => total - segments.fold<int>(0, (sum, s) => sum + s.bytes);

  /// Flex in thousandths of [total], at least one so a sliver still shows.
  int _share(int bytes) => (bytes * 1000 / total).round().clamp(1, 1000);

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(hollow.radiusXs),
      child: SizedBox(
        height: HollowSpacing.xs,
        child: ColoredBox(
          color: hollow.border,
          child: total <= 0
              ? const SizedBox.expand()
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final s in segments)
                      if (s.bytes > 0)
                        Expanded(
                          flex: _share(s.bytes),
                          child: ColoredBox(color: s.color),
                        ),
                    if (_rest > 0) Spacer(flex: _share(_rest)),
                  ],
                ),
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  final _Segment segment;
  const _Legend({required this.segment});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: HollowSpacing.sm,
          height: HollowSpacing.sm,
          decoration: BoxDecoration(
            color: segment.color,
            borderRadius: BorderRadius.circular(hollow.radiusXs / 2),
          ),
        ),
        const SizedBox(width: HollowSpacing.sm),
        Text(
          segment.label,
          style: HollowTypography.bodySmall.copyWith(color: hollow.textPrimary),
        ),
        const SizedBox(width: HollowSpacing.sm),
        Text(
          formatBytes(segment.bytes),
          style: HollowTypography.bodySmall.copyWith(
            color: hollow.textSecondary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// The pledge: moves freely, saves once when released.
class _PledgeRow extends ConsumerStatefulWidget {
  final String serverId;
  final String where;
  final int? free;
  const _PledgeRow({
    required this.serverId,
    required this.where,
    required this.free,
  });

  @override
  ConsumerState<_PledgeRow> createState() => _PledgeRowState();
}

class _PledgeRowState extends ConsumerState<_PledgeRow> {
  /// The value under the thumb while it moves, then until the stats reload.
  int? _draftMb;

  List<int> _stops(int currentMb, int usedMb) {
    // A pledge can take what is free plus what the server already uses here.
    final capMb = widget.free == null
        ? _pledgeStopsMb[6]
        : widget.free! ~/ _kMb + usedMb;
    final stops = [
      for (final s in _pledgeStopsMb)
        if (s <= capMb || s == kMinPledgeMb) s,
    ];
    if (!stops.contains(currentMb)) stops.add(currentMb);
    return stops..sort();
  }

  Future<void> _save(int mb, int savedMb) async {
    if (mb == savedMb) return;
    try {
      await crdt_api.setStoragePledge(
        serverId: widget.serverId,
        pledgeBytes: BigInt.from(mb) * BigInt.from(_kMb),
      );
      ref.invalidate(serverStorageStatsProvider(widget.serverId));
    } catch (e) {
      if (mounted) {
        setState(() => _draftMb = null);
        HollowToast.show(
          context,
          friendlyError(e, fallback: "Couldn't save the space. Try again."),
          type: HollowToastType.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final stats = ref
        .watch(serverStorageStatsProvider(widget.serverId))
        .valueOrNull;
    final savedMb = stats == null || stats.myPledgeBytes == BigInt.zero
        ? kMinPledgeMb
        : (stats.myPledgeBytes ~/ BigInt.from(_kMb)).toInt();
    final usedMb = stats == null
        ? 0
        : (stats.myUsedBytes ~/ BigInt.from(_kMb)).toInt();
    final currentMb = _draftMb ?? savedMb;
    final stops = _stops(savedMb, usedMb);
    if (!stops.contains(currentMb)) {
      stops
        ..add(currentMb)
        ..sort();
    }
    final index = stops.indexOf(currentMb);
    final movable = stats != null && stops.length > 1;

    return SettingsSliderRow(
      title: 'Keep for this server up to',
      subtitle:
          "Space ${widget.where} gives to the server's files. Saves when "
          'you let go.',
      value: index.toDouble(),
      min: 0,
      max: (stops.length - 1).clamp(1, stops.length).toDouble(),
      divisions: (stops.length - 1).clamp(1, stops.length),
      // Blank until the stats land: the minimum is not what was pledged.
      valueLabel: stats == null ? '' : _mbLabel(currentMb),
      onChanged: movable
          ? (v) => setState(() => _draftMb = stops[v.round()])
          : null,
      onChangeEnd: movable ? (v) => _save(stops[v.round()], savedMb) : null,
    );
  }
}

/// This server's override of the global auto-download setting.
class _AutoDownloadRow extends ConsumerWidget {
  final String serverId;
  const _AutoDownloadRow({required this.serverId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = 'server:$serverId';
    final value =
        (ref.watch(autoDownloadOverridesProvider).valueOrNull ?? const {})[key];
    final threshold = ref.watch(autoDownloadThresholdProvider).valueOrNull;
    final subtitle = switch (value) {
      true => 'Every file from this server downloads by itself.',
      false => 'Files wait for a click. Voice messages always play.',
      null =>
        threshold == 0
            ? 'Follows Settings, where it is off.'
            : 'Follows Settings, so files up to '
                  '${_mbLabel(threshold ?? 169)} download by themselves.',
    };
    return _ChoiceRow<bool?>(
      title: 'Download automatically',
      subtitle: subtitle,
      sheetTitle: 'Download automatically',
      value: value,
      options: const [(null, 'Default'), (true, 'Always on'), (false, 'Off')],
      onPick: (v) =>
          ref.read(autoDownloadOverridesProvider.notifier).setOverride(key, v),
    );
  }
}

class _DownloadedFilesRow extends ConsumerWidget {
  final String serverId;
  final String serverName;
  final int? downloads;
  const _DownloadedFilesRow({
    required this.serverId,
    required this.serverName,
    required this.downloads,
  });

  Future<void> _clear(BuildContext context, WidgetRef ref) async {
    final contexts =
        ref
            .read(storageBreakdownProvider)
            .valueOrNull
            ?.contexts
            .where(
              (c) =>
                  c.contextType == 'channel' &&
                  c.contextId.startsWith('$serverId:'),
            )
            .toList() ??
        const [];
    final actions = ref.read(storageActionsProvider);
    var freed = 0;
    final ok = await showHollowConfirm(
      context: context,
      title: 'Clear downloaded files?',
      message:
          'Deletes the ${formatBytes(downloads ?? 0)} of files you '
          'downloaded from $serverName. Messages stay, and the files can be '
          'downloaded again.',
      confirmLabel: 'Clear',
      destructive: true,
      onConfirm: () async {
        for (final c in contexts) {
          freed += await actions.clearContext(c.contextType, c.contextId);
        }
      },
    );
    if (!ok || !context.mounted) return;
    HollowToast.show(
      context,
      freed > 0 ? 'Freed ${formatBytes(freed)}' : 'Nothing was cleared',
      type: freed > 0 ? HollowToastType.success : HollowToastType.info,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final touch = SettingsDensity.touchOf(context);
    final has = (downloads ?? 0) > 0;
    return SettingsRow(
      title: 'Downloaded files',
      subtitle: downloads == null
          ? null
          : has
          ? '${formatBytes(downloads!)} from this server. Messages stay, '
                'and files can be downloaded again.'
          : 'Nothing downloaded from this server yet.',
      trailing: HollowButton.outline(
        compact: !touch,
        touch: touch,
        danger: true,
        onPressed: has ? () => _clear(context, ref) : null,
        child: const Text('Clear'),
      ),
    );
  }
}

class _WholeServer extends ConsumerWidget {
  final String serverId;
  const _WholeServer({required this.serverId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final touch = SettingsDensity.touchOf(context);
    final stats = ref.watch(serverStorageStatsProvider(serverId));
    final vault = ref.watch(vaultStatusProvider.select((s) => s[serverId]));
    final rowTitle =
        (touch ? HollowTypography.bodyTouch : HollowTypography.body).copyWith(
          color: hollow.textPrimary,
        );

    final s = stats.valueOrNull;
    final List<Widget> body;
    if (s != null) {
      final used = s.totalUsedBytes.toInt();
      final given = s.totalPledgedBytes.toInt();
      final members = s.memberCount;
      final how = members < _kSplitFromMembers
          ? 'Every member keeps a full copy of every file, so a file stays '
                'available while anyone is online.'
          : "Each file is split across members' devices, so it can be put "
                'back together while some of them are offline.';
      final who = members == 0
          ? null
          : '$members ${members == 1 ? 'member gives' : 'members give'} '
                'space, ${formatBytes(given ~/ members)} each on average.';
      body = [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(child: Text('Shared files', style: rowTitle)),
            Text(
              '${formatBytes(used)} of ${formatBytes(given)}',
              style: HollowTypography.bodySmall.copyWith(
                color: hollow.textPrimary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.sm),
        _Bar(
          segments: [_Segment('Shared', used, hollow.categorical[0])],
          total: given < used ? used : given,
        ),
        const SizedBox(height: HollowSpacing.md),
        Text(
          how,
          style: HollowTypography.bodySmall.copyWith(
            color: hollow.textSecondary,
          ),
        ),
        if (who != null) ...[
          const SizedBox(height: HollowSpacing.xs),
          Text(
            who,
            style: HollowTypography.caption.copyWith(
              color: hollow.textTertiary,
            ),
          ),
        ],
        ..._health(context, vault),
      ];
    } else if (stats.hasError) {
      body = [
        Text(
          "Couldn't read this server's storage.",
          style: HollowTypography.bodySmall.copyWith(color: hollow.error),
        ),
      ];
    } else {
      body = [
        Row(
          children: [
            Expanded(child: Text('Shared files', style: rowTitle)),
            const HollowSkeleton(width: 110, height: HollowSpacing.lg),
          ],
        ),
        const SizedBox(height: HollowSpacing.sm),
        const HollowSkeleton(height: HollowSpacing.xs),
        const SizedBox(height: HollowSpacing.md),
        const FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: 0.8,
          child: HollowSkeleton(height: HollowSpacing.md),
        ),
      ];
    }
    return SettingsSection(title: 'The whole server', children: body);
  }

  /// Speaks only when a file failed to spread out or is still moving.
  List<Widget> _health(BuildContext context, VaultServerStatus? vault) {
    if (vault == null) return const [];
    final hollow = HollowTheme.of(context);
    final failed = vault.activeUploads.values
        .where((u) => u.phase == 'failed')
        .length;
    final moving =
        vault.activeUploads.values
            .where((u) => u.phase != 'complete' && u.phase != 'failed')
            .length +
        vault.activeDownloads.length;
    if (failed == 0 && moving == 0) return const [];
    String files(int n) => n == 1 ? '1 file' : '$n files';
    return [
      const SizedBox(height: HollowSpacing.lg),
      if (failed > 0)
        Row(
          children: [
            Icon(LucideIcons.circleAlert, size: 16, color: hollow.error),
            const SizedBox(width: HollowSpacing.sm),
            Expanded(
              child: Text(
                '${files(failed)} could not be spread out',
                style: HollowTypography.bodySmall.copyWith(color: hollow.error),
              ),
            ),
          ],
        ),
      if (failed > 0 && moving > 0) const SizedBox(height: HollowSpacing.sm),
      if (moving > 0)
        Row(
          children: [
            const SizedBox(
              width: HollowSpacing.lg,
              child: Center(child: HollowSpinner()),
            ),
            const SizedBox(width: HollowSpacing.sm),
            Text(
              '${files(moving)} still spreading out',
              style: HollowTypography.bodySmall.copyWith(
                color: hollow.textSecondary,
              ),
            ),
          ],
        ),
    ];
  }
}

class _Retention extends ConsumerStatefulWidget {
  final String serverId;
  const _Retention({required this.serverId});

  @override
  ConsumerState<_Retention> createState() => _RetentionState();
}

class _RetentionState extends ConsumerState<_Retention> {
  /// Optimistic values: a read right after a write sees the old one.
  final Map<String, String> _local = {};

  String _value(String key) {
    final local = _local[key];
    if (local != null) return local;
    final stored = ref
        .watch(serverSettingProvider((serverId: widget.serverId, key: key)))
        .valueOrNull;
    if (stored == null || stored.isEmpty) {
      return key == 'retention_files' ? '365d' : 'permanent';
    }
    return stored;
  }

  Future<void> _set(String key, String value) async {
    final previous = _local[key];
    setState(() => _local[key] = value);
    try {
      await crdt_api.updateServerSetting(
        serverId: widget.serverId,
        key: key,
        value: value,
      );
      // Forward-only: the stamp keeps pruning off anything created before
      // the policy changed.
      await crdt_api.updateServerSetting(
        serverId: widget.serverId,
        key: '${key}_since',
        value: (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => previous == null ? _local.remove(key) : _local[key] = previous,
        );
      }
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    final role = ref.watch(myRoleProvider(widget.serverId)).valueOrNull;
    final canEdit = role == 'owner' || role == 'admin';
    Widget row(String title, String key, String sheetTitle) =>
        _ChoiceRow<String>(
          title: title,
          sheetTitle: sheetTitle,
          value: _value(key),
          options: _retentionOptions,
          onPick: canEdit ? (v) => _set(key, v) : null,
        );
    return SettingsSection(
      title: 'How long things are kept',
      children: [
        row('Messages', 'retention_messages', 'Keep messages for'),
        row('Files', 'retention_files', 'Keep files for'),
        SettingsNote(
          canEdit
              ? 'Applies to new messages and files.'
              : 'Only admins can change this.',
        ),
      ],
    );
  }
}

/// A setting with a few named values: a chip opening a menu on desktop, a
/// row opening one picker sheet on a phone. Null [onPick] shows the value
/// read-only.
class _ChoiceRow<T> extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String sheetTitle;
  final T value;
  final List<(T, String)> options;
  final Future<void> Function(T)? onPick;

  const _ChoiceRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.sheetTitle,
    required this.value,
    required this.options,
    required this.onPick,
  });

  String get _label =>
      options.firstWhere((o) => o.$1 == value, orElse: () => options.first).$2;

  void _pick(BuildContext context, T choice) {
    if (choice == value) return;
    onPick!(choice).catchError((Object e) {
      if (context.mounted) {
        HollowToast.show(
          context,
          friendlyError(e, fallback: "Couldn't save that. Try again."),
          type: HollowToastType.error,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final touch = SettingsDensity.touchOf(context);
    if (onPick == null) {
      return SettingsRow(
        title: title,
        subtitle: subtitle,
        trailing: Text(
          _label,
          style: (touch ? HollowTypography.body : HollowTypography.bodySmall)
              .copyWith(color: hollow.textPrimary),
        ),
      );
    }
    if (touch) {
      return HollowPressable(
        semanticLabel: '$title, $_label',
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        onTap: () => _openSheet(context),
        child: SettingsRow(
          title: title,
          subtitle: subtitle,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _label,
                style: HollowTypography.body.copyWith(
                  color: hollow.textSecondary,
                ),
              ),
              const SizedBox(width: HollowSpacing.xs),
              Icon(
                LucideIcons.chevronRight,
                size: 20,
                color: hollow.textTertiary,
              ),
            ],
          ),
        ),
      );
    }
    return SettingsRow(
      title: title,
      subtitle: subtitle,
      trailing: Builder(
        builder: (chipContext) => HollowChip(
          label: _label,
          trailingIcon: LucideIcons.chevronDown,
          semanticLabel: '$title, $_label',
          onTap: () => showHollowMenu(
            context: chipContext,
            alignEnd: true,
            anchor: overlayAnchorOf(
              chipContext,
              localOffset: Offset(
                chipContext.size?.width ?? 0,
                (chipContext.size?.height ?? 0) + HollowSpacing.xs,
              ),
            ),
            builder: (_, _) => [
              for (final (opt, label) in options)
                HollowMenuItem(
                  label: label,
                  isChecked: opt == value,
                  onTap: () => _pick(context, opt),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _openSheet(BuildContext context) {
    final hollow = HollowTheme.of(context);
    showHollowSheet<void>(
      context: context,
      scrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                HollowSpacing.lg,
                HollowSpacing.md,
                HollowSpacing.lg,
                HollowSpacing.sm,
              ),
              child: Text(
                sheetTitle,
                style: HollowTypography.subheading.copyWith(
                  color: hollow.textPrimary,
                ),
              ),
            ),
            for (final (opt, label) in options)
              HollowListRow(
                touch: true,
                title: label,
                selected: opt == value,
                trailing: opt == value
                    ? Icon(
                        LucideIcons.check,
                        size: 20,
                        color: hollow.accentText,
                      )
                    : null,
                onTap: () {
                  Navigator.pop(sheetContext);
                  _pick(context, opt);
                },
              ),
            const SizedBox(height: HollowSpacing.md),
          ],
        ),
      ),
    );
  }
}
