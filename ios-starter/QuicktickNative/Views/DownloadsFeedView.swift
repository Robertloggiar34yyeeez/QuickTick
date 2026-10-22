import SwiftUI
import UIKit

struct DownloadsFeedView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View { DownloadContent(manager: store.downloads) }
}

private struct DownloadContent: View {
    @ObservedObject var manager: DownloadManager
    @State private var immersive = false
    @State private var immersivePostID: String?
    var body: some View {
        Group {
            if immersive { ImmersiveFeedView(posts: localPosts, offline: true, activePostID: $immersivePostID, onClose: { immersive = false }) }
            else {
                GeometryReader { geometry in
                ScrollView {
                LazyVStack(spacing: 18) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Saved offline")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .tracking(-1)
                            Text("\(manager.records.count) downloads, always with you")
                                .font(.subheadline).foregroundStyle(AppTheme.secondaryLabel)
                        }
                        Spacer()
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 23))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .padding(.top, 2)
                    if let error = manager.storageError { Text(error).foregroundStyle(.orange) }
                    if manager.records.isEmpty { ContentUnavailableView("No downloads yet", systemImage: "arrow.down.to.line", description: Text("Save posts to view them offline here.")) }
                    ForEach(manager.records) { record in
                        if let post = record.offlinePost {
                            PostCardView(post: post, available: CGSize(width: min(680, geometry.size.width - 32), height: geometry.size.height), playbackTab: 3, offline: true, onDelete: { manager.delete(record) })
                                .frame(maxWidth: .infinity)
                            HStack {
                                Text(record.formattedSize).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("download-size-\(record.key)")
                                Spacer()
                                if let url = record.exportURL {
                                    ShareLink(item: url) { Label("Export", systemImage: "square.and.arrow.up") }
                                        .accessibilityIdentifier("export-download-\(record.key)")
                                }
                            }
                        } else {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                if let path = record.thumbnailLocalPath {
                                    CachedMediaImage(url: URL(fileURLWithPath: path).absoluteString, pixels: 216).frame(width: 72, height: 72).clipped()
                                }
                                VStack(alignment: .leading) {
                                    Text(record.title); Text("\(record.provider) · \(record.state.rawValue)").font(.caption)
                                    Text(record.formattedSize).font(.caption.monospacedDigit())
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
                        .padding(14)
                        .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppTheme.border))
                        }
                    }
                }.padding(16).frame(maxWidth: .infinity)
                }
                }
            }
        }.scrollContentBackground(.hidden).background(AppTheme.canvas).navigationTitle("Downloads")
            .toolbar { Button(immersive ? "Feed" : "Offline Immersive") { immersive.toggle() }.disabled(!immersive && !localPosts.contains(where: \.isImmersiveMedia)) }
    }
    private var localPosts: [Post] {
        manager.records.compactMap(\.offlinePost)
    }
}
