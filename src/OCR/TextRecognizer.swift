import Foundation
import CoreGraphics
import Vision
import NaturalLanguage

enum RecognitionError: LocalizedError, Sendable {
    case failed(code: Int)

    var errorDescription: String? {
        switch self {
        case .failed(let code):
            "Accurate text recognition failed (code \(code)). Try resuming. If it persists, check the recorded Vision/graphics diagnostic notes."
        }
    }
}

protocol Recognizing: Sendable {
    func recognize(_ frame: CapturedFrame) async throws -> OCRResult
}

actor TextRecognizer: Recognizing {
    private var manualLanguage: String?

    func setSourceLanguage(_ visionTag: String?) { manualLanguage = visionTag }
    /// A synchronous Vision call remains entirely on this actor's executor;
    /// neither Vision objects nor mutable image buffers reach the UI actor.
    func recognize(_ frame: CapturedFrame) async throws -> OCRResult {
        try Task.checkCancellation()
        return try autoreleasepool {
            let started = ProcessInfo.processInfo.systemUptime
            let request = VNRecognizeTextRequest()
            request.revision = VNRecognizeTextRequestRevision3
            request.recognitionLevel = .accurate
            request.automaticallyDetectsLanguage = true
            request.usesLanguageCorrection = true
            // Preserve the default recognitionLanguages in automatic mode.
            let supported: [String]
            do {
                supported = try request.supportedRecognitionLanguages()
                if let manualLanguage {
                    guard supported.contains(manualLanguage) else { throw RecognitionError.failed(code: -1) }
                    request.automaticallyDetectsLanguage = false
                    request.recognitionLanguages = manualLanguage == "en-US" ? [manualLanguage] :
                        [manualLanguage] + (supported.contains("en-US") ? ["en-US"] : [])
                }
                let image = try Self.recognitionImage(for: frame.surface)
                try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
            } catch {
                throw RecognitionError.failed(code: (error as NSError).code)
            }
            try Task.checkCancellation()
            let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let text = candidate.string
                let tokenizer = NLTokenizer(unit: .word)
                tokenizer.string = text
                var spans: [OCRSpan] = []
                tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                    if let box = try? candidate.boundingBox(for: range) {
                        let utf16 = NSRange(range, in: text)
                        spans.append(OCRSpan(
                            textRange: UTF16Range(location: utf16.location, length: utf16.length),
                            bounds: Self.pixelRect(box.boundingBox, size: frame.surface.size),
                            confidence: candidate.confidence))
                    }
                    return true
                }
                if spans.isEmpty, let box = try? candidate.boundingBox(for: text.startIndex..<text.endIndex) {
                    spans = [OCRSpan(textRange: UTF16Range(location: 0, length: text.utf16.count),
                                     bounds: Self.pixelRect(box.boundingBox, size: frame.surface.size),
                                     confidence: candidate.confidence)]
                }
                return OCRLine(
                    text: text,
                    bounds: Self.pixelRect(observation.boundingBox, size: frame.surface.size),
                    spans: spans,
                    confidence: candidate.confidence
                )
            }
            return OCRResult(frame: frame, lines: lines, supportedLanguages: supported,
                             elapsedSeconds: ProcessInfo.processInfo.systemUptime - started)
        }
    }

    /// Bound Vision's work on very large Retina captures. Normalized Vision
    /// boxes are still mapped back to the original full-resolution surface.
    static func recognitionImage(for surface: RasterSurface) throws -> CGImage {
        let original = try surface.makeCGImage()
        let width = Double(surface.size.width), height = Double(surface.size.height)
        let factor = min(1, 3072 / max(width, height), sqrt(4_000_000 / (width * height)))
        guard factor < 1 else { return original }
        let targetWidth = max(1, Int((width * factor).rounded(.down)))
        let targetHeight = max(1, Int((height * factor).rounded(.down)))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: targetWidth, height: targetHeight,
                  bitsPerComponent: 8, bytesPerRow: targetWidth * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw RasterError.invalidSurface
        }
        context.interpolationQuality = .high
        context.draw(original, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let image = context.makeImage() else { throw RasterError.invalidSurface }
        return image
    }

    private static func pixelRect(_ normalized: CGRect, size: PixelSize) -> PixelRect {
        let x0 = min(size.width, max(0, Int(floor(normalized.minX * Double(size.width)))))
        let y0 = min(size.height, max(0, Int(floor((1 - normalized.maxY) * Double(size.height)))))
        let x1 = min(size.width, max(x0, Int(ceil(normalized.maxX * Double(size.width)))))
        let y1 = min(size.height, max(y0, Int(ceil((1 - normalized.minY) * Double(size.height)))))
        return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
