import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/time_labels.dart';
import 'package:hollow/src/rust/api/archive.dart' as archive_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/archive/archive_message_viewer.dart'
    show archiveLoadError, jumpToArchiveDate, toggleArchiveSearch;
import 'package:hollow/src/ui/archive/my_data_view.dart' show ArchiveSplit;
import 'package:hollow/src/ui/archive/shared/archive_file_actions.dart';
import 'package:hollow/src/ui/archive/shared/archive_message_list.dart';
import 'package:hollow/src/ui/archive/shared/archive_toolbar.dart';
import 'package:hollow/src/ui/archive/shared/archive_verification_banner.dart';
import 'package:hollow/src/ui/archive/shared/imported_archive_prep.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/dialogs/message_proof_dialog.dart';
import 'package:hollow/src/ui/media/media_viewer_scope.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// True while an archive is being verified, which takes seconds on a big one.
/// Gates the Load button AND drag and drop: a re-drop mid-verify would
/// double-fire silently.
final importedArchiveBusyProvider = StateProvider<bool>((ref) => false);

/// Verifies an archive file and adds it to the list, selected.
Future<void> loadImportedArchive(
    BuildContext context, WidgetRef ref, String path) async {
  if (ref.read(importedArchiveBusyProvider)) return;
  ref.read(importedArchiveBusyProvider.notifier).state = true;
  try {
    await archive_api.verifyArchive(archivePath: path);
    await ref.read(importedArchivePathsProvider.notifier).addPath(path);
    ref.invalidate(importedArchiveVerifyProvider(path));
    ref.read(selectedImportedArchiveProvider.notifier).state = path;
    if (context.mounted) {
      HollowToast.show(context, 'Archive loaded',
          type: HollowToastType.success);
    }
  } catch (e) {
    if (context.mounted) {
      HollowToast.show(context, "Couldn't load the archive: $e",
          type: HollowToastType.error);
    }
  } finally {
    ref.read(importedArchiveBusyProvider.notifier).state = false;
  }
}

/// Asks for a .hollow-archive file, then verifies and adds it.
Future<void> pickAndLoadImportedArchive(
    BuildContext context, WidgetRef ref) async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['hollow-archive'],
    dialogTitle: 'Load an archive',
  );
  final path = result?.files.firstOrNull?.path;
  if (path != null && context.mounted) {
    await loadImportedArchive(context, ref, path);
  }
}

/// The Imported view's one primary action, in the Archive header.
class LoadArchiveButton extends ConsumerWidget {
  const LoadArchiveButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return HollowButton.filled(
      compact: true,
      loading: ref.watch(importedArchiveBusyProvider),
      icon: const Icon(LucideIcons.folderOpen, size: 14),
      onPressed: () => pickAndLoadImportedArchive(context, ref),
      child: const Text('Load an archive'),
    );
  }
}

/// Imported: archives someone exported and you loaded, each opened like a
/// conversation with its signatures checked.
///
/// With nothing loaded there is nothing to pick, so the list's empty state
/// (and its drop target) takes the whole pane rather than sitting beside a
/// second one.
class ImportedArchivesView extends ConsumerWidget {
  const ImportedArchivesView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final none =
        ref.watch(importedArchivePathsProvider).valueOrNull?.isEmpty ?? false;
    if (none) return const _ImportedArchiveList();
    return const ArchiveSplit(
      list: _ImportedArchiveList(),
      viewer: _ImportedArchiveViewer(),
    );
  }
}

class _ImportedArchiveList extends ConsumerStatefulWidget {
  const _ImportedArchiveList();

  @override
  ConsumerState<_ImportedArchiveList> createState() =>
      _ImportedArchiveListState();
}

class _ImportedArchiveListState extends ConsumerState<_ImportedArchiveList> {
  bool _dragging = false;

  Future<void> _handleDrop(DropDoneDetails details) async {
    setState(() => _dragging = false);
    final path = details.files.firstOrNull?.path;
    if (path == null || path.isEmpty) return;
    await loadImportedArchive(context, ref, path);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final pathsAsync = ref.watch(importedArchivePathsProvider);

    final list = pathsAsync.when(
      loading: () => const Center(child: HollowSpinner.medium()),
      error: (_, _) => HollowEmptyState(
        title: "Your archives didn't load",
        action: HollowButton.ghost(
          compact: true,
          onPressed: () => ref.invalidate(importedArchivePathsProvider),
          child: const Text('Try again'),
        ),
      ),
      data: (paths) => paths.isEmpty
          ? const HollowEmptyState(
              glyph: LucideIcons.fileArchive,
              title: 'No archives loaded',
              description: 'Load a .hollow-archive file, or drop one here.',
            )
          : ListView.builder(
              padding: const EdgeInsets.all(HollowSpacing.sm),
              itemCount: paths.length,
              itemBuilder: (context, index) => _ArchiveEntryRow(
                  key: ValueKey(paths[index]), path: paths[index]),
            ),
    );

    if (Platform.isAndroid || Platform.isIOS) return list;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: _handleDrop,
      child: Stack(
        children: [
          Positioned.fill(child: list),
          if (_dragging)
            Positioned.fill(
              child: Container(
                margin: const EdgeInsets.all(HollowSpacing.sm),
                decoration: BoxDecoration(
                  color: hollow.accentMuted,
                  borderRadius: BorderRadius.circular(hollow.radiusLg),
                  border: Border.all(color: hollow.accent),
                ),
                alignment: Alignment.center,
                child: Text(
                  'Drop the archive to load it',
                  style: HollowTypography.label
                      .copyWith(color: hollow.accentText),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ArchiveEntryRow extends ConsumerWidget {
  final String path;

  const _ArchiveEntryRow({super.key, required this.path});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final verifyAsync = ref.watch(importedArchiveVerifyProvider(path));
    final selected = ref
        .watch(selectedImportedArchiveProvider.select((p) => p == path));
    final fileName = path.split(RegExp(r'[\\/]')).last;
    void open() => ref.read(selectedImportedArchiveProvider.notifier).state =
        path;

    final remove = HollowIconButton(
      icon: LucideIcons.x,
      label: 'Remove $fileName from the list',
      size: 24,
      onPressed: () =>
          ref.read(importedArchivePathsProvider.notifier).removePath(path),
    );

    return verifyAsync.when(
      loading: () => HollowListRow(
        title: fileName,
        subtitle: 'Checking signatures',
        leading: const SizedBox.square(
            dimension: 20, child: Center(child: HollowSpinner())),
        selected: selected,
        onTap: open,
      ),
      error: (_, _) => HollowListRow(
        title: fileName,
        subtitle: "This file isn't a readable archive",
        leading: Icon(LucideIcons.alertCircle, size: 20, color: hollow.error),
        trailing: remove,
        selected: selected,
        onTap: open,
      ),
      data: (result) {
        final peerProfile = ref.watch(profileProvider.select(
            (p) => result.peerId != null ? p[result.peerId!] : null));
        final servers = ref.watch(serverListProvider);
        final String name;
        final String kindLabel;
        final IconData kindIcon;
        switch (result.archiveType) {
          case 'dm':
            name = result.peerId != null
                ? displayNameForPeer(peerProfile, result.peerId!)
                : 'Direct messages';
            kindLabel = 'Direct messages';
            kindIcon = LucideIcons.messageSquare;
          case 'server':
            name = result.serverName ?? 'Server';
            kindLabel = '${result.channels.length} channels';
            kindIcon = LucideIcons.server;
          default:
            name = result.channelName ?? result.channelId ?? 'Channel';
            kindLabel = (result.serverId != null
                    ? servers[result.serverId]?.name
                    : null) ??
                'Channel';
            kindIcon = LucideIcons.hash;
        }
        final exported = calendarDateLabel(
            DateTime.fromMillisecondsSinceEpoch(result.exportTimestamp));
        final problem = !result.archiveSignatureValid
            ? (LucideIcons.shieldOff, hollow.error,
                "The archive's signature doesn't match")
            : result.messagesWithInvalidSig > 0
                ? (LucideIcons.shieldAlert, hollow.warning,
                    'Some messages failed their signature check')
                : null;

        return HollowListRow(
          title: name,
          subtitle: '$kindLabel · ${result.messageCount} messages · $exported',
          leading: Icon(kindIcon, size: 20, color: hollow.textSecondary),
          selected: selected,
          onTap: open,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (problem != null)
                HollowTooltip(
                  message: problem.$3,
                  child: Icon(problem.$1, size: 16, color: problem.$2),
                ),
              remove,
            ],
          ),
        );
      },
    );
  }
}

class _ImportedArchiveViewer extends ConsumerWidget {
  const _ImportedArchiveViewer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final selectedPath = ref.watch(selectedImportedArchiveProvider);

    if (selectedPath == null) {
      return const HollowEmptyState(
        glyph: LucideIcons.fileArchive,
        title: 'Pick an archive to read it',
        description: 'Every message is checked against its sender\'s '
            'signature, so you can tell if anything was changed.',
      );
    }

    final dataAsync = ref.watch(importedArchiveDataProvider(selectedPath));
    return ColoredBox(
      color: hollow.background,
      child: dataAsync.when(
        loading: () => const Center(child: HollowSpinner.large()),
        error: (_, _) => archiveLoadError(
            () => ref.invalidate(importedArchiveDataProvider(selectedPath))),
        data: (data) =>
            _ArchivePovViewer(key: ValueKey(selectedPath), data: data),
      ),
    );
  }
}

class _ArchivePovViewer extends ConsumerStatefulWidget {
  final archive_api.ArchiveData data;

  const _ArchivePovViewer({super.key, required this.data});

  @override
  ConsumerState<_ArchivePovViewer> createState() => _ArchivePovViewerState();
}

class _ArchivePovViewerState extends ConsumerState<_ArchivePovViewer> {
  @override
  void initState() {
    super.initState();
    // Past the first frame: a provider written while the tree builds asserts.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      resetArchiveViewerState(ref.read);
      ref.read(importedArchiveSelectedChannelProvider.notifier).state = null;
    });
  }

  void _resetForChannelSwitch() {
    ref.read(archiveFilterSenderProvider.notifier).state = null;
    ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
    ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final data = widget.data;
    final localPeerId = ref.watch(identityProvider).peerId ?? '';
    final profiles = ref.watch(profileProvider);
    final filterSender = ref.watch(archiveFilterSenderProvider);
    final searchOpen = ref.watch(archiveMessageSearchOpenProvider);
    final selectedChannelId = ref.watch(importedArchiveSelectedChannelProvider);

    final prep = prepareImportedArchive(
      data: data,
      localPeerId: localPeerId,
      filterSender: filterSender,
      selectedChannelId: selectedChannelId,
      displayNameOf: (id) => displayNameFor(profiles, id),
    );
    final isDm = prep.isDm;
    final List<DateTime> timestamps = isDm
        ? [for (final m in prep.dmMessages!) m.timestamp]
        : [for (final m in prep.channelMessages!) m.timestamp];

    return Column(
      children: [
        ArchiveToolbar(
          leading: isDm
              ? HollowAvatar(peerId: data.peerId ?? '', size: 24)
              : Icon(LucideIcons.hash, size: 20, color: hollow.textSecondary),
          title: prep.headerTitle,
          subtitle: prep.headerSubtitle,
          messageCount: timestamps.length,
          totalMessageCount: filterSender != null
              ? prep.unfilteredChannelMessages?.length
              : null,
          badges: [
            archiveVerdictBadge(
              archiveSigValid: prep.archiveSigValid,
              archiveSigText: prep.archiveSigText,
              msgSigWarning: prep.msgSigWarning,
              msgSigText: prep.msgSigText,
            ),
          ],
          senderIds: prep.uniqueSenders,
          selectedSender: filterSender,
          senderDisplayNames: prep.senderNames,
          onSenderFilterChanged: (sender) {
            ref.read(archiveFilterSenderProvider.notifier).state = sender;
            ref.read(archiveMessageSearchQueryProvider.notifier).state = '';
            ref.read(archiveSearchMatchIndexProvider.notifier).state = 0;
          },
          onJumpToDate: timestamps.isNotEmpty
              ? () => jumpToArchiveDate(context, ref, timestamps)
              : null,
          searchOpen: searchOpen,
          onToggleSearch: () => toggleArchiveSearch(ref),
        ),
        ArchiveVerificationBanner(
          archiveSigValid: prep.archiveSigValid,
          archiveSigText: prep.archiveSigText,
          msgSigWarning: prep.msgSigWarning,
          msgSigText: prep.msgSigText,
        ),
        if (prep.isServer && data.channels.length > 1)
          ArchiveChannelSelector(
            channels: data.channels,
            activeChannelId: prep.activeChannelId,
            onChannelSelected: (channelId) {
              ref.read(importedArchiveSelectedChannelProvider.notifier).state =
                  channelId;
              _resetForChannelSwitch();
            },
          ),
        Expanded(
          child: MediaViewerScope(
            // Read-only: an archived file can be saved and nothing else.
            actions: MediaViewerActions(
                onSaveAs: (a) => saveArchivedAttachment(context, ref, a)),
            child: isDm
                ? _dmList(prep, localPeerId)
                : _channelList(prep),
          ),
        ),
      ],
    );
  }

  Widget _dmList(ImportedArchivePrep prep, String localPeerId) {
    final data = widget.data;
    final peerId = data.peerId ?? '';
    final exporter = data.exporterPeerId;
    return ArchiveDmMessageList(
      messages: prep.dmMessages!,
      peerId: peerId,
      localPeerId: localPeerId,
      editsMap: prep.editsMap,
      proofContextFor: (_) => prep.proofContext,
      proofMsgType: prep.proofMsgType,
      desktopChrome: true,
      actionWrapper: (context, ChatMessage msg, child) {
        final senderPeerId = msg.isMe ? localPeerId : peerId;
        return archiveHoverActions(
          context: context,
          ref: ref,
          isMe: msg.isMe,
          messageId: msg.messageId,
          text: msg.text,
          attachment: msg.fileAttachment,
          onInfo: () => showMessageProofDialog(
            context,
            MessageProofData(
              senderPeerId: senderPeerId,
              senderDisplayName: displayNameFor(
                  ref.read(profileProvider), senderPeerId),
              text: msg.text,
              timestampMs:
                  (msg.editedAt ?? msg.timestamp).millisecondsSinceEpoch,
              signature: msg.signature,
              publicKey: msg.publicKey,
              messageId: msg.messageId,
              // A DM is signed for the OTHER side: the exporter's messages
              // name the peer, the peer's name the exporter.
              context: prep.proofMsgType == 'dm'
                  ? (senderPeerId == exporter ? prep.proofContext : exporter)
                  : prep.proofContext,
              msgType: prep.proofMsgType,
              fileAttachment: msg.fileAttachment,
              preverified: msg.archiveSignatureValid,
            ),
          ),
          child: child,
        );
      },
    );
  }

  Widget _channelList(ImportedArchivePrep prep) {
    return ArchiveChannelMessageList(
      messages: prep.channelMessages!,
      allMessages: prep.unfilteredChannelMessages ?? prep.channelMessages!,
      serverId: widget.data.serverId ?? '',
      editsMap: prep.editsMap,
      proofContext: prep.proofContext,
      proofMsgType: prep.proofMsgType,
      desktopChrome: true,
      actionWrapper: (context, ChannelChatMessage msg, child) =>
          archiveHoverActions(
        context: context,
        ref: ref,
        isMe: msg.isMe,
        messageId: msg.messageId,
        text: msg.text,
        attachment: msg.fileAttachment,
        onInfo: () => showMessageProofDialog(
          context,
          MessageProofData(
            senderPeerId: msg.senderId,
            senderDisplayName:
                displayNameFor(ref.read(profileProvider), msg.senderId),
            text: msg.text,
            timestampMs:
                (msg.editedAt ?? msg.timestamp).millisecondsSinceEpoch,
            signature: msg.signature,
            publicKey: msg.publicKey,
            messageId: msg.messageId,
            context: prep.proofContext,
            msgType: prep.proofMsgType,
            fileAttachment: msg.fileAttachment,
            preverified: msg.archiveSignatureValid,
          ),
        ),
        child: child,
      ),
    );
  }
}
