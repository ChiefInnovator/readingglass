import CryptoKit
import Darwin
import Foundation

enum PipelineEvent: Sendable {
    case pending(RevisionStamp, UInt64)
    case recognized(OCRResult, UInt64)
    case failed(RevisionStamp, UInt64, String)
}

/// One executing recognition and one replaceable pending frame, even across
/// geometry changes. A cancelled generation never publishes its old result.
actor ReadingPipeline {
    typealias EventHandler = @MainActor @Sendable (PipelineEvent) -> Void
    private struct Work {
        let frame: CapturedFrame
        let generation: UInt64
        let sourceRevision: UInt64
    }

    private let recognizer: any Recognizing
    private let onEvent: EventHandler
    private let minimumInterval: Duration
    private var stamp: RevisionStamp?
    private var generation: UInt64 = 0
    private var sourceRevision: UInt64 = 0
    private var digest: SHA256.Digest?
    private var pending: Work?
    private var worker: Task<Void, Never>?
    private var latestFrame: CapturedFrame?
    private var reference: OCRResult?
    private let clock = ContinuousClock()
    private var lastScheduledAt: ContinuousClock.Instant?

    init(recognizer: any Recognizing, minimumInterval: Duration = .milliseconds(125),
         onEvent: @escaping EventHandler) {
        self.recognizer = recognizer
        self.minimumInterval = minimumInterval
        self.onEvent = onEvent
    }

    func activate(stamp: RevisionStamp) {
        generation &+= 1
        self.stamp = stamp
        pending = nil
        digest = nil
        sourceRevision = 0
        latestFrame = nil
        reference = nil
        lastScheduledAt = nil
    }

    func stop() {
        generation &+= 1
        stamp = nil
        pending = nil
        digest = nil
        latestFrame = nil
        reference = nil
        lastScheduledAt = nil
    }

    func consume(_ frame: CapturedFrame) async {
        guard frame.stamp == stamp else { return }
        let newDigest = SHA256.hash(data: frame.surface.pixels)
        guard newDigest != digest else { return }
        digest = newDigest
        latestFrame = frame
        let textUnchanged = reference.map { Self.textPixelsMatch($0, frame) } ?? false
        if textUnchanged, let lastScheduledAt, lastScheduledAt.duration(to: clock.now) < .seconds(1) {
            return
        }
        if !textUnchanged { sourceRevision &+= 1 }
        let work = Work(frame: frame, generation: generation, sourceRevision: sourceRevision)
        pending = work
        lastScheduledAt = clock.now
        if !textUnchanged { await onEvent(.pending(frame.stamp, work.sourceRevision)) }
        guard work.generation == generation, stamp != nil else { return }
        if worker == nil {
            worker = Task { await self.processQueue() }
        }
    }

    func waitUntilIdle() async { await worker?.value }

    private func processQueue() async {
        while pending != nil {
            // Throttle recognition without blocking delivery of fresher frames.
            if minimumInterval > .zero { try? await Task.sleep(for: minimumInterval) }
            guard let work = pending else { break }
            pending = nil
            do {
                let result = try await recognizer.recognize(work.frame)
                guard work.generation == generation, work.frame.stamp == stamp,
                      let latestFrame else { continue }
                let stableLines = latestFrame.id == work.frame.id ? result.lines : result.lines.filter { line in
                    Self.textPixelsMatch(OCRResult(frame: result.frame, lines: [line],
                        supportedLanguages: result.supportedLanguages, elapsedSeconds: result.elapsedSeconds), latestFrame)
                }
                guard latestFrame.id == work.frame.id || !stableLines.isEmpty else { continue }
                // Publish only text proven unchanged in the newest frame. A
                // clock or animated label cannot hold the whole page hostage.
                let current = OCRResult(frame: latestFrame, lines: stableLines,
                                        supportedLanguages: result.supportedLanguages,
                                        elapsedSeconds: result.elapsedSeconds)
                reference = current
                await onEvent(.recognized(current, sourceRevision))
            } catch {
                guard isCurrent(work) else { continue }
                // Error codes, never the recognized text or capture contents.
                let nsError = error as NSError
                await onEvent(.failed(work.frame.stamp, work.sourceRevision,
                                      "Accurate OCR failed (\(nsError.domain), \(nsError.code)). Try Resume to retry."))
            }
        }
        worker = nil
    }

    private static func textPixelsMatch(_ result: OCRResult, _ frame: CapturedFrame) -> Bool {
        let original = result.frame.surface, newest = frame.surface
        guard result.frame.stamp == frame.stamp, original.size == newest.size,
              original.bytesPerRow == newest.bytesPerRow, !result.lines.isEmpty else { return false }
        return original.pixels.withUnsafeBytes { old in
            newest.pixels.withUnsafeBytes { new in
                guard let oldBase = old.baseAddress, let newBase = new.baseAddress else { return false }
                for line in result.lines {
                    let x0 = max(0, line.bounds.x - 2), y0 = max(0, line.bounds.y - 2)
                    let x1 = min(original.size.width, line.bounds.x + line.bounds.width + 2)
                    let y1 = min(original.size.height, line.bounds.y + line.bounds.height + 2)
                    guard x1 > x0, y1 > y0 else { return false }
                    for y in y0..<y1 {
                        let offset = y * original.bytesPerRow + x0 * 4
                        guard memcmp(oldBase.advanced(by: offset), newBase.advanced(by: offset), (x1 - x0) * 4) == 0 else {
                            return false
                        }
                    }
                }
                return true
            }
        }
    }

    private func isCurrent(_ work: Work) -> Bool {
        work.generation == generation && work.frame.stamp == stamp &&
        work.sourceRevision == sourceRevision
    }
}
