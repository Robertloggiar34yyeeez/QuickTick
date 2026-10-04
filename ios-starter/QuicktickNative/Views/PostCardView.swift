import SwiftUI

struct PostCardView: View {
    @EnvironmentObject private var store: AppStore
    let post: Post
    @State private var comments = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AsyncImage(url: URL(string: post.thumbUrl.isEmpty ? post.previewUrl : post.thumbUrl)) { image in image.resizable().scaledToFit() } placeholder: { Rectangle().fill(.secondary.opacity(0.15)).aspectRatio(4/3, contentMode: .fit) }
                .clipShape(RoundedRectangle(cornerRadius: 14))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack { ForEach(post.tags.prefix(10), id: \.self) { tag in
                    Menu("#\(tag)") { Button("Add to search") { store.includeTag(tag) }; Button("Exclude from search", role: .destructive) { store.excludeTag(tag) } }
                        .buttonStyle(.bordered)
                } }
            }
            HStack {
                Button("Like") { store.toggleFavorite(post) }
                Button("Less") { store.less(post) }
                Button("Download") { store.download(post) }
                Button("Comments") { comments = true }
                Spacer(); Text(post.provider).foregroundStyle(.secondary)
            }.buttonStyle(.bordered)
        }.padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .sheet(isPresented: $comments) { CommentsView(post: post) }
    }
}
