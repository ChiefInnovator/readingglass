import CryptoKit
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
    }

    func stop() {
        generation &+= 1
        stamp = nil
        pending = nil
        digest = nil
    }

    func consume(_ frame: CapturedFrame) async {
        guard frame.stamp == stamp else { return }
        let newDigest = SHA256.hash(data: frame.surface.pixels)
        guard newDigest != digest else { return }
        digest = newDigest
        sourceRevision &+= 1
        let work = Work(frame: frame, generation: generation, sourceRevision: sourceRevision)
        pending = work
        await onEvent(.pending(frame.stamp, work.sourceRevision))
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
                guard isCurrent(work) else { continue }
                await onEvent(.recognized(result, work.sourceRevision))
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

    private func isCurrent(_ work: Work) -> Bool {
        work.generation == generation && work.frame.stamp == stamp &&
        work.sourceRevision == sourceRevision
    }
}
