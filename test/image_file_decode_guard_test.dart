/// AR-28: a file on disk reaches Flutter's decoder only through `AttachmentImage`
/// (Rust's image check first), never `Image.file` or `FileImage`, which decode any
/// bytes natively. Bytes in memory reach it only at the sites listed below, each
/// with where its bytes come from.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every way lib/ hands encoded bytes to Skia, plus the public widgets and helpers
/// that take bytes and decode them and the caches those widgets paint from, so a
/// new caller counts as a new site too. Tear-offs count like calls.
final _rawDecode = RegExp(
  r'\b(?:MemoryImage|NetworkImage|AnimatedGifImage|ShowcaseCover'
  r'|ShowcaseArtwork|ShowcaseWideArtwork|ShowcaseBlockView)\s*(?:\(|\.\s*new\b)'
  r'|\b(?:Image\s*\.\s*(?:memory|network)|FadeInImage\s*\.\s*memory\w*'
  r'|instantiateImageCodec\w*|decodeImageFromList'
  r'|ImmutableBuffer\s*\.\s*from\w+|ImageDescriptor\s*\.\s*\w+'
  r'|showGameCardDialog|showcaseImageStats)\b'
  r'|\bimageBytes\s*:'
  r'|\.\s*(?:setAvatar|seed|applyLocalWrite)\s*\('
  r'|\bguestServer\w*Provider\s*\.\s*notifier\s*\)\s*\.\s*'
  r'(?:state\s*=(?!=)|update\s*\()',
);

/// Gated = the bytes passed `image_gate` (`shown`, `rail_blob_shown`,
/// `read_at_rest_image`, `judge_for_ffi`, `guest_event_checked`) or Rust's own
/// re-encode (`peer_thumb_for_display`). Own = bytes this device picked, captured
/// or encoded. Catalog = a server our own search asked, never a peer.
const _allowed = <String, (int, String)>{
  'lib/src/core/providers/event_provider.dart': (3,
      'gated: guest server icon, banner and sender avatars (guest_event_checked)'),
  'lib/src/core/providers/owned_art_provider.dart':
      (4, 'gated: worn shop art via get_emote_bytes (rail_blob_shown)'),
  'lib/src/core/providers/profile_draft_provider.dart':
      (1, 'own: our animation as process_and_store re-encoded it'),
  'lib/src/core/providers/background_provider.dart':
      (3, 'own: the chat background the user picked'),
  'lib/src/ui/chat/dm_profile_panel.dart':
      (1, 'gated: banner via get_banner, its animation via rail_blob_shown'),
  'lib/src/ui/chat/emoji_picker.dart':
      (2, 'catalog: FFZ search thumbs; own: the picked file before processing'),
  'lib/src/ui/chat/emote_image.dart':
      (2, 'gated: rail blobs via get_emote_bytes (rail_blob_shown)'),
  'lib/src/ui/chat/file_attachment_widget.dart':
      (1, 'gated: the blur thumb is re-encoded by peer_thumb_for_display'),
  'lib/src/ui/chat/gif_picker.dart':
      (2, 'catalog: GIF search previews (Klipy via proxy, host-checked)'),
  'lib/src/ui/chat/link_preview_card.dart':
      (2, 'gated: the card thumb is re-encoded by peer_thumb_for_display'),
  'lib/src/ui/chat/staged_link_preview_card.dart':
      (1, 'own: our fetcher built the card with our encoder'),
  'lib/src/ui/chat/sticker_picker.dart':
      (2, 'catalog: sticker search previews (Klipy via proxy, host-checked)'),
  'lib/src/ui/chat/video_message_bubble.dart':
      (2, 'gated: the poster is re-encoded by peer_thumb_for_display'),
  'lib/src/ui/components/animated_gif_image.dart':
      (2, 'the widget itself; every caller is counted here'),
  'lib/src/ui/components/attachment_image.dart':
      (2, 'gated: AtRestImageProvider reads via read_at_rest_image'),
  'lib/src/ui/components/avatar_frame.dart':
      (2, 'gated: frame art via get_emote_bytes; seeded from the callers listed'),
  'lib/src/ui/components/hollow_avatar.dart':
      (4, 'gated: get_avatar and the rail; imageBytes only from own callers'),
  'lib/src/ui/components/profile_identity_column.dart':
      (1, 'gated: banner via get_banner, its animation via rail_blob_shown'),
  'lib/src/ui/components/server_folder_popup.dart':
      (1, 'gated: server icons via get_server_avatar (shown)'),
  'lib/src/ui/components/server_icon_image.dart':
      (2, 'gated: get_server_avatar (shown) and get_server_avatar_anim (rail)'),
  'lib/src/ui/components/showcase_blocks.dart':
      (16, 'gated: get_showcase_assets (judge_for_ffi); own: the editor draft'),
  'lib/src/ui/components/showcase_image_stats.dart':
      (2, 'the helper itself; its one caller is game_card_dialog'),
  'lib/src/ui/dialogs/avatar_frame_picker.dart':
      (1, 'own: our frame as process_and_store re-encoded it'),
  'lib/src/ui/dialogs/game_card_dialog.dart':
      (5, 'gated: showcase assets passed in by showcase_blocks'),
  'lib/src/ui/dialogs/image_crop_dialog.dart':
      (3, 'own: the image the user picked to crop'),
  'lib/src/ui/dialogs/screen_share_dialog.dart':
      (1, 'own: thumbnails of our own capture sources'),
  'lib/src/ui/dialogs/showcase_editor.dart':
      (2, 'own: the editor draft (own assets and own processed picks)'),
  'lib/src/ui/dialogs/showcase_editor_blocks.dart':
      (3, 'own: the editor draft (own assets and own processed picks)'),
  'lib/src/ui/dialogs/showcase_editor_phone.dart':
      (2, 'own: the editor draft (own assets and own processed picks)'),
  'lib/src/ui/dialogs/showcase_editor_search.dart':
      (1, 'catalog: IGDB covers in the editor search'),
  'lib/src/ui/guest/guest_server_sidebar.dart':
      (2, 'gated: guest_event_checked, else the member caches above'),
  'lib/src/ui/media/media_strip.dart':
      (1, 'gated: the poster is re-encoded by peer_thumb_for_display'),
  'lib/src/ui/media/media_video_page.dart':
      (1, 'gated: the poster is re-encoded by peer_thumb_for_display'),
  'lib/src/ui/mobile/mobile_chat_route.dart':
      (1, 'own: the chat background the user picked'),
  'lib/src/ui/mobile/mobile_image_crop_route.dart':
      (3, 'own: the image the user picked to crop'),
  'lib/src/ui/mobile/mobile_shell.dart':
      (1, 'own: the chat background the user picked'),
  'lib/src/ui/server_settings/pages/overview_page.dart':
      (11, 'own: the picked icon or banner, seeded as sent; gated: the rail'),
  'lib/src/ui/settings/appearance_section.dart':
      (1, 'own: the background the user picked to crop'),
  'lib/src/ui/settings/pages/profile_page.dart':
      (4, 'own: the profile draft; gated: our banner via get_banner'),
  'lib/src/ui/settings/profile_section.dart':
      (2, 'own: the profile draft; gated: our banner via get_banner'),
  'lib/src/ui/settings/stream_overlay/overlay_look_editor.dart':
      (2, 'gated: overlay_image_bytes (shown)'),
  'lib/src/ui/shell/channel_sidebar.dart':
      (1, 'gated: the server banner via get_server_banner (rail)'),
  'lib/src/ui/shell/hollow_shell.dart':
      (1, 'own: the chat background the user picked'),
  'lib/src/ui/shop/hollowpack_import.dart':
      (2, 'gated: what the import stored, via get_emote_bytes'),
  'lib/src/ui/shop/owned_art_panel.dart':
      (3, 'gated: owned art and seeded frames via get_emote_bytes'),
  'lib/src/ui/shop/shop_art.dart':
      (5, 'catalog: shop art and its seeded frame (check_art_bytes); gated: our banner'),
};

/// Raw-decode sites in [source], comment lines left out; a call may span lines.
int rawDecodeSites(String source) => _rawDecode
    .allMatches(source
        .replaceAll('\r\n', '\n')
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n'))
    .length;

void main() {
  test('no widget decodes a file straight from disk', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart') || f.path.contains('/rust/')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        if (line.contains('Image.file(') || line.contains('FileImage(')) {
          offenders.add('${f.path}:${i + 1}');
        }
      }
    }
    expect(offenders, isEmpty);
  });

  test('the scan sees every raw decode form and skips comments', () {
    expect(rawDecodeSites('Image.memory(b)'), 1);
    expect(rawDecodeSites('Image .memory (b)'), 1);
    expect(rawDecodeSites('image: MemoryImage(b)'), 1);
    expect(rawDecodeSites('Image.network(u)'), 1);
    expect(rawDecodeSites('await ui.instantiateImageCodec(b, targetWidth: 4)'), 1);
    expect(rawDecodeSites('ui.instantiateImageCodecFromBuffer(buf)'), 1);
    expect(rawDecodeSites('decodeImageFromList(b)'), 1);
    expect(rawDecodeSites('ui.ImmutableBuffer.fromUint8List(b)'), 1);
    expect(rawDecodeSites('ui.ImageDescriptor.encoded(buf)'), 1);
    expect(rawDecodeSites('AnimatedGifImage(bytes: b)'), 1);
    expect(rawDecodeSites('HollowAvatar(peerId: p, imageBytes: b)'), 1);
    expect(rawDecodeSites('// Image.memory(b)\n  /// AnimatedGifImage(bytes: b)'), 0);
    expect(rawDecodeSites('Image(image: AtRestImageProvider(p))'), 0);
    expect(rawDecodeSites('AttachmentImage(path: p)\r\nChatAssetImage(hash: h)'), 0);
    expect(rawDecodeSites('final MemoryImage? cached;\nvoid seed(String h) {}'), 0);
  });

  test('the scan sees tear-offs, split calls and the caches widgets paint from',
      () {
    for (final site in [
      'decode(await ui.ImmutableBuffer.fromFilePath(path))',
      'bytes.map(MemoryImage.new)',
      'MemoryImage.new(bytes)',
      'FadeInImage.memoryNetwork(placeholder: bytes, image: url)',
      'ref.read(avatarProvider.notifier).setAvatar(peer, bytes)',
      'ref.read(avatarFrameProvider.notifier).seed(hash, bytes)',
      'ref.read(serverAvatarProvider.notifier).applyLocalWrite(sid, bytes)',
      'Image\n    .memory(bytes)',
      'items.map(Image.memory)',
      'ref.read(profileAnimProvider.notifier).seed(hash, bytes)',
      'ref.read(serverBannerProvider.notifier).applyLocalWrite(sid, bytes)',
      'ref.read(guestServerAvatarProvider.notifier).state = map',
      'ref.read(guestServerBannerProvider.notifier).update((m) => m)',
    ]) {
      expect(rawDecodeSites(site), 1, reason: site);
    }
    expect(rawDecodeSites('if (ref.read(guestServerAvatarProvider.notifier).state == m) {}'),
        0);
  });

  test('every raw-bytes decode site is listed with where its bytes come from',
      () {
    final found = <String, int>{};
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = f.path.replaceAll(r'\', '/');
      if (!path.endsWith('.dart') || path.startsWith('lib/src/rust/')) continue;
      final n = rawDecodeSites(f.readAsStringSync());
      if (n > 0) found[path] = n;
    }
    final drift = <String>[
      for (final e in found.entries)
        if (_allowed[e.key]?.$1 != e.value)
          '${e.key}: ${e.value} site(s), listed ${_allowed[e.key]?.$1 ?? 0}',
      for (final path in _allowed.keys)
        if (!found.containsKey(path)) '$path: listed but has no site now',
    ];
    expect(drift, isEmpty,
        reason: 'A peer image reaches Skia only after image_gate (AR-28). '
            'Route new bytes through it (AttachmentImage, emoteBytesProvider, '
            'the gated FFI getters), then list the site here with its source.');
  });
}
