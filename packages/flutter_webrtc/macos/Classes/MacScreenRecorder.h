#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Records the primary display to an MP4 (H.264 + AAC) via ScreenCaptureKit
/// and AVAssetWriter — no ffmpeg involved. Audio is taken from a CoreAudio
/// aggregate device that mixes the user's microphone with system audio
/// output (other call participants, music, alerts) via macOS 14.2+ Process
/// Tap. If the tap can't be created (older macOS or permission denied),
/// falls back to recording the default mic only.
///
/// Singleton. One recording at a time.
@interface MacScreenRecorder : NSObject

+ (instancetype)sharedInstance;

/// Begin recording to [outputPath]. Returns an error via [completion] if
/// setup fails; otherwise the recorder is running and [completion] gets nil.
- (void)startWithOutputPath:(NSString *)outputPath
                 completion:(void (^)(NSError * _Nullable error))completion;

/// Stop the current recording. [completion] fires once the MP4 has been
/// finalized (moov atom written). Safe to call when not recording — runs
/// the completion with `nil` error.
- (void)stopWithCompletion:(void (^)(NSError * _Nullable error))completion;

@property(nonatomic, readonly, getter=isRecording) BOOL recording;

/// Whether the last recording captured system audio (the Process Tap path).
/// Set after [startWithOutputPath:completion:] succeeds.
@property(nonatomic, readonly) BOOL lastRecordingCapturedSystemAudio;

@end

NS_ASSUME_NONNULL_END
