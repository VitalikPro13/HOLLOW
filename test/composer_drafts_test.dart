import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/composer_draft_provider.dart';

void main() {
  test('an emptied composer forgets its draft', () {
    final drafts = ComposerDrafts()..keep('dm:a', 'hello');
    drafts.keep('dm:a', '  \n');
    expect(drafts.draftFor('dm:a'), isNull);
  });

  test('the oldest draft goes once the store is full', () {
    final drafts = ComposerDrafts();
    for (var i = 0; i <= ComposerDrafts.capacity; i++) {
      drafts.keep('dm:$i', 'draft $i');
    }
    expect(drafts.draftFor('dm:0'), isNull);
    expect(drafts.draftFor('dm:1'), 'draft 1');
    expect(drafts.draftFor('dm:${ComposerDrafts.capacity}'),
        'draft ${ComposerDrafts.capacity}');
  });

  test('keeping a draft again makes it the newest', () {
    final drafts = ComposerDrafts();
    for (var i = 0; i < ComposerDrafts.capacity; i++) {
      drafts.keep('dm:$i', 'draft $i');
    }
    drafts.keep('dm:0', 'still typing');
    drafts.keep('dm:new', 'another');
    expect(drafts.draftFor('dm:0'), 'still typing');
    expect(drafts.draftFor('dm:1'), isNull);
  });
}
