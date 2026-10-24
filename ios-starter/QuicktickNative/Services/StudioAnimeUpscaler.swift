import Foundation
import CoreGraphics
import CoreML
import ZIPFoundation

/// Fixed 522px Core ML model: up to 512px of content, with reflected padding.
/// Larger renders are blended from overlapping tiles instead of being rejected.
enum StudioAnimeUpscaler {
    static let name = "Real-ESRGAN X4+ Anime"
    static let estimatedBytes: Int64 = 8_500_000
    static let downloadURL = URL(string: "https://github.com/hanxiao/real-esrgan-coreml/releases/download/v1.0.0/RealESRGAN_anime_6B_522_fp16.zip")!

    private static let inputSide = 522
    private static let scale = 4
    private static let tileSize = 512
    private static let overlap = 32

    static func tileOrigins(length: Int) -> [Int] {
        guard length > tileSize else { return [0] }
        let count = Int(ceil(Double(length - tileSize) / Double(tileSize - overlap))) + 1
        return (0..<count).map { index in
            (index * (length - tileSize)) / (count - 1)
        }
    }

    static func install(zip: URL, in root: URL) throws -> URL {
        guard let archive = try? Archive(url: zip, accessMode: .read) else { throw StudioError.invalidArchive }
        var total: UInt64 = 0
        var count = 0
        for entry in archive {
            count += 1
            let components = entry.path.split(separator: "/")
            guard count < 4_000, !entry.path.hasPrefix("/"), !components.contains(".."),
                  !components.contains("."), entry.type == .file || entry.type == .directory
            else { throw StudioError.invalidArchive }
            total += UInt64(entry.uncompressedSize)
            guard total < 250_000_000 else { throw StudioError.invalidArchive }
        }
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent("staging-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        try manager.unzipItem(at: zip, to: staging)
        var queue = [staging]
        var package: URL?
        for _ in 0..<5 where package == nil {
            var children: [URL] = []
            for directory in queue {
                let entries = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
                for entry in entries where (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    if entry.pathExtension == "mlpackage" { package = entry; break }
                    children.append(entry)
                }
                if package != nil { break }
            }
            queue = children
        }
        guard let package else { throw StudioError.unsupportedModel }
        let compiled = try MLModel.compileModel(at: package)
        defer { try? manager.removeItem(at: compiled) }
        let destination = root.appendingPathComponent("RealESRGANAnime.mlmodelc", isDirectory: true)
        if manager.fileExists(atPath: destination.path) { return destination }
        try manager.moveItem(at: compiled, to: destination)
        return destination
    }

    static func upscale(_ source: CGImage, using compiledModel: URL) throws -> CGImage {
        guard source.width > 0, source.height > 0, source.width <= 1024, source.height <= 1024 else {
            throw StudioError.invalidFile
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let model = try MLModel(contentsOf: compiledModel, configuration: config)
        let width = source.width, height = source.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let didDraw = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard didDraw else { throw StudioError.noImage }
        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: inputSide), NSNumber(value: inputSide)], dataType: .float32)
        let floats = input.dataPointer.assumingMemoryBound(to: Float.self)
        let plane = inputSide * inputSide
        func reflected(_ index: Int, length: Int) -> Int {
            guard length > 1 else { return 0 }
            let period = 2 * length - 2
            let position = index % period
            return position < length ? position : period - position
        }
        let resultWidth = width * scale, resultHeight = height * scale
        var outputBytes = [UInt8](repeating: 255, count: resultWidth * resultHeight * 4)
        let xOrigins = tileOrigins(length: width)
        let yOrigins = tileOrigins(length: height)
        for (row, originY) in yOrigins.enumerated() {
            for (column, originX) in xOrigins.enumerated() {
                let contentWidth = min(tileSize, width - originX)
                let contentHeight = min(tileSize, height - originY)
                for y in 0..<inputSide {
                    let sy = originY + reflected(y, length: contentHeight)
                    for x in 0..<inputSide {
                        let sx = originX + reflected(x, length: contentWidth)
                        let sourceOffset = (sy * width + sx) * 4
                        let destination = y * inputSide + x
                        for channel in 0..<3 {
                            floats[channel * plane + destination] = Float(rgba[sourceOffset + channel]) / 255.0
                        }
                    }
                }
                let provider = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: input)])
                let prediction = try model.prediction(from: provider)
                guard let name = model.modelDescription.outputDescriptionsByName.keys.first,
                      let output = prediction.featureValue(for: name)?.multiArrayValue,
                      output.shape.map(\.intValue) == [1, 3, inputSide * scale, inputSide * scale],
                      output.dataType == .float32 || output.dataType == .float16 else { throw StudioError.noImage }
                let outputFloats = output.dataType == .float32
                    ? output.dataPointer.assumingMemoryBound(to: Float.self) : nil
                let outputHalves = output.dataType == .float16
                    ? output.dataPointer.assumingMemoryBound(to: UInt16.self) : nil
                let strides = output.strides.map(\.intValue)
                let blendX = column == 0 ? 0 : (xOrigins[column - 1] + tileSize - originX) * scale
                let blendY = row == 0 ? 0 : (yOrigins[row - 1] + tileSize - originY) * scale
                for y in 0..<(contentHeight * scale) {
                    let blendVertical = blendY > 0 ? min(1, Double(y) / Double(blendY)) : 1
                    for x in 0..<(contentWidth * scale) {
                        let blendHorizontal = blendX > 0 ? min(1, Double(x) / Double(blendX)) : 1
                        let weight = blendHorizontal * blendVertical
                        let destination = ((originY * scale + y) * resultWidth + originX * scale + x) * 4
                        for channel in 0..<3 {
                            let index = channel * strides[1] + y * strides[2] + x * strides[3]
                            let value = outputFloats.map { Double($0[index]) }
                                ?? outputHalves.map { Double(Float16(bitPattern: $0[index])) } ?? 0
                            let safeValue = value.isFinite ? max(0, min(1, value)) : 0
                            let enhanced = safeValue * 255
                            outputBytes[destination + channel] = UInt8((Double(outputBytes[destination + channel]) * (1 - weight) + enhanced * weight).rounded())
                        }
                    }
                }
            }
        }
        guard let dataProvider = CGDataProvider(data: Data(outputBytes) as CFData),
              let result = CGImage(width: resultWidth, height: resultHeight,
                                   bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: resultWidth * 4,
                                   space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                   provider: dataProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw StudioError.noImage }
        return result
    }
}
