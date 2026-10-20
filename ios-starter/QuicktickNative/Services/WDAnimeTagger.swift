import Foundation
import CoreML
import CoreGraphics

/// Anime only, serial, lazy and off the feed/player paths. Never downloads models.
actor WDAnimeTagger {
    struct Label: Decodable, Sendable { let name: String; let category: Int }
    struct Result: Sendable { var attributes: [String: Double] = [:]; var subjects: [String] = [] }
    private var model: MLModel?
    private var labels: [Label] = []
    private var unavailable = false
    private var cooldown = Date.distantPast
    private(set) var inferenceMs = 0.0
    private(set) var loadCount = 0
    var retainsModel: Bool { model != nil }
    func cooldownDelay() -> Double { max(0, cooldown.timeIntervalSinceNow) }
    func release() { model = nil; labels = [] }
    static func axis(_ tag: String) -> String {
        if ["hair", "eyes", "skin", "braid", "ponytail"].contains(where: tag.contains) { return "appearance" }
        if ["dress", "shirt", "skirt", "uniform", "qipao", "kimono", "jacket", "hat", "boots", "swimsuit", "gloves", "stockings"].contains(where: tag.contains) { return "clothing" }
        if ["smil", "blush", "tears", "angry", "expression", "closed_eyes", "open_mouth"].contains(where: tag.contains) { return "expression" }
        if ["sitting", "standing", "kneeling", "lying", "arms_up", "looking_", "hand_on"].contains(where: tag.contains) { return "pose" }
        if ["background", "outdoors", "indoors", "beach", "forest", "bedroom", "sky"].contains(where: tag.contains) { return "setting" }
        if ["style", "watercolor", "sketch", "realistic", "pixel_art", "monochrome"].contains(where: tag.contains) { return "style" }
        return "visual"
    }
    static func signals(labels: [Label], probabilities: [Float]) -> Result {
        var result = Result()
        for (label, value) in zip(labels, probabilities) where value.isFinite {
            if label.category == 4, value >= 0.9, result.subjects.count < 3 {
                let name = label.name.lowercased()
                result.subjects.append(name.hasPrefix("chun-li") || name.hasPrefix("chun_li") ? "chun_li" : name)
            } else if label.category == 0, value >= 0.65 {
                result.attributes[axis(label.name) + ":" + label.name] = Double(value) * 0.8
            }
        }
        result.attributes = Dictionary(uniqueKeysWithValues: result.attributes.sorted { $0.value > $1.value }.prefix(48).map { ($0.key,$0.value) })
        return result
    }
    func analyze(_ image: DecodedMediaImage, domain: VisualDomain) -> Result? {
        guard domain == .anime, !unavailable, cooldown < .now, !Task.isCancelled,
              !ProcessInfo.processInfo.isLowPowerModeEnabled, ProcessInfo.processInfo.thermalState.rawValue < 2 else { return nil }
        defer { release() }
        do {
            if model == nil {
                guard let url = Bundle.main.url(forResource: "WDTaggerV3", withExtension: "mlmodelc"),
                      let labelURL = Bundle.main.url(forResource: "wd-v3-labels", withExtension: "json") else { unavailable = true; return nil }
                labels = try JSONDecoder().decode([Label].self, from: Data(contentsOf: labelURL))
                guard labels.count == 10861 else { unavailable = true; return nil }
                let config = MLModelConfiguration(); config.computeUnits = .cpuAndNeuralEngine
                model = try MLModel(contentsOf: url, configuration: config)
                loadCount += 1
            }
            try Task.checkCancellation()
            var pixels = [UInt8](repeating: 255, count: 448 * 448 * 4)
            let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
                guard let ctx = CGContext(data: bytes.baseAddress, width: 448, height: 448, bitsPerComponent: 8, bytesPerRow: 448*4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0,y: 0,width: 448,height: 448))
                let scale = 448 / Double(max(image.image.width, image.image.height))
                let w = Double(image.image.width) * scale, h = Double(image.image.height) * scale
                ctx.interpolationQuality = .high
                ctx.draw(image.image, in: CGRect(x: (448-w)/2,y: (448-h)/2,width: w,height: h)); return true
            }
            guard rendered else { return nil }
            let input = try MLMultiArray(shape: [1,3,448,448], dataType: .float32)
            let pointer = input.dataPointer.assumingMemoryBound(to: Float.self), plane = 448*448
            for i in 0..<plane { pointer[i] = Float(pixels[i*4+2])/127.5-1; pointer[plane+i] = Float(pixels[i*4+1])/127.5-1; pointer[2*plane+i] = Float(pixels[i*4])/127.5-1 }
            try Task.checkCancellation()
            let start = Date()
            guard let output = try model?.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image":input])).featureValue(for: "probabilities")?.multiArrayValue,
                  output.count == labels.count else { return nil }
            inferenceMs = Date().timeIntervalSince(start)*1000
            if inferenceMs > 1500 { cooldown = Date.now.addingTimeInterval(30) }
            try Task.checkCancellation()
            let result = Self.signals(labels: labels, probabilities: (0..<output.count).map { output[$0].floatValue })
            // Do not retain a large transformer while the user resumes scrolling.
            release(); return result
        } catch { release(); return nil }
    }
}
