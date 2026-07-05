//
//  AudioSampleUploader.swift
//  BroadcastExtension
//
//  App-audio PCM uploader for the DEDICATED rtc_SSFD_audio socket, framed as
//  [uint32_le length][pcm bytes] — a byte-accumulator protocol the app can
//  never desync on. (Audio must NOT ride the CFHTTPMessage video socket: a
//  read that completes one message and carries the start of the next inflates
//  the body past Content-Length and wedges the stock parser permanently —
//  device-proven 2026-07-04, exactly 4 packets then silence.)
//
//  Same write discipline as the video uploader: nothing before the output
//  stream's .openCompleted, one frame in flight, chunk writes driven by
//  hasSpaceAvailable events, bounded queue (drop-oldest — realtime audio
//  prefers a glitch over growing latency).
//

import Foundation

class AudioSampleUploader {
    private enum Constants {
        static let bufferMaxLength = 10240
        static let maxQueuedFrames = 50  // ~1s of 20ms PCM chunks
    }

    private let connection: BroadcastSocketConnection
    private let serialQueue: DispatchQueue

    // All mutable state below is touched ONLY on serialQueue.
    private var streamOpened = false
    private var pending: [Data] = []
    private var dataToSend: Data?
    private var byteIndex = 0

    var paused = false

    init(connection: BroadcastSocketConnection) {
        self.connection = connection
        self.serialQueue = DispatchQueue(label: "com.anonlisten.hollow.broadcast.audioUploader")
        setupConnection()
    }

    // Called on ReplayKit's audio queue.
    func send(audioPcm pcm: Data) {
        if paused || pcm.isEmpty { return }

        var frame = Data(capacity: 4 + pcm.count)
        var length = UInt32(pcm.count).littleEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(pcm)

        serialQueue.async { [weak self] in
            guard let self = self else { return }
            if self.pending.count >= Constants.maxQueuedFrames {
                self.pending.removeFirst()
            }
            self.pending.append(frame)
            self.pump()
        }
    }

    // MARK: Private (serialQueue only)

    private func setupConnection() {
        connection.didOpen = { [weak self] in
            self?.serialQueue.async {
                self?.streamOpened = true
                self?.pump()
            }
        }
        connection.streamHasSpaceAvailable = { [weak self] in
            self?.serialQueue.async {
                self?.pump()
            }
        }
    }

    private func pump() {
        guard streamOpened else { return }
        if dataToSend == nil {
            guard !pending.isEmpty else { return }
            dataToSend = pending.removeFirst()
            byteIndex = 0
        }
        sendDataChunk()
    }

    private func sendDataChunk() {
        guard let data = dataToSend else { return }

        var bytesLeft = data.count - byteIndex
        var length = bytesLeft > Constants.bufferMaxLength
            ? Constants.bufferMaxLength : bytesLeft
        length = data[byteIndex..<(byteIndex + length)].withUnsafeBytes {
            guard let ptr = $0.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return connection.writeToStream(buffer: ptr, maxLength: length)
        }

        if length > 0 {
            byteIndex += length
            bytesLeft -= length
            if bytesLeft == 0 {
                dataToSend = nil
                byteIndex = 0
                // Drain any backlog immediately; a failed/blocked write ends
                // the cascade and the next hasSpaceAvailable resumes it.
                pump()
            }
        } else {
            NSLog("[HollowBroadcastAudio] writeToStream failure")
        }
    }
}
