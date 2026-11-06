import Foundation
import NaturalLanguage

/// Groups only aligned, nearby lines with the same confidently detected
/// language. Columns, cells and mixed-language fixture lines remain separate.
struct TextSegmenter {
    func segment(lines: [OCRLine], previous: [TextRegion]) -> [TextRegion] {
        let ordered = Self.coalescedLines(lines.filter { $0.text.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) &&
            $0.bounds.width > 0 && $0.bounds.height > 0 }
            .sorted { left, right in
                if left.bounds.y != right.bounds.y { return left.bounds.y < right.bounds.y }
                return left.bounds.x < right.bounds.x
            })
        var groups: [Group] = []
        let heights = ordered.map { $0.bounds.height }.sorted()
        let typicalHeight = heights.isEmpty ? 1 : heights[heights.count / 2]
        for line in ordered {
            let language = Self.detect(line.text)
            if let index = groups.indices.reversed().first(where: { Self.canAppend(line, language: language, to: groups[$0]) }) {
                var combined = groups.remove(at: index)
                let offset = combined.text.utf16.count + 1
                combined.text += "\n" + line.text
                combined.spans += line.spans.map {
                    OCRSpan(textRange: UTF16Range(location: $0.textRange.location + offset,
                                                 length: $0.textRange.length),
                            bounds: $0.bounds, confidence: $0.confidence)
                }
                combined.bounds = Self.union(combined.bounds, line.bounds)
                combined.lastLine = line.bounds
                combined.confidence = min(combined.confidence, line.confidence)
                combined.lineCount += 1
                if combined.language == nil { combined.language = language }
                groups.append(combined)
            } else {
                groups.append(Group(text: line.text, bounds: line.bounds, lastLine: line.bounds,
                                    spans: line.spans, language: language,
                                    confidence: line.confidence, lineCount: 1))
            }
        }

        var available = previous
        return groups.sorted { $0.bounds.y == $1.bounds.y ? $0.bounds.x < $1.bounds.x : $0.bounds.y < $1.bounds.y }.map { group in
            let words = group.text.split(whereSeparator: \.isWhitespace).count
            let kind: TextRegionKind = group.lineCount == 1 &&
                Double(group.bounds.height) >= Double(typicalHeight) * 1.18 && words <= 8 ? .heading :
                group.lineCount == 1 && words <= 4 && group.text.count <= 40 ? .label : .paragraph
            let candidates = available.enumerated().filter { Self.overlap($0.element.bounds, group.bounds) >= 0.80 }
            let match = candidates.sorted { lhs, rhs in
                let lEqual = Self.normalized(lhs.element.text) == Self.normalized(group.text)
                let rEqual = Self.normalized(rhs.element.text) == Self.normalized(group.text)
                if lEqual != rEqual { return lEqual }
                let lOverlap = Self.overlap(lhs.element.bounds, group.bounds)
                let rOverlap = Self.overlap(rhs.element.bounds, group.bounds)
                if lOverlap != rOverlap { return lOverlap > rOverlap }
                let lDistance = Self.distance(lhs.element.bounds, group.bounds)
                let rDistance = Self.distance(rhs.element.bounds, group.bounds)
                if lDistance != rDistance { return lDistance < rDistance }
                return lhs.element.id.uuidString < rhs.element.id.uuidString
            }.first
            if let match {
                let old = available.remove(at: match.offset)
                return TextRegion(id: old.id,
                                  sourceRevision: old.sourceRevision + (Self.normalized(old.text) == Self.normalized(group.text) ? 0 : 1),
                                  text: group.text, bounds: group.bounds, spans: group.spans,
                                  confidence: group.confidence, kind: kind)
            }
            return TextRegion(id: UUID(), sourceRevision: 1, text: group.text,
                              bounds: group.bounds, spans: group.spans,
                              confidence: group.confidence, kind: kind)
        }
    }

    private struct Group {
        var text: String
        var bounds: PixelRect
        var lastLine: PixelRect
        var spans: [OCRSpan]
        var language: NLLanguage?
        var confidence: Float
        var lineCount: Int
    }

    private static func canAppend(_ line: OCRLine, language: NLLanguage?, to group: Group) -> Bool {
        if let language, let previous = group.language {
            guard language == previous else { return false }
        } else {
            let words = group.text.split(whereSeparator: \.isWhitespace).count +
                line.text.split(whereSeparator: \.isWhitespace).count
            guard language != nil || group.language != nil, words >= 8,
                  !line.text.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains) else { return false }
        }
        let prior = group.lastLine
        guard Double(max(prior.height, line.bounds.height)) /
                Double(max(1, min(prior.height, line.bounds.height))) <= 1.25 else { return false }
        let gap = line.bounds.y - (prior.y + prior.height)
        let minWidth = min(prior.width, line.bounds.width)
        let horizontalOverlap = max(0, min(prior.x + prior.width, line.bounds.x + line.bounds.width) - max(prior.x, line.bounds.x))
        return gap >= -max(2, min(prior.height, line.bounds.height) / 5) &&
            gap <= Int(Double(max(prior.height, line.bounds.height)) * 0.80) &&
            abs(prior.x - line.bounds.x) <= max(8, minWidth / 12) &&
            Double(horizontalOverlap) / Double(max(1, minWidth)) >= 0.85
    }

    /// Vision may return a long line plus a nested fragment, or split one line
    /// around punctuation. Resolve those observations before paragraph grouping.
    private static func coalescedLines(_ lines: [OCRLine]) -> [OCRLine] {
        var result: [OCRLine] = []
        for line in lines {
            guard let index = result.indices.last(where: { sameRow(result[$0].bounds, line.bounds) }) else {
                result.append(line)
                continue
            }
            let previous = result[index]
            let left = previous.bounds.x <= line.bounds.x ? previous : line
            let right = previous.bounds.x <= line.bounds.x ? line : previous
            let overlap = left.bounds.x + left.bounds.width - right.bounds.x
            let gap = -overlap
            guard gap <= max(4, min(left.bounds.height, right.bounds.height) * 4 / 5) else {
                result.append(line)
                continue
            }
            let leftText = normalized(left.text).lowercased()
            let rightText = normalized(right.text).lowercased()
            if overlap > 0, leftText.contains(rightText) {
                result[index] = left
            } else if overlap > 0, rightText.contains(leftText) {
                result[index] = right
            } else if overlap >= min(left.bounds.width, right.bounds.width) * 4 / 5 {
                // A substantially smaller nested box is a duplicate observation,
                // not a second block to translate over the paragraph.
                let wider = left.bounds.width >= right.bounds.width ? left : right
                let narrower = left.bounds.width < right.bounds.width ? left : right
                if wider.bounds.width >= narrower.bounds.width * 3 / 2 {
                    result[index] = wider
                } else {
                    result[index] = OCRLine(text: wider.text, bounds: union(left.bounds, right.bounds),
                        spans: wider.spans, confidence: min(0.5, wider.confidence))
                }
            } else {
                let offset = left.text.utf16.count + 1
                let spans = left.spans + right.spans.map {
                    OCRSpan(textRange: UTF16Range(location: $0.textRange.location + offset,
                                                 length: $0.textRange.length),
                            bounds: $0.bounds, confidence: $0.confidence)
                }
                result[index] = OCRLine(text: left.text + " " + right.text,
                    bounds: union(left.bounds, right.bounds), spans: spans,
                    confidence: overlap > max(2, min(left.bounds.height, right.bounds.height) / 6) ?
                        min(0.5, min(left.confidence, right.confidence)) :
                        min(left.confidence, right.confidence))
            }
        }
        return result.sorted { $0.bounds.y == $1.bounds.y ? $0.bounds.x < $1.bounds.x : $0.bounds.y < $1.bounds.y }
    }

    private static func sameRow(_ a: PixelRect, _ b: PixelRect) -> Bool {
        let overlap = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
        return Double(overlap) / Double(max(1, min(a.height, b.height))) >= 0.6 &&
            Double(max(a.height, b.height)) / Double(max(1, min(a.height, b.height))) <= 1.6
    }

    private static func detect(_ text: String) -> NLLanguage? {
        guard text.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 12 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= 0.65 else { return nil }
        return best.key
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func union(_ a: PixelRect, _ b: PixelRect) -> PixelRect {
        let x = min(a.x, b.x), y = min(a.y, b.y)
        return PixelRect(x: x, y: y, width: max(a.x + a.width, b.x + b.width) - x,
                         height: max(a.y + a.height, b.y + b.height) - y)
    }

    private static func overlap(_ a: PixelRect, _ b: PixelRect) -> Double {
        let width = max(0, min(a.x + a.width, b.x + b.width) - max(a.x, b.x))
        let height = max(0, min(a.y + a.height, b.y + b.height) - max(a.y, b.y))
        let intersection = Double(width) * Double(height)
        return intersection / max(1, Double(a.width) * Double(a.height) + Double(b.width) * Double(b.height) - intersection)
    }

    private static func distance(_ a: PixelRect, _ b: PixelRect) -> Double {
        hypot(Double(2 * a.x + a.width - 2 * b.x - b.width),
              Double(2 * a.y + a.height - 2 * b.y - b.height))
    }
}
