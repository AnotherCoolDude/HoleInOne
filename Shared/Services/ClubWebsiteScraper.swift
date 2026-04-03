import Foundation

// MARK: - ClubWebsiteScraper
//
// Searches the official website of a golf club and extracts:
//   • A Platzuebersicht (course overview) image URL — used as a visual header
//     in RoundSetupView.
//   • Per-hole scorecard data (par, handicap, length) when the club uses the
//     TYPO3 tx_gkmbcoursetable plugin — common at German clubs.
//   • Individual hole diagram image URLs (bahn1.jpg … bahn18.jpg style paths).
//
// Discovery strategy:
//   1. DuckDuckGo Lite search → extract real club URL from DDG redirect.
//   2. Fetch club homepage; detect CMS (TYPO3 / WordPress / unknown).
//   3. Try known scorecard sub-paths (e.g. /platz/, /club/platz/spielbahnen/).
//   4. Parse whichever content is found.
//
// Caching:
//   Results are stored in UserDefaults under "club_web_<courseId>" for 30 days.
//   A failed lookup (no website found) is cached for 7 days to avoid repeated
//   fruitless searches.
//
// Limitations:
//   • HTML parsing is done with basic string scanning — no external dependencies.
//   • Only public, indexable pages are accessed (no login walls).
//   • Image URLs are not downloaded; only the URL string is returned.

// MARK: - Public types

struct ClubWebData {
    /// The club's main website URL.
    let websiteURL: URL?

    /// Platzuebersicht / course overview image.
    let overviewImageURL: URL?

    /// Per-hole images keyed by hole number (1-based). May be empty.
    let holeImageURLs: [Int: URL]

    /// Structured scorecard data extracted from TYPO3 tx_gkmbcoursetable plugin.
    /// Nil when the CMS is WordPress or the page has no HTML scorecard table.
    let scrapedHoles: [ScrapedHole]?

    /// True when at least one useful piece of data was found.
    var hasData: Bool {
        overviewImageURL != nil || !holeImageURLs.isEmpty || scrapedHoles != nil
    }

    struct ScrapedHole {
        let number: Int
        let par: Int?
        let handicap: Int?
        /// Length in metres (converted from yards/metres depending on page).
        let lengthMeters: Int?
    }
}

// MARK: - Service

actor ClubWebsiteScraper {
    static let shared = ClubWebsiteScraper()

    private let cacheTTL: TimeInterval       = 30 * 24 * 60 * 60  // 30 days
    private let failureCacheTTL: TimeInterval =  7 * 24 * 60 * 60  //  7 days
    private let cachePrefix = "club_web_"

    private init() {}

    // MARK: - Public entry point

    /// Scrapes the golf club's website for hole imagery and scorecard data.
    /// Returns a cached result if one exists and is still fresh.
    func scrape(courseId: String, clubName: String, city: String) async -> ClubWebData {
        // Cache check
        if let cached = loadCache(courseId: courseId) { return cached }

        // 1. Find the club's website
        let websiteURL = await findWebsite(clubName: clubName, city: city)

        guard let siteURL = websiteURL else {
            let empty = ClubWebData(websiteURL: nil, overviewImageURL: nil,
                                    holeImageURLs: [:], scrapedHoles: nil)
            saveCache(courseId: courseId, data: empty, ttl: failureCacheTTL)
            return empty
        }

        // 2. Scrape the site
        let result = await scrapeSite(baseURL: siteURL)
        let data = ClubWebData(
            websiteURL: siteURL,
            overviewImageURL: result.overviewURL,
            holeImageURLs: result.holeImages,
            scrapedHoles: result.holes
        )
        saveCache(courseId: courseId, data: data,
                  ttl: data.hasData ? cacheTTL : failureCacheTTL)
        return data
    }

    // MARK: - Step 1: find the club website via DuckDuckGo Lite

    private func findWebsite(clubName: String, city: String) async -> URL? {
        // Build query: first 4 words of club name + city
        let nameWords = clubName
            .components(separatedBy: .whitespaces)
            .prefix(4)
            .joined(separator: " ")
        let query = "\(nameWords) \(city) Golf"
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://lite.duckduckgo.com/lite/?q=\(encoded)") else {
            return nil
        }

        guard let html = await fetchHTML(url: searchURL) else { return nil }

        // DDG Lite result links look like:
        //   <a class="result-link" href="/l/?uddg=https%3A%2F%2Fwww.example.de&amp;rut=...">
        //   or just href="https://www.example.de"
        //
        // Extract all candidate result URLs and pick the best match.
        let candidates = extractDDGResultURLs(from: html, baseURL: searchURL)

        // Score each candidate: prefer URLs that contain club name tokens or "golf"
        let tokens = clubName.lowercased().split(separator: " ").map(String.init)
        let scored: [(URL, Int)] = candidates.map { url in
            let host = url.host?.lowercased() ?? ""
            let score = tokens.filter { host.contains($0) }.count
                + (host.contains("golf") ? 1 : 0)
            return (url, score)
        }

        // Reject obviously wrong domains (social media, directories, booking platforms)
        let blocklist = ["facebook", "instagram", "twitter", "youtube", "yelp",
                         "tripadvisor", "booking", "golfbuchung", "golfbreaks",
                         "hole19", "golfnow", "thegrint", "golfcourseapi", "google"]
        let filtered = scored.filter { url, _ in
            let host = url.host?.lowercased() ?? ""
            return !blocklist.contains(where: { host.contains($0) })
        }

        return filtered.max(by: { $0.1 < $1.1 })?.0
    }

    /// Parses DuckDuckGo Lite HTML and returns the target URLs of search results.
    private func extractDDGResultURLs(from html: String, baseURL: URL) -> [URL] {
        var urls: [URL] = []

        // Find all href attributes in the page
        var searchRange = html.startIndex..<html.endIndex
        while let anchorRange = html.range(of: "<a ", range: searchRange) {
            guard let closeRange = html.range(of: ">", range: anchorRange.upperBound..<html.endIndex) else {
                break
            }
            let tagContent = String(html[anchorRange.lowerBound..<closeRange.upperBound])

            if let href = extractAttribute("href", from: tagContent) {
                if let url = resolveURL(href, relativeTo: baseURL) {
                    urls.append(url)
                }
            }
            searchRange = closeRange.upperBound..<html.endIndex
        }

        return urls
    }

    // MARK: - Step 2: scrape the club site

    private struct ScrapeResult {
        var overviewURL: URL?
        var holeImages: [Int: URL] = [:]
        var holes: [ClubWebData.ScrapedHole]?
    }

    private func scrapeSite(baseURL: URL) async -> ScrapeResult {
        guard let homeHTML = await fetchHTML(url: baseURL) else { return ScrapeResult() }

        var result = ScrapeResult()

        // Detect CMS
        let isTypo3 = homeHTML.contains("tx_gkmbcoursetable")
            || homeHTML.contains("/fileadmin/")
            || homeHTML.lowercased().contains("typo3")

        // Look for Platzuebersicht image on homepage first
        result.overviewURL = findOverviewImage(in: homeHTML, baseURL: baseURL)

        // Try known sub-pages for scorecard content
        let scorecardPaths = isTypo3
            ? ["/platz/", "/platz/spielbahnen/", "/club/platz/spielbahnen/",
               "/kurs/", "/golfanlage/", "/golf/platz/"]
            : ["/platz/", "/der-platz/", "/unsere-anlage/",
               "/golfplatz/", "/course/", "/spielbahn/"]

        for path in scorecardPaths {
            guard let subURL = URL(string: path, relativeTo: baseURL)?.absoluteURL else { continue }
            guard let subHTML = await fetchHTML(url: subURL) else { continue }

            // Check for tx_gkmbcoursetable (TYPO3 structured scorecard)
            if subHTML.contains("tx_gkmbcoursetable") {
                result.holes = parseTypo3Scorecard(html: subHTML)
            }

            // Look for Platzuebersicht image on this sub-page too
            if result.overviewURL == nil {
                result.overviewURL = findOverviewImage(in: subHTML, baseURL: subURL)
            }

            // Look for hole diagram images
            let holeImages = findHoleImages(in: subHTML, baseURL: subURL)
            for (num, url) in holeImages where result.holeImages[num] == nil {
                result.holeImages[num] = url
            }

            // Stop if we found scorecard data
            if result.holes != nil { break }
        }

        // Also scan the homepage for hole images if none found yet
        if result.holeImages.isEmpty {
            let holeImages = findHoleImages(in: homeHTML, baseURL: baseURL)
            result.holeImages = holeImages
        }

        return result
    }

    // MARK: - Platzuebersicht image detection

    /// Finds an img src that looks like a course overview image.
    private func findOverviewImage(in html: String, baseURL: URL) -> URL? {
        // Patterns that suggest a Platzuebersicht / course map image
        let keywords = ["platzuebersicht", "platz-uebersicht", "platz_uebersicht",
                        "course-map", "coursemap", "course_map", "lageplatz",
                        "gelaendeplan", "lageplan"]

        var searchRange = html.startIndex..<html.endIndex
        while let imgRange = html.range(of: "<img", options: .caseInsensitive, range: searchRange) {
            guard let closeRange = html.range(of: ">", range: imgRange.upperBound..<html.endIndex) else {
                break
            }
            let tag = String(html[imgRange.lowerBound..<closeRange.upperBound])
            if let src = extractAttribute("src", from: tag) {
                let srcLower = src.lowercased()
                if keywords.contains(where: { srcLower.contains($0) }),
                   let url = resolveURL(src, relativeTo: baseURL) {
                    return url
                }
            }
            searchRange = closeRange.upperBound..<html.endIndex
        }
        return nil
    }

    // MARK: - Hole diagram image detection

    /// Finds individual hole diagram images (e.g. bahn1.jpg, __1_.png).
    private func findHoleImages(in html: String, baseURL: URL) -> [Int: URL] {
        var result: [Int: URL] = [:]

        // Patterns for German golf club hole image URLs:
        //   bahn1.jpg, bahn-1.jpg, bahn_1.jpg
        //   hole1.jpg, hole-1.jpg
        //   __1_.png (Augsburg-style)
        //   spielbahn1.jpg
        let pattern = try? NSRegularExpression(
            pattern: #"(?:bahn|hole|spielbahn|__)[_\-]?(\d{1,2})[_\-]?(?:\.[a-z]{3,4})"#,
            options: .caseInsensitive
        )

        var searchRange = html.startIndex..<html.endIndex
        while let imgRange = html.range(of: "<img", options: .caseInsensitive, range: searchRange) {
            guard let closeRange = html.range(of: ">", range: imgRange.upperBound..<html.endIndex) else {
                break
            }
            let tag = String(html[imgRange.lowerBound..<closeRange.upperBound])
            if let src = extractAttribute("src", from: tag) {
                let srcLower = src.lowercased()

                // Check if it looks like a hole image
                let srcNS = srcLower as NSString
                let fullRange = NSRange(location: 0, length: srcNS.length)
                if let match = pattern?.firstMatch(in: srcLower, range: fullRange),
                   let numRange = Range(match.range(at: 1), in: srcLower),
                   let holeNum = Int(srcLower[numRange]),
                   holeNum >= 1, holeNum <= 18,
                   let url = resolveURL(src, relativeTo: baseURL) {
                    result[holeNum] = url
                }
            }
            searchRange = closeRange.upperBound..<html.endIndex
        }

        return result
    }

    // MARK: - TYPO3 tx_gkmbcoursetable parser

    /// Parses the structured per-hole scorecard embedded by the TYPO3
    /// tx_gkmbcoursetable plugin. Returns an array of up to 18 ScrapedHole entries.
    ///
    /// Typical HTML structure (one block per hole):
    ///   <div class="tx_gkmbcoursetable">
    ///     <table>
    ///       <tr class="...header..."> … hole number … </tr>
    ///       <tr class="tx_gkmbcoursetable_rating">
    ///         <td>Länge</td><td>420</td><td>380</td>…
    ///       </tr>
    ///       <tr class="tx_gkmbcoursetable_rating">
    ///         <td>Par</td><td>4</td>…
    ///       </tr>
    ///       <tr class="tx_gkmbcoursetable_rating">
    ///         <td>Hcp</td><td>7</td>…
    ///       </tr>
    ///     </table>
    ///   </div>
    private func parseTypo3Scorecard(html: String) -> [ClubWebData.ScrapedHole]? {
        var results: [ClubWebData.ScrapedHole] = []

        // Split HTML into per-hole blocks using the tx_gkmbcoursetable div boundary
        let blocks = html.components(separatedBy: "tx_gkmbcoursetable")
        guard blocks.count > 2 else { return nil }  // Need at least a few blocks

        var holeNumber = 1
        for block in blocks.dropFirst() {
            // Extract all <td> cell text from this block (up to the next block boundary)
            let cells = extractTableCells(from: block)
            guard cells.count >= 3 else { holeNumber += 1; continue }

            // Try to find row labels and their values
            // The first cell in a rating row is a label ("Par", "Hcp", "Länge", "Length")
            var par: Int?
            var handicap: Int?
            var length: Int?

            var i = 0
            while i < cells.count {
                let label = cells[i].lowercased().trimmingCharacters(in: .whitespaces)
                let value = i + 1 < cells.count ? cells[i + 1] : ""
                let numericValue = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))

                if label.hasPrefix("par") {
                    par = numericValue
                } else if label.hasPrefix("hcp") || label.hasPrefix("hdcp") || label.hasPrefix("hand") {
                    handicap = numericValue
                } else if label.hasPrefix("läng") || label.hasPrefix("leng") || label.hasPrefix("yds")
                    || label.hasPrefix("mtr") || label.hasPrefix("meter") {
                    if let meters = numericValue {
                        // Values ≥ 200 in a German club are likely metres already.
                        // Values < 200 are more likely par/hcp ─ skip.
                        length = meters >= 80 ? meters : nil
                    }
                }
                i += 1
            }

            if par != nil || handicap != nil || length != nil {
                results.append(ClubWebData.ScrapedHole(
                    number: holeNumber,
                    par: par,
                    handicap: handicap,
                    lengthMeters: length
                ))
                holeNumber += 1
            }

            if holeNumber > 18 { break }
        }

        return results.isEmpty ? nil : results
    }

    /// Extracts the visible text content of every <td> element in an HTML fragment.
    private func extractTableCells(from html: String) -> [String] {
        var cells: [String] = []
        var searchRange = html.startIndex..<html.endIndex

        while let openRange = html.range(of: "<td", options: .caseInsensitive, range: searchRange) {
            // Skip past the opening tag's >
            guard let tagClose = html.range(of: ">", range: openRange.upperBound..<html.endIndex) else { break }
            guard let closeTag = html.range(of: "</td", options: .caseInsensitive,
                                             range: tagClose.upperBound..<html.endIndex) else { break }

            let rawContent = String(html[tagClose.upperBound..<closeTag.lowerBound])
            let text = stripHTML(rawContent).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { cells.append(text) }

            searchRange = closeTag.upperBound..<html.endIndex
        }
        return cells
    }

    // MARK: - HTML utilities

    /// Extracts an attribute value from an HTML tag string.
    private func extractAttribute(_ name: String, from tag: String) -> String? {
        // Match  name="value"  or  name='value'
        let patterns = ["\(name)=\"([^\"]*)\"", "\(name)='([^']*)'"]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let ns = tag as NSString
            if let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)),
               let valueRange = Range(match.range(at: 1), in: tag) {
                return String(tag[valueRange])
            }
        }
        return nil
    }

    /// Strips all HTML tags from a string, collapsing whitespace.
    private func stripHTML(_ html: String) -> String {
        var result = html
        // Remove tags
        while let open = result.range(of: "<"),
              let close = result.range(of: ">", range: open.upperBound..<result.endIndex) {
            result.removeSubrange(open.lowerBound...close.upperBound)
        }
        // Decode common HTML entities
        result = result
            .replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#160;", with: " ")
        return result
    }

    /// Resolves an href/src (potentially relative, potentially a DDG redirect) to an absolute URL.
    private func resolveURL(_ raw: String, relativeTo base: URL) -> URL? {
        // Handle DuckDuckGo redirect: /l/?uddg=<ENCODED_URL>&rut=…
        if raw.contains("uddg=") {
            guard let comps = URLComponents(string: raw.hasPrefix("http") ? raw : "https://lite.duckduckgo.com\(raw)"),
                  let uddg = comps.queryItems?.first(where: { $0.name == "uddg" })?.value,
                  let decoded = uddg.removingPercentEncoding,
                  let url = URL(string: decoded) else { return nil }
            return url
        }

        // Absolute URL
        if let url = URL(string: raw), url.scheme != nil { return url }

        // Relative URL — resolve against base
        return URL(string: raw, relativeTo: base)?.absoluteURL
    }

    // MARK: - Networking

    private func fetchHTML(url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("de-DE,de;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }

            // Try UTF-8 first, then Latin-1 (common for German sites)
            if let text = String(data: data, encoding: .utf8) { return text }
            if let text = String(data: data, encoding: .isoLatin1) { return text }
            if let text = String(data: data, encoding: .windowsCP1252) { return text }
            return nil
        } catch {
            #if DEBUG
            print("[ClubScraper] Fetch failed for \(url): \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    // MARK: - Caching

    private struct CacheEntry: Codable {
        let websiteURL: String?
        let overviewImageURL: String?
        let holeImageURLs: [String: String]  // "1" … "18" → URL string
        struct CachedHole: Codable {
            let number: Int
            let par: Int?
            let handicap: Int?
            let lengthMeters: Int?
        }
        let scrapedHoles: [CachedHole]?
        let timestamp: Date
        let ttl: TimeInterval
    }

    private func cacheKey(_ courseId: String) -> String { cachePrefix + courseId }

    private func loadCache(courseId: String) -> ClubWebData? {
        guard let raw = UserDefaults.standard.data(forKey: cacheKey(courseId)),
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: raw),
              Date().timeIntervalSince(entry.timestamp) < entry.ttl else { return nil }

        let websiteURL    = entry.websiteURL.flatMap { URL(string: $0) }
        let overviewURL   = entry.overviewImageURL.flatMap { URL(string: $0) }
        let holeImages    = Dictionary(uniqueKeysWithValues:
            entry.holeImageURLs.compactMap { k, v -> (Int, URL)? in
                guard let num = Int(k), let url = URL(string: v) else { return nil }
                return (num, url)
            }
        )
        let holes = entry.scrapedHoles?.map {
            ClubWebData.ScrapedHole(number: $0.number, par: $0.par,
                                    handicap: $0.handicap, lengthMeters: $0.lengthMeters)
        }
        return ClubWebData(websiteURL: websiteURL, overviewImageURL: overviewURL,
                           holeImageURLs: holeImages, scrapedHoles: holes)
    }

    private func saveCache(courseId: String, data: ClubWebData, ttl: TimeInterval) {
        let holeImages = Dictionary(uniqueKeysWithValues:
            data.holeImageURLs.map { num, url in ("\(num)", url.absoluteString) }
        )
        let holes = data.scrapedHoles?.map {
            CacheEntry.CachedHole(number: $0.number, par: $0.par,
                                  handicap: $0.handicap, lengthMeters: $0.lengthMeters)
        }
        let entry = CacheEntry(
            websiteURL: data.websiteURL?.absoluteString,
            overviewImageURL: data.overviewImageURL?.absoluteString,
            holeImageURLs: holeImages,
            scrapedHoles: holes,
            timestamp: .now,
            ttl: ttl
        )
        if let encoded = try? JSONEncoder().encode(entry) {
            UserDefaults.standard.set(encoded, forKey: cacheKey(courseId))
        }
    }

    /// Clears the cached website data for a specific course.
    func clearCache(courseId: String) {
        UserDefaults.standard.removeObject(forKey: cacheKey(courseId))
    }
}
