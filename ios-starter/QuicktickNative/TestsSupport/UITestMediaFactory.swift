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
        // A checked-in H.264/AAC clip exercises real AVPlayer decoding without
        // depending on a simulator video encoder or leaving partial MP4 files
        // behind when a previous test launch is terminated.
        guard let clip = Bundle.main.url(forResource: "UITestClip", withExtension: "mp4") else {
            throw APIError.server("UI test video resource is missing")
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
