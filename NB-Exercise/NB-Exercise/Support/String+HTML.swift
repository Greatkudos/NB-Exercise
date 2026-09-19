//
//  String+HTML.swift
//  NBExercise
//
//  Copied from Nexus (`RSSModels.swift`). Episode summaries in podcast feeds
//  are HTML, often badly formed, and get rendered as plain `Text` — so the
//  markup has to come out before display.
//
//  Done by hand rather than via `NSAttributedString(html:)`: that API is
//  main-thread-only and spins up a WebKit parser per call, which is far too
//  heavy for a list of episode rows.
//

import Foundation

extension String {
    /// A plain-text version of an HTML-ish string: decodes common entities,
    /// turns block-level tags into newlines, and strips the rest.
    nonisolated var strippingHTML: String {
        var s = self
            .replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</li>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(
                of: "</h[1-6]>",
                with: "\n\n",
                options: [.caseInsensitive, .regularExpression]
            )

        // Strip remaining tags.
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        // Decode common named entities.
        let namedEntities: [(String, String)] = [
            ("&nbsp;", " "),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'"),
            ("&#8217;", "\u{2019}"),
            ("&#8220;", "\u{201C}"),
            ("&#8221;", "\u{201D}"),
            ("&#8211;", "\u{2013}"),
            ("&#8212;", "\u{2014}"),
            ("&#8230;", "\u{2026}"),
            ("&hellip;", "\u{2026}"),
            ("&mdash;", "\u{2014}"),
            ("&ndash;", "\u{2013}"),
            ("&ldquo;", "\u{201C}"),
            ("&rdquo;", "\u{201D}"),
            ("&lsquo;", "\u{2018}"),
            ("&rsquo;", "\u{2019}"),
            ("&amp;", "&") // last, so we don't re-decode entities like &amp;lt;
        ]
        for (name, value) in namedEntities {
            s = s.replacingOccurrences(of: name, with: value)
        }

        // Decode decimal numeric entities (&#1234;).
        if let regex = try? NSRegularExpression(pattern: "&#(\\d+);") {
            let nsText = s as NSString
            var result = ""
            var cursor = 0
            for match in regex.matches(
                in: s,
                range: NSRange(location: 0, length: nsText.length)
            ) {
                let range = match.range
                let numRange = match.range(at: 1)
                result += nsText.substring(
                    with: NSRange(location: cursor, length: range.location - cursor)
                )
                let codeString = nsText.substring(with: numRange)
                if let code = UInt32(codeString), let scalar = Unicode.Scalar(code) {
                    result.unicodeScalars.append(scalar)
                }
                cursor = range.location + range.length
            }
            result += nsText.substring(
                with: NSRange(location: cursor, length: nsText.length - cursor)
            )
            s = result
        }

        // Collapse runs of spaces/tabs and excessive blank lines.
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
