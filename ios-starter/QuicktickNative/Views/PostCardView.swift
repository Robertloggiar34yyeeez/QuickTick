import SwiftUI

struct PostCardView: View {
    @EnvironmentObject private var store: AppStore
    let post: Post
    @State private var comments = false
    @State private var tags = false
    var body: some View {
        VStack(spacing: 0) {
            PosterView(url: post.thumbUrl.isEmpty ? post.previewUrl : post.thumbUrl)
                .aspectRatio(4/3, contentMode: .fit).frame(maxWidth: .infinity).background(Color.black).clipped()
            VStack(spacing: 8) {
                HStack {
                    Text(post.provider.uppercased()).font(.caption.weight(.bold)).tracking(1.5).foregroundStyle(AppTheme.gradient)
                    Spacer()
                    Button("View tags") { tags = true }.font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                }
                HStack(spacing: 0) {
                    ActionIcon(title: "Like", symbol: store.favorites[post.stableID] == nil ? "heart" : "heart.fill", selected: store.favorites[post.stableID] != nil) { store.toggleFavorite(post) }
                    ActionIcon(title: "Less", symbol: "hand.thumbsdown") { store.less(post) }
                    ActionIcon(title: "Download", symbol: "arrow.down.to.line") { store.download(post) }
                    ActionIcon(title: "Comments", symbol: "bubble.left") { comments = true }
                }
            }.padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 4)
        }.background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 22))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.07), lineWidth: 1))
            .sheet(isPresented: $comments) { CommentsView(post: post) }
            .sheet(isPresented: $tags) { PostTagsView(post: post) }
    }
}
