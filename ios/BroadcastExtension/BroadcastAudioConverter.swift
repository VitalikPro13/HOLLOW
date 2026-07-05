//
//  BroadcastAudioConverter.swift
//  BroadcastExtension
//
//  ReplayKit's .audioApp buffers arrive at whatever the sharing app plays
//  (typically 44.1 kHz, mono or stereo, int16 or float). The screen-share
//  audio pipeline is strictly 48 kHz stereo s16le end to end (Rust Opus
//  encoder, desktop decoders), so convert here with AVAudioConverter —
//  Apple's resampler, stateful across calls for seamless rate conversion.
//

import AVFoundation
import CoreMedia

class BroadcastAudioConverter {
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 48_000,
        channels: 2,
        interleaved: true)!

    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    /// Convert one CMSampleBuffer of app audio to interleaved 48 kHz stereo
    /// s16le bytes. Returns nil on any format/conversion hiccup (that buffer
    /// is skipped — a glitch, not a stream failure).
    func convertTo48kStereoS16(_ sampleBuffer: CMSampleBuffer) -> Data? {
        guard let formatDescription =
            CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(
                formatDescription)
        else { return nil }

        guard let inputFormat = AVAudioFormat(streamDescription: asbd) else {
            return nil
        }

        let frameCount = AVAudioFrameCount(
            CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return nil }

        // (Re)build the converter when the source format changes (app switch
        // mid-broadcast can change rate/channels).
        if converter == nil || converterInputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            converterInputFormat = inputFormat
        }
        guard let converter = converter else { return nil }

        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat, frameCapacity: frameCount) else { return nil }
        inputBuffer.frameLength = frameCount
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount),
            into: inputBuffer.mutableAudioBufferList)
        guard copyStatus == noErr else { return nil }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity =
            AVAudioFrameCount(Double(frameCount) * ratio) + 64
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat, frameCapacity: outputCapacity)
        else { return nil }

        var fed = false
        var conversionError: NSError?
        let status = converter.convert(
            to: outputBuffer, error: &conversionError
        ) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, conversionError == nil,
              outputBuffer.frameLength > 0,
              let channelData = outputBuffer.int16ChannelData
        else { return nil }

        // Interleaved output: all samples live in channelData[0].
        let byteCount = Int(outputBuffer.frameLength) *
            Int(outputFormat.channelCount) * MemoryLayout<Int16>.size
        return Data(bytes: channelData[0], count: byteCount)
    }
}
