import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/composer_insert_provider.dart';

/// A person opened a conversation by hand on a desktop, so its composer takes
/// the keyboard and they can type at once (#105).
///
/// [scope] uses the [ComposerInsert] scope strings. A pane that mounts later
/// still honours a fresh request; an old one is ignored, so a conversation that
/// opens by itself (sibling sync, startup restore) never takes focus.
@immutable
class ComposerFocusRequest {
  final String scope;
  final DateTime at;

  const ComposerFocusRequest({required this.scope, required this.at});

  /// Long enough for a channel's list to load before its pane mounts.
  static const freshFor = Duration(seconds: 3);

  bool isFor(String scope, DateTime now) =>
      this.scope == scope && now.difference(at) < freshFor;
}

class ComposerFocusNotifier extends Notifier<ComposerFocusRequest?> {
  @override
  ComposerFocusRequest? build() => null;

  void request(String scope, {@visibleForTesting DateTime? at}) =>
      state = ComposerFocusRequest(scope: scope, at: at ?? DateTime.now());

  /// Clears [request] once a composer took it, so it fires once.
  void consume(ComposerFocusRequest request) {
    if (identical(state, request)) state = null;
  }
}

final composerFocusProvider =
    NotifierProvider<ComposerFocusNotifier, ComposerFocusRequest?>(
        ComposerFocusNotifier.new);

/// Phones never take it: focusing a field there pops the keyboard over the
/// conversation the person came to read.
bool get composerFocusOnOpen =>
    defaultTargetPlatform != TargetPlatform.android &&
    defaultTargetPlatform != TargetPlatform.iOS;

/// Asks the composer of [scope] to take focus when it shows; a no-op on phones.
/// Call it only where a person opened the conversation themselves.
void requestComposerFocus(
    T Function<T>(ProviderListenable<T>) read, String scope) {
  if (!composerFocusOnOpen) return;
  read(composerFocusProvider.notifier).request(scope);
}

/// A chat pane whose composer answers [composerFocusProvider]: call
/// [watchComposerFocus] from `build`.
mixin ComposerFocusOnOpen<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  String get composerScope;
  FocusNode get composerFocusNode;

  @override
  void initState() {
    super.initState();
    // The request usually lands before this pane exists: the click selects the
    // conversation, then the pane mounts.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _take(ref.read(composerFocusProvider));
    });
  }

  void watchComposerFocus() {
    ref.listen<ComposerFocusRequest?>(composerFocusProvider, (_, next) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _take(next);
      });
    });
  }

  void _take(ComposerFocusRequest? request) {
    if (request == null || !request.isFor(composerScope, DateTime.now())) {
      return;
    }
    ref.read(composerFocusProvider.notifier).consume(request);
    composerFocusNode.requestFocus();
  }
}
