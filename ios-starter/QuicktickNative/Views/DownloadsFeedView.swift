import SwiftUI
import UIKit

struct DownloadsFeedView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View { DownloadContent(manager: store.downloads) }
}

private struct DownloadContent: View {
    @ObservedObject var manager: DownloadManager
    @State private var immersive = false
    var body: some View {
        Group {
            if immersive { ImmersiveFeedView(posts: localPosts, offline: true) }
            else {
                List {
                    if let error = manager.storageError { Text(error).foregroundStyle(.orange) }
                    ForEach(manager.records) { record in
                        VStack(alignment: .leading) {
                            HStack {
                                if let path = record.thumbnailLocalPath, let image = UIImage(contentsOfFile: path) {
                                    Image(uiImage: image).resizable().scaledToFill().frame(width: 72, height: 72).clipped()
                                }
                                VStack(alignment: .leading) {
                                    Text(record.title); Text("\(record.provider) · \(record.state.rawValue)").font(.caption)
                                    ProgressView(value: record.progress)
                                    if let error = record.errorMessage { Text(error).foregroundStyle(.orange).font(.caption) }
                                }
                            }
                            HStack {
                                if record.state == .downloading { Button("Pause") { manager.pause(record) }; Button("Cancel") { manager.cancel(record) } }
                                if record.state == .paused { Button("Resume") { manager.resume(record) }; Button("Cancel") { manager.cancel(record) } }
                                if record.state == .failed || record.state == .cancelled { Button("Retry") { manager.retry(record) } }
                                Spacer(); Button("Delete", role: .destructive) { manager.delete(record) }
                            }.buttonStyle(.bordered)
                        }
                    }
                }
            }
        }.navigationTitle("Downloads")
            .toolbar { Button(immersive ? "Feed" : "Offline Immersive") { immersive.toggle() }.disabled(!immersive && localPosts.isEmpty) }
    }
    private var localPosts: [Post] {
        manager.records.compactMap { record in
            guard record.state == .complete, let path = record.localMediaPath, FileManager.default.fileExists(atPath: path) else { return nil }
            let thumbnail = record.thumbnailLocalPath.map { URL(fileURLWithPath: $0).absoluteString } ?? ""
            let media = URL(fileURLWithPath: path).absoluteString
            return Post(key: record.key, id: record.postID, provider: record.provider, tags: record.tags, mediaUrl: media, previewUrl: record.mediaType == "image" && thumbnail.isEmpty ? media : thumbnail, thumbUrl: thumbnail, type: record.mediaType ?? "video")
        }
    }
}
