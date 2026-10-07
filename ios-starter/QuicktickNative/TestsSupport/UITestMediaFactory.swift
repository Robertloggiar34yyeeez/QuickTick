#if DEBUG
import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

actor UITestMediaFactory {
    static let shared = UITestMediaFactory()
    func posts(sort: String) async throws -> [Post] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("QuicktickMediaFixture", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clip = folder.appendingPathComponent("clip.mp4")
        if !FileManager.default.fileExists(atPath: clip.path) {
            let writer = try AVAssetWriter(outputURL: clip, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180, kCVPixelBufferCGImageCompatibilityKey as String: true])
            writer.add(input); guard writer.startWriting() else { throw writer.error ?? URLError(.cannotCreateFile) }; writer.startSession(atSourceTime: .zero)
            for frame in 0..<60 {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
                var buffer: CVPixelBuffer?; CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32ARGB, nil, &buffer)
                guard let buffer else { throw URLError(.cannotCreateFile) }
                CVPixelBufferLockBaseAddress(buffer, []);
                if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                    context.setFillColor(CGColor(red: CGFloat(frame) / 60, green: 0.2, blue: 0.65, alpha: 1)); context.fill(CGRect(x: 0,y: 0,width: 320,height: 180))
                }
                CVPixelBufferUnlockBaseAddress(buffer, []); guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 20)) else { throw writer.error ?? URLError(.cannotCreateFile) }
            }
            input.markAsFinished(); await writer.finishWriting(); guard writer.status == .completed else { throw writer.error ?? URLError(.cannotCreateFile) }
        }
        let image = folder.appendingPathComponent("comic.jpg")
        if !FileManager.default.fileExists(atPath: image.path), let context = CGContext(data: nil,width: 320,height: 1600,bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.setFillColor(CGColor(red: 0.12,green: 0.16,blue: 0.3,alpha: 1));context.fill(CGRect(x: 0,y: 0,width: 320,height: 1600))
            if let cg = context.makeImage(), let destination = CGImageDestinationCreateWithURL(image as CFURL, UTType.jpeg.identifier as CFString,1,nil) { CGImageDestinationAddImage(destination,cg,nil);CGImageDestinationFinalize(destination) }
        }
        let recommended = sort == "recommended"
        let prefix = recommended ? "test" : "home"
        var video = Post(key: "\(prefix):video",id: "1",provider: "Rule34",tags: ["test_tag"],mediaUrl: clip.absoluteString,thumbUrl: image.absoluteString,type: "video");video.width=320;video.height=180
        var comic = Post(key: "\(prefix):image",id: "2",provider: "Rule34",tags: ["still_tag"],mediaUrl: image.absoluteString,type: "image");comic.width=320;comic.height=1600
        var next = Post(key:"\(prefix):next",id:"3",provider:video.provider,tags:video.tags,mediaUrl:video.mediaUrl,thumbUrl:video.thumbUrl,type:"video");next.width=320;next.height=180
        return [video,comic,next]
    }
}
#endif
