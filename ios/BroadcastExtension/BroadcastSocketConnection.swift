//
//  BroadcastSocketConnection.swift
//  BroadcastExtension
//
//  Client side of the App-Group unix socket. The Hollow app's flutter_webrtc
//  plugin (FlutterSocketConnection) is the SERVER — it binds/listens at
//  <app group>/rtc_SSFD while a broadcast capture is active; this extension
//  connects and streams framed messages to it.
//
//  Faithful adaptation of the field-proven Jitsi Meet / LiveKit broadcast
//  extension SocketConnection (Apache-2.0): delegate-driven streams scheduled
//  on a GCD-hosted RunLoop BEFORE open, writes gated on .openCompleted via
//  didOpen, hasSpaceAvailable surfaced as a callback, and the input stream
//  kept alive solely to detect the server closing (app quit / share stopped).
//

import Foundation

class BroadcastSocketConnection: NSObject {
    var didOpen: (() -> Void)?
    var didClose: ((Error?) -> Void)?
    var streamHasSpaceAvailable: (() -> Void)?

    private let filePath: String
    private var socketHandle: Int32 = -1
    private var address: sockaddr_un?

    private var inputStream: InputStream?
    private var outputStream: OutputStream?

    private var networkQueue: DispatchQueue?
    private var shouldKeepRunning = false

    init?(filePath path: String) {
        filePath = path
        socketHandle = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketHandle != -1 else {
            NSLog("[HollowBroadcast] failure: create socket")
            return nil
        }
        super.init()
    }

    func open() -> Bool {
        NSLog("[HollowBroadcast] open socket connection")
        // The app creates the socket file when it starts hosting a share —
        // absence means "not yet"; the caller retries.
        guard FileManager.default.fileExists(atPath: filePath) else {
            NSLog("[HollowBroadcast] failure: socket file missing (app not hosting yet)")
            return false
        }
        guard setupAddress() else { return false }
        guard connectSocket() else { return false }

        setupStreams()
        inputStream?.open()
        outputStream?.open()
        return true
    }

    func close() {
        unscheduleStreams()

        inputStream?.delegate = nil
        outputStream?.delegate = nil

        inputStream?.close()
        outputStream?.close()

        inputStream = nil
        outputStream = nil
    }

    func writeToStream(buffer: UnsafePointer<UInt8>, maxLength length: Int) -> Int {
        return outputStream?.write(buffer, maxLength: length) ?? 0
    }
}

extension BroadcastSocketConnection: StreamDelegate {
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            NSLog("[HollowBroadcast] client stream open completed")
            if aStream == outputStream {
                didOpen?()
            }
        case .hasBytesAvailable:
            if aStream == inputStream {
                // The server never sends data — bytes/EOF here mean it closed.
                var buffer: UInt8 = 0
                let numberOfBytesRead = inputStream?.read(&buffer, maxLength: 1)
                if numberOfBytesRead == 0 && aStream.streamStatus == .atEnd {
                    NSLog("[HollowBroadcast] server socket closed")
                    close()
                    notifyDidClose(error: nil)
                }
            }
        case .hasSpaceAvailable:
            if aStream == outputStream {
                streamHasSpaceAvailable?()
            }
        case .errorOccurred:
            NSLog("[HollowBroadcast] client stream error: \(String(describing: aStream.streamError))")
            close()
            notifyDidClose(error: aStream.streamError)
        default:
            break
        }
    }
}

private extension BroadcastSocketConnection {
    func setupAddress() -> Bool {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard filePath.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            NSLog("[HollowBroadcast] failure: socket path too long")
            return false
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            filePath.withCString { strncpy(ptr, $0, filePath.count) }
        }
        address = addr
        return true
    }

    func connectSocket() -> Bool {
        guard var addr = address else { return false }
        let status = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketHandle, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == noErr else {
            NSLog("[HollowBroadcast] failure: connect (\(status))")
            return false
        }
        return true
    }

    func setupStreams() {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocket(kCFAllocatorDefault, socketHandle, &readStream, &writeStream)

        inputStream = readStream?.takeRetainedValue()
        inputStream?.delegate = self
        inputStream?.setProperty(kCFBooleanTrue,
                                 forKey: Stream.PropertyKey(
                                     kCFStreamPropertyShouldCloseNativeSocket as String))

        outputStream = writeStream?.takeRetainedValue()
        outputStream?.delegate = self
        outputStream?.setProperty(kCFBooleanTrue,
                                  forKey: Stream.PropertyKey(
                                      kCFStreamPropertyShouldCloseNativeSocket as String))

        scheduleStreams()
    }

    func scheduleStreams() {
        shouldKeepRunning = true
        networkQueue = DispatchQueue.global(qos: .userInitiated)
        networkQueue?.async { [weak self] in
            self?.inputStream?.schedule(in: .current, forMode: .common)
            self?.outputStream?.schedule(in: .current, forMode: .common)
            var isRunning = false
            repeat {
                isRunning = self?.shouldKeepRunning ?? false
                    && RunLoop.current.run(mode: .default, before: .distantFuture)
            } while isRunning
        }
    }

    func unscheduleStreams() {
        networkQueue?.sync { [weak self] in
            self?.inputStream?.remove(from: .current, forMode: .common)
            self?.outputStream?.remove(from: .current, forMode: .common)
        }
        shouldKeepRunning = false
    }

    func notifyDidClose(error: Error?) {
        didClose?(error)
    }
}
