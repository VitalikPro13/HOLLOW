import 'package:hollow/src/core/message_tokens.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/voice_note_name.dart';

/// Mirror of `_videoExtensions` in `lib/src/ui/chat/file_attachment_widget.dart`.
const _videoExtensions = {'mp4', 'webm', 'mov', 'mkv', 'avi', 'm4v'};

/// Preview of a message for lists, reply bars and notifications.
///
/// Tokens are replaced in place, so a caption around them survives; with no
/// [attachment] a file token can only say "File". Never contains an emoji
/// glyph. Pass [singleLine] false for a surface that renders several lines
/// (a pinned list): line breaks then survive instead of becoming spaces.
String messagePreviewText(String text,
    {FileAttachment? attachment, bool singleLine = true}) {
  final label = attachment == null ? 'File' : _attachmentLabel(attachment);
  final replaced = text
      .replaceAll(fileTokenRegex, label)
      .replaceAllMapped(emoteTokenRegex, (m) => ':${m.group(1)}:')
      .replaceAllMapped(
          assetTokenRegex, (m) => m.group(1) == 'g' ? 'GIF' : 'Sticker');
  final out =
      singleLine ? _oneLine(replaced) : _keepingLineBreaks(replaced);
  if (out.isEmpty && attachment != null) return label;
  return out;
}

String _oneLine(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

String _keepingLineBreaks(String s) => s
    .split(RegExp(r'\r\n?|\n'))
    .map((line) => line.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
    .join('\n')
    .replaceAll(RegExp(r'\n{2,}'), '\n')
    .trim();

String _attachmentLabel(FileAttachment a) {
  final ext = a.fileExt.toLowerCase();
  if (ext == 'gif') return 'GIF';
  if (a.isImage) return 'Photo';
  if (_videoExtensions.contains(ext)) return 'Video';
  // A shared song is not a voice note, and the predicate already pins the
  // recorder's two name shapes, so the audio extensions stay out of it.
  if (isVoiceMessageFile(a.fileName)) return 'Voice message';
  return a.fileName;
}

/// Preview for a whole album: what kind of files, and how many.
///
/// A caption on the album wins, since it says more than a count does.
String albumPreviewText(List<FileAttachment?> attachments, {String caption = ''}) {
  final captionText = messagePreviewText(caption.replaceAll(fileTokenRegex, ''));
  if (captionText.isNotEmpty) return captionText;
  final n = attachments.length;
  var images = 0;
  var videos = 0;
  for (final a in attachments) {
    if (a == null) continue;
    if (a.isImage) {
      images++;
    } else if (_videoExtensions.contains(a.fileExt.toLowerCase())) {
      videos++;
    }
  }
  if (images == n) return '$n photos';
  if (videos == n) return '$n videos';
  if (images + videos == n) return '$n photos and videos';
  return '$n files';
}

/// A DM row's own preview, so a conversation list never reaches for the raw
/// text and its attachment separately.
extension ChatMessagePreview on ChatMessage {
  String get previewText =>
      messagePreviewText(text, attachment: fileAttachment);
}
