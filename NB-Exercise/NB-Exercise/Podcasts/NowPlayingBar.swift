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

    /// The speeds offered in the menu. Nexus had a slider in its full-screen
    /// player; with only this bar to put a control in, a short fixed list is
    /// both easier to hit and what people actually pick.
    private static let rates: [Float] = [0.8, 1.0, 1.25, 1.5, 1.75, 2.0]

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
            speedMenu

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

    /// Goes through the store rather than the player directly, so the chosen
    /// speed is remembered for this show and applied the next time one of its
    /// episodes starts.
    private var speedMenu: some View {
        Menu {
            Picker("Playback Speed", selection: rateBinding) {
                ForEach(Self.rates, id: \.self) { rate in
                    Text(Self.label(for: rate)).tag(rate)
                }
            }
        } label: {
            Text(Self.label(for: store.playback.playbackRate))
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                // Right-aligned with a floor, so the transport doesn't shuffle
                // sideways as the label grows from "1×" to "1.75×".
                .frame(minWidth: 38, alignment: .trailing)
        }
        .accessibilityLabel("Playback speed")
        .accessibilityValue(Self.label(for: store.playback.playbackRate))
    }

    private var rateBinding: Binding<Float> {
        Binding(
            get: { store.playback.playbackRate },
            set: { store.setPlaybackRate($0) }
        )
    }

    /// "1×", "1.25×" — trailing zeros dropped so the common speeds stay short.
    private static func label(for rate: Float) -> String {
        let number = Double(rate).formatted(.number.precision(.fractionLength(0...2)))
        return "\(number)×"
    }
}
