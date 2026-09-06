import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/guest_provider.dart';
import 'package:hollow/src/core/providers/share_tab_provider.dart';
import 'package:hollow/src/core/providers/shop_tab_provider.dart';

/// The full-screen views that take over the centre pane: Browse Public
/// Channels, Share, Archive, Conferences, Hollow Shop.
///
/// They are mutually exclusive but each keeps its own boolean provider, so
/// every navigation site had to clear ALL of them and half never learned about
/// Conferences (issue #28). [setShellTab] is now the ONE place that knows the
/// full list: a new tab is added to the enum and to it, and every site follows.
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
/// listing the tabs a widget happens to know about: a strip with no Conferences
/// button of its own still has to notice one is open.
final anyShellTabOpenProvider = Provider<bool>(
  (ref) =>
      ref.watch(guestTabOpenProvider) ||
      ref.watch(shareTabOpenProvider) ||
      ref.watch(archiveTabOpenProvider) ||
      ref.watch(conferenceTabOpenProvider) ||
      ref.watch(shopTabOpenProvider),
);
