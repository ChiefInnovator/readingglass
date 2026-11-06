import XCTest
@testable import ReadingGlass

final class ReadingPipelineTests: XCTestCase, @unchecked Sendable {
    func testOnlyOneRecognitionRunsAndNewestPendingFrameWins() async throws {
        let firstStarted = expectation(description: "First recognition starts")
        let newestStarted = expectation(description: "Newest pending recognition starts")
        let recognizer = ControlledRecognizer { sequence in
            if sequence == 1 { firstStarted.fulfill() }
            if sequence == 3 { newestStarted.fulfill() }
        }
        let events = await MainActor.run { PipelineEventCollector() }
        let pipeline = ReadingPipeline(recognizer: recognizer, minimumInterval: .zero) {
            events.record($0)
        }
        let stamp = makeStamp(1)
        await pipeline.activate(stamp: stamp)
        await pipeline.consume(makeFrame(1, stamp: stamp, pixel: 10))
        await fulfillment(of: [firstStarted], timeout: 3)
        await pipeline.consume(makeFrame(2, stamp: stamp, pixel: 20))
        await pipeline.consume(makeFrame(3, stamp: stamp, pixel: 30))

        let callsWhileBlocked = await recognizer.calls
        XCTAssertEqual(callsWhileBlocked, [1])
        await recognizer.succeed(1)
        await fulfillment(of: [newestStarted], timeout: 3)
        await recognizer.succeed(3)
        await pipeline.waitUntilIdle()

        let calls = await recognizer.calls
        let peak = await recognizer.maximumActive
        let recognized = await events.recognizedSequences
        XCTAssertEqual(calls, [1, 3], "Intermediate pending work must be replaced")
        XCTAssertEqual(peak, 1, "Recognition must never overlap")
        XCTAssertEqual(recognized, [3], "Old content must not publish after new content arrives")
    }

    func testGeometryActivationRejectsInFlightAndLateOldGeometryFrames() async throws {
        let firstStarted = expectation(description: "Old geometry recognition starts")
        let newStarted = expectation(description: "New geometry recognition starts")
        let recognizer = ControlledRecognizer { sequence in
            if sequence == 1 { firstStarted.fulfill() }
            if sequence == 3 { newStarted.fulfill() }
        }
        let events = await MainActor.run { PipelineEventCollector() }
        let pipeline = ReadingPipeline(recognizer: recognizer, minimumInterval: .zero) {
            events.record($0)
        }
        let oldStamp = makeStamp(1)
        let newStamp = makeStamp(2)
        await pipeline.activate(stamp: oldStamp)
        await pipeline.consume(makeFrame(1, stamp: oldStamp, pixel: 10))
        await fulfillment(of: [firstStarted], timeout: 3)
        await pipeline.activate(stamp: newStamp)
        await pipeline.consume(makeFrame(2, stamp: oldStamp, pixel: 20))
        // Identical pixels still need recognition at the new geometry.
        await pipeline.consume(makeFrame(3, stamp: newStamp, pixel: 10))
        await recognizer.succeed(1)
        await fulfillment(of: [newStarted], timeout: 3)
        await recognizer.succeed(3)
        await pipeline.waitUntilIdle()

        let calls = await recognizer.calls
        let recognized = await events.recognizedSequences
        let stamps = await events.recognizedStamps
        XCTAssertEqual(calls, [1, 3])
        XCTAssertEqual(recognized, [3])
        XCTAssertEqual(stamps, [newStamp])
    }

    func testStopDiscardsPendingWorkAndSuppressesInFlightResult() async throws {
        let firstStarted = expectation(description: "Recognition starts before stop")
        let recognizer = ControlledRecognizer { sequence in
            if sequence == 1 { firstStarted.fulfill() }
        }
        let events = await MainActor.run { PipelineEventCollector() }
        let pipeline = ReadingPipeline(recognizer: recognizer, minimumInterval: .zero) {
            events.record($0)
        }
        let stamp = makeStamp(1)
        await pipeline.activate(stamp: stamp)
        await pipeline.consume(makeFrame(1, stamp: stamp, pixel: 10))
        await fulfillment(of: [firstStarted], timeout: 3)
        await pipeline.consume(makeFrame(2, stamp: stamp, pixel: 20))
        await pipeline.stop()
        await recognizer.succeed(1)
        await pipeline.waitUntilIdle()
        await pipeline.consume(makeFrame(3, stamp: stamp, pixel: 30))
        await pipeline.waitUntilIdle()

        let calls = await recognizer.calls
        let recognized = await events.recognizedSequences
        let failures = await events.failureCount
        XCTAssertEqual(calls, [1])
        XCTAssertTrue(recognized.isEmpty)
        XCTAssertEqual(failures, 0)
    }

    func testIdenticalPixelsDoNotInvalidateOrRetriggerRecognition() async throws {
        let firstStarted = expectation(description: "Initial recognition starts")
        let recognizer = ControlledRecognizer { sequence in
            if sequence == 1 { firstStarted.fulfill() }
        }
        let events = await MainActor.run { PipelineEventCollector() }
        let pipeline = ReadingPipeline(recognizer: recognizer, minimumInterval: .zero) {
            events.record($0)
        }
        let stamp = makeStamp(1)
        await pipeline.activate(stamp: stamp)
        await pipeline.consume(makeFrame(1, stamp: stamp, pixel: 10))
        await fulfillment(of: [firstStarted], timeout: 3)
        await pipeline.consume(makeFrame(2, stamp: stamp, pixel: 10))
        await recognizer.succeed(1)
        await pipeline.waitUntilIdle()
        await pipeline.consume(makeFrame(3, stamp: stamp, pixel: 10))
        await pipeline.waitUntilIdle()

        let calls = await recognizer.calls
        let recognized = await events.recognizedSequences
        let pendingCount = await events.pendingCount
        XCTAssertEqual(calls, [1])
        XCTAssertEqual(recognized, [1])
        XCTAssertEqual(pendingCount, 1)
    }

    func testObsoleteFailureCannotReplaceNewContent() async throws {
        let firstStarted = expectation(description: "Initial recognition starts")
        let newStarted = expectation(description: "Replacement recognition starts")
        let recognizer = ControlledRecognizer { sequence in
            if sequence == 1 { firstStarted.fulfill() }
            if sequence == 2 { newStarted.fulfill() }
        }
        let events = await MainActor.run { PipelineEventCollector() }
        let pipeline = ReadingPipeline(recognizer: recognizer, minimumInterval: .zero) {
            events.record($0)
        }
        let stamp = makeStamp(1)
        await pipeline.activate(stamp: stamp)
        await pipeline.consume(makeFrame(1, stamp: stamp, pixel: 10))
        await fulfillment(of: [firstStarted], timeout: 3)
        await pipeline.consume(makeFrame(2, stamp: stamp, pixel: 20))
        await recognizer.fail(1)
        await fulfillment(of: [newStarted], timeout: 3)
        await recognizer.succeed(2)
        await pipeline.waitUntilIdle()

        let failures = await events.failureCount
        let recognized = await events.recognizedSequences
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(recognized, [2])
    }

    private func makeStamp(_ geometry: UInt64) -> RevisionStamp {
        RevisionStamp(geometry: geometry, language: 0, model: "test")
    }

    private func makeFrame(_ sequence: UInt64, stamp: RevisionStamp, pixel: UInt8) -> CapturedFrame {
        CapturedFrame(
            id: FrameID(sequence: sequence, capturedAtNanoseconds: sequence),
            stamp: stamp, displayID: 1,
            captureRectGlobalPoints: PointRect(CGRect(x: 0, y: 0, width: 1, height: 1)),
            surface: RasterSurface(size: PixelSize(width: 1, height: 1), bytesPerRow: 4,
                                   pixels: Data([pixel, pixel, pixel, 255])),
            scaleX: 1, scaleY: 1
        )
    }
}

private actor ControlledRecognizer: Recognizing {
    private struct Waiting {
        let frame: CapturedFrame
        let continuation: CheckedContinuation<OCRResult, Error>
    }

    private let onStart: @Sendable (UInt64) -> Void
    private var waiting: [UInt64: Waiting] = [:]
    private(set) var calls: [UInt64] = []
    private(set) var maximumActive = 0
    private var active = 0

    init(onStart: @escaping @Sendable (UInt64) -> Void) {
        self.onStart = onStart
    }

    func recognize(_ frame: CapturedFrame) async throws -> OCRResult {
        let sequence = frame.id.sequence
        calls.append(sequence)
        active += 1
        maximumActive = max(maximumActive, active)
        return try await withCheckedThrowingContinuation { continuation in
            waiting[sequence] = Waiting(frame: frame, continuation: continuation)
            onStart(sequence)
        }
    }

    func succeed(_ sequence: UInt64) {
        guard let request = waiting.removeValue(forKey: sequence) else { return }
        active -= 1
        request.continuation.resume(returning: OCRResult(
            frame: request.frame, lines: [], supportedLanguages: ["en-US"], elapsedSeconds: 0
        ))
    }

    func fail(_ sequence: UInt64) {
        guard let request = waiting.removeValue(forKey: sequence) else { return }
        active -= 1
        request.continuation.resume(throwing: NSError(domain: "SyntheticOCR", code: 1))
    }
}

@MainActor
private final class PipelineEventCollector {
    private var events: [PipelineEvent] = []

    func record(_ event: PipelineEvent) { events.append(event) }

    var recognizedSequences: [UInt64] {
        events.compactMap { event in
            if case .recognized(let result, _) = event { return result.frame.id.sequence }
            return nil
        }
    }

    var recognizedStamps: [RevisionStamp] {
        events.compactMap { event in
            if case .recognized(let result, _) = event { return result.frame.stamp }
            return nil
        }
    }

    var pendingCount: Int {
        events.filter { if case .pending = $0 { return true }; return false }.count
    }

    var failureCount: Int {
        events.filter { if case .failed = $0 { return true }; return false }.count
    }
}
