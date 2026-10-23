import Foundation
import CoreGraphics
import CoreML
import ZIPFoundation

/// The fixed-shape, 522px Core ML conversion of Real-ESRGAN x4plus anime 6B.
/// The first 512px contain image data and 10px are reflection padding. This
/// avoids reallocating giant float buffers for each source image on an iPhone.
enum StudioAnimeUpscaler {
    static let name = "Real-ESRGAN X4+ Anime"
    static let estimatedBytes: Int64 = 8_500_000
    static let downloadURL = URL(string: "https://github.com/hanxiao/real-esrgan-coreml/releases/download/v1.0.0/RealESRGAN_anime_6B_522_fp16.zip")!

    private static let inputSide = 522
    private static let scale = 4

    static func install(zip: URL, in root: URL) throws -> URL {
        let archive: Archive
        do { archive = try Archive(url: zip, accessMode: .read) }
        catch { throw StudioError.invalidArchive }
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
        guard source.width > 0, source.height > 0, source.width <= 512, source.height <= 512 else {
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
        for y in 0..<inputSide {
            let sy = reflected(y, length: height)
            for x in 0..<inputSide {
                let sx = reflected(x, length: width)
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
              output.dataType == .float32 else { throw StudioError.noImage }
        let resultWidth = width * scale, resultHeight = height * scale
        let resultPlane = inputSide * scale * inputSide * scale
        let outputFloats = output.dataPointer.assumingMemoryBound(to: Float.self)
        var outputBytes = [UInt8](repeating: 255, count: resultWidth * resultHeight * 4)
        for y in 0..<resultHeight {
            for x in 0..<resultWidth {
                let sourceIndex = y * inputSide * scale + x
                let destination = (y * resultWidth + x) * 4
                for channel in 0..<3 {
                    let value = outputFloats[channel * resultPlane + sourceIndex]
                    outputBytes[destination + channel] = UInt8(max(0, min(255, Int((value * 255).rounded()))))
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
