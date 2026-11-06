import XCTest
@testable import ReadingGlass

final class SnapshotPipelineTests: XCTestCase, @unchecked Sendable {
    func testFrozenSnapshotFinishesBeforeNewestCaptureIsRecognized() async throws {
        let first = expectation(description: "First snapshot, first paragraph")
        let second = expectation(description: "First snapshot, second paragraph")
        let newest = expectation(description: "Newest snapshot starts only after first completes")
        let translator = SnapshotTestTranslator { index in
            if index == 1 { first.fulfill() }
            if index == 2 { second.fulfill() }
            if index == 3 { newest.fulfill() }
        }
        let recognizer = SnapshotTestRecognizer()
        let events = await MainActor.run { SnapshotEvents() }
        let translation = TranslationPipeline(translator: translator, languageNames: ["fr": "French", "en": "English"]) {
            events.accept($0)
        }
        let reading = ReadingPipeline(recognizer: recognizer, minimumInterval: .zero) { event in
            if case let .recognized(result, _) = event {
                await translation.consume(result)
                await translation.waitUntilIdle()
            }
        }
        let stamp = RevisionStamp(geometry: 1, language: 0, model: "synthetic")
        await translation.activate(stamp: stamp, target: "en", manualSource: "fr")
        await reading.activate(stamp: stamp)
        let original = frame(1, stamp: stamp)
        await reading.consume(original)
        await fulfillment(of: [first], timeout: 3)
        for sequence in 2...50 { await reading.consume(frame(UInt64(sequence), stamp: stamp)) }
        let duringFirst = await recognizer.calls
        XCTAssertEqual(duringFirst, [1], "Incoming captures must not start another OCR/translation job")
        await translator.complete(1, text: "The train leaves tomorrow at nine.")
        await fulfillment(of: [second], timeout: 3)
        let partial = await events.presentations
        XCTAssertTrue(partial.isEmpty, "The first translated paragraph must remain unpublished")
        await translator.complete(2, text: "Please arrive at the station early.")
        await fulfillment(of: [newest], timeout: 3)
        let firstComposite = await events.presentations
        XCTAssertEqual(firstComposite.count, 1)
        XCTAssertEqual(firstComposite.first?.frame.surface, original.surface)
        XCTAssertEqual(firstComposite.first?.regions.count, 2)
        await translator.complete(3, text: "The next train leaves tomorrow at nine.")
        await reading.waitUntilIdle()
        let completed = await events.presentations
        let calls = await recognizer.calls
        let requests = await translator.requests
        let cancellations = await translator.cancellations
        XCTAssertEqual(calls, [1, 50])
        XCTAssertEqual(requests.count, 3, "The unchanged second paragraph is reused from cache")
        XCTAssertEqual(cancellations, 1, "Only initial activation cancels, never a new capture")
        XCTAssertEqual(completed.map { $0.frame.id.sequence }, [1, 50])
        XCTAssertTrue(completed.allSatisfy { $0.regions.count == 2 })
        XCTAssertEqual(completed.last?.frame.surface, frame(50, stamp: stamp).surface)
    }

    private func frame(_ sequence: UInt64, stamp: RevisionStamp) -> CapturedFrame {
        CapturedFrame(id: FrameID(sequence: sequence, capturedAtNanoseconds: sequence), stamp: stamp,
            displayID: 1, captureRectGlobalPoints: PointRect(CGRect(x: 0, y: 0, width: 400, height: 220)),
            surface: RasterSurface(size: PixelSize(width: 400, height: 220), bytesPerRow: 1600,
                pixels: Data((0..<(400 * 220)).flatMap { _ in [UInt8(sequence), UInt8(sequence), UInt8(sequence), 255] })),
            scaleX: 1, scaleY: 1)
    }
}

private actor SnapshotTestRecognizer: Recognizing {
    private(set) var calls: [UInt64] = []
    func recognize(_ frame: CapturedFrame) async throws -> OCRResult {
        calls.append(frame.id.sequence)
        let first = frame.id.sequence == 1 ? "Le train part demain à neuf heures." : "Le prochain train part demain à neuf heures."
        return OCRResult(frame: frame, lines: [
            OCRLine(text: first, bounds: PixelRect(x: 20, y: 20, width: 240, height: 30), spans: [], confidence: 1),
            OCRLine(text: "Veuillez arriver à la gare avant le départ.",
                    bounds: PixelRect(x: 20, y: 120, width: 240, height: 30), spans: [], confidence: 1)
        ], supportedLanguages: ["fr-FR"], elapsedSeconds: 0)
    }
}

private actor SnapshotTestTranslator: TextTranslating {
    private let onStart: @Sendable (Int) -> Void
    private var waiting: [Int: CheckedContinuation<TextTranslationResult, Never>] = [:]
    private(set) var requests: [String] = []
    private(set) var cancellations = 0
    init(onStart: @escaping @Sendable (Int) -> Void) { self.onStart = onStart }
    func countTokens(_ text: String) async throws -> Int { text.split(separator: " ").count }
    func translate(text: String, source: String, target: String, maximumOutputTokens: Int,
                   deadline: Duration) async throws -> TextTranslationResult {
        requests.append(text)
        let index = requests.count
        return await withCheckedContinuation { continuation in
            waiting[index] = continuation
            onStart(index)
        }
    }
    func complete(_ index: Int, text: String) {
        waiting.removeValue(forKey: index)?.resume(returning: TextTranslationResult(text: text, finish: .complete))
    }
    func cancel() async { cancellations += 1 }
}

@MainActor
private final class SnapshotEvents {
    private(set) var presentations: [TranslationPresentation] = []
    func accept(_ event: TranslationEvent) {
        if case let .presented(presentation, _) = event { presentations.append(presentation) }
    }
}
