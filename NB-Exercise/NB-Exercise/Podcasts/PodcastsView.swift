//
//  PodcastsView.swift
//  NBExercise
//
//  The Listen tab: subscribed shows, an episode list per show, and an "add
//  podcast" search sheet backed by the iTunes Search API.
//
//  Slimmed down from Nexus's 1,000-line `PodcastsView` to the template
//  essentials. Deliberately not carried over: the downloads manager screen,
//  per-feed settings, and the full-screen player. `PodcastStore` already has
//  the download and queue logic behind it, so those are additive later.
//

import SwiftUI

struct PodcastsView: View {
    @Bindable var store: PodcastStore

    @State private var isAddingPodcast = false

    var body: some View {
        NavigationStack {
            Group {
                if store.subscriptions.isEmpty {
                    emptyState
                } else {
                    subscriptionList
                }
            }
            .navigationTitle("Listen")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Podcast", systemImage: "plus") {
                        isAddingPodcast = true
                    }
                }
            }
            .sheet(isPresented: $isAddingPodcast) {
                AddPodcastView(store: store)
            }
            // An optional-item binding, so dismissing clears the message and
            // a second error can present cleanly.
            .alert(
                "Podcasts",
                isPresented: Binding(
                    get: { store.errorMessage != nil },
                    set: { if !$0 { store.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { store.errorMessage = nil }
            } message: {
                Text(store.errorMessage ?? "")
            }
        }
    }

    private var subscriptionList: some View {
        List {
            ForEach(store.subscriptions) { subscription in
                NavigationLink {
                    EpisodeListView(store: store, subscription: subscription)
                } label: {
                    SubscriptionRow(subscription: subscription)
                }
            }
            .onDelete { offsets in
                for index in offsets {
                    store.unsubscribe(store.subscriptions[index])
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Podcasts", systemImage: "headphones")
        } description: {
            Text("Add a show to listen to while you exercise.")
        } actions: {
            Button("Add Podcast") { isAddingPodcast = true }
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Subscription row

private struct SubscriptionRow: View {
    let subscription: Subscription

    var body: some View {
        HStack(spacing: 12) {
            PodcastArtwork(urlString: subscription.imageURL, size: 52)

            VStack(alignment: .leading, spacing: 2) {
                Text(subscription.displayTitle)
                    .font(.body)
                    .lineLimit(2)
                if let author = subscription.author, !author.isEmpty {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Show or episode artwork, with a placeholder while loading. `AsyncImage`
/// is fine here — feed artwork is small and the system caches it.
struct PodcastArtwork: View {
    let urlString: String?
    var size: CGFloat = 52

    var body: some View {
        AsyncImage(url: urlString.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "waveform")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}

// MARK: - Episode list

private struct EpisodeListView: View {
    @Bindable var store: PodcastStore
    let subscription: Subscription

    var body: some View {
        List {
            // The catalogue is shared across shows, so only render it when
            // it actually belongs to this feed — see `PodcastCatalogState`.
            if store.catalogState.feedURL == subscription.feedURL {
                switch store.catalogState {
                case .loading where store.episodes.isEmpty:
                    loadingRow
                case .failed where store.episodes.isEmpty:
                    failedRow
                default:
                    episodeRows
                }
            } else {
                loadingRow
            }
        }
        .navigationTitle(subscription.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: subscription.feedURL) {
            await store.refresh(feedURL: subscription.feedURL)
        }
        .refreshable {
            await store.refresh(feedURL: subscription.feedURL)
        }
    }

    private var episodeRows: some View {
        ForEach(store.episodes) { episode in
            EpisodeRow(
                episode: episode,
                state: store.state(for: episode.guid),
                isPlaying: store.playback.currentEpisode?.guid == episode.guid
                    && store.playback.isPlaying
            )
            .contentShape(.rect)
            .onTapGesture { store.playEpisode(episode) }
            .swipeActions(edge: .leading) {
                Button {
                    store.togglePlayed(guid: episode.guid, feedURL: episode.feedURL)
                } label: {
                    Label(
                        store.state(for: episode.guid).isPlayed ? "Unplayed" : "Played",
                        systemImage: store.state(for: episode.guid).isPlayed
                            ? "arrow.uturn.backward"
                            : "checkmark"
                    )
                }
                .tint(.accentColor)
            }
            .swipeActions(edge: .trailing) {
                if store.isDownloaded(episode) {
                    Button(role: .destructive) {
                        store.deleteDownload(episode)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                } else {
                    Button {
                        store.download(episode)
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                }
            }
        }
    }

    private var loadingRow: some View {
        HStack {
            ProgressView()
            Text("Loading episodes…")
                .foregroundStyle(.secondary)
        }
    }

    private var failedRow: some View {
        ContentUnavailableView {
            Label("Couldn't Load", systemImage: "wifi.exclamationmark")
        } description: {
            Text("Pull down to try again.")
        }
    }
}

private struct EpisodeRow: View {
    let episode: PodcastEpisode
    let state: EpisodeStateInfo
    let isPlaying: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if isPlaying {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                    Text(episode.title)
                        .font(.body)
                        .lineLimit(2)
                        .foregroundStyle(state.isPlayed ? .secondary : .primary)
                }

                if !episode.summary.isEmpty {
                    Text(episode.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    Text(episode.pubDate.formatted(date: .abbreviated, time: .omitted))
                    if let duration = episode.duration {
                        Text("·")
                        Text(Format.duration(duration))
                    }
                    // Only meaningful once started and not yet finished.
                    if state.position > 0, !state.isPlayed {
                        Text("·")
                        Text("\(Format.duration(state.position)) in")
                            .foregroundStyle(.tint)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Add podcast

private struct AddPodcastView: View {
    @Bindable var store: PodcastStore
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [PodcastSearchResult] = []
    @State private var isSearching = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(results) { result in
                        Button {
                            store.subscribe(
                                feedURL: result.feedURL,
                                title: result.title,
                                author: result.author,
                                imageURL: result.artworkURL?.absoluteString
                            )
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                PodcastArtwork(
                                    urlString: result.artworkURL?.absoluteString,
                                    size: 44
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(result.title)
                                        .lineLimit(2)
                                    Text(result.author)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    if isSearching { ProgressView() }
                } footer: {
                    // A raw feed URL is a valid search term — searching for
                    // one returns nothing, so say what to do with it.
                    Text("Search by name, or paste a feed URL and press return.")
                }
            }
            .navigationTitle("Add Podcast")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Podcast name or feed URL")
            .onSubmit(of: .search) { handleSubmit() }
            .task(id: query) {
                // Debounce: a keystroke-per-request would hammer the API.
                // A cancelled sleep means another keystroke arrived.
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                await runSearch()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    /// Pasting a feed URL and hitting return subscribes directly rather than
    /// searching for it.
    private func handleSubmit() {
        guard PodcastStore.normalizeFeedURL(query) != nil else { return }
        store.subscribe(feedURL: query)
        dismiss()
    }

    private func runSearch() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            results = []
            return
        }
        isSearching = true
        results = await store.search(term)
        isSearching = false
    }
}
