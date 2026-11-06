import CryptoKit
import Darwin
import Foundation

enum PipelineEvent: Sendable {
    case pending(RevisionStamp, UInt64)
    case recognized(OCRResult, UInt64)
    case failed(RevisionStamp, UInt64, String)
}

/// One frozen snapshot runs through OCR and its async consumer to completion.
/// Capture only replaces the pending snapshot; geometry changes invalidate a job.
actor ReadingPipeline {
    typealias EventHandler = @MainActor @Sendable (PipelineEvent) async -> Void
    private struct Work {
        let frame: CapturedFrame
        let generation: UInt64
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
    private var reference: OCRResult?
    private let clock = ContinuousClock()
    private var lastRecognizedAt: ContinuousClock.Instant?

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
        reference = nil
        lastRecognizedAt = nil
    }

    func stop() {
        generation &+= 1
        stamp = nil
        pending = nil
        digest = nil
        reference = nil
        lastRecognizedAt = nil
    }

    func consume(_ frame: CapturedFrame) async {
        guard frame.stamp == stamp else { return }
        let newDigest = SHA256.hash(data: frame.surface.pixels)
        guard newDigest != digest else { return }
        digest = newDigest
        pending = Work(frame: frame, generation: generation)
        if worker == nil {
            worker = Task { await self.processQueue() }
        }
    }

    func waitUntilIdle() async { await worker?.value }

    private func processQueue() async {
        while pending != nil {
            if minimumInterval > .zero { try? await Task.sleep(for: minimumInterval) }
            // Background changes can reveal newly added text, so scan them at
            // most once a second. Keep the latest frame during this wait.
            if let next = pending, let reference, let lastRecognizedAt,
               Self.textPixelsMatch(reference, next.frame) {
                let remaining = Duration.seconds(1) - lastRecognizedAt.duration(to: clock.now)
                if remaining > .zero { try? await Task.sleep(for: remaining) }
            }
            guard let work = pending else { break }
            pending = nil
            guard isCurrent(work) else { continue }
            sourceRevision &+= 1
            let revision = sourceRevision
            let mayChangeText = reference.map { !Self.textPixelsMatch($0, work.frame) } ?? true
            if mayChangeText { await onEvent(.pending(work.frame.stamp, revision)) }
            guard isCurrent(work) else { continue }
            do {
                let result = try await recognizer.recognize(work.frame)
                guard isCurrent(work) else { continue }
                let changed = reference.map { TranslationPipeline.signature($0) != TranslationPipeline.signature(result) } ?? true
                reference = result
                lastRecognizedAt = clock.now
                guard changed || mayChangeText else { continue }
                if !mayChangeText { await onEvent(.pending(work.frame.stamp, revision)) }
                guard isCurrent(work) else { continue }
                // The consumer waits for translation/rendering. No other OCR
                // starts and no frame/text from pending work enters this job.
                await onEvent(.recognized(result, revision))
            } catch {
                guard isCurrent(work) else { continue }
                if !mayChangeText { continue }
                let nsError = error as NSError
                await onEvent(.failed(work.frame.stamp, revision,
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
        work.generation == generation && work.frame.stamp == stamp
    }
}
