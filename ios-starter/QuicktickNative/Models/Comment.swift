import Foundation

struct PostComment: Decodable, Identifiable, Sendable {
    let id: String
    let author: String
    let body: String
    let score: Double
    let createdAt: String
}

struct CommentPage: Decodable, Sendable {
    let items: [PostComment]
    let available: Bool
    let message: String?
}
