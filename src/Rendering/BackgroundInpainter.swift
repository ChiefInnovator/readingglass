import CoreML
import Foundation

enum RestorationError: LocalizedError, Sendable {
    case notReady
    case invalidModelIO
    case invalidPixels
    case predictionFailed(Int)

    var errorDescription: String? {
        switch self {
        case .notReady: "Background restoration is not ready."
        case .invalidModelIO: "The background model has an incompatible tensor interface."
        case .invalidPixels: "The background image or mask is invalid."
        case .predictionFailed(let code): "Background restoration failed (code \(code)); the readable translation is retained."
        }
    }
}

enum RestorationTiling {
    static let tileSize = 512
    static let stride = 448

    static func origins(length: Int) -> [Int] {
        guard length > 0 else { return [] }
        return Array(Swift.stride(from: 0, to: length, by: stride))
    }

    static func axisWeight(pixel: Int, before: Bool, after: Bool) -> Float {
        let center = Float(pixel) + 0.5
        let left: Float = before ? min(1, max(0, center / 64)) : 1
        let right: Float = after ? min(1, max(0, (512 - center) / 64)) : 1
        return left * right
    }
}

/// The model and its mutable multi-arrays never leave this actor. Restoration
/// returns one completed background; it cannot alter the foreground raster.
actor BackgroundInpainter {
    private var model: MLModel?
    private let scheduler: InferenceScheduler

    init(scheduler: InferenceScheduler = InferenceScheduler()) {
        self.scheduler = scheduler
    }

    func prepare(modelURL: URL) async throws {
        try Task.checkCancellation()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        configuration.allowLowPrecisionAccumulationOnGPU = false
        let loaded: MLModel
        do { loaded = try MLModel(contentsOf: modelURL, configuration: configuration) }
        catch { throw RestorationError.predictionFailed((error as NSError).code) }
        let inputs = loaded.modelDescription.inputDescriptionsByName
        let outputs = loaded.modelDescription.outputDescriptionsByName
        guard Set(inputs.keys) == ["image", "mask"], Set(outputs.keys) == ["output"],
              Self.matches(inputs["image"], shape: [1, 3, 512, 512]),
              Self.matches(inputs["mask"], shape: [1, 1, 512, 512]),
              Self.matches(outputs["output"], shape: [1, 3, 512, 512]) else {
            throw RestorationError.invalidModelIO
        }
        try Task.checkCancellation()
        model = loaded
    }

    func restore(presentation: TranslationPresentation) async throws -> RasterSurface {
        guard let model else { throw RestorationError.notReady }
        try Task.checkCancellation()
        let source = presentation.frame.surface
        _ = try source.makeCGImage()
        guard presentation.foreground.size == source.size,
              presentation.initialBackground.size == source.size else { throw RestorationError.invalidPixels }
        let width = source.size.width, height = source.size.height
        let count = width * height
        let sourceBytes = [UInt8](source.pixels)
        var mask = [UInt8](repeating: 0, count: count)
        let displayed = Set(presentation.backingRegions.map(\.regionID))
        for translated in presentation.regions where displayed.contains(translated.region.id) {
            let boxes = translated.region.spans.isEmpty
                ? [translated.region.bounds] : translated.region.spans.map(\.bounds)
            for box in boxes {
                guard Self.valid(box, size: source.size) else { throw RestorationError.invalidPixels }
                let x0 = max(0, box.x - 2), y0 = max(0, box.y - 2)
                let x1 = min(width, box.x + box.width + 2), y1 = min(height, box.y + box.height + 2)
                for y in y0..<y1 {
                    for x in x0..<x1 { mask[y * width + x] = 1 }
                }
            }
        }
        guard mask.contains(1) else { return presentation.initialBackground }
        var sums = [Float](repeating: 0, count: count * 3)
        var weights = [Float](repeating: 0, count: count)
        for originY in RestorationTiling.origins(length: height) {
            for originX in RestorationTiling.origins(length: width) {
                try Task.checkCancellation()
                let validWidth = min(512, width - originX), validHeight = min(512, height - originY)
                let containsMask = (0..<validHeight).contains { y in
                    mask[((originY + y) * width + originX)..<((originY + y) * width + originX + validWidth)].contains(1)
                }
                guard containsMask else { continue }
                try await scheduler.acquire(.refinement)
                do {
                    try Task.checkCancellation()
                    try autoreleasepool {
                    let image = try MLMultiArray(shape: [1, 3, 512, 512], dataType: .float32)
                    let tileMask = try MLMultiArray(shape: [1, 1, 512, 512], dataType: .float32)
                    let rgb = image.dataPointer.assumingMemoryBound(to: Float.self)
                    let maskValues = tileMask.dataPointer.assumingMemoryBound(to: Float.self)
                    let imageStrides = image.strides.map(\.intValue)
                    let maskStrides = tileMask.strides.map(\.intValue)
                    for y in 0..<512 {
                        if y % 64 == 0 { try Task.checkCancellation() }
                        for x in 0..<512 {
                            let globalX = min(width - 1, originX + x), globalY = min(height - 1, originY + y)
                            let byte = (globalY * width + globalX) * 4
                            let alpha = Float(sourceBytes[byte + 3]) / 255
                            for channel in 0..<3 {
                                let value = Float(sourceBytes[byte + 2 - channel]) / 255
                                rgb[channel * imageStrides[1] + y * imageStrides[2] + x * imageStrides[3]] =
                                    alpha > 0 ? min(1, value / alpha) : 0
                            }
                            maskValues[y * maskStrides[2] + x * maskStrides[3]] =
                                x < validWidth && y < validHeight ? Float(mask[globalY * width + globalX]) : 0
                        }
                    }
                    let input = try MLDictionaryFeatureProvider(dictionary: [
                        "image": MLFeatureValue(multiArray: image), "mask": MLFeatureValue(multiArray: tileMask)
                    ])
                    let prediction: MLFeatureProvider
                    do { prediction = try model.prediction(from: input) }
                    catch { throw RestorationError.predictionFailed((error as NSError).code) }
                    guard let output = prediction.featureValue(for: "output")?.multiArrayValue,
                          output.dataType == .float32, output.shape.map(\.intValue) == [1, 3, 512, 512] else {
                        throw RestorationError.invalidModelIO
                    }
                    let values = output.dataPointer.assumingMemoryBound(to: Float.self)
                    let strides = output.strides.map(\.intValue)
                    let xWeights = (0..<512).map {
                        RestorationTiling.axisWeight(pixel: $0, before: originX > 0, after: originX + 448 < width)
                    }
                    let yWeights = (0..<512).map {
                        RestorationTiling.axisWeight(pixel: $0, before: originY > 0, after: originY + 448 < height)
                    }
                    for y in 0..<512 {
                        if y % 64 == 0 { try Task.checkCancellation() }
                        for x in 0..<512 {
                            let position = y * strides[2] + x * strides[3]
                            let red = values[position]
                            let green = values[strides[1] + position]
                            let blue = values[2 * strides[1] + position]
                            guard red.isFinite, green.isFinite, blue.isFinite else { throw RestorationError.invalidPixels }
                            guard x < validWidth, y < validHeight else { continue }
                            let global = (originY + y) * width + originX + x
                            guard mask[global] == 1 else { continue }
                            let weight = xWeights[x] * yWeights[y]
                            weights[global] += weight
                            sums[global * 3] += min(1, max(0, red)) * weight
                            sums[global * 3 + 1] += min(1, max(0, green)) * weight
                            sums[global * 3 + 2] += min(1, max(0, blue)) * weight
                        }
                    }
                    }
                    await scheduler.release()
                } catch {
                    await scheduler.release()
                    throw error
                }
            }
        }
        try Task.checkCancellation()
        var result = sourceBytes
        for index in 0..<count where mask[index] == 1 {
            guard weights[index] > 0 else { throw RestorationError.invalidPixels }
            for channel in 0..<3 {
                let normalized = sums[index * 3 + channel] / weights[index]
                result[index * 4 + 2 - channel] = UInt8(min(255, max(0, (normalized * 255).rounded())))
            }
            result[index * 4 + 3] = 255
        }
        // Only explicit text backing may change an otherwise unmasked pixel.
        // Its fixed polarity/floor preserves readable contrast during the fade.
        for backing in presentation.backingRegions {
            guard Self.valid(backing.bounds, size: source.size) else { throw RestorationError.invalidPixels }
            let alpha: Float = backing.blackText ? 0.60 : 0.67
            let color: Float = backing.blackText ? 255 : 0
            for y in backing.bounds.y..<(backing.bounds.y + backing.bounds.height) {
                for x in backing.bounds.x..<(backing.bounds.x + backing.bounds.width) {
                    let offset = (y * width + x) * 4
                    for channel in 0..<3 {
                        result[offset + channel] = UInt8((Float(result[offset + channel]) * (1 - alpha) + color * alpha).rounded())
                    }
                    result[offset + 3] = 255
                }
            }
        }
        return RasterSurface(size: source.size, bytesPerRow: source.bytesPerRow, pixels: Data(result))
    }

    private static func matches(_ feature: MLFeatureDescription?, shape: [Int]) -> Bool {
        feature?.type == .multiArray && feature?.multiArrayConstraint?.dataType == .float32 &&
        feature?.multiArrayConstraint?.shape.map(\.intValue) == shape
    }

    private static func valid(_ rect: PixelRect, size: PixelSize) -> Bool {
        rect.x >= 0 && rect.y >= 0 && rect.width > 0 && rect.height > 0 &&
        rect.x <= size.width && rect.y <= size.height &&
        rect.width <= size.width - rect.x && rect.height <= size.height - rect.y
    }
}
