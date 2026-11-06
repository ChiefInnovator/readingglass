import Foundation
@main struct VerifyRestoration {
    static func main() async throws {
        precondition(RestorationTiling.origins(length: 600) == [0, 448])
        precondition(RestorationTiling.origins(length: 300) == [0])
        for x in 0..<64 {
            let total = RestorationTiling.axisWeight(pixel: 448 + x, before: false, after: true) + RestorationTiling.axisWeight(pixel: x, before: true, after: false)
            precondition(abs(total - 1) < 0.00001)
        }
        let width = 600, height = 300
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let offset = (y * width + x) * 4
            bytes[offset] = UInt8(x % 256)
            bytes[offset+1] = UInt8(y % 256)
            bytes[offset+2] = 100
        }}
        let surface = RasterSurface(size: PixelSize(width: width, height: height), bytesPerRow: width * 4, pixels: Data(bytes))
        let frame = CapturedFrame(id: FrameID(sequence: 1, capturedAtNanoseconds: 1), stamp: RevisionStamp(geometry: 1, language: 1, model: "fixture"), displayID: 1, captureRectGlobalPoints: PointRect(CGRect(x: 0, y: 0, width: width, height: height)), surface: surface, scaleX: 1, scaleY: 1)
        let bounds = PixelRect(x: 445, y: 95, width: 40, height: 20)
        let region = TextRegion(id: UUID(), sourceRevision: 1, text: "fixture", bounds: bounds, spans: [OCRSpan(textRange: UTF16Range(location: 0, length: 7), bounds: bounds, confidence: 1)])
        let foreground = RasterSurface(size: surface.size, bytesPerRow: surface.bytesPerRow, pixels: Data(repeating: 0, count: bytes.count))
        let backing = PixelRect(x: 443, y: 93, width: 44, height: 24)
        let presentation = TranslationPresentation(frame: frame, regions: [RegionTranslation(region: region, text: "fixture")], foreground: foreground, initialBackground: surface, overflow: [], backingRegions: [TranslationBacking(regionID: region.id, bounds: backing, blackText: true)])
        let painter = BackgroundInpainter()
        try await painter.prepare(modelURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let start = ProcessInfo.processInfo.systemUptime
        let result = try await painter.restore(presentation: presentation)
        let restored = [UInt8](result.pixels)
        var preserved = 0
        for y in 0..<height { for x in 0..<width {
            let offset = (y * width + x) * 4
            let inside = x >= backing.x && x < backing.x + backing.width && y >= backing.y && y < backing.y + backing.height
            if !inside {
                precondition(Array(restored[offset..<offset+4]) == Array(bytes[offset..<offset+4]), "Unmasked pixel changed")
                preserved += 1
            } else {
                precondition(restored[offset] >= 153 && restored[offset+1] >= 153 && restored[offset+2] >= 153, "Backing contrast floor lost")
            }
        }}
        print("Native CoreML restore passed: 600x300, 2 overlapping tiles; \(preserved) unmasked pixels preserved; backing >=153; seconds \(ProcessInfo.processInfo.systemUptime - start)")
    }
}
