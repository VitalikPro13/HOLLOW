import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The ONE place that knows how a widget is addressed by name.
///
/// Every probe scenario names its targets with these strings, and the dump
/// (`probe_dump.dart`) suggests targets in the same grammar, so what the map
/// prints can be pasted straight into a scenario.
///
/// Three traps cost a run each before this existed, and they are why the
/// obvious finders are NOT the ones used here:
///
/// * `find.byTooltip` finds nothing. The app uses [HollowTooltip], not the
///   Material Tooltip.
/// * `find.bySemanticsLabel` finds nothing for a server icon. It walks the
///   MERGED semantics tree, and an icon's label is absorbed into a parent
///   node. Matching the [Semantics] WIDGET works.
/// * `find.byType(TextField).first` grabs the chat composer, not the dialog
///   field, because the composer comes first in the tree. Anything inside a
///   dialog must be scoped: `dialog > type:TextField`.
///
/// ## Grammar
///
/// `prefix:value`, with `A > B` meaning "B inside A" (any depth, chainable):
///
/// * `text:Delete` — exact visible text, rich text included
/// * `contains:Are you sure` — substring of visible text
/// * `semantics:Create channel` — a Semantics / HollowPressable / HollowButton label
/// * `icon:hash` or `icon:0xe5d4` — an Icon by lucide alias or codepoint
/// * `type:HollowDialog` — widget runtime type, private types included
/// * `key:ach-abc123` — a ValueKey by its value
/// * `tooltip:Public: anyone...` — a HollowTooltip message
/// * `hint:Category name` — a TextField by its hint
/// * `channel:general` — a channel row in the server sidebar
/// * `server:test3` — a server icon in the strip
/// * `dialog` — the open HollowDialog
/// * `menu` — the open context menu
/// * `field` — the text field of the open dialog, else the first one
///
/// A bare value with no prefix is treated as `text:`.
class ProbeTargets {
  const ProbeTargets._();

  /// Resolves [spec] to a finder.
  ///
  /// Some prefixes have more than one plausible reading (`channel:` prefers a
  /// row in the sidebar but falls back to any matching text). Those candidates
  /// are evaluated here and the first one with a hit wins; when none hit, the
  /// primary candidate is returned so the failure message names what was
  /// actually looked for.
  static Finder resolve(String spec) {
    final parts =
        spec.split('>').map((s) => s.trim()).where((s) => s.isNotEmpty);
    Finder? chain;
    for (final part in parts) {
      final candidates = _candidates(part);
      if (chain == null) {
        chain = _firstHit(candidates);
      } else {
        final parent = chain;
        chain = _firstHit(candidates
            .map((c) => find.descendant(of: parent, matching: c))
            .toList());
      }
    }
    return chain ?? find.byWidgetPredicate((_) => false);
  }

  static Finder _firstHit(List<Finder> candidates) {
    for (final candidate in candidates) {
      if (candidate.evaluate().isNotEmpty) return candidate;
    }
    return candidates.first;
  }

  static List<Finder> _candidates(String spec) {
    final colon = spec.indexOf(':');
    final prefix = colon < 0 ? spec : spec.substring(0, colon);
    final value = colon < 0 ? spec : spec.substring(colon + 1);

    switch (prefix) {
      case 'text':
        return [find.text(value, findRichText: true)];
      case 'contains':
        return [find.textContaining(value, findRichText: true)];
      case 'semantics':
        return [byLabel(value)];
      case 'icon':
        final code = iconCodePointFor(value);
        if (code == null) return [find.byWidgetPredicate((_) => false)];
        return [
          find.byWidgetPredicate(
              (w) => w is Icon && w.icon?.codePoint == code),
        ];
      case 'type':
        return [byTypeName(value)];
      case 'key':
        return [
          find.byWidgetPredicate((w) {
            final key = w.key;
            return key is ValueKey && '${key.value}' == value;
          }),
        ];
      case 'tooltip':
        return [
          find.byWidgetPredicate(
              (w) => w is HollowTooltip && w.message == value),
          find.byTooltip(value),
        ];
      case 'hint':
        return [
          find.byWidgetPredicate(
              (w) => w is TextField && w.decoration?.hintText == value),
        ];
      case 'channel':
        // A channel name shows up in the chat header and the composer hint as
        // well as in the sidebar row, so prefer the sidebar. Tapping the label
        // reaches the row: the tile's gesture handlers are its ancestors.
        return [
          find.descendant(
            of: byTypeName('_ServerContent'),
            matching: find.text(value, findRichText: true),
          ),
          find.text(value, findRichText: true),
        ];
      case 'server':
        return [byLabel(value), find.bySemanticsLabel(value)];
      case 'dialog':
        return [byTypeName('HollowDialog')];
      case 'menu':
        return [byTypeName('_HollowMenuHost')];
      case 'field':
        // The dialog's field when a dialog is open; the composer otherwise.
        return [
          find.descendant(
            of: byTypeName('HollowDialog'),
            matching: find.byType(TextField),
          ),
          find.byType(TextField),
        ];
      default:
        // No prefix: plain text, which is what most rows are.
        return [find.text(spec, findRichText: true)];
    }
  }

  /// A label carried by the accessibility layer, wherever it is declared.
  ///
  /// Matches the [Semantics] WIDGET rather than the merged semantics tree, and
  /// the two Hollow controls that declare a label of their own.
  static Finder byLabel(String label) => find.byWidgetPredicate((w) =>
      (w is Semantics && w.properties.label == label) ||
      (w is HollowPressable && w.semanticLabel == label) ||
      (w is HollowButton && w.semanticLabel == label));

  /// Matches by runtime type NAME, so a private widget (`_ChannelTile`,
  /// `_HollowMenuHost`) is addressable from outside its library.
  static Finder byTypeName(String name) =>
      find.byWidgetPredicate((w) => w.runtimeType.toString() == name);

  /// `hash`, `0xe5d4` or `58756` to a codepoint.
  ///
  /// Codepoints rather than [IconData] on purpose: lucide ships several
  /// [IconData] variants per glyph (weights, the `Dir` mirrors) that share one
  /// codepoint, so comparing the whole object would miss the variant actually
  /// on screen.
  static int? iconCodePointFor(String value) {
    final alias = iconAliases[value];
    if (alias != null) return alias.codePoint;
    return value.startsWith('0x')
        ? int.tryParse(value.substring(2), radix: 16)
        : int.tryParse(value);
  }

  /// The alias for [icon], or null when it is not one of the common ones.
  static String? aliasOf(IconData icon) {
    for (final entry in iconAliases.entries) {
      if (entry.value.codePoint == icon.codePoint) return entry.key;
    }
    return null;
  }

  /// The lucide icons this app leans on, so a dump reads `icon:hash` instead
  /// of `icon:0xe5d4`. Anything absent is still addressable by codepoint, and
  /// the dump prints the codepoint for exactly that reason.
  static const Map<String, IconData> iconAliases = {
    'x': LucideIcons.x,
    'shieldCheck': LucideIcons.shieldCheck,
    'video': LucideIcons.video,
    'trash2': LucideIcons.trash2,
    'pencil': LucideIcons.pencil,
    'plus': LucideIcons.plus,
    'hash': LucideIcons.hash,
    'monitor': LucideIcons.monitor,
    'download': LucideIcons.download,
    'copy': LucideIcons.copy,
    'chevronRight': LucideIcons.chevronRight,
    'chevronDown': LucideIcons.chevronDown,
    'check': LucideIcons.check,
    'shield': LucideIcons.shield,
    'users': LucideIcons.users,
    'image': LucideIcons.image,
    'volume2': LucideIcons.volume2,
    'search': LucideIcons.search,
    'eye': LucideIcons.eye,
    'eyeOff': LucideIcons.eyeOff,
    'userPlus': LucideIcons.userPlus,
    'server': LucideIcons.server,
    'hardDrive': LucideIcons.hardDrive,
    'settings': LucideIcons.settings,
    'refreshCw': LucideIcons.refreshCw,
    'mic': LucideIcons.mic,
    'micOff': LucideIcons.micOff,
    'alertTriangle': LucideIcons.alertTriangle,
    'messageSquare': LucideIcons.messageSquare,
    'messageCircle': LucideIcons.messageCircle,
    'globe': LucideIcons.globe,
    'user': LucideIcons.user,
    'play': LucideIcons.play,
    'phoneOff': LucideIcons.phoneOff,
    'arrowLeft': LucideIcons.arrowLeft,
    'tag': LucideIcons.tag,
    'lock': LucideIcons.lock,
    'bell': LucideIcons.bell,
    'bellOff': LucideIcons.bellOff,
    'folder': LucideIcons.folder,
    'pin': LucideIcons.pin,
    'reply': LucideIcons.reply,
    'smile': LucideIcons.smile,
    'ban': LucideIcons.ban,
  };
}
