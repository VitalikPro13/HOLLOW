import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';

/// What deleting a channel does, said the same way everywhere. A removal drops
/// the channel from the server; messages already on a device stay there.
const kDeleteChannelMessage = 'It disappears for everyone. Its messages stay '
    "on the devices that already have them. This can't be undone.";

/// THE delete-channel confirm, for server settings, the sidebar menu and the
/// phone channel sheet. The delete runs inside the dialog, so a failure stays
/// on screen; resolves true once the channel is gone.
Future<bool> confirmDeleteChannel(
  BuildContext context, {
  required String serverId,
  required String channelId,
  required String channelName,
}) async {
  // The container, not a ref: a menu or sheet that opened this may be gone by
  // the time the dialog answers.
  final read = ProviderScope.containerOf(context, listen: false).read;
  final ok = await showHollowConfirm(
    context: context,
    title: 'Delete #$channelName?',
    message: kDeleteChannelMessage,
    confirmLabel: 'Delete channel',
    destructive: true,
    onConfirm: () =>
        crdt_api.removeChannel(serverId: serverId, channelId: channelId),
  );
  if (!ok) return false;
  read(channelListProvider.notifier).onChannelRemoved(serverId, channelId);
  if (context.mounted) {
    HollowToast.show(context, '#$channelName deleted',
        type: HollowToastType.info);
  }
  return true;
}
