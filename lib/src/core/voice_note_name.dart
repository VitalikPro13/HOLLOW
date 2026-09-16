/// True when [fileName] is a recorded voice message. Voice notes are exempt
/// from the auto-download gate on every path. Matches both the UI display name
/// and the recorder's wire basename; keep in sync with the Rust twin.
///
/// A name is not evidence: the sender picks it. Anything that ACTS on the
/// answer must use `isGenuineVoiceNote` instead.
bool isVoiceMessageFile(String fileName) {
  return fileName == 'Voice message.ogg' ||
      (fileName.startsWith('voice_') && fileName.endsWith('.ogg'));
}
