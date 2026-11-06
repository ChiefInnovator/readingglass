import CryptoKit
import Foundation
import NaturalLanguage

/// Finish one immutable snapshot at a time. Retain only the newest pending
/// text/layout, and publish one composite after all its regions have settled.
actor TranslationPipeline {
    typealias Handler = @MainActor @Sendable (TranslationEvent) -> Void
    private struct Work {
        let result: OCRResult
        let regions: [TextRegion]
        let key: String
        let generation: UInt64
    }
    private struct Cached {
        let text: String
        let expires: Date
    }

    private let translator: any TextTranslating
    private let renderer = TranslationRenderer()
    private let catalog: LanguageCatalog
    private let onEvent: Handler
    private let segmenter = TextSegmenter()
    private var stamp: RevisionStamp?
    private var target = "en"
    private var manualSource: String?
    private var maximumWidth: Double?
    private var generation: UInt64 = 0
    private var previous: [TextRegion] = []
    private var latest: Work?
    private var pending: Work?
    private var runningKey: String?
    private var runningGeneration: UInt64?
    private var completedKey: String?
    private var worker: Task<Void, Never>?
    private var cache: [String: Cached] = [:]

    init(translator: any TextTranslating, languageNames: [String: String], onEvent: @escaping Handler) {
        self.translator = translator
        self.catalog = LanguageCatalog(languageNames: languageNames)
        self.onEvent = onEvent
    }

    nonisolated static func signature(_ result: OCRResult) -> String {
        let text = result.lines.map { line in
            "\(line.bounds.x),\(line.bounds.y),\(line.bounds.width),\(line.bounds.height):\(line.confidence >= 0.6):\(line.text.precomposedStringWithCanonicalMapping)"
        }.joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func activate(stamp: RevisionStamp, target: String, manualSource: String?, maximumWidth: Double? = nil) async {
        generation &+= 1
        self.stamp = stamp
        self.target = target
        self.manualSource = manualSource
        self.maximumWidth = maximumWidth
        previous = []
        pending = nil
        latest = nil
        completedKey = nil
        await translator.cancel()
    }

    func stop() async {
        generation &+= 1
        stamp = nil
        pending = nil
        latest = nil
        completedKey = nil
        await translator.cancel()
    }

    func waitUntilIdle() async { await worker?.value }

    func retryLatest() {
        guard worker == nil, let latest, latest.result.frame.stamp == stamp else { return }
        pending = latest
        worker = Task { await self.run() }
    }

    func consume(_ result: OCRResult) async {
        guard result.frame.stamp == stamp else { return }
        let key = Self.signature(result)
        let regions = segmenter.segment(lines: result.lines, previous: previous)
        previous = regions
        let work = Work(result: result, regions: regions, key: key, generation: generation)
        latest = work
        if runningKey == key, runningGeneration == generation {
            // The newest screen matches the job already executing. A queued
            // intermediate screen must not run after this one completes.
            pending = nil
            return
        }
        if worker == nil, completedKey == key { return }
        pending = work
        if worker == nil { worker = Task { await self.run() } }
    }

    private func run() async {
        while let work = pending {
            pending = nil
            runningKey = work.key
            runningGeneration = work.generation
            guard current(work) else { continue }
            await onEvent(.working(work.result.frame.stamp, work.key))
            do {
                let scale = max(work.result.frame.scaleX, work.result.frame.scaleY)
                let clippedRight = work.regions.contains {
                    $0.confidence >= 0.6 && $0.kind != .label &&
                    $0.mayBeCutOff(in: work.result.frame) &&
                    $0.bounds.x + $0.bounds.width >= work.result.frame.surface.size.width - Int(64 * scale)
                }
                if clippedRight, await requestWidth(
                    max(work.result.frame.captureRectGlobalPoints.width * 1.2,
                        work.result.frame.captureRectGlobalPoints.width + 160), for: work) { continue }
                let page = work.regions.filter { $0.confidence >= 0.6 && !$0.mayBeCutOff(in: work.result.frame) }
                    .map(\.text).joined(separator: "\n")
                var translated: [RegionTranslation] = []
                var unknownLanguage = false
                var incompleteRegions = 0
                var progress = TranslationProgress(total: work.regions.count)
                var candidates: [(TextRegion, String)] = []
                for region in work.regions {
                    if region.mayBeCutOff(in: work.result.frame) {
                        progress.clipped += 1
                        continue
                    }
                    guard region.confidence >= 0.6 else {
                        progress.uncertain += 1
                        continue
                    }
                    // Counters and icon-adjacent numeric labels are safer as original pixels.
                    if region.kind == .label && !Self.numbers(in: region.text).isEmpty {
                        progress.preserved += 1
                        continue
                    }
                    guard let source = catalog.language(for: region, pageText: page, manual: manualSource) else {
                        if region.kind == .label {
                            progress.preserved += 1
                            continue
                        }
                        unknownLanguage = true
                        progress.uncertain += 1
                        continue
                    }
                    guard !Self.sameLanguage(source, target) else {
                        progress.preserved += 1
                        continue
                    }
                    candidates.append((region, source))
                }
                await onEvent(.progress(work.result.frame.stamp, work.key, progress))
                for (region, source) in candidates {
                    guard current(work) else { break }
                    do {
                    let key = "\(work.result.frame.stamp.model)|\(source)|\(target)|\(region.text)"
                    let output: String
                    if let item = cache[key], item.expires > Date() {
                        output = item.text
                    } else {
                        let chunks = try await TranslationChunker.chunks(region.text, translator: translator)
                        var completed: [String] = []
                        for chunk in chunks {
                            guard current(work) else { throw CancellationError() }
                            completed.append(try await translateComplete(chunk, source: source, target: target))
                        }
                        output = completed.joined(separator: ["ja", "zh-Hans", "zh-Hant"].contains(target) ? "" : " ")
                        guard Self.numbers(in: output) == Self.numbers(in: region.text) else {
                            throw TranslationFailure.incomplete
                        }
                        let entryBytes = key.utf8.count + output.utf8.count
                        let storedBytes = cache.reduce(0) { $0 + $1.key.utf8.count + $1.value.text.utf8.count }
                        if entryBytes <= 10_000_000 {
                            if cache.count >= 512 || storedBytes + entryBytes > 10_000_000 {
                                cache.removeAll(keepingCapacity: true)
                            }
                            cache[key] = Cached(text: output, expires: Date().addingTimeInterval(300))
                        }
                    }
                    translated.append(RegionTranslation(region: region, text: output))
                    progress.translated += 1
                    } catch {
                        guard current(work) else { throw CancellationError() }
                        incompleteRegions += 1
                        progress.failed += 1
                    }
                    if current(work) { await onEvent(.progress(work.result.frame.stamp, work.key, progress)) }
                }
                guard current(work) else { continue }
                let presentation = try await renderer.render(frame: work.result.frame, translations: translated,
                                                              occupiedRegions: work.regions)
                guard current(work) else { continue }
                if let width = presentation.suggestedWidth, await requestWidth(width, for: work) { continue }
                await onEvent(.presented(presentation, work.key))
                guard current(work) else { continue }
                progress.finished = true
                await onEvent(.progress(work.result.frame.stamp, work.key, progress))
                if translated.isEmpty && unknownLanguage {
                    await onEvent(.unavailable(work.result.frame.stamp, work.key, "Choose a source language to translate this snapshot."))
                } else if translated.isEmpty && incompleteRegions > 0 {
                    await onEvent(.unavailable(work.result.frame.stamp, work.key,
                        "Translation could not finish. Original text is still visible; use Retry to try this snapshot again."))
                }
                if current(work) { completedKey = work.key }
            } catch {
                guard current(work) else { continue }
                let message = error is CancellationError ? "Translation interrupted. Move the glass or retry." :
                    "This region could not be translated completely. Original text is still visible."
                await onEvent(.unavailable(work.result.frame.stamp, work.key, message))
                if current(work) { completedKey = work.key }
            }
        }
        runningKey = nil
        runningGeneration = nil
        worker = nil
    }

    private func current(_ work: Work) -> Bool {
        work.generation == generation && stamp == work.result.frame.stamp
    }

    private func requestWidth(_ proposed: Double, for work: Work) async -> Bool {
        guard current(work), let maximumWidth, maximumWidth.isFinite, proposed.isFinite else { return false }
        let width = min(proposed, maximumWidth)
        guard width > work.result.frame.captureRectGlobalPoints.width + 1 else { return false }
        await onEvent(.requestWidth(work.result.frame.stamp, work.key, width))
        return true
    }

    private static func sameLanguage(_ left: String, _ right: String) -> Bool {
        if left == right { return true }
        let a = left.split(separator: "-")
        let b = right.split(separator: "-")
        guard a.first == b.first else { return false }
        let aScript = a.dropFirst().first { $0.count == 4 }
        let bScript = b.dropFirst().first { $0.count == 4 }
        return aScript == bScript
    }

    private static func numbers(in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: "\\p{N}+(?:[.,:/-]\\p{N}+)*") else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }.sorted()
    }

    private func translateComplete(_ text: String, source: String, target: String) async throws -> String {
        let count = try await translator.countTokens(text)
        let result = try await translator.translate(text: text, source: source, target: target,
            maximumOutputTokens: min(512, max(96, 3 * count + 32)), deadline: .seconds(10))
        if result.finish == .complete, !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard result.finish == .outputLimit else { throw TranslationFailure.incomplete }
        let children = TranslationChunker.midpointSplit(text)
        guard children.count == 2 else { throw TranslationFailure.incomplete }
        var output: [String] = []
        for child in children {
            let tokens = try await translator.countTokens(child)
            guard tokens <= 128 else { throw TranslationFailure.incomplete }
            let retry = try await translator.translate(text: child, source: source, target: target,
                maximumOutputTokens: min(512, max(96, 3 * tokens + 32)), deadline: .seconds(10))
            guard retry.finish == .complete, !retry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TranslationFailure.incomplete
            }
            output.append(retry.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output.joined(separator: ["ja", "zh-Hans", "zh-Hant"].contains(target) ? "" : " ")
    }
}

enum TranslationFailure: Error { case incomplete }

enum TranslationChunker {
    static func chunks(_ text: String, translator: any TextTranslating) async throws -> [String] {
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var chunks: [String] = []
        while !remaining.isEmpty {
            try Task.checkCancellation()
            let source = remaining
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = source
            var ends: [String.Index] = []
            var starts: [String.Index] = []
            tokenizer.enumerateTokens(in: source.startIndex..<source.endIndex) { range, _ in
                starts.append(range.lowerBound)
                ends.append(range.upperBound)
                return ends.count < 81
            }
            var end = ends.count > 80 ? starts[80] : source.endIndex
            // Prefer a complete sentence when the 80-word boundary cuts a paragraph.
            let sentences = NLTokenizer(unit: .sentence)
            sentences.string = source
            var sentenceEnd: String.Index?
            sentences.enumerateTokens(in: source.startIndex..<source.endIndex) { range, _ in
                guard range.upperBound <= end else { return false }
                sentenceEnd = range.upperBound
                return true
            }
            if let sentenceEnd, end < source.endIndex { end = sentenceEnd }
            var candidate = String(source[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            while try await translator.countTokens(candidate) > 256 {
                guard source.distance(from: source.startIndex, to: end) > 1 else { throw TranslationFailure.incomplete }
                if let shorter = ends.last(where: { $0 < end }) { end = shorter }
                else { end = source.index(source.startIndex, offsetBy: max(1, source.distance(from: source.startIndex, to: end) / 2)) }
                candidate = String(source[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !candidate.isEmpty else { throw TranslationFailure.incomplete }
            }
            chunks.append(candidate)
            remaining = String(source[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return chunks
    }

    static func midpointSplit(_ text: String) -> [String] {
        guard text.count > 1 else { return [text] }
        let middle = text.index(text.startIndex, offsetBy: text.count / 2)
        let boundaries = text.indices.filter { text[$0].isWhitespace }
        let split = boundaries.min {
            abs(text.distance(from: middle, to: $0)) < abs(text.distance(from: middle, to: $1))
        } ?? middle
        let result = [String(text[..<split]), String(text[split...])].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return result.allSatisfy { !$0.isEmpty } ? result : [text]
    }
}
