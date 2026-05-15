/// EmojiDatabase.swift
/// Disco — system-wide emoji autocomplete
///
/// Owns the emoji data model, fuzzy search engine, and usage tracking.
///
/// Data source: Resources/emoji.json — 745 entries, each with:
///   emoji, description, aliases[], tags[], category
///
/// Search scoring (higher = better match):
///   100  exact alias match
///    90  exact description match
///    80  alias prefix match
///    70  description prefix match
///    65  exact tag match
///    50  alias contains match
///    45  tag prefix match
///    40  description contains match
///    30  tag contains match
///   +0–20 recency-weighted usage boost (capped so stale overuse can't bury fresh matches)

import Foundation

// MARK: - Model

/// A single emoji entry decoded from emoji.json.
struct EmojiEntry: Codable {
    let emoji: String
    let description: String
    let aliases: [String]   // shortcodes, e.g. ["tada", "party_popper"]
    let tags: [String]       // search hints, e.g. ["party", "celebration", "confetti"]
    let category: String     // e.g. "Activities", "Smileys & Emotion"

    /// The canonical shortcode shown in the popup alias label (e.g. ":tada:").
    var primaryAlias: String {
        aliases.first ?? description.lowercased().replacingOccurrences(of: " ", with: "_")
    }

    enum CodingKeys: String, CodingKey {
        case emoji, description, aliases, tags, category
    }
}

// MARK: - Database

final class EmojiDatabase {
    static let shared = EmojiDatabase()

    private(set) var allEmoji: [EmojiEntry] = []
    private(set) var categories: [String] = []

    // MARK: Usage tracking

    /// Stores per-emoji usage count and the timestamp of last use.
    /// Persisted to UserDefaults as JSON under `com.disco.usageRecords`.
    private struct UsageRecord: Codable {
        var count: Int
        var lastUsed: Date
    }
    private var usageRecords: [String: UsageRecord] = [:]

    private let usageKey  = "com.disco.usageRecords"
    private let legacyKey = "com.disco.usage"   // old flat [String: Int] format — migrated on first load

    /// Maximum number of results returned by search() and shown in the popup.
    /// 30 fills a 10-column, 3-row grid cleanly. Adjust alongside `cols` in
    /// AutocompleteWindowController if you change the grid layout.
    private let popupLimit = 30

    private init() {}

    // MARK: - Load

    func load() {
        loadUsageRecords()

        guard let url = bundledEmojiURL() else {
            print("Disco: emoji.json not found")
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let entries = try JSONDecoder().decode([EmojiEntry].self, from: data)
            // Deduplicate on the emoji character itself, preserving original order.
            var seen = Set<String>()
            allEmoji = entries.filter { seen.insert($0.emoji).inserted }
            categories = Array(Set(allEmoji.map { $0.category })).sorted()
        } catch {
            print("Disco: failed to load emoji database: \(error)")
        }
    }

    // MARK: - Usage persistence

    private func loadUsageRecords() {
        // Try the current JSON format first.
        if let data = UserDefaults.standard.data(forKey: usageKey),
           let decoded = try? JSONDecoder().decode([String: UsageRecord].self, from: data) {
            usageRecords = decoded
            return
        }
        // Migrate from the old flat [String: Int] format (Disco 1.0).
        // All migrated records are stamped with "now" as lastUsed, which is
        // conservative — it avoids immediately penalising long-term favourites.
        if let legacy = UserDefaults.standard.dictionary(forKey: legacyKey) as? [String: Int] {
            let now = Date()
            for (emoji, count) in legacy {
                usageRecords[emoji] = UsageRecord(count: count, lastUsed: now)
            }
            saveUsageRecords()
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
    }

    private func saveUsageRecords() {
        if let data = try? JSONEncoder().encode(usageRecords) {
            UserDefaults.standard.set(data, forKey: usageKey)
        }
    }

    // MARK: - Decay

    /// Recency-weighted score for a given emoji.
    ///
    /// Formula: `count / sqrt(hoursSinceLastUse + 1)`
    ///
    /// Properties:
    ///   - At 0 hours: score = count       (just used — full weight)
    ///   - At 24 hours: score ≈ count / 5  (used yesterday — significantly reduced)
    ///   - At 1 week: score ≈ count / 13   (week-old use — much reduced)
    ///   - At 1 year: score ≈ count / 93   (year-old use — nearly irrelevant)
    ///
    /// The sqrt curve decays gradually rather than cliff-dropping, so casual users
    /// who use a handful of emoji regularly aren't suddenly penalised after a weekend.
    private func decayedScore(for emoji: String) -> Double {
        guard let record = usageRecords[emoji] else { return 0 }
        let hoursSince = max(0, -record.lastUsed.timeIntervalSinceNow) / 3600
        return Double(record.count) / sqrt(hoursSince + 1)
    }

    // MARK: - Emoji.json location

    private func bundledEmojiURL() -> URL? {
        // 1. Bundle resources — works when running as a .app
        if let url = Bundle.main.url(forResource: "emoji", withExtension: "json") { return url }

        // 2. Relative to the executable — works with `swift build` during development
        let exec = URL(fileURLWithPath: CommandLine.arguments[0])
        let candidates = [
            exec.deletingLastPathComponent().appendingPathComponent("emoji.json"),
            exec.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/emoji.json"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Search

    /// Returns up to `limit` emoji ranked by fuzzy match quality, boosted by
    /// recency-weighted usage. When `query` is empty, returns `popular(limit:)`.
    func search(query: String, limit: Int = 30) -> [EmojiEntry] {
        guard !query.isEmpty else { return popular(limit: limit) }
        let q = query.lowercased()
        var results: [(EmojiEntry, Double)] = []

        for entry in allEmoji {
            let base = scoreEntry(entry, query: q)
            if base > 0 {
                // Cap usage boost at +20 so a heavily-used-but-stale emoji
                // can't permanently displace a fresh, highly-relevant match.
                let boost = min(decayedScore(for: entry.emoji) * 2, 20)
                results.append((entry, Double(base) + boost))
            }
        }

        return results.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Scores a single emoji entry against a lowercase query string.
    /// Returns 0 if no match is found.
    private func scoreEntry(_ entry: EmojiEntry, query q: String) -> Int {
        var score = 0
        for alias in entry.aliases {
            if alias == q              { score = max(score, 100) }
            else if alias.hasPrefix(q) { score = max(score,  80) }
            else if alias.contains(q)  { score = max(score,  50) }
        }
        let desc = entry.description.lowercased()
        if desc == q               { score = max(score, 90) }
        else if desc.hasPrefix(q)  { score = max(score, 70) }
        else if desc.contains(q)   { score = max(score, 40) }
        for tag in entry.tags {
            if tag == q              { score = max(score, 65) }
            else if tag.hasPrefix(q) { score = max(score, 45) }
            else if tag.contains(q)  { score = max(score, 30) }
        }
        return score
    }

    // MARK: - Popular

    /// Returns frequently and recently used emoji, falling back to a curated
    /// default set when the user has no usage history.
    func popular(limit: Int = 30) -> [EmojiEntry] {
        let defaults = ["😀","👍","❤️","🔥","✨","😂","🎉","🙌","💯","🤔",
                        "😊","👋","🚀","💪","🙏","😎","🤝","💡","✅","🎯",
                        "😅","🥳","💻","📱","🪩","🎊","💃","🕺","🌟","⭐️"]
        if usageRecords.isEmpty {
            return allEmoji.filter { defaults.contains($0.emoji) }.prefix(limit).map { $0 }
        }
        // Sort tracked emoji by decayed score — recency matters, not just raw count.
        let used = usageRecords.keys
            .sorted { decayedScore(for: $0) > decayedScore(for: $1) }
            .prefix(limit)
            .compactMap { e in allEmoji.first { $0.emoji == e } }
        if used.count >= limit { return Array(used) }
        // Pad with defaults if the user's history is short.
        let usedSet = Set(used.map(\.emoji))
        let fill = allEmoji.filter { defaults.contains($0.emoji) && !usedSet.contains($0.emoji) }
        return Array((used + fill).prefix(limit))
    }

    // MARK: - Category

    /// Returns all emoji in the given category, in database order.
    func emoji(forCategory category: String) -> [EmojiEntry] {
        allEmoji.filter { $0.category == category }
    }

    // MARK: - Record usage

    /// Increments the usage count for `entry` and updates its last-used timestamp
    /// to now. Persists immediately to UserDefaults.
    func recordUsage(_ entry: EmojiEntry) {
        let existing = usageRecords[entry.emoji]
        usageRecords[entry.emoji] = UsageRecord(
            count: (existing?.count ?? 0) + 1,
            lastUsed: Date()
        )
        saveUsageRecords()
    }
}
