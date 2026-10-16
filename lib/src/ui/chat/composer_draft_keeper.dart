import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/composer_draft_provider.dart';

import 'chat_pane_shared.dart';
import 'emote_composer.dart';

/// A chat composer whose unsent text outlives its pane (#110): it comes back
/// when the same conversation shows again, on any surface.
///
/// [draftScope] uses the [ComposerInsert] scope strings, so a desktop pane and
/// a phone page of one conversation share a draft.
mixin ComposerDraftKeeper<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  String get draftScope;
  EmoteComposerController get draftComposer;

  // Both read once: deactivate may not touch ref, and the draft goes back
  // under the key it came out of.
  late final ComposerDrafts _drafts;
  late final String _scope;

  @override
  void initState() {
    super.initState();
    _drafts = ref.read(composerDraftsProvider);
    _scope = draftScope;
    final draft = _drafts.draftFor(_scope);
    if (draft != null) restoreFailedDraft(draftComposer, draft);
  }

  // Before dispose, while the composer is still alive.
  @override
  void deactivate() {
    _drafts.keep(_scope, draftComposer.expandedText());
    super.deactivate();
  }
}
