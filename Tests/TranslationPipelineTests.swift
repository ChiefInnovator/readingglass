import XCTest
@testable import ReadingGlass

final class TranslationPipelineTests: XCTestCase, @unchecked Sendable {
    func testSourceTargetAndGenerationLimitsReachTranslator() async throws {
        let translator = ScriptedTextTranslator { _, _ in
            TextTranslationResult(text: "The train leaves tomorrow at nine.", finish: .complete)
        }
        let events = await MainActor.run { TranslationEventRecorder() }
        let pipeline = TranslationPipeline(translator: translator, languageNames: languages) { events.record($0) }
        let stamp = makeStamp(1)
        await pipeline.activate(stamp: stamp, target: "en", manualSource: "fr")
        await pipeline.consume(makeResult(1, stamp: stamp))
        await pipeline.waitUntilIdle()
        let requests = await translator.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.source, "fr")
        XCTAssertEqual(request.target, "en")
        XCTAssertEqual(request.text, french)
        XCTAssertEqual(request.maximumOutputTokens, 96)
        XCTAssertEqual(request.deadline, .seconds(10))
        let results = await events.presentations
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(try XCTUnwrap(results.first).regions.map(\.text), ["The train leaves tomorrow at nine."])
    }

    func testSameTargetSourceBypassesInferenceAndPreservesOriginalPixels() async throws {
        let translator = ScriptedTextTranslator { _, _ in
            XCTFail("English source should bypass an English translator request.")
            return TextTranslationResult(text: "unexpected", finish: .complete)
        }
        let events = await MainActor.run { TranslationEventRecorder() }
        let pipeline = TranslationPipeline(translator: translator, languageNames: languages) { events.record($0) }
        let stamp = makeStamp(1)
        let original = makeResult(1, stamp: stamp, text: "The train leaves tomorrow at nine.")
        await pipeline.activate(stamp: stamp, target: "en", manualSource: nil)
        await pipeline.consume(original)
        await pipeline.waitUntilIdle()
        let requests = await translator.requests
        let results = await events.presentations
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(results.count, 1)
        let presentation = try XCTUnwrap(results.first)
        XCTAssertTrue(presentation.regions.isEmpty)
        XCTAssertEqual(presentation.initialBackground, original.frame.surface)
    }

    func testRegionalAliasOfTargetAlsoBypassesInference() async throws {
        let translator = ScriptedTextTranslator { _, _ in
            XCTFail("en-US source and en target are the same language.")
            return TextTranslationResult(text: "unexpected", finish: .complete)
        }
        let events = await MainActor.run { TranslationEventRecorder() }
        let pipeline = TranslationPipeline(translator: translator,
                                          languageNames: ["en": "English", "en-US": "US English"]) { events.record($0) }
        let stamp = makeStamp(1)
        await pipeline.activate(stamp: stamp, target: "en", manualSource: "en-US")
        await pipeline.consume(makeResult(1, stamp: stamp, text: "The train leaves tomorrow at nine."))
        await pipeline.waitUntilIdle()
        let requests = await translator.requests
        let results = await events.presentations
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(try XCTUnwrap(results.first).regions.isEmpty)
    }

    func testTruncatedParentIsReplacedOnlyAfterBothChildrenComplete() async throws {
        let translator = ScriptedTextTranslator { index, _ in
            switch index {
            case 1: TextTranslationResult(text: "DO NOT PUBLISH PARTIAL PARENT", finish: .outputLimit)
            case 2: TextTranslationResult(text: "First half.", finish: .complete)
            default: TextTranslationResult(text: "Second half.", finish: .complete)
            }
        }
        let events = await MainActor.run { TranslationEventRecorder() }
        let pipeline = TranslationPipeline(translator: translator, languageNames: languages) { events.record($0) }
        let stamp = makeStamp(1)
        await pipeline.activate(stamp: stamp, target: "en", manualSource: "fr")
        await pipeline.consume(makeResult(1, stamp: stamp))
        await pipeline.waitUntilIdle()
        let requests = await translator.requests
        let results = await events.presentations
        XCTAssertEqual(requests.count, 3)
        guard requests.count == 3 else { return }
        XCTAssertEqual(requests[0].text, french)
        XCTAssertEqual(requests[1].source, "fr")
        XCTAssertEqual(requests[2].target, "en")
        XCTAssertEqual((requests[1].text + " " + requests[2].text), french)
        XCTAssertEqual(results.count, 1)
        let presentation = try XCTUnwrap(results.first)
        XCTAssertEqual(presentation.regions.count, 1)
        XCTAssertEqual(try XCTUnwrap(presentation.regions.first).text, "First half. Second half.")
    }

    func testSecondTruncationNeverPublishesParentOrCompletedFirstChild() async throws {
        let translator = ScriptedTextTranslator { index, _ in
            TextTranslationResult(text: index == 2 ? "A complete first child." : "partial", finish: index == 2 ? .complete : .outputLimit)
        }
        let events = await MainActor.run { TranslationEventRecorder() }
        let pipeline = TranslationPipeline(translator: translator, languageNames: languages) { events.record($0) }
        let stamp = makeStamp(1)
        await pipeline.activate(stamp: stamp, target: "en", manualSource: "fr")
        await pipeline.consume(makeResult(1, stamp: stamp))
        await pipeline.waitUntilIdle()
        let requests = await translator.requests
        let results = await events.presentations
        let failures = await events.failures
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(try XCTUnwrap(results.first).regions.isEmpty)
        XCTAssertEqual(failures.count, 1)
    }

    func testSnapshotPublishesOnceAfterEveryRegionSettles() async throws {
        let firstStarted = expectation(description: "First region starts")
        let secondStarted = expectation(description: "Second region starts without partial publication")
        let translator = ControlledTextTranslator { index in
            if index == 1 { firstStarted.fulfill() }
            if index == 2 { secondStarted.fulfill() }
        }
        let events = await MainActor.run { TranslationEventRecorder() }
        let pipeline = TranslationPipeline(translator: translator, languageNames: languages) { events.record($0) }
        let stamp = makeStamp(1)
        let original = makeResult(1, stamp: stamp)
        let secondText = "Veuillez arriver à la gare avant le départ."
        let input = OCRResult(frame: original.frame,
                              lines: original.lines + [OCRLine(text: secondText,
                                  bounds: PixelRect(x: 20, y: 120, width: 240, height: 40), spans: [], confidence: 1)],
                              supportedLanguages: original.supportedLanguages, elapsedSeconds: 0)
        await pipeline.activate(stamp: stamp, target: "en", manualSource: "fr")
        await pipeline.consume(input)
        await fulfillment(of: [firstStarted], timeout: 3)
        await translator.complete(1, text: "The first translated paragraph.")
        await fulfillment(of: [secondStarted], timeout: 3)

        let whileWaiting = await events.presentations
        XCTAssertTrue(whileWaiting.isEmpty, "No partial snapshot may appear while a region is still running")

        await translator.finish(2, text: "Do not show an unfinished second region", finish: .timedOut)
        await pipeline.waitUntilIdle()
        let afterFailure = await events.presentations
        let failures = await events.failures
        XCTAssertEqual(afterFailure.count, 1, "Publish one complete snapshot after success/failure is known")
        let final = try XCTUnwrap(afterFailure.first)
        XCTAssertEqual(final.frame.id, original.frame.id)
        XCTAssertEqual(final.regions.map(\.text), ["The first translated paragraph."])
        let originalSecondRow = original.frame.surface.pixels[(140 * 1360)..<(141 * 1360)]
        XCTAssertEqual(final.initialBackground.pixels[(140 * 1360)..<(141 * 1360)], originalSecondRow)
        XCTAssertTrue(failures.isEmpty, "A failed region must not replace the valid readable region with an error-only state.")
        let finalProgress = await events.progress.last
        XCTAssertEqual(finalProgress?.translated, 1)
        XCTAssertEqual(finalProgress?.failed, 1)
        XCTAssertEqual(finalProgress?.finished, true)
    }

    func testNewGenerationWithIdenticalTextStillReceivesTranslation() async throws {
        let first = expectation(description: "Old generation starts")
        let second = expectation(description: "New generation starts")
        let translator = ControlledTextTranslator { index in
            if index == 1 { first.fulfill() }
            if index == 2 { second.fulfill() }
        }
        let events = await MainActor.run { TranslationEventRecorder() }
        let pipeline = TranslationPipeline(translator: translator, languageNames: languages) { events.record($0) }
        let oldStamp = makeStamp(1), newStamp = makeStamp(2)
        await pipeline.activate(stamp: oldStamp, target: "en", manualSource: "fr")
        await pipeline.consume(makeResult(1, stamp: oldStamp))
        await fulfillment(of: [first], timeout: 3)
        await pipeline.activate(stamp: newStamp, target: "ja", manualSource: "fr")
        await pipeline.consume(makeResult(2, stamp: newStamp))
        await translator.complete(1, text: "Obsolete translation.")
        await fulfillment(of: [second], timeout: 3)
        await translator.complete(2, text: "Current translation.")
        await pipeline.waitUntilIdle()
        let results = await events.presentations
        XCTAssertEqual(results.map { $0.frame.id.sequence }, [2])
        XCTAssertEqual(results.map { $0.frame.stamp }, [newStamp])
        XCTAssertEqual(try XCTUnwrap(results.first).regions.map(\.text), ["Current translation."])
    }

    func testActiveSnapshotFinishesThenNewestPendingSnapshotRuns() async throws {
        let first = expectation(description: "Initial source starts")
        let newest = expectation(description: "Newest source starts")
        let translator = ControlledTextTranslator { index in
            if index == 1 { first.fulfill() }
            if index == 2 { newest.fulfill() }
        }
        let events = await MainActor.run { TranslationEventRecorder() }
        let pipeline = TranslationPipeline(translator: translator, languageNames: languages) { events.record($0) }
        let stamp = makeStamp(1)
        await pipeline.activate(stamp: stamp, target: "en", manualSource: "fr")
        await pipeline.consume(makeResult(1, stamp: stamp))
        await fulfillment(of: [first], timeout: 3)
        await pipeline.consume(makeResult(2, stamp: stamp, text: "Le train part demain à dix heures."))
        let latestText = "Le train part demain à onze heures."
        await pipeline.consume(makeResult(3, stamp: stamp, text: latestText))
        await translator.complete(1, text: "Obsolete source.")
        await fulfillment(of: [newest], timeout: 3)
        await translator.complete(2, text: "The train leaves tomorrow at eleven.")
        await pipeline.waitUntilIdle()
        let requests = await translator.requests
        let results = await events.presentations
        let maximumActive = await translator.maximumActive
        XCTAssertEqual(requests.map(\.text), [french, latestText])
        XCTAssertEqual(maximumActive, 1)
        XCTAssertEqual(results.map { $0.frame.id.sequence }, [1, 3])
    }

    func testIdenticalSourceKeepsFrozenPixelsAndDoesNotRepeatInference() async throws {
        let first = expectation(description: "First source starts")
        let translator = ControlledTextTranslator(maximumExpectedRequests: 1) { index in if index == 1 { first.fulfill() } }
        let events = await MainActor.run { TranslationEventRecorder() }
        let pipeline = TranslationPipeline(translator: translator, languageNames: languages) { events.record($0) }
        let stamp = makeStamp(1)
        await pipeline.activate(stamp: stamp, target: "en", manualSource: "fr")
        await pipeline.consume(makeResult(1, stamp: stamp))
        await fulfillment(of: [first], timeout: 3)
        await pipeline.consume(makeResult(2, stamp: stamp))
        await translator.complete(1, text: "The train leaves tomorrow at nine.")
        await pipeline.waitUntilIdle()
        await pipeline.consume(makeResult(3, stamp: stamp))
        await pipeline.waitUntilIdle()
        let requests = await translator.requests
        let results = await events.presentations
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(results.map { $0.frame.id.sequence }, [1], "Never repaint active text onto newer snapshot pixels")
        await pipeline.retryLatest()
        await pipeline.waitUntilIdle()
        let retried = await events.presentations
        let afterRetry = await translator.requests
        XCTAssertEqual(retried.map { $0.frame.id.sequence }, [1, 3])
        XCTAssertEqual(afterRetry.count, 1, "Explicit retry can reuse cached successful text")
    }

    func testReturningToActiveSnapshotDropsIntermediateWorkWithoutCancellation() async throws {
        let first = expectation(description: "First A starts")
        let translator = ControlledTextTranslator(maximumExpectedRequests: 1) { index in
            if index == 1 { first.fulfill() }
        }
        let events = await MainActor.run { TranslationEventRecorder() }
        let pipeline = TranslationPipeline(translator: translator, languageNames: languages) { events.record($0) }
        let stamp = makeStamp(1)
        await pipeline.activate(stamp: stamp, target: "en", manualSource: "fr")
        await pipeline.consume(makeResult(1, stamp: stamp))
        await fulfillment(of: [first], timeout: 3)
        await pipeline.consume(makeResult(2, stamp: stamp, text: "Le train part demain à dix heures."))
        await pipeline.consume(makeResult(3, stamp: stamp))
        await translator.complete(1, text: "The completed A snapshot.")
        await pipeline.waitUntilIdle()
        let requests = await translator.requests
        let results = await events.presentations
        let cancellations = await translator.cancellationCount
        XCTAssertEqual(requests.map(\.text), [french])
        XCTAssertEqual(results.map { $0.frame.id.sequence }, [1])
        XCTAssertEqual(cancellations, 1, "Only initial activation cancels; incoming text never does")
    }

    func testWordAndModelTokenBoundsPreserveAllInputWords() async throws {
        let text = (1...205).map { "word\($0)" }.joined(separator: " ")
        let words = ScriptedTextTranslator { _, _ in TextTranslationResult(text: "unused", finish: .complete) }
        let wordChunks = try await TranslationChunker.chunks(text, translator: words)
        XCTAssertTrue(wordChunks.count >= 3)
        XCTAssertTrue(wordChunks.allSatisfy { $0.split(whereSeparator: \.isWhitespace).count <= 80 })
        XCTAssertEqual(wordChunks.joined(separator: " "), text)

        let tokens = ScriptedTextTranslator(tokenCount: { $0.split(whereSeparator: \.isWhitespace).count * 30 }) { _, _ in
            TextTranslationResult(text: "unused", finish: .complete)
        }
        let tokenChunks = try await TranslationChunker.chunks(text, translator: tokens)
        XCTAssertTrue(tokenChunks.allSatisfy { $0.split(whereSeparator: \.isWhitespace).count * 30 <= 256 })
        XCTAssertEqual(tokenChunks.joined(separator: " "), text)
    }

    func testSentencePunctuationNeverBecomesAStandaloneRequest() async throws {
        let translator = ScriptedTextTranslator { _, _ in TextTranslationResult(text: "unused", finish: .complete) }
        let chunks = try await TranslationChunker.chunks(french, translator: translator)
        XCTAssertEqual(chunks, [french])
    }

    func testUnsplitableSingleGraphemeFailsInsteadOfLooping() async throws {
        let translator = ScriptedTextTranslator(tokenCount: { $0.isEmpty ? 0 : 257 }) { _, _ in
            TextTranslationResult(text: "unused", finish: .complete)
        }
        do {
            _ = try await TranslationChunker.chunks("👨‍👩‍👧‍👦", translator: translator)
            XCTFail("A single grapheme over the source-token allowance cannot be split safely.")
        } catch {
            XCTAssertTrue(error is TranslationFailure)
        }
        let counts = await translator.tokenCountRequests
        XCTAssertEqual(counts.count, 1)
    }

    func testMixedPagePreservesNumericLabelsAndUncertainOCR() async throws {
        let translator = ScriptedTextTranslator { _, _ in
            TextTranslationResult(text: "The train leaves tomorrow at nine.", finish: .complete)
        }
        let events = await MainActor.run { TranslationEventRecorder() }
        let pipeline = TranslationPipeline(translator: translator, languageNames: languages) { events.record($0) }
        let original = makeResult(1, stamp: makeStamp(1))
        let input = OCRResult(frame: original.frame, lines: original.lines + [
            OCRLine(text: "20 speakers", bounds: PixelRect(x: 20, y: 100, width: 100, height: 20), spans: [], confidence: 1),
            OCRLine(text: "uncertain words", bounds: PixelRect(x: 180, y: 100, width: 100, height: 20), spans: [], confidence: 0.2)
        ], supportedLanguages: original.supportedLanguages, elapsedSeconds: 0)
        await pipeline.activate(stamp: original.frame.stamp, target: "en", manualSource: nil)
        await pipeline.consume(input)
        await pipeline.waitUntilIdle()
        let requests = await translator.requests
        XCTAssertEqual(requests.map(\.text), [french])
        let final = await events.progress.last
        XCTAssertEqual(final?.translated, 1)
        XCTAssertEqual(final?.preserved, 1)
        XCTAssertEqual(final?.uncertain, 1)
        XCTAssertEqual(final?.processed, 3)
        XCTAssertEqual(final?.finished, true)
    }

    func testClippedInputIsPreservedAndExplainedWithoutInference() async throws {
        let translator = ScriptedTextTranslator { _, _ in
            XCTFail("Clipped text must not be translated as a complete sentence")
            return TextTranslationResult(text: "unused", finish: .complete)
        }
        let events = await MainActor.run { TranslationEventRecorder() }
        let pipeline = TranslationPipeline(translator: translator, languageNames: languages) { events.record($0) }
        let original = makeResult(1, stamp: makeStamp(1))
        let input = OCRResult(frame: original.frame, lines: [OCRLine(text: french,
            bounds: PixelRect(x: 20, y: 20, width: 320, height: 40), spans: [], confidence: 1)],
            supportedLanguages: original.supportedLanguages, elapsedSeconds: 0)
        await pipeline.activate(stamp: original.frame.stamp, target: "en", manualSource: "fr")
        await pipeline.consume(input)
        await pipeline.waitUntilIdle()
        let final = await events.progress.last
        let presentation = await events.presentations.last
        XCTAssertEqual(final?.clipped, 1)
        XCTAssertTrue(final?.compactStatus.contains("Widen") == true)
        XCTAssertEqual(presentation?.initialBackground, original.frame.surface)
    }

    func testClippedProseRequestsAutomaticWidthBeforeInference() async throws {
        let translator = ScriptedTextTranslator { _, _ in
            XCTFail("Wait for a wider capture before translating clipped text")
            return TextTranslationResult(text: "unused", finish: .complete)
        }
        let events = await MainActor.run { TranslationEventRecorder() }
        let pipeline = TranslationPipeline(translator: translator, languageNames: languages) { events.record($0) }
        let original = makeResult(1, stamp: makeStamp(1))
        let input = OCRResult(frame: original.frame, lines: [OCRLine(text: french,
            bounds: PixelRect(x: 20, y: 20, width: 320, height: 40), spans: [], confidence: 1)],
            supportedLanguages: original.supportedLanguages, elapsedSeconds: 0)
        await pipeline.activate(stamp: input.frame.stamp, target: "en", manualSource: "fr", maximumWidth: 500)
        await pipeline.consume(input)
        await pipeline.waitUntilIdle()
        let widths = await events.widthRequests
        let results = await events.presentations
        XCTAssertEqual(widths, [500])
        XCTAssertTrue(results.isEmpty)
    }

    func testAutomaticWidthStopsAtConfiguredDisplayLimit() async throws {
        let translator = ScriptedTextTranslator { _, _ in
            XCTFail("Clipped text should remain original at the width limit")
            return TextTranslationResult(text: "unused", finish: .complete)
        }
        let events = await MainActor.run { TranslationEventRecorder() }
        let pipeline = TranslationPipeline(translator: translator, languageNames: languages) { events.record($0) }
        let original = makeResult(1, stamp: makeStamp(1))
        let input = OCRResult(frame: original.frame, lines: [OCRLine(text: french,
            bounds: PixelRect(x: 20, y: 20, width: 320, height: 40), spans: [], confidence: 1)],
            supportedLanguages: original.supportedLanguages, elapsedSeconds: 0)
        await pipeline.activate(stamp: input.frame.stamp, target: "en", manualSource: "fr", maximumWidth: 340)
        await pipeline.consume(input)
        await pipeline.waitUntilIdle()
        let widths = await events.widthRequests
        let progress = await events.progress.last
        XCTAssertTrue(widths.isEmpty)
        XCTAssertEqual(progress?.clipped, 1)
        XCTAssertEqual(progress?.finished, true)
    }

    func testNearEdgeWordOmissionAlsoRequestsWiderCapture() async throws {
        let translator = ScriptedTextTranslator { _, _ in
            XCTFail("Recapture first when Vision may have omitted a clipped final word")
            return TextTranslationResult(text: "unused", finish: .complete)
        }
        let events = await MainActor.run { TranslationEventRecorder() }
        let pipeline = TranslationPipeline(translator: translator, languageNames: languages) { events.record($0) }
        let original = makeResult(1, stamp: makeStamp(1))
        let bounds = PixelRect(x: 20, y: 20, width: 300, height: 40)
        let input = OCRResult(frame: original.frame, lines: [OCRLine(text: french, bounds: bounds,
            spans: [OCRSpan(textRange: UTF16Range(location: 0, length: french.utf16.count),
                            bounds: bounds, confidence: 1)], confidence: 1)],
            supportedLanguages: original.supportedLanguages, elapsedSeconds: 0)
        await pipeline.activate(stamp: input.frame.stamp, target: "en", manualSource: "fr", maximumWidth: 500)
        await pipeline.consume(input)
        await pipeline.waitUntilIdle()
        let widths = await events.widthRequests
        XCTAssertEqual(widths, [500])
    }

    func testNearEdgeWordOmissionIsNotTranslatedAtDisplayWidthLimit() async throws {
        let translator = ScriptedTextTranslator { _, _ in
            XCTFail("Suspected cut-off text must stay original even when the display cannot widen")
            return TextTranslationResult(text: "unused", finish: .complete)
        }
        let events = await MainActor.run { TranslationEventRecorder() }
        let pipeline = TranslationPipeline(translator: translator, languageNames: languages) { events.record($0) }
        let original = makeResult(1, stamp: makeStamp(1))
        let bounds = PixelRect(x: 20, y: 20, width: 300, height: 40)
        let input = OCRResult(frame: original.frame, lines: [OCRLine(text: french, bounds: bounds,
            spans: [OCRSpan(textRange: UTF16Range(location: 0, length: french.utf16.count),
                            bounds: bounds, confidence: 1)], confidence: 1)],
            supportedLanguages: original.supportedLanguages, elapsedSeconds: 0)
        await pipeline.activate(stamp: input.frame.stamp, target: "en", manualSource: "fr", maximumWidth: 340)
        await pipeline.consume(input)
        await pipeline.waitUntilIdle()
        let requests = await translator.requests
        let progress = await events.progress.last
        let presentation = await events.presentations.last
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(progress?.clipped, 1)
        XCTAssertEqual(progress?.translated, 0)
        XCTAssertEqual(presentation?.initialBackground, original.frame.surface)
    }

    func testChangedNumericFactsAreRejected() async throws {
        let translator = ScriptedTextTranslator { _, _ in
            TextTranslationResult(text: "There are 25 people waiting for the train.", finish: .complete)
        }
        let events = await MainActor.run { TranslationEventRecorder() }
        let pipeline = TranslationPipeline(translator: translator, languageNames: languages) { events.record($0) }
        let input = makeResult(1, stamp: makeStamp(1), text: "Il y a 24 personnes qui attendent le train.")
        await pipeline.activate(stamp: input.frame.stamp, target: "en", manualSource: "fr")
        await pipeline.consume(input)
        await pipeline.waitUntilIdle()
        let results = await events.presentations
        let final = await events.progress.last
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(try XCTUnwrap(results.first).regions.isEmpty)
        XCTAssertEqual(final?.failed, 1)
    }

    func testRetryReusesSuccessfulRegionsAndRetriesOnlyFailure() async throws {
        let secondText = "Veuillez arriver à la gare avant le départ."
        let translator = ScriptedTextTranslator { index, _ in
            TextTranslationResult(text: index == 1 ? "The train leaves tomorrow." : "Arrive before departure.",
                                  finish: index == 2 ? .timedOut : .complete)
        }
        let events = await MainActor.run { TranslationEventRecorder() }
        let pipeline = TranslationPipeline(translator: translator, languageNames: languages) { events.record($0) }
        let original = makeResult(1, stamp: makeStamp(1))
        let input = OCRResult(frame: original.frame, lines: original.lines + [OCRLine(text: secondText,
            bounds: PixelRect(x: 20, y: 120, width: 240, height: 40), spans: [], confidence: 1)],
            supportedLanguages: original.supportedLanguages, elapsedSeconds: 0)
        await pipeline.activate(stamp: input.frame.stamp, target: "en", manualSource: "fr")
        await pipeline.consume(input)
        await pipeline.waitUntilIdle()
        await pipeline.retryLatest()
        await pipeline.waitUntilIdle()
        let requests = await translator.requests
        let final = await events.progress.last
        XCTAssertEqual(requests.map(\.text), [french, secondText, secondText])
        XCTAssertEqual(final?.translated, 2)
        XCTAssertEqual(final?.failed, 0)
        XCTAssertEqual(final?.finished, true)
    }

    private let french = "Le train part demain à neuf heures."
    private var languages: [String: String] { ["en": "English", "fr": "French", "ja": "Japanese"] }

    private func makeStamp(_ generation: UInt64) -> RevisionStamp {
        RevisionStamp(geometry: generation, language: 1, model: "test-model")
    }

    private func makeResult(_ sequence: UInt64, stamp: RevisionStamp, text: String? = nil) -> OCRResult {
        let text = text ?? french
        let bounds = PixelRect(x: 20, y: 20, width: 240, height: 40)
        let frame = CapturedFrame(
            id: FrameID(sequence: sequence, capturedAtNanoseconds: sequence), stamp: stamp, displayID: 1,
            captureRectGlobalPoints: PointRect(CGRect(x: 0, y: 0, width: 340, height: 220)),
            surface: RasterSurface(size: PixelSize(width: 340, height: 220), bytesPerRow: 1360,
                                   pixels: Data(repeating: 255, count: 340 * 220 * 4)),
            scaleX: 1, scaleY: 1
        )
        return OCRResult(frame: frame, lines: [OCRLine(text: text, bounds: bounds, spans: [], confidence: 1)],
                         supportedLanguages: ["fr-FR", "en-US"], elapsedSeconds: 0)
    }
}

private struct RecordedTranslationRequest: Sendable {
    let text: String
    let source: String
    let target: String
    let maximumOutputTokens: Int
    let deadline: Duration
}

private actor ScriptedTextTranslator: TextTranslating {
    private let counter: @Sendable (String) -> Int
    private let response: @Sendable (Int, RecordedTranslationRequest) -> TextTranslationResult
    private(set) var requests: [RecordedTranslationRequest] = []
    private(set) var tokenCountRequests: [String] = []

    init(tokenCount: @escaping @Sendable (String) -> Int = { $0.split(whereSeparator: \.isWhitespace).count },
         response: @escaping @Sendable (Int, RecordedTranslationRequest) -> TextTranslationResult) {
        counter = tokenCount
        self.response = response
    }

    func countTokens(_ text: String) async throws -> Int {
        tokenCountRequests.append(text)
        return counter(text)
    }

    func translate(text: String, source: String, target: String, maximumOutputTokens: Int,
                   deadline: Duration) async throws -> TextTranslationResult {
        let request = RecordedTranslationRequest(text: text, source: source, target: target,
                                                 maximumOutputTokens: maximumOutputTokens, deadline: deadline)
        requests.append(request)
        return response(requests.count, request)
    }

    func cancel() async {}
}

private actor ControlledTextTranslator: TextTranslating {
    private enum Failure: Error { case unexpectedRequest }
    private let onStart: @Sendable (Int) -> Void
    private let maximumExpectedRequests: Int
    private var waiting: [Int: CheckedContinuation<TextTranslationResult, Error>] = [:]
    private(set) var requests: [RecordedTranslationRequest] = []
    private(set) var maximumActive = 0
    private var active = 0
    private(set) var cancellationCount = 0

    init(maximumExpectedRequests: Int = 2, onStart: @escaping @Sendable (Int) -> Void) {
        self.maximumExpectedRequests = maximumExpectedRequests
        self.onStart = onStart
    }

    func countTokens(_ text: String) async throws -> Int { text.split(whereSeparator: \.isWhitespace).count }

    func translate(text: String, source: String, target: String, maximumOutputTokens: Int,
                   deadline: Duration) async throws -> TextTranslationResult {
        requests.append(RecordedTranslationRequest(text: text, source: source, target: target,
                                                   maximumOutputTokens: maximumOutputTokens, deadline: deadline))
        let index = requests.count
        guard index <= maximumExpectedRequests else { throw Failure.unexpectedRequest }
        active += 1
        maximumActive = max(maximumActive, active)
        return try await withCheckedThrowingContinuation { continuation in
            waiting[index] = continuation
            onStart(index)
        }
    }

    func complete(_ index: Int, text: String) {
        finish(index, text: text, finish: .complete)
    }

    func finish(_ index: Int, text: String, finish: TextTranslationFinish) {
        guard let continuation = waiting.removeValue(forKey: index) else { return }
        active -= 1
        continuation.resume(returning: TextTranslationResult(text: text, finish: finish))
    }

    // Deliberately uninterruptible: stale result rejection must still work if
    // an underlying native operation finishes after cancellation was requested.
    func cancel() async { cancellationCount += 1 }
}

@MainActor
private final class TranslationEventRecorder {
    private(set) var presentations: [TranslationPresentation] = []
    private(set) var failures: [String] = []
    private(set) var progress: [TranslationProgress] = []
    private(set) var widthRequests: [Double] = []

    func record(_ event: TranslationEvent) {
        switch event {
        case .working: break
        case let .progress(_, _, value): progress.append(value)
        case let .requestWidth(_, _, width): widthRequests.append(width)
        case let .presented(presentation, _): presentations.append(presentation)
        case let .unavailable(_, _, message): failures.append(message)
        }
    }
}
