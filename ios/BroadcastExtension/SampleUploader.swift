//
//  SampleUploader.swift
//  BroadcastExtension
//
//  VIDEO-ONLY uploader for the rtc_SSFD socket — a faithful adaptation of the
//  field-proven Jitsi Meet / LiveKit broadcast extension SampleUploader
//  (Apache-2.0). Frames every message the way the app's
//  FlutterSocketConnectionFrameReader parses it: a serialized CFHTTPMessage
//  RESPONSE ("HTTP/1.1 200 OK" + Buffer-Width/Height/Orientation +
//  Content-Length + JPEG body).
//
//  Audio deliberately does NOT ride this socket (see AudioSampleUploader):
//  the reader's CFHTTPMessage parser wedges permanently when a read carries
//  bytes of the NEXT message past the current one's Content-Length — fine
//  for one-big-frame-in-flight video, fatal for small back-to-back audio.
//
//  Writes start only after the output stream reports .openCompleted, ONE
//  message is in flight at a time, sent in <=10240-byte chunks driven by
//  hasSpaceAvailable events; frames are DROPPED while a message is in flight
//  (realtime wants the newest frame). Every 3rd frame + 2x downscale keeps
//  the extension under its hard ~50 MB memory ceiling (the Jitsi cadence).
//

import CoreImage
import CoreMedia
import ReplayKit

class SampleUploader {
    private enum Constants {
        static let bufferMaxLength = 10240
    }

    // CIContext is costly — one per process.
    private static var imageContext = CIContext(options: nil)

    private let connection: BroadcastSocketConnection
    private let serialQueue: DispatchQueue

    // All mutable state below is touched ONLY on serialQueue.
    private var streamOpened = false
    private var dataToSend: Data?
    private var byteIndex = 0

    private var frameCount = 0
    var paused = false

    init(connection: BroadcastSocketConnection) {
        self.connection = connection
        self.serialQueue = DispatchQueue(label: "com.anonlisten.hollow.broadcast.sampleUploader")
        setupConnection()
    }

    // Called on ReplayKit's queue.
    func send(videoSample sampleBuffer: CMSampleBuffer) {
        if paused { return }
        // Every 3rd frame: the simple frame-rate/memory valve the reference
        // uses (ReplayKit buffers spike memory if we fall behind).
        frameCount += 1
        guard frameCount % 3 == 0 else { return }

        var busy = false
        serialQueue.sync { busy = dataToSend != nil || !streamOpened }
        // Drop while busy — a screen share wants the NEWEST frame, not a queue.
        if busy { return }

        guard let message = prepare(sample: sampleBuffer) else { return }
        serialQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.dataToSend == nil else { return }
            self.dataToSend = message
            self.byteIndex = 0
            self.sendDataChunk()
        }
    }

    // MARK: Private (serialQueue only)

    private func setupConnection() {
        connection.didOpen = { [weak self] in
            self?.serialQueue.async {
                self?.streamOpened = true
                self?.sendDataChunk()
            }
        }
        connection.streamHasSpaceAvailable = { [weak self] in
            self?.serialQueue.async {
                self?.sendDataChunk()
            }
        }
    }

    /// Write ONE chunk of the in-flight message (reference cadence: the next
    /// chunk rides the next hasSpaceAvailable event).
    private func sendDataChunk() {
        guard streamOpened, let data = dataToSend else { return }

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
            }
        } else {
            NSLog("[HollowBroadcast] video writeToStream failure")
        }
    }

    private func prepare(sample buffer: CMSampleBuffer) -> Data? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(buffer) else {
            return nil
        }
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)

        let scaleFactor = 2.0
        let width = CVPixelBufferGetWidth(imageBuffer) / Int(scaleFactor)
        let height = CVPixelBufferGetHeight(imageBuffer) / Int(scaleFactor)
        let orientationAttachment = CMGetAttachment(
            buffer, key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: nil) as? NSNumber
        let orientation = orientationAttachment?.uintValue ?? 0

        let scaleTransform = CGAffineTransform(
            scaleX: CGFloat(1.0 / scaleFactor), y: CGFloat(1.0 / scaleFactor))
        let bufferData = jpegData(from: imageBuffer, scale: scaleTransform)

        CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly)

        guard let messageData = bufferData else {
            NSLog("[HollowBroadcast] corrupted image buffer")
            return nil
        }

        // One serialized HTTP/1.1 200 RESPONSE — exactly what the app's
        // CFHTTPMessageCreateEmpty(isRequest:false) parser expects.
        let httpResponse = CFHTTPMessageCreateResponse(
            kCFAllocatorDefault, 200, nil, kCFHTTPVersion1_1).takeRetainedValue()
        CFHTTPMessageSetHeaderFieldValue(
            httpResponse, "Content-Length" as CFString,
            String(messageData.count) as CFString)
        CFHTTPMessageSetHeaderFieldValue(
            httpResponse, "Buffer-Width" as CFString, String(width) as CFString)
        CFHTTPMessageSetHeaderFieldValue(
            httpResponse, "Buffer-Height" as CFString, String(height) as CFString)
        CFHTTPMessageSetHeaderFieldValue(
            httpResponse, "Buffer-Orientation" as CFString,
            String(orientation) as CFString)
        CFHTTPMessageSetBody(httpResponse, messageData as CFData)

        return CFHTTPMessageCopySerializedMessage(httpResponse)?
            .takeRetainedValue() as Data?
    }

    private func jpegData(from buffer: CVPixelBuffer,
                          scale scaleTransform: CGAffineTransform) -> Data? {
        var image = CIImage(cvPixelBuffer: buffer)
        image = image.transformed(by: scaleTransform)
        guard let colorSpace = image.colorSpace else { return nil }
        let options: [CIImageRepresentationOption: Float] =
            [kCGImageDestinationLossyCompressionQuality
                as CIImageRepresentationOption: 1.0]
        return SampleUploader.imageContext.jpegRepresentation(
            of: image, colorSpace: colorSpace, options: options)
    }
}
