import Foundation
import CoreGraphics

struct PixelSize: Sendable, Equatable {
    let width: Int
    let height: Int
}

/// Half-open rectangle in upright, top-left-origin capture pixels.
struct PixelRect: Sendable, Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

/// Global AppKit points (bottom-left origin) when used by CapturedFrame.
struct PointRect: Sendable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct UTF16Range: Sendable, Equatable {
    let location: Int
    let length: Int
}

enum RasterError: Error {
    case invalidSurface
}

/// Immutable, packed BGRA8 premultiplied sRGB. No IOSurface or mutable buffer
/// crosses the capture queue, recognition actor or main-actor boundaries.
struct RasterSurface: Sendable, Equatable {
    let size: PixelSize
    let bytesPerRow: Int
    let pixels: Data

    func makeCGImage() throws -> CGImage {
        guard size.width > 0, size.height > 0,
              size.width <= Int.max / 4,
              bytesPerRow == size.width * 4,
              size.height <= Int.max / bytesPerRow,
              pixels.count == bytesPerRow * size.height,
              let provider = CGDataProvider(data: pixels as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: size.width, height: size.height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                    .union(.byteOrder32Little),
                provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent
              ) else { throw RasterError.invalidSurface }
        return image
    }
}

struct RevisionStamp: Sendable, Equatable {
    let geometry: UInt64
    let language: UInt64
    let model: String
}

struct FrameID: Sendable, Equatable {
    let sequence: UInt64
    let capturedAtNanoseconds: UInt64
}

struct CapturedFrame: Sendable, Equatable {
    let id: FrameID
    let stamp: RevisionStamp
    let displayID: UInt32
    let captureRectGlobalPoints: PointRect
    let surface: RasterSurface
    let scaleX: Double
    let scaleY: Double
}

struct OCRSpan: Sendable, Equatable {
    let textRange: UTF16Range
    let bounds: PixelRect
    let confidence: Float
}

struct OCRLine: Sendable, Equatable {
    let text: String
    let bounds: PixelRect
    let spans: [OCRSpan]
    let confidence: Float
}

struct OCRResult: Sendable {
    let frame: CapturedFrame
    let lines: [OCRLine]
    let supportedLanguages: [String]
    let elapsedSeconds: Double
}
