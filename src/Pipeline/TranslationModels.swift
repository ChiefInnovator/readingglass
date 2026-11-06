import Foundation

enum TextRegionKind: Sendable, Equatable {
    case paragraph, heading, label
}

struct TextRegion: Sendable, Equatable {
    let id: UUID
    let sourceRevision: UInt64
    let text: String
    let bounds: PixelRect
    let spans: [OCRSpan]
    let confidence: Float
    let kind: TextRegionKind

    init(id: UUID, sourceRevision: UInt64, text: String, bounds: PixelRect,
         spans: [OCRSpan], confidence: Float = 1, kind: TextRegionKind = .paragraph) {
        self.id = id
        self.sourceRevision = sourceRevision
        self.text = text
        self.bounds = bounds
        self.spans = spans
        self.confidence = confidence
        self.kind = kind
    }

    func touchesEdge(of frame: CapturedFrame) -> Bool {
        let margin = max(2, Int(ceil(max(frame.scaleX, frame.scaleY) * 2)))
        return bounds.x <= margin || bounds.y <= margin ||
            bounds.x + bounds.width >= frame.surface.size.width - margin ||
            bounds.y + bounds.height >= frame.surface.size.height - margin
    }

    func mayBeCutOff(in frame: CapturedFrame) -> Bool {
        if touchesEdge(of: frame) { return true }
        guard kind != .label else { return false }
        let heights = spans.map { $0.bounds.height }.sorted()
        let lineHeight = heights.isEmpty ? bounds.height : heights[heights.count / 2]
        // Vision may omit a clipped last word. Preserve the preceding text
        // even when the display has no room for a wider capture.
        let scale = max(frame.scaleX, frame.scaleY)
        let margin = min(Int(64 * scale), max(Int(12 * scale), lineHeight * 2))
        return bounds.x + bounds.width >= frame.surface.size.width - margin
    }
}

struct TranslationProgress: Sendable, Equatable {
    let total: Int
    var translated = 0
    var preserved = 0
    var uncertain = 0
    var clipped = 0
    var failed = 0
    var finished = false

    var processed: Int { translated + preserved + uncertain + clipped + failed }
    var compactStatus: String {
        if total == 0 { return "No text found" }
        if !finished { return "Translating \(processed)/\(total)…" }
        if clipped > 0 { return "Widen glass · \(clipped) cut off" }
        if failed > 0 { return "Partial · \(failed) failed" }
        if uncertain > 0 { return "Partial · \(uncertain) uncertain" }
        return translated > 0 ? "Ready · \(translated) translated" : "Original text preserved"
    }
    var summary: String {
        if total == 0 { return "No readable text in the glass." }
        if !finished { return "Translating \(processed) of \(total) regions…" }
        var parts = ["\(translated) translated", "\(preserved) unchanged"]
        if clipped > 0 { parts.append("\(clipped) cut off — widen or reposition the glass") }
        if uncertain > 0 { parts.append("\(uncertain) uncertain — original text retained") }
        if failed > 0 { parts.append("\(failed) failed — retry available") }
        return parts.joined(separator: " · ")
    }
}

struct RegionTranslation: Sendable, Equatable {
    let region: TextRegion
    let text: String
}

struct TranslationPresentation: Sendable {
    let frame: CapturedFrame
    let regions: [RegionTranslation]
    let foreground: RasterSurface
    let initialBackground: RasterSurface
    let overflow: [RegionTranslation]
    let backingRegions: [TranslationBacking]
    let suggestedWidth: Double?

    init(frame: CapturedFrame, regions: [RegionTranslation], foreground: RasterSurface,
         initialBackground: RasterSurface, overflow: [RegionTranslation],
         backingRegions: [TranslationBacking] = [], suggestedWidth: Double? = nil) {
        self.frame = frame
        self.regions = regions
        self.foreground = foreground
        self.initialBackground = initialBackground
        self.overflow = overflow
        self.backingRegions = backingRegions
        self.suggestedWidth = suggestedWidth
    }
}

struct TranslationBacking: Sendable {
    let regionID: UUID
    let bounds: PixelRect
    let blackText: Bool
}

enum TextTranslationFinish: Sendable, Equatable {
    case complete, outputLimit, timedOut, cancelled
}

struct TextTranslationResult: Sendable {
    let text: String
    let finish: TextTranslationFinish
}

protocol TextTranslating: Sendable {
    func countTokens(_ text: String) async throws -> Int
    func translate(text: String, source: String, target: String,
                   maximumOutputTokens: Int, deadline: Duration) async throws -> TextTranslationResult
    func cancel() async
}

enum TranslationEvent: Sendable {
    case working(RevisionStamp, String)
    case progress(RevisionStamp, String, TranslationProgress)
    case requestWidth(RevisionStamp, String, Double)
    case presented(TranslationPresentation, String)
    case unavailable(RevisionStamp, String, String)
}
