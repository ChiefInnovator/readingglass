import CoreGraphics
import XCTest
@testable import ReadingGlass

final class TranslationRenderingTests: XCTestCase, @unchecked Sendable {
    func testLocaleNormalizationPreservesSupportedVariantsAndChineseScripts() {
        let catalog = LanguageCatalog(languageNames: [
            "en": "English", "fr": "French", "ja": "Japanese", "pt": "Portuguese",
            "pt-BR": "Brazilian Portuguese", "zh-Hans": "Simplified Chinese", "zh-Hant": "Traditional Chinese"
        ])
        XCTAssertEqual(catalog.normalize("en_US"), "en")
        XCTAssertEqual(catalog.normalize("fr-FR"), "fr")
        XCTAssertEqual(catalog.normalize("ja-JP"), "ja")
        XCTAssertEqual(catalog.normalize("pt_br"), "pt-BR")
        XCTAssertEqual(catalog.normalize("pt-PT"), "pt")
        XCTAssertEqual(catalog.normalize("zh-Hans-CN"), "zh-Hans")
        XCTAssertEqual(catalog.normalize("zh-TW"), "zh-Hant")
        XCTAssertNil(catalog.normalize("zh"))
        XCTAssertNil(catalog.normalize("not-a-language"))
    }

    func testExplicitSourceSelectionDoesNotInventAnUnsupportedLanguage() {
        let catalog = LanguageCatalog(languageNames: ["en": "English", "fr": "French"])
        let short = region(text: "123", bounds: PixelRect(x: 0, y: 0, width: 40, height: 20))
        XCTAssertEqual(catalog.language(for: short, pageText: "", manual: "fr-FR"), "fr")
        XCTAssertNil(catalog.language(for: short, pageText: "", manual: "ja-JP"))
        XCTAssertNil(catalog.language(for: short, pageText: "", manual: nil))
    }

    func testMixedLanguagesAndColumnsRemainSeparate() {
        let segmenter = TextSegmenter()
        let lines = [
            line("The train leaves tomorrow at nine.", x: 20, y: 20, width: 300),
            line("Le train part demain à neuf heures.", x: 20, y: 48, width: 300),
            line("Another independent English column.", x: 360, y: 20, width: 300)
        ]
        let regions = segmenter.segment(lines: lines, previous: [])
        XCTAssertEqual(regions.count, 3)
        XCTAssertTrue(regions.contains { $0.text == lines[0].text })
        XCTAssertTrue(regions.contains { $0.text == lines[1].text })
        XCTAssertTrue(regions.contains { $0.text == lines[2].text })
    }

    func testRegionMatchingIsOneToOneAndTracksTextRevision() {
        let segmenter = TextSegmenter()
        let left = line("The train leaves tomorrow at nine.", x: 20, y: 20, width: 300)
        let right = line(left.text, x: 400, y: 20, width: 300)
        let original = segmenter.segment(lines: [left, right], previous: [])
        let moved = segmenter.segment(lines: [line(left.text, x: 22, y: 20, width: 300), right], previous: original)
        XCTAssertEqual(moved.map(\.id), original.map(\.id))
        XCTAssertEqual(Set(moved.map(\.id)).count, 2)
        let changed = segmenter.segment(lines: [line("The train leaves today at eleven.", x: 22, y: 20, width: 300), right], previous: moved)
        XCTAssertEqual(changed[0].id, original[0].id)
        XCTAssertEqual(changed[0].sourceRevision, 2)
        XCTAssertEqual(changed[1].sourceRevision, 1)
    }

    func testAlignedSameLanguageLinesPreserveSpanOffsetsWhenGrouped() {
        let first = line("The train leaves tomorrow at nine.", x: 20, y: 20, width: 300)
        let second = line("Please arrive at the station early.", x: 20, y: 48, width: 300)
        let output = TextSegmenter().segment(lines: [first, second], previous: [])
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output[0].text, first.text + "\n" + second.text)
        XCTAssertEqual(output[0].spans[1].textRange.location, first.text.utf16.count + 1)
        XCTAssertEqual(output[0].spans[1].textRange.length, second.text.utf16.count)
    }

    func testShortLabelsDoNotInheritForeignPageLanguageAndSymbolsAreIgnored() {
        let page = "Le train part demain à neuf heures."
        let catalog = LanguageCatalog(languageNames: ["en": "English", "fr": "French"])
        let label = TextRegion(id: UUID(), sourceRevision: 1, text: "20 speakers",
                               bounds: PixelRect(x: 20, y: 20, width: 100, height: 20), spans: [], kind: .label)
        let language = catalog.language(for: label, pageText: page, manual: nil)
        XCTAssertTrue(language == "en" || language == nil, "A compact English label must not inherit French.")
        let symbols = TextSegmenter().segment(lines: [line("• )", x: 10, y: 10, width: 20)], previous: [])
        XCTAssertTrue(symbols.isEmpty)
    }

    func testParagraphIncludesShortContinuationAndRetainsConfidence() {
        let first = line("Please arrive at the station before the train leaves", x: 20, y: 20, width: 300)
        let last = line("at dawn.", x: 20, y: 48, width: 150)
        let output = TextSegmenter().segment(lines: [first, last], previous: [])
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output.first?.text, first.text + "\n" + last.text)
        XCTAssertEqual(output.first?.kind, .paragraph)
        XCTAssertEqual(output.first?.confidence, 1)
    }

    func testNestedOCRFragmentIsNotTranslatedAsAnotherBlock() {
        let full = line("This paragraph explains careful discussion and respectful feedback.", x: 20, y: 40, width: 620)
        let fragment = line("respectful feedback.", x: 450, y: 37, width: 170)
        let next = line("Everyone can ask questions and share useful ideas.", x: 20, y: 68, width: 500)
        let output = TextSegmenter().segment(lines: [fragment, full, next], previous: [])
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output.first?.text, full.text + "\n" + next.text)
    }

    func testAdjacentInlineFragmentsJoinButSeparateColumnsDoNot() {
        let left = line("This is the beginning", x: 20, y: 40, width: 170)
        let right = line("and this is the continuation.", x: 198, y: 38, width: 220)
        let column = line("Independent column content.", x: 500, y: 40, width: 200)
        let output = TextSegmenter().segment(lines: [left, right, column], previous: [])
        XCTAssertEqual(output.count, 2)
        XCTAssertTrue(output.contains { $0.text == left.text + " " + right.text })
        XCTAssertTrue(output.contains { $0.text == column.text })
    }

    func testOverlappingTranslationBackingsNeverPaintOverEachOther() async throws {
        let source = frame(width: 500, height: 220)
        let main = RegionTranslation(region: region(text: "Main paragraph", bounds: PixelRect(x: 20, y: 20, width: 400, height: 80)),
                                     text: "A complete translated paragraph stays readable without an overlapping fragment.")
        let fragment = RegionTranslation(region: region(text: "nested fragment", bounds: PixelRect(x: 280, y: 22, width: 150, height: 20)),
                                         text: "A nested fragment")
        let result = try await TranslationRenderer().render(frame: source, translations: [fragment, main])
        XCTAssertEqual(result.backingRegions.count, 1)
        XCTAssertEqual(result.backingRegions.first?.regionID, main.region.id)
        XCTAssertTrue(result.overflow.contains(fragment))
    }

    func testOverflowAtRightEdgeSuggestsWiderGlass() async throws {
        let source = frame(width: 220, height: 70)
        let translation = RegionTranslation(region: region(text: "Original", bounds: PixelRect(x: 20, y: 20, width: 180, height: 20)),
            text: "This complete translation needs more room to stay readable without shrinking the letters.")
        let result = try await TranslationRenderer().render(frame: source, translations: [translation])
        XCTAssertTrue(result.overflow.contains(translation))
        XCTAssertGreaterThan(try XCTUnwrap(result.suggestedWidth), 220)
    }

    func testCompactLabelExpandsHorizontallyWithoutStackingOrCoveringNeighbor() async throws {
        let source = frame(width: 400, height: 120)
        let label = TextRegion(id: UUID(), sourceRevision: 1, text: "Tâches",
                               bounds: PixelRect(x: 20, y: 20, width: 55, height: 20), spans: [], kind: .label)
        let neighbor = region(text: "Unchanged", bounds: PixelRect(x: 170, y: 20, width: 120, height: 20))
        let result = try await TranslationRenderer().render(frame: source,
            translations: [RegionTranslation(region: label, text: "Two tasks")], occupiedRegions: [label, neighbor])
        XCTAssertTrue(result.overflow.isEmpty)
        let backing = try XCTUnwrap(result.backingRegions.first?.bounds)
        XCTAssertGreaterThan(backing.width, label.bounds.width)
        XCTAssertLessThanOrEqual(backing.x + backing.width, neighbor.bounds.x - 2)
        let glyphs = nontransparentCoordinates(result.foreground)
        XCTAssertFalse(glyphs.isEmpty)
        XCTAssertLessThan((glyphs.map(\.y).max() ?? 0) - (glyphs.map(\.y).min() ?? 0), 30)
    }

    func testCompactLabelThatCannotFitRetainsOriginalAndUsesFullText() async throws {
        let source = frame(width: 130, height: 200)
        let label = TextRegion(id: UUID(), sourceRevision: 1, text: "Court",
                               bounds: PixelRect(x: 20, y: 20, width: 30, height: 20), spans: [], kind: .label)
        let translation = RegionTranslation(region: label, text: "Supercalifragilisticexpialidocious")
        let result = try await TranslationRenderer().render(frame: source, translations: [translation])
        XCTAssertEqual(result.overflow, [translation])
        XCTAssertEqual(result.initialBackground, source.surface)
        XCTAssertTrue(nontransparentCoordinates(result.foreground).isEmpty)
    }

    func testParagraphExpansionStopsBeforeCardSeparator() async throws {
        var source = frame(width: 300, height: 200)
        var pixels = source.surface.pixels
        for x in 0..<300 { setPixel(&pixels, size: source.surface.size, x: x, y: 65, rgba: (80, 80, 80, 255)) }
        source = replacingPixels(in: source, with: pixels)
        let text = region(text: "Original", bounds: PixelRect(x: 20, y: 20, width: 240, height: 20))
        let translation = RegionTranslation(region: text,
            text: "This translated paragraph needs more than the available space above the card separator.")
        let result = try await TranslationRenderer().render(frame: source, translations: [translation])
        XCTAssertEqual(result.overflow, [translation])
        XCTAssertTrue(result.backingRegions.allSatisfy { $0.bounds.y + $0.bounds.height <= 65 })
        XCTAssertEqual(pixel(result.initialBackground, x: 100, y: 65), [80, 80, 80, 255])
    }

    func testOpaqueBackingErasesSourceWhileOutsidePixelsArePreserved() async throws {
        let bounds = PixelRect(x: 20, y: 20, width: 200, height: 40)
        var source = frame()
        var pixels = source.surface.pixels
        for y in bounds.y..<(bounds.y + bounds.height) {
            for x in bounds.x..<(bounds.x + bounds.width) {
                setPixel(&pixels, size: source.surface.size, x: x, y: y, rgba: (0, 0, 0, 255))
            }
        }
        source = replacingPixels(in: source, with: pixels)
        let translation = RegionTranslation(region: region(text: "Original", bounds: bounds), text: "Bonjour")
        let output = try await TranslationRenderer().render(frame: source, translations: [translation])
        XCTAssertTrue(output.overflow.isEmpty)
        XCTAssertEqual(output.backingRegions.count, 1)
        XCTAssertTrue(output.backingRegions[0].blackText)
        XCTAssertEqual(output.frame.id, source.id)
        XCTAssertEqual(output.regions, [translation])
        for y in bounds.y..<(bounds.y + bounds.height) {
            for x in bounds.x..<(bounds.x + bounds.width) {
                XCTAssertEqual(pixel(output.initialBackground, x: x, y: y), [255, 255, 255, 255])
            }
        }
        XCTAssertEqual(pixel(output.initialBackground, x: 2, y: 2), pixel(source.surface, x: 2, y: 2))
        XCTAssertEqual(pixel(output.initialBackground, x: 300, y: 150), pixel(source.surface, x: 300, y: 150))
        let glyphCoordinates = nontransparentCoordinates(output.foreground)
        XCTAssertFalse(glyphCoordinates.isEmpty)
        XCTAssertTrue(glyphCoordinates.allSatisfy { $0.y >= 18 && $0.y < 66 && $0.x >= 18 && $0.x < 222 })
        XCTAssertEqual(pixel(output.foreground, x: 300, y: 150), [0, 0, 0, 0])
    }

    func testLongTranslationUsesOverflowInsteadOfShrinkingBelowSixteenPoints() async throws {
        let source = frame(width: 220, height: 55)
        let translation = RegionTranslation(
            region: region(text: "Source", bounds: PixelRect(x: 10, y: 28, width: 190, height: 18)),
            text: "Please read this translated paragraph carefully."
        )
        let output = try await TranslationRenderer().render(frame: source, translations: [translation])
        XCTAssertEqual(output.overflow, [translation])
        XCTAssertFalse(nontransparentCoordinates(output.foreground).isEmpty)
        XCTAssertEqual(output.regions[0].text, translation.text, "The full text must remain available to the overflow view.")
    }

    func testNoWholeWordFitKeepsOriginalInsteadOfPaintingAFragment() async throws {
        let source = frame(width: 70, height: 40)
        let translation = RegionTranslation(
            region: region(text: "Source", bounds: PixelRect(x: 10, y: 10, width: 35, height: 20)),
            text: "Supercalifragilisticexpialidocious"
        )
        let output = try await TranslationRenderer().render(frame: source, translations: [translation])
        XCTAssertEqual(output.overflow, [translation])
        XCTAssertEqual(output.initialBackground, source.surface)
        XCTAssertTrue(nontransparentCoordinates(output.foreground).isEmpty)
        XCTAssertTrue(output.backingRegions.isEmpty)
    }

    func testSkippedSourceRegionsStillBlockTranslationExpansion() async throws {
        let bounds = PixelRect(x: 20, y: 20, width: 200, height: 20)
        let translated = region(text: "Source", bounds: bounds)
        let untouched = region(text: "Already in the target language", bounds: PixelRect(x: 20, y: 45, width: 200, height: 40))
        var source = frame()
        var pixels = source.surface.pixels
        for y in 45..<85 {
            for x in 20..<220 { setPixel(&pixels, size: source.surface.size, x: x, y: y, rgba: (30, 180, 70, 255)) }
        }
        source = replacingPixels(in: source, with: pixels)
        let translation = RegionTranslation(region: translated, text: "A complete translation is longer and wraps onto several additional lines.")
        let output = try await TranslationRenderer().render(frame: source, translations: [translation],
                                                            occupiedRegions: [translated, untouched])
        XCTAssertEqual(output.overflow, [translation])
        XCTAssertEqual(pixel(output.initialBackground, x: 40, y: 55), pixel(source.surface, x: 40, y: 55))
        XCTAssertTrue(nontransparentCoordinates(output.foreground).allSatisfy { $0.y < 43 })
    }

    func testRetinaFontFloorStillProducesOverflowForAOneLineRegion() async throws {
        let source = frame(width: 440, height: 110, scale: 2)
        let translation = RegionTranslation(
            region: region(text: "Source", bounds: PixelRect(x: 20, y: 56, width: 380, height: 36)),
            text: "Please read this translated paragraph carefully."
        )
        let output = try await TranslationRenderer().render(frame: source, translations: [translation])
        XCTAssertEqual(output.overflow, [translation])
        XCTAssertFalse(nontransparentCoordinates(output.foreground).isEmpty)
    }

    func testDarkSourceUsesWhiteGlyphsAndInvalidGeometryFails() async throws {
        let source = frame(color: (0, 0, 0, 255))
        let translation = RegionTranslation(region: region(text: "Source", bounds: PixelRect(x: 20, y: 20, width: 200, height: 40)),
                                            text: "Hello")
        let output = try await TranslationRenderer().render(frame: source, translations: [translation])
        let positions = nontransparentCoordinates(output.foreground)
        XCTAssertEqual(output.backingRegions.count, 1)
        XCTAssertFalse(output.backingRegions[0].blackText)
        XCTAssertTrue(positions.contains { pixel(output.foreground, x: $0.x, y: $0.y)[0] > 200 })
        let invalid = RegionTranslation(region: region(text: "Source", bounds: PixelRect(x: -1, y: 0, width: 20, height: 20)), text: "Hello")
        do {
            _ = try await TranslationRenderer().render(frame: source, translations: [invalid])
            XCTFail("Out-of-frame source geometry must fail.")
        } catch {
            XCTAssertTrue(error is TranslationRenderError)
        }
    }

    private func region(text: String, bounds: PixelRect) -> TextRegion {
        TextRegion(id: UUID(), sourceRevision: 1, text: text, bounds: bounds, spans: [])
    }

    private func line(_ text: String, x: Int, y: Int, width: Int) -> OCRLine {
        let bounds = PixelRect(x: x, y: y, width: width, height: 20)
        return OCRLine(text: text, bounds: bounds,
                       spans: [OCRSpan(textRange: UTF16Range(location: 0, length: text.utf16.count), bounds: bounds, confidence: 1)],
                       confidence: 1)
    }

    private func frame(width: Int = 320, height: Int = 160, scale: Double = 1,
                       color: (UInt8, UInt8, UInt8, UInt8) = (255, 255, 255, 255)) -> CapturedFrame {
        let pixels = Data((0..<(width * height)).flatMap { _ in [color.2, color.1, color.0, color.3] })
        return CapturedFrame(id: FrameID(sequence: 1, capturedAtNanoseconds: 1),
                             stamp: RevisionStamp(geometry: 1, language: 1, model: "test"), displayID: 1,
                             captureRectGlobalPoints: PointRect(CGRect(x: 0, y: 0, width: Double(width) / scale, height: Double(height) / scale)),
                             surface: RasterSurface(size: PixelSize(width: width, height: height), bytesPerRow: width * 4, pixels: pixels),
                             scaleX: scale, scaleY: scale)
    }

    private func replacingPixels(in frame: CapturedFrame, with pixels: Data) -> CapturedFrame {
        CapturedFrame(id: frame.id, stamp: frame.stamp, displayID: frame.displayID,
                      captureRectGlobalPoints: frame.captureRectGlobalPoints,
                      surface: RasterSurface(size: frame.surface.size, bytesPerRow: frame.surface.bytesPerRow, pixels: pixels),
                      scaleX: frame.scaleX, scaleY: frame.scaleY)
    }

    private func setPixel(_ data: inout Data, size: PixelSize, x: Int, y: Int, rgba: (UInt8, UInt8, UInt8, UInt8)) {
        let offset = (y * size.width + x) * 4
        data.replaceSubrange(offset..<(offset + 4), with: [rgba.2, rgba.1, rgba.0, rgba.3])
    }

    private func pixel(_ surface: RasterSurface, x: Int, y: Int) -> [UInt8] {
        let offset = y * surface.bytesPerRow + x * 4
        return Array(surface.pixels[offset..<(offset + 4)])
    }

    private func nontransparentCoordinates(_ surface: RasterSurface) -> [(x: Int, y: Int)] {
        (0..<surface.size.height).flatMap { y in
            (0..<surface.size.width).compactMap { x in
                surface.pixels[y * surface.bytesPerRow + x * 4 + 3] == 0 ? nil : (x, y)
            }
        }
    }
}
