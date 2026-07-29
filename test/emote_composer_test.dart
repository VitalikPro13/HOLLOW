import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/ui/chat/emote_composer.dart';

const _hashA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _hashB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  group('EmoteComposerController', () {
    test('placeholder expands to wire token, text stays 1 char', () {
      final c = EmoteComposerController();
      final p = c.placeholderFor('monkaw', _hashA);
      expect(p.length, 1);
      c.text = 'hello $p world';
      expect(c.expandedText(), 'hello [e:monkaw:$_hashA] world');
    });

    test('displayTextFor converts tokens, passes Unicode through', () {
      final c = EmoteComposerController();
      expect(c.displayTextFor('😀'), '😀');
      final p = c.displayTextFor('[e:pog:$_hashA]');
      expect(p.length, 1);
      c.text = p;
      expect(c.expandedText(), '[e:pog:$_hashA]');
    });

    test('multiple emotes expand independently and in order', () {
      final c = EmoteComposerController();
      final p1 = c.placeholderFor('one', _hashA);
      final p2 = c.placeholderFor('two', _hashB);
      c.text = '$p1 and $p2';
      expect(c.expandedText(), '[e:one:$_hashA] and [e:two:$_hashB]');
    });

    test('unmapped private-use chars are stripped at expansion', () {
      final c = EmoteComposerController();
      c.text = 'ab'; // never registered
      expect(c.expandedText(), 'ab');
    });

    test('clear() resets the emote map', () {
      final c = EmoteComposerController();
      final p = c.placeholderFor('gone', _hashA);
      c.text = p;
      c.clear();
      c.text = p; // same char, mapping wiped
      expect(c.expandedText(), '');
    });

    test('asset placeholder expands to [a:kind:hash:w:h] wire token', () {
      final c = EmoteComposerController();
      final p = c.placeholderForAsset('g', _hashA, 480, 270);
      expect(p.length, 1);
      c.text = 'look $p';
      expect(c.expandedText(), 'look [a:g:$_hashA:480:270]');
    });

    test('displayTextFor converts asset tokens too', () {
      final c = EmoteComposerController();
      final p = c.displayTextFor('[a:g:$_hashB:320:240]');
      expect(p.length, 1);
      c.text = p;
      expect(c.expandedText(), '[a:g:$_hashB:320:240]');
    });

    test('emotes and assets expand side by side, clear() wipes both', () {
      final c = EmoteComposerController();
      final e = c.placeholderFor('pog', _hashA);
      final a = c.placeholderForAsset('g', _hashB, 100, 100);
      c.text = '$e$a';
      expect(c.expandedText(), '[e:pog:$_hashA][a:g:$_hashB:100:100]');
      c.clear();
      c.text = '$e$a';
      expect(c.expandedText(), '');
    });
  });

  group('scanEmoteShortcode', () {
    const emotes = [ComposerEmote('monkaw', _hashA)];

    EmoteShortcodeScan? scan(String text, [int? cursor]) => scanEmoteShortcode(
        text: text, cursor: cursor ?? text.length, emotes: emotes);

    test('triggers on :xx at start and after whitespace', () {
      expect(scan(':mo'), isNotNull);
      expect(scan('hi :monk'), isNotNull);
      expect(scan(':mo')!.suggestions.first.name, 'monkaw');
    });

    test('does not trigger mid-word (5:30) or with 1 query char', () {
      expect(scan('5:30'), isNull);
      expect(scan(':m'), isNull);
    });

    test('does not trigger after the query is broken by a space', () {
      expect(scan(':mo hi'), isNull);
    });

    test('unicode emoji names match too', () {
      final s = scan(':fire');
      expect(s, isNotNull);
      expect(s!.suggestions.any((c) => c.char != null), isTrue);
    });

    test('custom emotes come before unicode matches', () {
      final s = scan(':monka');
      expect(s!.suggestions.first.hash, _hashA);
    });
  });

  group('acceptEmoteSuggestion', () {
    test('replaces :query with placeholder + trailing space', () {
      final c = EmoteComposerController();
      c.text = 'hi :monk';
      c.selection = TextSelection.collapsed(offset: c.text.length);
      final s =
          scanEmoteShortcode(text: c.text, cursor: 8, emotes: const [
        ComposerEmote('monkaw', _hashA),
      ])!;
      acceptEmoteSuggestion(
          controller: c, colonPos: s.colonPos, suggestion: s.suggestions.first);
      expect(c.expandedText(), 'hi [e:monkaw:$_hashA] ');
      expect(c.text.length, 'hi '.length + 2); // placeholder + space
      expect(c.selection.baseOffset, c.text.length);
    });

    test('unicode suggestion inserts the raw character', () {
      final c = EmoteComposerController();
      c.text = ':fire';
      c.selection = const TextSelection.collapsed(offset: 5);
      final s = scanEmoteShortcode(text: c.text, cursor: 5, emotes: const [])!;
      final uni = s.suggestions.firstWhere((x) => x.char != null);
      acceptEmoteSuggestion(
          controller: c, colonPos: s.colonPos, suggestion: uni);
      expect(c.text, '${uni.char} ');
    });
  });
}
