//
//  SampleHandler.swift
//  BroadcastExtension
//
//  Hollow screen share: ReplayKit Broadcast Upload Extension. The system runs
//  this in a SEPARATE process while the user shares their screen (any app,
//  backgrounded Hollow included — the system-blessed path). Frames and app
//  audio hop to the Hollow app over TWO unix sockets in the shared App Group;
//  the app's flutter_webrtc plugin (FlutterBroadcastScreenCapturer) is the
//  socket SERVER for both:
//    rtc_SSFD       — video, CFHTTPMessage-framed JPEG (stock protocol)
//    rtc_SSFD_audio — app-audio PCM, [u32le len][payload] (Hollow fork; audio
//                     on the video socket wedges the stock parser — see
//                     AudioSampleUploader.swift)
//
//  Lifecycle adapted from the field-proven Jitsi Meet / LiveKit broadcast
//  extension (Apache-2.0): socket opens are RETRIED every 100 ms until the
//  app's servers exist, and a VIDEO-socket close (app quit / share stopped)
//  finishes the broadcast with a user-visible message. The audio socket is
//  best-effort — its loss never kills the broadcast.
//
//  Audio: .audioApp buffers -> 48 kHz stereo s16 PCM (AVAudioConverter) ->
//  audio socket -> app -> Rust Opus encode -> 0x03 data channel (identical to
//  every other platform's share audio). Mic (.audioMic) is deliberately
//  IGNORED — the voice call carries the mic, so the user talks over the
//  shared audio (mic-stays-unmuted design).
//

import ReplayKit

class SampleHandler: RPBroadcastSampleHandler {
    private enum Constants {
        static let appGroupIdentifier = "group.com.anonlisten.hollow"
        // Must match kRTCScreensharingSocketFD / kRTCScreensharingAudioSocketFD
        // in the flutter_webrtc fork.
        static let videoSocketFileName = "rtc_SSFD"
        static let audioSocketFileName = "rtc_SSFD_audio"
    }

    private var videoConnection: BroadcastSocketConnection?
    private var audioConnection: BroadcastSocketConnection?
    private var uploader: SampleUploader?
    private var audioUploader: AudioSampleUploader?
    private let audioConverter = BroadcastAudioConverter()

    private func socketFilePath(_ name: String) -> String {
        let sharedContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Constants.appGroupIdentifier)
        return sharedContainer?.appendingPathComponent(name).path ?? ""
    }

    override init() {
        super.init()
        if let connection = BroadcastSocketConnection(
            filePath: socketFilePath(Constants.videoSocketFileName)) {
            videoConnection = connection
            setupVideoConnection()
            uploader = SampleUploader(connection: connection)
        }
        if let connection = BroadcastSocketConnection(
            filePath: socketFilePath(Constants.audioSocketFileName)) {
            audioConnection = connection
            audioUploader = AudioSampleUploader(connection: connection)
        }
        NSLog("[HollowBroadcast] SampleHandler init")
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        NSLog("[HollowBroadcast] broadcast started")
        openConnection(videoConnection, label: "video")
        openConnection(audioConnection, label: "audio")
    }

    override func broadcastPaused() {
        // Screen locked or user paused: keep the sockets, just stop sending.
        uploader?.paused = true
        audioUploader?.paused = true
    }

    override func broadcastResumed() {
        uploader?.paused = false
        audioUploader?.paused = false
    }

    override func broadcastFinished() {
        NSLog("[HollowBroadcast] broadcast finished")
        videoConnection?.close()
        audioConnection?.close()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            uploader?.send(videoSample: sampleBuffer)
        case .audioApp:
            if let audioUploader = audioUploader,
               let pcm = audioConverter.convertTo48kStereoS16(sampleBuffer) {
                audioUploader.send(audioPcm: pcm)
            }
        case .audioMic:
            // Mic rides the voice call, never the share (talk over the audio).
            break
        @unknown default:
            break
        }
    }

    private func setupVideoConnection() {
        videoConnection?.didClose = { [weak self] error in
            NSLog("[HollowBroadcast] video connection closed (\(String(describing: error)))")
            if let error = error {
                self?.finishBroadcastWithError(error)
            } else {
                // The app stopped hosting (share ended / app quit).
                let customError = NSError(
                    domain: RPRecordingErrorDomain,
                    code: 10001,
                    userInfo: [NSLocalizedDescriptionKey: "Screen sharing stopped"])
                self?.finishBroadcastWithError(customError)
            }
        }
    }

    private func openConnection(_ connection: BroadcastSocketConnection?,
                                label: String) {
        guard let connection = connection else { return }
        // Retry until the app's socket server exists — tolerant of the user
        // starting the broadcast before/without Hollow hosting a share.
        let queue = DispatchQueue(
            label: "com.anonlisten.hollow.broadcast.connectTimer.\(label)")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100),
                       leeway: .milliseconds(500))
        timer.setEventHandler { [weak connection] in
            guard connection?.open() == true else { return }
            NSLog("[HollowBroadcast] \(label) socket connected")
            timer.cancel()
        }
        timer.resume()
    }
}
