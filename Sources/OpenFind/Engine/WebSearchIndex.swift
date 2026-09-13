import Foundation

/// Builds destinations locally. No query is sent until the user opens a row.
enum WebSearchIndex {
    static func directURL(_ text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace),
              let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    static func results(for query: String, limit: Int = 10) -> [QuickSearchItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        if let url = directURL(term) {
            return [QuickSearchItem(url: url, name: L("Open Website"), location: term, kind: .web)]
        }
        let engines = [("Google", "https://www.google.com/search", "q"),
                       ("Bing", "https://www.bing.com/search", "q"),
                       ("Baidu", "https://www.baidu.com/s", "wd"),
                       ("DuckDuckGo", "https://duckduckgo.com/", "q")]
        return engines.prefix(limit).compactMap { name, base, parameter in
            var components = URLComponents(string: base)
            // A query value must not inject additional parameters or a fragment.
            let encoded = term.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            components?.percentEncodedQuery = parameter + "=" + encoded
            guard let url = components?.url else { return nil }
            return QuickSearchItem(url: url, name: name, location: term, kind: .web)
        }
    }
}
