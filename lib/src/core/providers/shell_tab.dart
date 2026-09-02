import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/guest_provider.dart';
import 'package:hollow/src/core/providers/share_tab_provider.dart';
import 'package:hollow/src/core/providers/shop_tab_provider.dart';

/// The full-screen views that take over the centre pane, replacing whatever
/// chat is selected: Browse Public Channels, Share, Archive, Conferences,
/// Hollow Shop.
///
/// They are mutually exclusive — `_buildChatOrEmpty` checks them in order and
/// returns the first one that is open — but each keeps its own boolean
/// provider, so every navigation site had to remember to clear ALL of them.
/// Conferences shipped last and half the sites never learned about it, which
/// is issue #28: with the Conferences tab open, clicking a server icon set the
/// server and channel underneath but left `conferenceTabOpen` true, so the
/// conference dashboard kept covering the channel. Home and the friend list
/// happened to clear it, which is why those were the only way back out.
///
/// [setShellTab] is now the ONE place that knows the full list. A new tab is
/// added to the enum and to this function, and every navigation site stays
/// correct for free.
enum ShellTab { guest, share, archive, conference, shop }

/// `ref.read`, torn off either a [WidgetRef] or a provider [Ref] — the same
/// helper has to serve widgets and notifiers.
typedef ProviderRead = T Function<T>(ProviderListenable<T> provider);

/// Opens [tab] and closes every other centre tab; `null` closes all of them,
/// revealing whatever chat/server selection sits underneath.
void setShellTab(ProviderRead read, ShellTab? tab) {
  read(guestTabOpenProvider.notifier).state = tab == ShellTab.guest;
  read(shareTabOpenProvider.notifier).state = tab == ShellTab.share;
  read(archiveTabOpenProvider.notifier).state = tab == ShellTab.archive;
  read(conferenceTabOpenProvider.notifier).state = tab == ShellTab.conference;
  read(shopTabOpenProvider.notifier).state = tab == ShellTab.shop;
}

/// True when any centre tab is covering the chat area. Watch this instead of
/// listing the tabs a widget happens to know about — the Home button reads
/// "selected" only when nothing is covering the chat, and a strip with no
/// Conferences button of its own still has to notice one is open.
final anyShellTabOpenProvider = Provider<bool>(
  (ref) =>
      ref.watch(guestTabOpenProvider) ||
      ref.watch(shareTabOpenProvider) ||
      ref.watch(archiveTabOpenProvider) ||
      ref.watch(conferenceTabOpenProvider) ||
      ref.watch(shopTabOpenProvider),
);
