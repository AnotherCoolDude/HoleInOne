import Foundation

// MARK: - WikipediaPhotoService
//
// Finds a representative photo for a golf course using the Wikipedia REST API.
// No API key required — all endpoints are free and public.
//
// Strategy:
//   1. Search Wikipedia for the club/course name + country using the MediaWiki
//      action API.
//   2. Take the top article hit and fetch its REST summary, which includes
//      `thumbnail.source` — a properly licensed Wikimedia Commons image.
//   3. Request a larger size by bumping the pixel dimension in the URL
//      (Wikimedia serves thumbnails at arbitrary widths via URL rewriting).
//
// Coverage:
//   • Excellent for internationally known courses (St Andrews, Pebble Beach, …)
//   • Good for large German clubs that have Wikipedia articles
//   • Returns nil for small local clubs without Wikipedia pages — the caller
//     falls back to the og:image from ClubWebsiteScraper.

actor WikipediaPhotoService {
    static let shared = WikipediaPhotoService()

    private init() {}

    // MARK: - Public

    /// Returns the URL of a thumbnail image from Wikipedia for the given club.
    /// Returns `nil` when no relevant Wikipedia article or image is found.
    func thumbnailURL(for clubName: String, city: String, country: String) async -> URL? {
        // Try progressively broader queries to maximise hit rate
        let queries: [String] = [
            "\(clubName) golf course",
            "\(clubName) golf \(city)",
            "\(clubName) golf \(country)"
        ]

        for query in queries {
            if let url = await search(query: query) { return url }
        }
        return nil
    }

    // MARK: - Private

    private struct SearchResponse: Decodable {
        struct Query: Decodable {
            struct SearchResult: Decodable { let title: String }
            let search: [SearchResult]
        }
        let query: Query
    }

    private struct SummaryResponse: Decodable {
        struct Thumbnail: Decodable { let source: String; let width: Int; let height: Int }
        let thumbnail: Thumbnail?
    }

    private func search(query: String) async -> URL? {
        // Step 1: MediaWiki search → article title
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string:
                "https://en.wikipedia.org/w/api.php"
                + "?action=query&list=search&srsearch=\(encoded)"
                + "&srlimit=3&srwhat=text&format=json"
              ) else { return nil }

        guard let searchData = await fetch(url: searchURL),
              let response = try? JSONDecoder().decode(SearchResponse.self, from: searchData),
              let topResult = response.query.search.first else { return nil }

        // Require at least one golf-related keyword in the article title to avoid
        // matching unrelated articles (e.g. towns named after golf clubs).
        let titleLower = topResult.title.lowercased()
        guard titleLower.contains("golf") || titleLower.contains("links")
                || titleLower.contains("country club") else { return nil }

        // Step 2: REST summary → thumbnail URL
        guard let titleEncoded = topResult.title
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let summaryURL = URL(string:
                "https://en.wikipedia.org/api/rest_v1/page/summary/\(titleEncoded)"
              ) else { return nil }

        guard let summaryData = await fetch(url: summaryURL),
              let summary = try? JSONDecoder().decode(SummaryResponse.self, from: summaryData),
              let thumb = summary.thumbnail else { return nil }

        // Wikimedia serves thumbnails at arbitrary widths by rewriting the URL:
        // …/320px-image.jpg → …/800px-image.jpg
        let widerSource = upgradeThumbnailWidth(thumb.source, to: 800)
        return URL(string: widerSource)
    }

    /// Rewrites a Wikimedia thumbnail URL to request a larger width.
    /// e.g. `…/320px-Image.jpg` → `…/800px-Image.jpg`
    private func upgradeThumbnailWidth(_ source: String, to width: Int) -> String {
        // Wikimedia format: /thumb/…/<N>px-filename.ext
        guard let regex = try? NSRegularExpression(pattern: #"/(\d+)px-"#),
              let match = regex.firstMatch(in: source,
                                           range: NSRange(source.startIndex..., in: source)),
              let range = Range(match.range(at: 1), in: source) else { return source }
        return source.replacingCharacters(in: range, with: "\(width)")
    }

    // MARK: - Networking

    private func fetch(url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(
            "HoleInOne Golf App (iOS; contact via GitHub)",
            forHTTPHeaderField: "User-Agent"
        )
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return data
        } catch {
            #if DEBUG
            print("[WikipediaPhoto] Fetch failed: \(error.localizedDescription)")
            #endif
            return nil
        }
    }
}
