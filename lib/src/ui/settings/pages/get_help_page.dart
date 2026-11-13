import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/help_resources.dart';
import 'package:hollow/src/core/providers/settings_place_provider.dart';
import 'package:hollow/src/core/services/untrusted_link.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_text_link.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/ime_keys.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_settings_tab.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

const _title = 'Get help';

/// Settings > Get help: emergency numbers, hotlines and helplines from a list
/// bundled with the app. Hollow is not a reporting channel; every action here
/// leaves the app (a call, a website) or copies a number.
///
/// The first screen holds what is urgent (the emergency number and one crisis
/// line); every other kind of help is a choice that opens its own page.
class GetHelpSettingsPage extends ConsumerWidget {
  const GetHelpSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(helpResourcesProvider);
    return data.when(
      // A bundled read: over before anything would show.
      loading: () =>
          const SettingsPage(title: _title, children: []),
      error: (_, _) => SettingsPage(
        title: _title,
        children: [
          SettingsLoadFailed(
            title: "The help list didn't load",
            onRetry: () => ref.invalidate(helpResourcesProvider),
          ),
        ],
      ),
      data: (res) => _Loaded(res),
    );
  }
}

/// Where the reader is: the country the page uses and how it was found.
class _Place {
  final HelpCountry? country;
  final HelpRegion? found;
  final bool picked;
  const _Place(this.country, this.found, {required this.picked});

  HelpLists? get local => country?.help;
}

/// Null until the remembered pick and the device's region are read, so the
/// page never swaps its layout under the reader.
_Place? _placeOf(WidgetRef ref, HelpResources res) {
  final choice = ref.watch(helpCountryChoiceProvider);
  final region = ref.watch(deviceRegionProvider);
  if (choice.isLoading || region.isLoading) return null;
  final found = region.valueOrNull;
  final picked = choice.valueOrNull;
  final pickedListed = picked != null && res.countries.containsKey(picked);
  return _Place(res.countries[pickedListed ? picked : found?.code], found,
      picked: pickedListed);
}

/// A kind of help with a page of its own.
enum _Need {
  crisis('Talk to someone now'),
  photos('Someone threatens to share your photos'),
  children('Help for children and teens'),
  police('Report a crime to the police'),
  websites('Someone sent you a link to child sexual abuse material');

  final String title;
  const _Need(this.title);

  /// The line under the page title. The crisis page leaves its top free.
  String? get intro => switch (this) {
        _Need.photos =>
          "Don't pay and don't send anything more. Paying rarely makes it "
              'stop. Keep the messages, because they are evidence, then block '
              'the person and report their account. Tell someone you trust or '
              "the police. This isn't your fault.",
        _Need.police =>
          'The messages on your device are the evidence, so keep them.',
        _Need.websites => "Don't download, screenshot or forward it. These "
            'hotlines get it taken off websites, and most need the link to act.',
        _Need.crisis || _Need.children => null,
      };

  List<HelpContact> of(HelpLists lists) => switch (this) {
        _Need.crisis => lists.crisis,
        _Need.photos => lists.photos,
        _Need.children => lists.children,
        _Need.police => lists.police,
        _Need.websites => lists.websites,
      };
}

class _Loaded extends ConsumerStatefulWidget {
  final HelpResources res;
  const _Loaded(this.res);

  @override
  ConsumerState<_Loaded> createState() => _LoadedState();
}

class _LoadedState extends ConsumerState<_Loaded> {
  /// The need open in the desktop pane; a phone pushes a page instead.
  _Need? _open;
  double _chooserOffset = 0;
  final _choiceFocus = {for (final n in _Need.values) n: FocusNode()};

  @override
  void dispose() {
    for (final f in _choiceFocus.values) {
      f.dispose();
    }
    super.dispose();
  }

  void _openNeed(_Need need) {
    if (SettingsDensity.touchOf(context)) {
      Navigator.of(context).push(hollowMobileRoute(
        builder: (_) => MobileSettingsSubPage(
          title: _title,
          child: SettingsDensity(
            touch: true,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(HollowSpacing.lg,
                  HollowSpacing.sm, HollowSpacing.lg, HollowSpacing.xl),
              child: _NeedRoute(widget.res, need),
            ),
          ),
        ),
      ));
      return;
    }
    // Opening a need switches what the pane shows: instant, from its top.
    final scroll = Scrollable.maybeOf(context)?.position;
    _chooserOffset = scroll?.pixels ?? 0;
    setState(() => _open = need);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll != null && scroll.hasPixels) scroll.jumpTo(0);
    });
  }

  void _back() {
    final need = _open;
    setState(() => _open = null);
    final scroll = Scrollable.maybeOf(context)?.position;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (scroll != null && scroll.hasPixels) {
        scroll.jumpTo(_chooserOffset.clamp(0.0, scroll.maxScrollExtent));
      }
      if (need != null) _choiceFocus[need]!.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Choosing Get help in the rail again starts from its first screen.
    ref.listen(settingsPageOpenedProvider, (_, _) {
      if (_open != null) setState(() => _open = null);
    });
    final place = _placeOf(ref, widget.res);
    if (place == null) {
      return const SettingsPage(title: _title, children: []);
    }
    final open = _open;
    if (open != null && !SettingsDensity.touchOf(context)) {
      return _DeskNeed(widget.res, place, open, onBack: _back);
    }
    return _Chooser(widget.res, place,
        onOpen: _openNeed, focus: _choiceFocus);
  }
}

/// The first screen: the emergency numbers and the country they are for,
/// someone to talk to now, then a choice for every other kind of help.
class _Chooser extends ConsumerWidget {
  final HelpResources res;
  final _Place place;
  final void Function(_Need) onOpen;
  final Map<_Need, FocusNode> focus;

  const _Chooser(this.res, this.place,
      {required this.onOpen, required this.focus});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final country = place.country;
    final local = place.local;
    final world = res.worldwide;
    final numbers = country?.emergency ?? const <HelpPhone>[];
    // The focal point: what to call in the worst minute, before anything else.
    final emergency = SettingsSection(
      key: const ValueKey('help-emergency-section'),
      title: 'Emergency',
      children: [
        KeyedSubtree(
          key: const ValueKey('help-emergency'),
          child: country == null
              ? Text('Call your local emergency number.',
                  style: HollowTypography.body
                      .copyWith(color: hollow.textPrimary))
              : _Ways(HelpContact(name: 'Emergency', phones: numbers),
                  // One number needs no label; several each say what they reach.
                  services: numbers.length > 1),
        ),
        if (country?.notes['emergency'] case final note?) _NoteText(note),
        // Which country the numbers are for: a second group in the section.
        Padding(
          padding: const EdgeInsets.only(top: HollowSpacing.sm),
          child: _CountryRow(res, place),
        ),
      ],
    );
    final main = local?.mainCrisis;
    // A country with no line of its own gets the finders here, so the most
    // urgent help never sits behind a tap.
    final crisis = SettingsSection(
      key: const ValueKey('help-crisis'),
      title: _Need.crisis.title,
      subtitle: country != null && main == null
          ? "We couldn't confirm a crisis line for ${country.name}. These "
              'services can find one for you.'
          : null,
      wrapTitle: true,
      children: [
        if (main == null)
          for (final c in world.crisis) _ContactRow(c)
        else ...[
          _ContactRow(main, key: const ValueKey('help-crisis-main')),
          _choice(_Need.crisis,
              title: 'More ways to talk',
              subtitle: _moreWays(local!.crisis.length)),
        ],
      ],
    );
    final hasPolice = local != null && local.police.isNotEmpty;
    final other = SettingsSection(
      key: const ValueKey('help-other'),
      title: 'Other help',
      children: [
        _choice(_Need.photos, subtitle: 'What to do now, and who can help'),
        _choice(_Need.children, subtitle: 'Helplines for young people'),
        if (hasPolice)
          _choice(_Need.police,
              subtitle: "The police's online form"),
        _choice(_Need.websites,
            subtitle: 'Hotlines that get it taken off websites'),
        _FootNote(res.checked, privacy: true),
      ],
    );
    return SettingsPage(
      title: _title,
      children: [emergency, crisis, other],
    );
  }

  Widget _choice(_Need need, {String? title, required String subtitle}) =>
      _ChoiceRow(
        key: ValueKey('help-open-${need.name}'),
        title: title ?? need.title,
        subtitle: subtitle,
        focusNode: focus[need],
        onTap: () => onOpen(need),
      );
}

/// What the crisis page adds to the line already on the first screen. No
/// country name: many read wrong without "the".
String _moreWays(int lines) => switch (lines) {
      1 => 'Services that find a line in any country',
      2 => 'Another line, and services that find one in any country',
      _ => '${lines - 1} more lines, and services that find one in any '
          'country',
    };

/// Which country the page uses, where that came from, and the picker.
class _CountryRow extends ConsumerWidget {
  final HelpResources res;
  final _Place place;
  const _CountryRow(this.res, this.place);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final country = place.country;
    final device = place.found?.code;
    void pick() => _pickCountry(context, ref, res, device);
    return SettingsRow(
      key: const ValueKey('help-country'),
      title: 'Country',
      subtitle: place.picked
          ? 'You chose this'
          : country != null
              ? switch (place.found!.source) {
                  HelpRegionSource.network => 'From your mobile network',
                  HelpRegionSource.sim => 'From your SIM card',
                  HelpRegionSource.locale =>
                    "From your device's region settings",
                }
              // The button already asks; a subtitle would ask again.
              : device == null
                  ? null
                  : "Your device's region isn't on the list",
      stackWhenNarrow: true,
      // Beside the chip a narrow subtitle breaks a word a line (320 px at
      // x2.0); short of three fifths of the row, the chip goes below.
      stackLeadShare: 0.6,
      // With no country yet, choosing one is what the row is for.
      trailing: country == null
          ? HollowButton.outline(
              compact: !SettingsDensity.touchOf(context),
              touch: SettingsDensity.touchOf(context),
              onPressed: pick,
              child: const Text('Choose a country'),
            )
          : HollowChip(
              label: country.name,
              trailingIcon: LucideIcons.chevronDown,
              semanticLabel: 'Country, ${country.name}. Change',
              onTap: pick,
            ),
    );
  }
}

/// A row that opens a page: the whole row takes the tap, a chevron says so.
class _ChoiceRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final FocusNode? focusNode;
  final VoidCallback onTap;

  const _ChoiceRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final touch = SettingsDensity.touchOf(context);
    final inset = HollowListRow.insetOf(touch: touch);
    // Content on the page's text edge, the hover fill past it.
    return HollowBleed(
      horizontal: inset,
      child: HollowPressable(
        onTap: onTap,
        focusNode: focusNode,
        subtle: true,
        borderRadius:
            touch ? BorderRadius.zero : BorderRadius.circular(hollow.radiusMd),
        padding: EdgeInsets.symmetric(horizontal: inset),
        child: SettingsRow(
          title: title,
          subtitle: subtitle,
          trailing: Icon(LucideIcons.chevronRight,
              size: 16, color: hollow.textSecondary),
        ),
      ),
    );
  }
}

/// A need's page in the desktop pane: Escape goes back before it closes
/// Settings, and focus starts on the title so a screen reader names the page.
class _DeskNeed extends StatefulWidget {
  final HelpResources res;
  final _Place place;
  final _Need need;
  final VoidCallback onBack;
  const _DeskNeed(this.res, this.place, this.need, {required this.onBack});

  @override
  State<_DeskNeed> createState() => _DeskNeedState();
}

class _DeskNeedState extends State<_DeskNeed> {
  final _focus = FocusNode(debugLabel: 'help-need-title', skipTraversal: true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent ||
              event.logicalKey != LogicalKeyboardKey.escape ||
              keyBelongsToFocusedIme(event)) {
            return KeyEventResult.ignored;
          }
          widget.onBack();
          return KeyEventResult.handled;
        },
        child: _NeedPage(widget.res, widget.place, widget.need,
            onBack: widget.onBack, titleFocus: _focus),
      );
}

/// A need's page pushed on a phone; it reads the place itself, so it follows
/// a change of country made behind it.
class _NeedRoute extends ConsumerWidget {
  final HelpResources res;
  final _Need need;
  const _NeedRoute(this.res, this.need);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final place = _placeOf(ref, res);
    if (place == null) return const SizedBox.shrink();
    return _NeedPage(res, place, need);
  }
}

/// One kind of help: the country's rows, then the ones that work anywhere,
/// in one list.
class _NeedPage extends StatelessWidget {
  final HelpResources res;
  final _Place place;
  final _Need need;
  final VoidCallback? onBack;

  /// Where focus lands when the page opens in the desktop pane.
  final FocusNode? titleFocus;

  const _NeedPage(this.res, this.place, this.need,
      {this.onBack, this.titleFocus});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final touch = SettingsDensity.touchOf(context);
    final local = place.local;
    final here = local == null ? const <HelpContact>[] : need.of(local);
    final note = place.country?.notes[need.name];
    // Police forms are national; there is no worldwide one.
    final anywhere =
        need == _Need.police ? const <HelpContact>[] : need.of(res.worldwide);
    final intro = need.intro;
    final back = onBack;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (back != null && !touch) ...[
          // The arrow's glyph sits on the text edge, its hover past it.
          HollowBleed(
            horizontal: HollowSpacing.md,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: HollowButton.ghost(
                compact: true,
                icon: const Icon(LucideIcons.arrowLeft, size: 16),
                semanticLabel: 'Back to Get help',
                onPressed: back,
                child: const Text(_title),
              ),
            ),
          ),
          const SizedBox(height: HollowSpacing.sm),
        ],
        Focus(
          focusNode: titleFocus,
          canRequestFocus: titleFocus != null,
          skipTraversal: true,
          child: Semantics(
            header: true,
            child: Text(
              need.title,
              style: (touch
                      ? HollowTypography.subheading
                      : HollowTypography.heading)
                  .copyWith(color: hollow.textPrimary),
            ),
          ),
        ),
        SizedBox(height: intro == null ? HollowSpacing.xl : HollowSpacing.sm),
        SettingsPage(
          intro: intro,
          children: [
            SettingsSection(
              key: ValueKey('help-need-${need.name}'),
              children: [
                for (final c in here) _ContactRow(c),
                // A country's note about these rows sits with them.
                if (note != null) _NoteText(note),
                if (here.isNotEmpty && anywhere.isNotEmpty)
                  const _AnywhereCaption(),
                for (final c in anywhere) _ContactRow(c),
                _FootNote(res.checked),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

/// The quiet line between a country's help and the help that works anywhere;
/// a heading to a screen reader, so it can jump to the boundary.
class _AnywhereCaption extends StatelessWidget {
  const _AnywhereCaption();

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      key: const ValueKey('help-anywhere'),
      padding: const EdgeInsets.only(
          top: HollowSpacing.lg, bottom: HollowSpacing.xs),
      child: Semantics(
        header: true,
        child: Text(
          'Anywhere in the world',
          style: HollowTypography.caption.copyWith(color: hollow.textTertiary),
        ),
      ),
    );
  }
}

/// One organisation: what it is, when it answers, and every way in.
class _ContactRow extends StatelessWidget {
  final HelpContact contact;
  const _ContactRow(this.contact, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = contact;
    final link = switch (c.linkRequired) {
      true => 'Needs the link to the website',
      false => 'You can report without a link',
      null => null,
    };
    final lines = [
      ?c.note,
      ?link,
      // The first word a text line asks for, said once in the row rather
      // than squeezed into its button.
      for (final p in c.phones)
        if (p.keyword case final word?) 'Text $word to ${p.number}',
      ..._whenLines(c),
    ];
    return SettingsRow(
      title: c.name,
      subtitle: lines.isEmpty ? null : lines.join('\n'),
      wideTrailing: true,
      stackWhenNarrow: true,
      trailing: _Ways(c),
    );
  }
}

/// When it answers and in which languages. A chat with hours of its own
/// gets its own line, so the phone hours never read as the chat's.
List<String> _whenLines(HelpContact c) {
  final langs = c.languages.isEmpty ? '' : ', in ${_joinWords(c.languages)}';
  final hours = c.hours;
  final chat = c.chatHours;
  final calls = c.phones.any((p) => !p.isText) ? 'Phone' : 'Text';
  if (chat == null) return [if (hours != null) '$hours$langs'];
  return [
    if (hours != null && c.phones.isNotEmpty) '$calls ${_mid(hours)}$langs',
    'Chat ${_mid(chat)}${hours == null || c.phones.isEmpty ? langs : ''}',
  ];
}

/// [hours] after a word: "Every day, ..." reads "every day, ...".
String _mid(String hours) =>
    hours.startsWith('Every ') ? 'e${hours.substring(1)}' : hours;

/// "Polish", "Polish and English", "Polish, English and Ukrainian".
String _joinWords(List<String> words) => words.length < 2
    ? words.join()
    : '${words.sublist(0, words.length - 1).join(', ')} and ${words.last}';

Future<void> _pickCountry(BuildContext context, WidgetRef ref,
    HelpResources res, String? device) async {
  final picked = await showHollowDialog<_Pick>(
    context: context,
    builder: (_) => _CountryPicker(
      countries: res.byName,
      device: res.countries[device],
    ),
  );
  if (picked == null) return;
  try {
    await ref.read(helpCountryChoiceProvider.notifier).choose(picked.code);
  } catch (_) {
    // The page already shows the pick; only remembering it failed.
  }
}

/// The picker's answer: a country code, or null for the device's region.
class _Pick {
  final String? code;
  const _Pick(this.code);
}

class _CountryPicker extends StatefulWidget {
  final List<HelpCountry> countries;
  final HelpCountry? device;

  const _CountryPicker({required this.countries, required this.device});

  @override
  State<_CountryPicker> createState() => _CountryPickerState();
}

class _CountryPickerState extends State<_CountryPicker> {
  String _query = '';

  static const double _listHeight = 360;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final compact = HollowDialogSurface.isCompact(context);
    final matches = [
      for (final c in widget.countries)
        if (c.matches(_query)) c,
    ];
    final device = widget.device;
    return HollowDialog(
      title: 'Choose a country',
      showClose: true,
      width: 420,
      // The list scrolls itself, so the search field stays put above it.
      scrollable: false,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HollowTextField(
            autofocus: !compact,
            isDense: true,
            hintText: 'Search countries',
            prefixIcon:
                Icon(LucideIcons.search, size: 16, color: hollow.textTertiary),
            onChanged: (v) => setState(() => _query = v),
            onSubmitted: (text) {
              // An empty query matches everything; Enter there picks nothing.
              if (text.trim().isEmpty) return;
              final top = widget.countries.where((c) => c.matches(text));
              if (top.isNotEmpty) {
                Navigator.of(context).pop(_Pick(top.first.code));
              }
            },
          ),
          const SizedBox(height: HollowSpacing.sm),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: _listHeight),
              child: matches.isEmpty
                  ? const HollowEmptyState(
                      dense: true, title: 'No country matches that')
                  : HollowBleed(
                      horizontal: HollowListRow.insetOf(touch: compact),
                      child: ListView.builder(
                        shrinkWrap: true,
                        padding: EdgeInsets.symmetric(
                            horizontal: HollowListRow.insetOf(touch: compact)),
                        itemCount: matches.length,
                        itemBuilder: (context, i) {
                          final c = matches[i];
                          return HollowListRow(
                            key: ValueKey(c.code),
                            touch: compact,
                            title: c.name,
                            trailing: Text(c.code,
                                style: HollowTypography.monoSmall
                                    .copyWith(color: hollow.textTertiary)),
                            onTap: () =>
                                Navigator.of(context).pop(_Pick(c.code)),
                          );
                        },
                      ),
                    ),
            ),
          ),
        ],
      ),
      leadingActions: [
        if (device != null)
          HollowButton.ghost(
            onPressed: () => Navigator.of(context).pop(const _Pick(null)),
            child: const Text("Use my device's region"),
          ),
      ],
    );
  }
}

/// Every way into one organisation as one kind of button, so a stacked row
/// wraps evenly: numbers to call or text (phones) or copy (desktops and
/// noted numbers), then its web chat, else its website.
class _Ways extends StatelessWidget {
  final HelpContact contact;

  /// Each number's button says what it reaches ("103 (ambulance)").
  final bool services;

  const _Ways(this.contact, {this.services = false});

  @override
  Widget build(BuildContext context) {
    final touch = SettingsDensity.touchOf(context);
    final canDialHere = helpCanDial();
    final c = contact;
    final chat = c.chat;
    final url = c.url;
    return Wrap(
      spacing: HollowSpacing.sm,
      runSpacing: HollowSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final p in c.phones)
          _phoneButton(context, p, touch, dial: canDialHere && p.canDial),
        if (chat != null)
          _LinkButton(
            label: 'Chat',
            icon: LucideIcons.messageCircle,
            semanticLabel: 'Open the ${c.name} chat',
            url: chat,
          )
        // The chat page is on the service's own site; one link is enough.
        else if (url != null)
          _LinkButton(
            label: 'Open website',
            icon: LucideIcons.arrowUpRight,
            semanticLabel: 'Open the ${c.name} website',
            url: url,
          ),
      ],
    );
  }

  Widget _phoneButton(BuildContext context, HelpPhone p, bool touch,
      {required bool dial}) {
    final shown = _hint(p, services: services);
    // A screen reader always hears what an emergency number reaches.
    final heard = _hint(p, services: true);
    return HollowButton.outline(
      compact: !touch,
      touch: touch,
      icon: Icon(
        dial
            ? (p.isText ? LucideIcons.messageSquare : LucideIcons.phone)
            : LucideIcons.copy,
        size: 16,
      ),
      semanticLabel: '${dial ? (p.isText ? 'Text' : 'Call') : 'Copy'} '
          '${p.number}${heard == null ? '' : ', $heard'}',
      onPressed: () => _usePhone(context, p, dial),
      child: Text(shown == null ? p.number : '${p.number} ($shown)'),
    );
  }
}

/// The quiet words after a number: what it reaches, then any caveat. A text
/// line's first word shows in its row.
String? _hint(HelpPhone p, {required bool services}) {
  final words = [
    if (services) ?p.service,
    if (p.isText) 'text' else ?p.hint,
  ];
  return words.isEmpty ? null : words.join(', ');
}

Future<void> _usePhone(BuildContext context, HelpPhone p, bool dial) async {
  if (dial && await dialHelpPhone(p)) return;
  await Clipboard.setData(ClipboardData(text: p.number));
  if (context.mounted) {
    HollowToast.show(context, 'Copied ${p.number}',
        type: HollowToastType.success);
  }
}

Future<void> _openSite(BuildContext context, String url) async {
  // https only, through the one opener for links Hollow did not write.
  final opened = isHttpsUrl(url) && await openUntrustedUrl(url);
  if (!opened && context.mounted) {
    HollowToast.show(context, "Couldn't open the link",
        type: HollowToastType.error);
  }
}

class _LinkButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final String semanticLabel;
  final String url;

  const _LinkButton({
    required this.label,
    required this.icon,
    required this.semanticLabel,
    required this.url,
  });

  @override
  Widget build(BuildContext context) {
    final touch = SettingsDensity.touchOf(context);
    return HollowButton.outline(
      compact: !touch,
      touch: touch,
      icon: Icon(icon, size: 16),
      semanticLabel: semanticLabel,
      onPressed: () => _openSite(context, url),
      child: Text(label),
    );
  }
}

/// A country's notes, with any https address in them as a link named by its
/// host.
class _NoteText extends StatelessWidget {
  final String text;
  const _NoteText(this.text);

  static final _url = RegExp(r'https://[^\s()]+');

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final spans = <InlineSpan>[];
    var at = 0;
    for (final m in _url.allMatches(text)) {
      var url = m.group(0)!;
      // A sentence's full stop or comma is not part of the address.
      while (url.endsWith('.') || url.endsWith(',')) {
        url = url.substring(0, url.length - 1);
      }
      final host = Uri.tryParse(url)?.host ?? '';
      if (host.isEmpty) continue;
      spans.add(TextSpan(text: text.substring(at, m.start)));
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: HollowTextLink(
          host.startsWith('www.') ? host.substring(4) : host,
          onTap: () => _openSite(context, url),
        ),
      ));
      at = m.start + url.length;
    }
    spans.add(TextSpan(text: text.substring(at)));
    return Padding(
      padding: const EdgeInsets.only(top: HollowSpacing.sm),
      child: Text.rich(
        TextSpan(children: spans),
        style: HollowTypography.bodySmall.copyWith(color: hollow.textSecondary),
      ),
    );
  }
}

/// The page's last lines: on the first screen what Hollow sees (nothing),
/// then when the list was checked.
class _FootNote extends StatelessWidget {
  final DateTime? checked;
  final bool privacy;
  const _FootNote(this.checked, {this.privacy = false});

  @override
  Widget build(BuildContext context) {
    final checked = this.checked;
    if (!privacy && checked == null) return const SizedBox.shrink();
    return Padding(
      key: const ValueKey('help-footnote'),
      padding: const EdgeInsets.only(top: HollowSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (privacy)
            const SettingsNote("Hollow can't read your messages, so contact "
                'these organizations yourself. This page sends nothing to '
                'us or anyone else.'),
          if (checked != null)
            SettingsNote('Checked in ${_monthYear(checked)}. '
                "Numbers and websites change, so if one doesn't work, "
                'search for the organization by name.'),
        ],
      ),
    );
  }
}

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', 'July', //
  'August', 'September', 'October', 'November', 'December',
];

String _monthYear(DateTime d) => '${_months[d.month - 1]} ${d.year}';
