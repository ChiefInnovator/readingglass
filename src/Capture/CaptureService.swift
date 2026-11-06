import Foundation
import CoreMedia
import CoreVideo
import CoreGraphics
@preconcurrency import ScreenCaptureKit

struct CaptureConfiguration: Sendable {
    let display: DisplayGeometry
    let rect: CGRect
    let stamp: RevisionStamp
}

enum CaptureError: LocalizedError, Sendable {
    case displayUnavailable
    case applicationExclusionUnavailable
    case invalidFrame
    case streamFailed(code: Int)

    var errorDescription: String? {
        switch self {
        case .displayUnavailable:
            "The selected display is no longer available. Select another display."
        case .applicationExclusionUnavailable:
            "ReadingGlass could not exclude its own windows. Capture has stopped."
        case .invalidFrame:
            "Screen capture returned an invalid image. Try resuming capture."
        case .streamFailed(let code):
            "Screen capture stopped (code \(code)). Check Screen Recording permission and resume."
        }
    }
}

actor CaptureService {
    private struct Session {
        let stream: SCStream
        let output: FrameOutput
    }

    private var generation: UInt64 = 0
    private var session: Session?

    /// Ask the capture API itself to verify consent. A Core Graphics preflight
    /// alone is not authoritative for a ScreenCaptureKit capture session.
    func verifyAccess() async throws {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !content.displays.isEmpty else { throw CaptureError.displayUnavailable }
        } catch let error as CaptureError {
            throw error
        } catch {
            throw CaptureError.streamFailed(code: (error as NSError).code)
        }
    }

    /// A fresh one-shot image, independent of translation or pause state.
    func screenshot(configuration: CaptureConfiguration) async throws -> RasterSurface {
        try Task.checkCancellation()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == configuration.display.id }) else {
            throw CaptureError.displayUnavailable
        }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        guard !ownApps.isEmpty else { throw CaptureError.applicationExclusionUnavailable }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let settings = SCStreamConfiguration()
        settings.sourceRect = try CaptureGeometry.sourceRect(glassFrame: configuration.rect, display: configuration.display)
        let pixels = CaptureGeometry.pixelSize(for: configuration.rect, scale: configuration.display.scale)
        guard pixels.width > 0, pixels.height > 0 else { throw CaptureError.invalidFrame }
        settings.width = Int(pixels.width)
        settings.height = Int(pixels.height)
        settings.showsCursor = false
        settings.showMouseClicks = false
        settings.shouldBeOpaque = true
        settings.pixelFormat = kCVPixelFormatType_32BGRA
        settings.colorSpaceName = CGColorSpace.sRGB
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: settings)
        try Task.checkCancellation()
        guard image.width > 0, image.height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                  bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw CaptureError.invalidFrame
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let bytes = context.data else { throw CaptureError.invalidFrame }
        return RasterSurface(size: PixelSize(width: image.width, height: image.height), bytesPerRow: image.width * 4,
                             pixels: Data(bytes: bytes, count: image.width * image.height * 4))
    }

    /// A stream belongs to one immutable geometry revision. Repositioning stops
    /// and replaces the stream rather than relabelling in-flight old frames.
    func start(configuration: CaptureConfiguration) async throws
        -> AsyncThrowingStream<CapturedFrame, Error> {
        try Task.checkCancellation()
        generation &+= 1
        let token = generation
        let previous = session
        session = nil
        previous?.output.finish()
        if let previous { try? await previous.stream.stopCapture() }
        try ensureCurrent(token)

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw CaptureError.streamFailed(code: (error as NSError).code)
        }
        try ensureCurrent(token)
        guard let display = content.displays.first(where: { $0.displayID == configuration.display.id }) else {
            throw CaptureError.displayUnavailable
        }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        guard !ownApps.isEmpty else { throw CaptureError.applicationExclusionUnavailable }

        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let settings = SCStreamConfiguration()
        settings.sourceRect = try CaptureGeometry.sourceRect(glassFrame: configuration.rect, display: configuration.display)
        let size = CaptureGeometry.pixelSize(for: configuration.rect, scale: configuration.display.scale)
        guard size.width > 0, size.height > 0 else { throw CaptureError.invalidFrame }
        settings.width = Int(size.width)
        settings.height = Int(size.height)
        settings.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        settings.queueDepth = 3
        settings.showsCursor = false
        settings.showMouseClicks = false
        settings.capturesAudio = false
        settings.captureMicrophone = false
        settings.pixelFormat = kCVPixelFormatType_32BGRA
        settings.colorSpaceName = CGColorSpace.sRGB
        settings.shouldBeOpaque = true
        settings.captureResolution = .best

        let (frames, continuation) = AsyncThrowingStream<CapturedFrame, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let output = FrameOutput(configuration: configuration, continuation: continuation)
        let stream = SCStream(filter: filter, configuration: settings, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stop(ifCurrent: token) }
        }
        session = Session(stream: stream, output: output)
        do {
            try await stream.startCapture()
            try ensureCurrent(token)
            return frames
        } catch {
            if token == generation { session = nil }
            output.finish()
            try? await stream.stopCapture()
            if error is CancellationError { throw error }
            throw CaptureError.streamFailed(code: (error as NSError).code)
        }
    }

    func stop() async {
        generation &+= 1
        let old = session
        session = nil
        old?.output.finish()
        if let old { try? await old.stream.stopCapture() }
    }

    private func stop(ifCurrent token: UInt64) async {
        guard generation == token else { return }
        await stop()
    }

    private func ensureCurrent(_ token: UInt64) throws {
        guard token == generation, !Task.isCancelled else { throw CancellationError() }
    }
}

/// ScreenCaptureKit calls on a private serial queue. The only mutable state
/// touched by delegate/termination callbacks is protected by stateLock.
private final class FrameOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.readingglass.capture", qos: .userInitiated)
    private let configuration: CaptureConfiguration
    private let continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation
    private let stateLock = NSLock()
    private var ended = false
    private var sequence: UInt64 = 0

    init(configuration: CaptureConfiguration, continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation) {
        self.configuration = configuration
        self.continuation = continuation
    }

    func finish(throwing error: Error? = nil) {
        let shouldFinish = stateLock.withLock {
            guard !ended else { return false }
            ended = true
            return true
        }
        if shouldFinish { continuation.finish(throwing: error) }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        finish(throwing: CaptureError.streamFailed(code: (error as NSError).code))
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let buffer = sampleBuffer.imageBuffer else { return }
        let nextSequence: UInt64? = stateLock.withLock {
            guard !ended else { return nil }
            sequence &+= 1
            return sequence
        }
        guard let nextSequence else { return }
        autoreleasepool {
            do {
                let surface = try Self.copySurface(buffer)
                let rect = configuration.rect
                let expected = CaptureGeometry.pixelSize(for: rect, scale: configuration.display.scale)
                guard surface.size.width == Int(expected.width), surface.size.height == Int(expected.height) else {
                    throw CaptureError.invalidFrame
                }
                let frame = CapturedFrame(
                    id: FrameID(sequence: nextSequence, capturedAtNanoseconds: DispatchTime.now().uptimeNanoseconds),
                    stamp: configuration.stamp,
                    displayID: configuration.display.id,
                    captureRectGlobalPoints: PointRect(rect),
                    surface: surface,
                    scaleX: Double(surface.size.width) / rect.width,
                    scaleY: Double(surface.size.height) / rect.height
                )
                continuation.yield(frame)
            } catch {
                finish(throwing: CaptureError.invalidFrame)
            }
        }
    }

    private static func copySurface(_ buffer: CVPixelBuffer) throws -> RasterSurface {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw CaptureError.invalidFrame
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let sourceStride = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, width <= Int.max / 4,
              height <= Int.max / (width * 4), sourceStride >= width * 4,
              let source = CVPixelBufferGetBaseAddress(buffer) else { throw CaptureError.invalidFrame }
        let stride = width * 4
        var pixels = Data(count: stride * height)
        pixels.withUnsafeMutableBytes { destination in
            guard let base = destination.baseAddress else { return }
            for row in 0..<height {
                base.advanced(by: row * stride).copyMemory(from: source.advanced(by: row * sourceStride), byteCount: stride)
            }
        }
        return RasterSurface(size: PixelSize(width: width, height: height), bytesPerRow: stride, pixels: pixels)
    }
}
