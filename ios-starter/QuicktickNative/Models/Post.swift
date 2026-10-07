import Foundation
import CoreGraphics

struct Post: Codable, Identifiable, Hashable, Sendable, Equatable {
    let key: String
    let id: String
    let provider: String
    var score: Double = 0
    var tags: [String] = []
    var mediaUrl: String = ""
    var previewUrl: String = ""
    var thumbUrl: String = ""
    var pageUrl: String = ""
    var type: String = ""
    var embedUrl: String? = nil

    var isImmersiveMedia: Bool { ["video", "gif"].contains(type.lowercased()) }
    var cardPreviewURL: String {
        if type.lowercased() == "image" {
            return !previewUrl.isEmpty ? previewUrl : (!mediaUrl.isEmpty ? mediaUrl : thumbUrl)
        }
        let candidates = [previewUrl, thumbUrl].filter { !$0.isEmpty }
        return candidates.first(where: { url in
            let ext = URL(string: url)?.pathExtension.lowercased() ?? ""
            return !["mp4", "webm", "mov", "m3u8", "gif"].contains(ext)
        }) ?? thumbUrl
    }

    var width: Double?
    var height: Double?
    var caption: String?
    var creator: String?
    var category: String?
    var createdAt: Double?
    var nativeSize: CGSize? { guard let width, let height, width > 0, height > 0 else { return nil }; return CGSize(width: width, height: height) }

    var stableID: String { key.isEmpty ? "\(provider):\(id)" : key }
    var providerKey: Provider? { Provider(rawValue: provider.lowercased().replacingOccurrences(of: " ", with: "")) }

    enum CodingKeys: String, CodingKey {
        case key, id, provider, score, tags, mediaUrl, previewUrl, thumbUrl, pageUrl, type, embedUrl, width, height, caption, creator, category, createdAt
    }

    init(key: String, id: String, provider: String, score: Double = 0, tags: [String] = [], mediaUrl: String = "", previewUrl: String = "", thumbUrl: String = "", pageUrl: String = "", type: String = "", embedUrl: String? = nil) {
        self.key = key; self.id = id; self.provider = provider; self.score = score
        self.tags = tags; self.mediaUrl = mediaUrl; self.previewUrl = previewUrl
        self.thumbUrl = thumbUrl; self.pageUrl = pageUrl; self.type = type; self.embedUrl = embedUrl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        provider = try c.decode(String.self, forKey: .provider)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? "\(provider.lowercased()):\(id)"
        score = try c.decodeIfPresent(Double.self, forKey: .score) ?? 0
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        mediaUrl = try c.decodeIfPresent(String.self, forKey: .mediaUrl) ?? ""
        previewUrl = try c.decodeIfPresent(String.self, forKey: .previewUrl) ?? ""
        thumbUrl = try c.decodeIfPresent(String.self, forKey: .thumbUrl) ?? ""
        pageUrl = try c.decodeIfPresent(String.self, forKey: .pageUrl) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        embedUrl = try c.decodeIfPresent(String.self, forKey: .embedUrl)
        width = try? c.decode(Double.self, forKey: .width); height = try? c.decode(Double.self, forKey: .height)
        caption = try? c.decode(String.self, forKey: .caption); creator = try? c.decode(String.self, forKey: .creator); category = try? c.decode(String.self, forKey: .category); createdAt = try? c.decode(Double.self, forKey: .createdAt)
    }
}

struct PostPage: Codable, Sendable {
    var items: [Post]
    var hasMore: Bool?
}
