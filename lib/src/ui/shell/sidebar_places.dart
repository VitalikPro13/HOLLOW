import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/sidebar_items_provider.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Where the optional places sit in the current layout, for the copy that
/// names it.
enum PlacesHost {
  sidebar('sidebar'),
  dock('dock');

  final String noun;
  const PlacesHost(this.noun);
}

extension SidebarItemUi on SidebarItem {
  String get label => switch (this) {
        SidebarItem.publicChannels => 'Public channels',
        SidebarItem.share => 'Share',
        SidebarItem.archive => 'Archive',
        SidebarItem.conferences => 'Conferences',
        SidebarItem.shop => 'Hollow Shop',
      };

  IconData get icon => switch (this) {
        SidebarItem.publicChannels => LucideIcons.globe,
        SidebarItem.share => LucideIcons.share2,
        SidebarItem.archive => LucideIcons.archive,
        SidebarItem.conferences => LucideIcons.video,
        SidebarItem.shop => LucideIcons.store,
      };
}

/// The toast after a hide names both ways back, so nobody loses a place.
String sidebarItemHiddenMessage(SidebarItem item) =>
    '${item.label} is hidden. Open it from the Home menu, '
    'or show it again in Appearance settings.';

const kSidebarItemSaveFailed = "Couldn't save that change. Try again.";

/// The right-click menu on one optional place in the rail or the dock. A
/// hidden place shows only while it is open, so its menu offers it back.
void showSidebarItemMenu({
  required BuildContext context,
  required WidgetRef ref,
  required Offset anchor,
  required SidebarItem item,
  required PlacesHost host,
}) {
  showHollowMenu(
    context: context,
    anchor: anchor,
    builder: (_, menuRef) => [
      if (menuRef.watch(hiddenSidebarItemsProvider).contains(item))
        HollowMenuItem(
          icon: LucideIcons.eye,
          label: 'Show in ${host.noun}',
          onTap: () => saveSidebarItem(context, ref, item, shown: true),
        )
      else
        HollowMenuItem(
          icon: LucideIcons.eyeOff,
          label: 'Hide from ${host.noun}',
          onTap: () => hideSidebarItem(context, ref, item),
        ),
    ],
  );
}

/// Shows or hides [item], then toasts [savedMessage] once it is saved, or the
/// failure. The overlay is taken first: a hide unmounts the widget [context]
/// is from.
void saveSidebarItem(
  BuildContext context,
  WidgetRef ref,
  SidebarItem item, {
  required bool shown,
  String? savedMessage,
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  void toast(String message, HollowToastType type, Duration duration) {
    if (overlay == null || !overlay.mounted) return;
    HollowToast.show(overlay.context, message,
        type: type, duration: duration, overlayState: overlay);
  }

  ref.read(hiddenSidebarItemsProvider.notifier).setShown(item, shown).then(
    (_) {
      if (savedMessage != null) {
        toast(savedMessage, HollowToastType.info, const Duration(seconds: 6));
      }
    },
    onError: (Object e) => toast(
      friendlyError(e, fallback: kSidebarItemSaveFailed),
      HollowToastType.error,
      const Duration(seconds: 3),
    ),
  );
}

void hideSidebarItem(BuildContext context, WidgetRef ref, SidebarItem item) =>
    saveSidebarItem(context, ref, item,
        shown: false, savedMessage: sidebarItemHiddenMessage(item));

/// The Home menu's rows for the places hidden from the rail or dock: the
/// other way in, so hiding never strands one.
List<HollowMenuEntry> hiddenPlaceMenuEntries({
  required List<SidebarItem> hidden,
  required void Function(SidebarItem item) open,
}) {
  if (hidden.isEmpty) return const [];
  return [
    const HollowMenuDivider(),
    const HollowMenuSection('Hidden places'),
    for (final item in hidden)
      HollowMenuItem(
        icon: item.icon,
        label: item.label,
        onTap: () => open(item),
      ),
  ];
}
