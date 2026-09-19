//
//  PodcastParser.swift
//  NBExercise
//
//  Copied from Nexus. XML parser for podcast RSS feeds: needs `<enclosure>`
//  audio URLs and the `itunes:` extensions (artwork, duration, author).
//
//  Namespaces are left unprocessed, so prefixed elements arrive verbatim as
//  qualified names like `itunes:image` and `content:encoded`.
//

import Foundation

nonisolated final class PodcastParser: NSObject, XMLParserDelegate {

    /// Fetches and parses a feed. Upgrades http→https first, bypasses the URL
    /// cache so a manual refresh really re-fetches, and identifies itself as
    /// a podcast client.
    func parseFeed(from url: URL, feedURL: String) async -> PodcastChannel? {
        var candidates: [URL] = [url]
        if url.scheme?.lowercased() == "http",
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.scheme = "https"
            if let upgraded = components.url { candidates = [upgraded, url] }
        }

        for candidate in candidates {
            do {
                var request = URLRequest(url: candidate)
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                request.setValue(
                    "NBExercise/0.1 (podcast client)",
                    forHTTPHeaderField: "User-Agent"
                )
                request.setValue(
                    "application/rss+xml, application/xml;q=0.9, */*;q=0.5",
                    forHTTPHeaderField: "Accept"
                )
                let data = try await URLSession.shared.data(for: request).0
                return parseData(data, feedURL: feedURL)
            } catch {
                continue
            }
        }
        return nil
    }

    // MARK: - Accumulated state

    private var feedTitle = ""
    private var feedAuthor: String?
    private var channelImageURL: String?
    private var episodes: [PodcastEpisode] = []
    private var resolvedFeedURL = ""

    private var currentElement = ""
    private var isProcessingItem = false
    /// True once we've entered the first `<item>`, so channel-level `<title>`
    /// and `<image>` aren't overwritten by episode ones.
    private var seenFirstItem = false

    private var itemTitle = ""
    private var itemDescription = ""
    private var itemSummary = ""
    private var itemGUID = ""
    private var itemPubDate = ""
    private var itemDuration = ""
    private var itemAudioURL: String?
    private var itemAudioType: String?
    private var itemImageURL: String?

    private func parseData(_ data: Data, feedURL: String) -> PodcastChannel? {
        resolvedFeedURL = feedURL
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { return nil }
        return PodcastChannel(
            title: feedTitle.isEmpty ? feedURL : feedTitle,
            author: feedAuthor,
            imageURL: channelImageURL.flatMap { URL(string: $0) },
            episodes: episodes,
            feedURL: feedURL
        )
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName

        if elementName == "item" {
            isProcessingItem = true
            seenFirstItem = true
            itemTitle = ""; itemDescription = ""; itemSummary = ""
            itemGUID = ""; itemPubDate = ""; itemDuration = ""
            itemAudioURL = nil; itemAudioType = nil; itemImageURL = nil
            return
        }

        // Enclosure carries the playable media URL as attributes.
        if elementName == "enclosure", isProcessingItem {
            if let url = attributeDict["url"]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
                itemAudioURL = url
                itemAudioType = attributeDict["type"]
            }
        }

        // itunes:image uses an href attribute at both channel and item level.
        if elementName == "itunes:image",
           let href = attributeDict["href"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !href.isEmpty {
            if isProcessingItem {
                itemImageURL = href
            } else if channelImageURL == nil {
                channelImageURL = href
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { append(string) }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let text = String(data: CDATABlock, encoding: .utf8) {
            append(text)
        } else if let text = String(data: CDATABlock, encoding: .isoLatin1) {
            append(text)
        }
    }

    private func append(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isProcessingItem {
            switch currentElement {
            case "title":                          itemTitle += trimmed
            case "description", "content:encoded": itemDescription += trimmed
            case "itunes:summary":                 itemSummary += trimmed
            case "guid":                           itemGUID += trimmed
            case "pubDate":                        itemPubDate += trimmed
            case "itunes:duration":                itemDuration += trimmed
            default: break
            }
        } else {
            switch currentElement {
            case "title" where !seenFirstItem:            feedTitle += trimmed
            case "itunes:author" where feedAuthor == nil: feedAuthor = trimmed
            // Channel-level RSS <image><url> as an artwork fallback.
            case "url" where channelImageURL == nil:      channelImageURL = trimmed
            default: break
            }
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard elementName == "item" else {
            currentElement = ""
            return
        }

        isProcessingItem = false
        currentElement = ""

        // Only items that actually carry audio become episodes.
        guard let audio = itemAudioURL, let audioURL = URL(string: audio) else { return }

        let guid = itemGUID.isEmpty ? audio : itemGUID
        let summarySource = itemSummary.isEmpty ? itemDescription : itemSummary
        let strippedTitle = itemTitle.strippingHTML

        episodes.append(
            PodcastEpisode(
                guid: guid,
                title: strippedTitle.isEmpty ? "Untitled Episode" : strippedTitle,
                summary: summarySource.strippingHTML,
                audioURL: audioURL,
                audioType: itemAudioType,
                pubDate: Self.parseDate(itemPubDate),
                duration: Self.parseDuration(itemDuration),
                imageURL: (itemImageURL ?? channelImageURL).flatMap { URL(string: $0) },
                feedURL: resolvedFeedURL,
                feedTitle: feedTitle
            )
        )
    }

    // MARK: - Field parsing

    /// Parses an `<itunes:duration>`: bare seconds ("3600"), "MM:SS", or
    /// "HH:MM:SS". Nil when absent or unparseable.
    static func parseDuration(_ raw: String) -> TimeInterval? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains(":") { return TimeInterval(trimmed) }
        let parts = trimmed.split(separator: ":").map { Double($0) ?? 0 }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        default: return nil
        }
    }

    /// RFC 822 / ISO 8601 parsing, tolerant of the assorted shapes real feeds
    /// emit. Falls back to "now" so an unparseable date can't drop an episode.
    static func parseDate(_ raw: String) -> Date {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Date() }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }

        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss z",
            "EEE, dd MMM yyyy HH:mm Z",
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
            "yyyy-MM-dd HH:mm:ss"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return Date()
    }
}
