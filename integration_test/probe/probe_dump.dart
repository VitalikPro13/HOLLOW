import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/channel_layout.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/models/strip_item.dart';
import 'package:hollow/src/core/providers/chat_provider.dart';
import 'package:hollow/src/core/providers/channel_chat_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/layout_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_strip_layout_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';

import 'probe_targets.dart';

/// Writes an inventory of what is on screen right now, so scenarios can be
/// authored against facts instead of guesses.
///
/// This exists because every addressing failure while building the probe came
/// from not knowing how a widget is identified, and a hand-written note about
/// it would go stale. This one is regenerated from the running app, and every
/// entry carries the exact `target:` string [ProbeTargets] will accept.
///
/// Two artifacts per call:
/// * `map-<name>.json` — machine-readable, what scenarios are written against.
/// * `map-<name>.md` — the same thing arranged to be read.
///
/// The provider snapshot matters as much as the widget list: half the bugs
/// this tool was built for are "the UI disagrees with the provider", and that
/// is only visible when both are in one artifact.
class ProbeDump {
  const ProbeDump._();

  /// Entries beyond this are dropped, with a note. A busy screen produces a
  /// few hundred; a runaway would produce thousands and be unreadable.
  static const int maxEntries = 700;

  static Future<Map<String, dynamic>> write({
    required WidgetTester tester,
    required String name,
    required String outDir,
    ProviderContainer? container,
  }) async {
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    final entries = collect(tester, screen);
    final providers = providerSnapshot(container);

    final map = <String, dynamic>{
      'name': name,
      'screen': {'width': screen.width, 'height': screen.height},
      'overlays': _overlays(),
      'providers': providers,
      'entryCount': entries.length,
      'truncated': entries.length > maxEntries,
      'entries': entries.take(maxEntries).toList(),
    };

    final dir = Directory(outDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    File('$outDir/map-$name.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(map));
    File('$outDir/map-$name.md').writeAsStringSync(_markdown(map));
    debugPrint('[ui-probe] dump -> $outDir/map-$name.md '
        '(${entries.length} entries)');
    return map;
  }

  // -------------------------------------------------------------------------
  // Widgets
  // -------------------------------------------------------------------------

  /// Every on-screen widget the target grammar can address, with its rect and
  /// the exact target string for it. Public because the runner's `look` op
  /// serves the same list inline in an answer - the whole point of `look` is
  /// that deciding what to click next should not cost a second round trip
  /// through a file on disk.
  static List<Map<String, dynamic>> collect(WidgetTester tester, Size screen) {
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};

    for (final element in tester.allElements) {
      final entry = _describe(element);
      if (entry == null) continue;

      final rect = _rectOf(element);
      if (rect == null || rect.width <= 0 || rect.height <= 0) continue;
      // Offscreen widgets are real (a scrolled-away list row) but they are not
      // what a scenario is looking at, and they triple the size of the map.
      final onScreen = rect.right > 0 &&
          rect.bottom > 0 &&
          rect.left < screen.width &&
          rect.top < screen.height;
      if (!onScreen) continue;

      entry['rect'] = [
        rect.left.round(),
        rect.top.round(),
        rect.width.round(),
        rect.height.round(),
      ];
      entry['center'] = [
        rect.center.dx.round(),
        rect.center.dy.round(),
      ];

      final fingerprint = '${entry['type']}|${entry['label']}|'
          '${entry['target']}|${entry['rect']}';
      if (!seen.add(fingerprint)) continue;
      out.add(entry);
    }

    out.sort((a, b) {
      final ra = (a['rect'] as List).cast<int>();
      final rb = (b['rect'] as List).cast<int>();
      final byTop = ra[1].compareTo(rb[1]);
      return byTop != 0 ? byTop : ra[0].compareTo(rb[0]);
    });

    // How many things a given target string would hit. A scenario that taps a
    // spec matching four widgets is a coin flip, and this is the only warning
    // it will get before the tap lands somewhere unintended.
    final counts = <String, int>{};
    for (final entry in out) {
      final target = entry['target'] as String?;
      if (target != null) counts[target] = (counts[target] ?? 0) + 1;
    }
    for (final entry in out) {
      final target = entry['target'] as String?;
      if (target != null) entry['matches'] = counts[target];
    }
    return out;
  }

  /// One widget to an entry, or null when it is not worth listing.
  static Map<String, dynamic>? _describe(Element element) {
    final widget = element.widget;
    final type = widget.runtimeType.toString();
    final key = widget.key;
    final keyValue = key is ValueKey ? '${key.value}' : null;

    Map<String, dynamic> base(String kind, {String? label, String? target}) => {
          'kind': kind,
          'type': type,
          'label': ?label,
          'key': ?keyValue,
          'target': target ?? (keyValue != null ? 'key:$keyValue' : 'type:$type'),
        };

    if (widget is Text) {
      final data = widget.data ?? widget.textSpan?.toPlainText();
      if (data == null || data.trim().isEmpty) return null;
      final text = _clip(data);
      return base('text', label: text, target: 'text:$text');
    }

    if (widget is EditableText) {
      return base('input',
          label: _clip(widget.controller.text),
          target: keyValue != null ? 'key:$keyValue' : 'type:EditableText');
    }

    if (widget is TextField) {
      final hint = widget.decoration?.hintText;
      return base('field',
          label: hint == null ? null : 'hint "$hint"',
          target: hint != null ? 'hint:$hint' : 'type:TextField');
    }

    if (widget is Icon) {
      final icon = widget.icon;
      if (icon == null) return null;
      final alias = ProbeTargets.aliasOf(icon);
      final code = '0x${icon.codePoint.toRadixString(16)}';
      return base('icon',
          label: alias == null ? code : '$alias ($code)',
          target: 'icon:${alias ?? code}');
    }

    if (widget is HollowPressable) {
      final label = widget.semanticLabel ?? _childText(element);
      return base('pressable',
          label: label,
          target: widget.semanticLabel != null
              ? 'semantics:${widget.semanticLabel}'
              : (label != null ? 'text:$label' : 'type:HollowPressable'));
    }

    if (widget is HollowButton) {
      final label = widget.semanticLabel ?? _childText(element);
      return base('button',
          label: label,
          target: widget.semanticLabel != null
              ? 'semantics:${widget.semanticLabel}'
              : (label != null ? 'text:$label' : 'type:HollowButton'));
    }

    if (widget is HollowTooltip) {
      return base('tooltip',
          label: _clip(widget.message), target: 'tooltip:${widget.message}');
    }

    if (widget is Semantics) {
      final label = widget.properties.label;
      if (label == null || label.trim().isEmpty) return null;
      return base('semantics',
          label: _clip(label), target: 'semantics:$label');
    }

    // Anything explicitly keyed is addressable and was keyed on purpose.
    if (keyValue != null) return base('keyed');

    // Surfaces worth knowing are open, even with nothing else to say.
    if (type == 'HollowDialog' || type == '_HollowMenuHost') {
      return base('surface');
    }

    return null;
  }

  /// The first non-empty text under [element], for a control whose name comes
  /// from its child rather than from a label.
  static String? _childText(Element element) {
    String? found;
    void visit(Element child) {
      if (found != null) return;
      final widget = child.widget;
      if (widget is Text) {
        final data = widget.data ?? widget.textSpan?.toPlainText();
        if (data != null && data.trim().isNotEmpty) {
          found = _clip(data);
          return;
        }
      }
      child.visitChildren(visit);
    }

    element.visitChildren(visit);
    return found;
  }

  static Rect? _rectOf(Element element) {
    try {
      final ro = element.findRenderObject();
      if (ro is! RenderBox || !ro.attached || !ro.hasSize) return null;
      return ro.localToGlobal(Offset.zero) & ro.size;
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic> _overlays() {
    final dialogs = ProbeTargets.byTypeName('HollowDialog').evaluate().length;
    final menus = ProbeTargets.byTypeName('_HollowMenuHost').evaluate().length;
    return {
      'dialogOpen': dialogs > 0,
      'dialogCount': dialogs,
      'menuOpen': menus > 0,
      'menuRows': menus == 0
          ? <String>[]
          : find
              .descendant(
                of: ProbeTargets.byTypeName('_HollowMenuHost'),
                matching: find.byType(Text),
              )
              .evaluate()
              .map((e) => (e.widget as Text).data ?? '')
              .where((s) => s.trim().isNotEmpty)
              .toList(),
    };
  }

  static String _clip(String value, [int max = 80]) {
    final flat = value.replaceAll('\n', ' ').trim();
    return flat.length <= max ? flat : '${flat.substring(0, max)}...';
  }

  // -------------------------------------------------------------------------
  // Providers
  // -------------------------------------------------------------------------

  /// Reads the state that drives the current screen.
  ///
  /// Every read is guarded by `exists`, so the dump reports what the app has
  /// already built and never initialises a provider itself. Observing must not
  /// change what is being observed: initialising, say, a FutureProvider here
  /// would fire real FFI that the app under test never asked for.
  static Map<String, dynamic> providerSnapshot(ProviderContainer? container) {
    if (container == null) return {'note': 'no container'};
    final out = <String, dynamic>{};

    T? read<T>(ProviderBase<T> provider) {
      if (!container.exists(provider)) return null;
      try {
        return container.read(provider);
      } catch (e) {
        out['errors'] = [...(out['errors'] as List? ?? []), '$provider: $e'];
        return null;
      }
    }

    final servers = read(serverListProvider);
    final selectedServer = read(selectedServerProvider);
    final channels = read(channelListProvider);
    final selectedChannel = read(selectedChannelProvider);
    final layoutJson = read(channelLayoutProvider);
    final layoutMode = read(layoutModeProvider);

    out['selectedServer'] = selectedServer;
    out['selectedServerName'] = selectedServer == null
        ? null
        : servers?[selectedServer]?.name;
    out['selectedChannel'] = selectedChannel;
    out['selectedChannelName'] = selectedChannel == null
        ? null
        : channels?[selectedChannel]?.name;
    out['layoutMode'] = layoutMode?.toString();
    out['servers'] = servers?.values
        .map((s) => {'id': s.serverId, 'name': s.name})
        .toList();
    out['channels'] = channels?.values
        .map((c) => {
              'id': c.channelId,
              'name': c.name,
              'type': c.channelType.name,
              'category': c.category,
              'visibility': c.visibility,
              'posting': c.posting,
              'canSee': c.meCanSee,
              'canPost': c.meCanPost,
            })
        .toList();

    // The server strip: which servers sit in which folder. Folder membership
    // is now menu-driven (issue #61 phase 4), and a folder that quietly
    // dissolves itself is exactly the class of bug the layout outline caught
    // for channel categories.
    final strip = read(serverStripLayoutProvider);
    if (strip != null) {
      out['stripOutline'] = [
        for (final item in strip)
          switch (item) {
            ServerStripItem(:final serverId) =>
              'server ${servers?[serverId]?.name ?? serverId}',
            FolderStripItem(:final name, :final serverIds) =>
              'folder "$name" [${serverIds.map((id) => servers?[id]?.name ?? id).join(", ")}]',
          }
      ];
    }

    out['selectedPeer'] = read(selectedPeerProvider);
    final unread = read(unreadProvider);
    if (unread != null) {
      out['dmUnreadCounts'] = unread.dmUnreadCounts;
    }

    // Everything below is what a FLEET run needs: which instance am I, who do
    // I think my friends are, am I actually connected, and did the message
    // land. One instance can never disagree with itself about these; two can,
    // and that disagreement IS the bug class the fleet exists to catch.
    final identity = read(identityProvider);
    if (identity != null) {
      out['peerId'] = identity.peerId;
      out['identityLoaded'] = identity.isLoaded;
      if (identity.error != null) out['identityError'] = identity.error;
    }
    out['connection'] = read(overallConnectionProvider)?.name;

    final friends = read(friendsProvider);
    if (friends != null) {
      out['friends'] = [
        for (final f in friends.values)
          {
            'peerId': f.peerId,
            'status': f.status,
            if (f.direction.isNotEmpty) 'direction': f.direction,
          }
      ];
    }

    // Counts, not bodies: a dump is read by eye, and forty message bodies bury
    // the one line that matters. The last few are enough to see WHICH message
    // arrived, and the count answers whether a duplicate slipped through.
    final dms = read(chatProvider);
    if (dms != null && dms.isNotEmpty) {
      out['dms'] = {
        for (final e in dms.entries)
          e.key: {
            'count': e.value.length,
            'last': e.value.isEmpty
                ? null
                : e.value
                    .skip(e.value.length > 3 ? e.value.length - 3 : 0)
                    .map((m) => m.text)
                    .toList(),
          }
      };
    }
    final channelChats = read(channelChatProvider);
    if (channelChats != null && channelChats.isNotEmpty) {
      out['channelMessages'] = {
        for (final e in channelChats.entries)
          e.key: {
            'count': e.value.length,
            'last': e.value.isEmpty
                ? null
                : e.value
                    .skip(e.value.length > 3 ? e.value.length - 3 : 0)
                    .map((m) => m.text)
                    .toList(),
          }
      };
    }

    if (layoutJson != null) {
      out['layoutJson'] = layoutJson;
      final stored = parseLayoutJson(layoutJson);
      out['layoutOutline'] = _outline(stored, channels ?? const {});
      if (channels != null) {
        out['effectiveOutline'] =
            _outline(effectiveLayoutFrom(stored, channels), channels);
      }
    }
    return out;
  }

  /// The layout rendered as the nesting it claims, which is the only way to
  /// see at a glance whether a channel is inside a category or merely below
  /// one. Channel ids are resolved to names; an id with no channel is called
  /// out rather than skipped, because a dangling reference is a bug.
  static List<String> _outline(
      List<LayoutItem> layout, Map<String, ChannelInfo> channels) {
    final lines = <String>[];
    var inCategory = false;
    for (var i = 0; i < layout.length; i++) {
      final item = layout[i];
      switch (item) {
        case CategoryItem(:final name):
          inCategory = true;
          lines.add('[$i] CATEGORY "$name"');
        case SeparatorItem():
          inCategory = false;
          lines.add('[$i] --- separator ---');
        case ChannelItem(:final channelId):
          final channel = channels[channelId];
          final indent = inCategory ? '    ' : '';
          final label = channel == null
              ? 'MISSING channel $channelId'
              : '${channel.name} (${channel.channelType.name}, $channelId)';
          lines.add('$indent[$i] $label');
      }
    }
    if (lines.isEmpty) lines.add('(empty layout)');
    return lines;
  }

  // -------------------------------------------------------------------------
  // Markdown digest
  // -------------------------------------------------------------------------

  static String _markdown(Map<String, dynamic> map) {
    final buffer = StringBuffer();
    final screen = map['screen'] as Map<String, dynamic>;
    buffer.writeln('# UI map: ${map['name']}');
    buffer.writeln();
    buffer.writeln('Screen ${screen['width']} x ${screen['height']} logical '
        'pixels. ${map['entryCount']} entries'
        '${map['truncated'] == true ? ' (truncated to $maxEntries)' : ''}.');
    buffer.writeln();

    final overlays = map['overlays'] as Map<String, dynamic>;
    buffer.writeln('## Open surfaces');
    buffer.writeln();
    buffer.writeln('- dialog open: ${overlays['dialogOpen']}');
    buffer.writeln('- context menu open: ${overlays['menuOpen']}');
    final rows = (overlays['menuRows'] as List).cast<String>();
    if (rows.isNotEmpty) {
      buffer.writeln('- menu rows: ${rows.join(" | ")}');
    }
    buffer.writeln();

    final providers = map['providers'] as Map<String, dynamic>;
    buffer.writeln('## Providers');
    buffer.writeln();
    buffer.writeln('- server: ${providers['selectedServerName']} '
        '(${providers['selectedServer']})');
    buffer.writeln('- channel: ${providers['selectedChannelName']} '
        '(${providers['selectedChannel']})');
    buffer.writeln('- layout mode: ${providers['layoutMode']}');
    buffer.writeln('- peer: ${providers['selectedPeer']}');
    if (providers.containsKey('peerId')) {
      buffer.writeln('- identity: ${providers['peerId']} '
          '(loaded: ${providers['identityLoaded']})');
    }
    if (providers['identityError'] != null) {
      buffer.writeln('- identity ERROR: ${providers['identityError']}');
    }
    if (providers['connection'] != null) {
      buffer.writeln('- connection: ${providers['connection']}');
    }
    final friends = providers['friends'] as List?;
    if (friends != null) {
      buffer.writeln('- friends (${friends.length}):');
      for (final f in friends.cast<Map>()) {
        buffer.writeln('  - ${f['peerId']} — ${f['status']}'
            '${f['direction'] == null ? '' : ' (${f['direction']})'}');
      }
    }
    for (final key in const ['dms', 'channelMessages']) {
      final conversations = providers[key] as Map?;
      if (conversations == null || conversations.isEmpty) continue;
      buffer.writeln('- $key:');
      for (final e in conversations.entries) {
        final value = e.value as Map;
        final last = (value['last'] as List?)?.join(' / ') ?? '';
        buffer.writeln('  - ${e.key}: ${value['count']} loaded'
            '${last.isEmpty ? '' : ' — last: $last'}');
      }
    }
    final dmUnread = providers['dmUnreadCounts'] as Map?;
    if (dmUnread != null && dmUnread.isNotEmpty) {
      buffer.writeln('- DM unread: $dmUnread');
    }
    final strip = providers['stripOutline'] as List?;
    if (strip != null) {
      buffer.writeln();
      buffer.writeln('### Server strip');
      buffer.writeln();
      buffer.writeln('```');
      for (final line in strip) {
        buffer.writeln(line);
      }
      buffer.writeln('```');
    }
    final outline = (providers['layoutOutline'] as List?)?.cast<String>();
    if (outline != null) {
      buffer.writeln();
      buffer.writeln('### Stored layout');
      buffer.writeln();
      buffer.writeln('```');
      for (final line in outline) {
        buffer.writeln(line);
      }
      buffer.writeln('```');
    }
    final effective = (providers['effectiveOutline'] as List?)?.cast<String>();
    if (effective != null && !_sameLines(outline, effective)) {
      buffer.writeln();
      buffer.writeln('### Effective layout (stored + unplaced channels)');
      buffer.writeln();
      buffer.writeln('```');
      for (final line in effective) {
        buffer.writeln(line);
      }
      buffer.writeln('```');
    }
    buffer.writeln();

    buffer.writeln('## On screen');
    buffer.writeln();
    buffer.writeln('`y,x` is the top-left corner. Paste a target straight into '
        'a scenario; `xN` means the target matches N widgets, so scope it '
        '(`dialog > ...`) or pass an index.');
    buffer.writeln();
    buffer.writeln('| y,x | size | kind | label | target |');
    buffer.writeln('|---|---|---|---|---|');
    for (final entry in (map['entries'] as List).cast<Map<String, dynamic>>()) {
      final rect = (entry['rect'] as List).cast<int>();
      final matches = entry['matches'] as int? ?? 1;
      final label = (entry['label'] as String? ?? '').replaceAll('|', r'\|');
      final target = (entry['target'] as String? ?? '').replaceAll('|', r'\|');
      buffer.writeln('| ${rect[1]},${rect[0]} | ${rect[2]}x${rect[3]} | '
          '${entry['kind']} | $label | `$target`'
          '${matches > 1 ? ' x$matches' : ''} |');
    }
    return buffer.toString();
  }

  static bool _sameLines(List<String>? a, List<String>? b) {
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
