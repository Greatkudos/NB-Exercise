//
//  NowPlayingBar.swift
//  NBExercise
//
//  A compact transport pinned above the tab bar on every tab, so playback
//  stays reachable while the exercise timer runs on another tab — the whole
//  reason the player lives at app scope.
//
//  Collapses to nothing when there's no episode loaded, rather than showing
//  an empty bar.
//

import SwiftUI

struct NowPlayingBar: View {
    @Bindable var store: PodcastStore

    var body: some View {
        if let episode = store.playback.currentEpisode {
            VStack(spacing: 0) {
                progressBar(for: episode)

                HStack(spacing: 12) {
                    PodcastArtwork(
                        urlString: episode.imageURL?.absoluteString,
                        size: 40
                    )

                    VStack(alignment: .leading, spacing: 1) {
                        Text(episode.title)
                            .font(.footnote)
                            .lineLimit(1)
                        Text(episode.feedTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    controls
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.bar)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Now playing: \(episode.title)")
        }
    }

    /// A thin determinate line rather than a scrubber — the bar is too short
    /// to drag accurately, and the lock screen already offers scrubbing.
    @ViewBuilder
    private func progressBar(for episode: PodcastEpisode) -> some View {
        let total = store.playback.duration
        if total > 0 {
            ProgressView(value: min(store.playback.currentTime, total), total: total)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .frame(height: 2)
                .accessibilityHidden(true)
        } else {
            // Streaming items don't report a duration until the asset loads.
            Divider()
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button {
                store.playback.skipBackward()
            } label: {
                Image(systemName: "gobackward.15")
            }
            .accessibilityLabel("Skip back 15 seconds")

            Button {
                store.playback.togglePlayPause()
            } label: {
                Image(systemName: store.playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    // A fixed frame stops the row shifting as the glyph
                    // swaps between the two different widths.
                    .frame(width: 24)
            }
            .accessibilityLabel(store.playback.isPlaying ? "Pause" : "Play")

            Button {
                store.playback.skipForward()
            } label: {
                Image(systemName: "goforward.30")
            }
            .accessibilityLabel("Skip forward 30 seconds")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}
