import Foundation
import Vision
import CoreGraphics

/// Built-in on-device visual encoder. Called only by the serial, idle analyzer.
enum VisualAppearanceEncoder {
    private final class Cancellation: @unchecked Sendable {
        let request: VNRequest
        init(_ request: VNRequest) { self.request = request }
    }
    static func embedding(_ image: DecodedMediaImage) async throws -> (vector: [Float], version: String) {
        try Task.checkCancellation()
        let request = VNGenerateImageFeaturePrintRequest()
        request.preferBackgroundProcessing = true
        request.usesCPUOnly = true
        request.revision = VNGenerateImageFeaturePrintRequest.supportedRevisions.contains(2) ? 2 : 1
        let cancellation = Cancellation(request)
        try await withTaskCancellationHandler {
            try VNImageRequestHandler(cgImage: image.image, options: [:]).perform([request])
        } onCancel: { cancellation.request.cancel() }
        try Task.checkCancellation()
        guard let observation = request.results?.first, observation.elementType == .float,
              (1...2048).contains(observation.elementCount), observation.data.count == observation.elementCount * 4 else { throw CocoaError(.coderInvalidValue) }
        let vector: [Float] = observation.data.withUnsafeBytes { bytes in
            (0..<observation.elementCount).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
        guard vector.allSatisfy(\.isFinite) else { throw CocoaError(.coderInvalidValue) }
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0 else { throw CocoaError(.coderInvalidValue) }
        return (vector.map { $0 / norm }, "vision-featureprint-r\(request.revision)-v2")
    }
    static func attributes(_ image: CGImage) -> [String: Double] {
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32)); return true
        }
        guard rendered else { return [:] }
        var counts: [String: Int] = [:], luminance = 0.0, squared = 0.0, neutral = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i+1]) / 255, b = Double(pixels[i+2]) / 255
            let high = max(r, max(g, b)), low = min(r, min(g, b)), delta = high - low
            let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
            luminance += l; squared += l * l
            let color: String
            if delta < 0.12 { neutral += 1; color = l < 0.2 ? "black" : (l > 0.8 ? "white" : "gray") }
            else if r == high { color = b > g * 1.2 ? "pink" : (g > r * 0.65 ? "orange" : "red") }
            else if g == high { color = r > g * 0.75 ? "yellow" : "green" }
            else { color = r > b * 0.65 ? "purple" : "blue" }
            counts[color, default: 0] += 1
        }
        var result: [String: Double] = [:]
        for (color, count) in counts where count > 205 { result["color:" + color] = min(0.85, Double(count) / 1024) }
        if neutral > 850 { result["style:monochrome"] = 0.8 }
        let mean = luminance / 1024, spread = sqrt(max(0, squared / 1024 - mean * mean))
        if mean < 0.25 { result["style:low_key_lighting"] = 0.8 }
        if mean > 0.75 { result["style:high_key_lighting"] = 0.8 }
        if spread > 0.3 { result["style:high_contrast"] = 0.75 }
        result[image.width > image.height ? "style:landscape_composition" : "style:portrait_composition"] = 0.7
        return result
    }
}
