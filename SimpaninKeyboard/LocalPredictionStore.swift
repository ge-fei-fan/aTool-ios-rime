import Foundation

struct LocalPredictionCandidate: Equatable {
    let text: String
    let score: Double
}

final class LocalPredictionStore {
    struct Configuration {
        let maxCandidates: Int
        let maxEntries: Int
        let contextTimeout: TimeInterval
        let expiry: TimeInterval
        let pGramExpiry: TimeInterval
        let decayRate: Double
        let maxCommitLength: Int

        static let `default` = Configuration(
            maxCandidates: 5,
            maxEntries: 2_000,
            contextTimeout: 5,
            expiry: 90 * 24 * 60 * 60,
            pGramExpiry: 30 * 24 * 60 * 60,
            decayRate: 0.85,
            maxCommitLength: 4
        )
    }

    static let shared = LocalPredictionStore(appGroupIdentifier: "group.com.local.fitnex")

    private struct StoredEntry: Codable {
        var count: Int
        var timestamp: TimeInterval
    }

    private struct Snapshot: Codable {
        var version: Int
        var entries: [String: StoredEntry]
    }

    private let queue = DispatchQueue(label: "com.local.simpanin.keyboard.local-prediction")
    private let storageURL: URL?
    private let configuration: Configuration

    private var entries: [String: StoredEntry] = [:]
    private var hasLoaded = false
    private var history: [String] = []
    private var lastCommitTimestamp: TimeInterval = 0

    init(
        appGroupIdentifier: String,
        configuration: Configuration = .default
    ) {
        self.storageURL = Self.defaultStorageURL(appGroupIdentifier: appGroupIdentifier)
        self.configuration = configuration
    }

    init(
        fileURL: URL?,
        configuration: Configuration = .default
    ) {
        self.storageURL = fileURL
        self.configuration = configuration
    }

    func recordCommittedText(_ text: String, now: Date = Date()) -> [LocalPredictionCandidate] {
        queue.sync {
            loadIfNeeded()

            let timestamp = now.timeIntervalSince1970
            let committedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isValidCommitText(committedText),
                  Self.characterCount(committedText) <= configuration.maxCommitLength else {
                resetContextLocked()
                persist()
                return []
            }

            if lastCommitTimestamp > 0,
               timestamp - lastCommitTimestamp > configuration.contextTimeout {
                resetContextLocked()
            }

            var didUpdate = false
            if let previousText = history.last,
               previousText != committedText {
                updateMemory(from: previousText, to: committedText, timestamp: timestamp)
                didUpdate = true

                if history.count >= 2 {
                    let previousPreviousText = history[history.count - 2]
                    let previousLength = Self.characterCount(previousText)
                    let previousPreviousLength = Self.characterCount(previousPreviousText)
                    if previousLength <= configuration.maxCommitLength,
                       previousPreviousLength + previousLength <= 5 {
                        updateEntry(
                            key: "2\t\(previousPreviousText)\t\(previousText)\t\(committedText)",
                            timestamp: timestamp
                        )
                    }
                }
            }

            if history.count >= 2,
               committedText == history[history.count - 2] {
                history.removeLast()
            } else if history.last != committedText {
                history.append(committedText)
                if history.count > 2 {
                    history.removeFirst(history.count - 2)
                }
            }

            lastCommitTimestamp = timestamp
            pruneExpiredEntries(now: timestamp)
            if didUpdate {
                persist()
            }
            return predictionsLocked(now: timestamp)
        }
    }

    func currentPredictionRankMap(now: Date = Date()) -> [String: Int] {
        queue.sync {
            loadIfNeeded()
            let predictions = predictionsLocked(now: now.timeIntervalSince1970)
            return Dictionary(
                uniqueKeysWithValues: predictions.enumerated().map { ($0.element.text, $0.offset) }
            )
        }
    }

    func resetContext() {
        queue.sync {
            resetContextLocked()
        }
    }

    func removeAllData() {
        queue.sync {
            entries = [:]
            history = []
            lastCommitTimestamp = 0
            hasLoaded = true
            if let storageURL {
                try? FileManager.default.removeItem(at: storageURL)
            }
        }
    }

    private static func defaultStorageURL(appGroupIdentifier: String) -> URL? {
        let fileManager = FileManager.default
        let baseURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Simpanin", isDirectory: true)
            ?? fileManager.temporaryDirectory.appendingPathComponent("Simpanin", isDirectory: true)
        return baseURL
            .appendingPathComponent("Prediction", isDirectory: true)
            .appendingPathComponent("local-predict.json")
    }

    private func updateMemory(from previousText: String, to committedText: String, timestamp: TimeInterval) {
        let previousLength = Self.characterCount(previousText)
        if previousLength <= configuration.maxCommitLength {
            updateEntry(key: "1\t\(previousText)\t\(committedText)", timestamp: timestamp)
        }

        let characters = Array(previousText)
        for suffixLength in Self.suffixLengths(for: characters.count) {
            if suffixLength < characters.count || characters.count >= configuration.maxCommitLength {
                let suffix = String(characters.suffix(suffixLength))
                updateEntry(key: "P\t\(suffix)\t\(committedText)", timestamp: timestamp)
            }
        }
    }

    private func updateEntry(key: String, timestamp: TimeInterval) {
        var entry = entries[key] ?? StoredEntry(count: 0, timestamp: timestamp)
        let expiry = key.hasPrefix("P\t") ? configuration.pGramExpiry : configuration.expiry
        if timestamp - entry.timestamp > expiry {
            entry.count = 0
        }
        entry.count += 1
        entry.timestamp = timestamp
        entries[key] = entry
    }

    private func predictionsLocked(now: TimeInterval) -> [LocalPredictionCandidate] {
        guard let lastText = history.last else { return [] }

        struct RankedPrediction {
            var score: Double
            var timestamp: TimeInterval
        }

        var rankedPredictions: [String: RankedPrediction] = [:]
        var expiredKeys: [String] = []

        func fetch(prefix: String, multiplier: Double) {
            for (key, entry) in entries where key.hasPrefix(prefix) {
                let expiry = key.hasPrefix("P\t") ? configuration.pGramExpiry : configuration.expiry
                guard now - entry.timestamp <= expiry else {
                    expiredKeys.append(key)
                    continue
                }
                guard entry.count > 0 else { continue }

                let word = String(key.dropFirst(prefix.count))
                guard !word.isEmpty else { continue }

                let ageDays = max(0, now - entry.timestamp) / 86_400
                let score = Double(entry.count) * pow(configuration.decayRate, ageDays) * multiplier
                guard score > 0.05 else { continue }

                if let existing = rankedPredictions[word] {
                    if score > existing.score || (score == existing.score && entry.timestamp > existing.timestamp) {
                        rankedPredictions[word] = RankedPrediction(score: score, timestamp: entry.timestamp)
                    }
                } else {
                    rankedPredictions[word] = RankedPrediction(score: score, timestamp: entry.timestamp)
                }
            }
        }

        func fetchTier(prefixes: [(prefix: String, multiplier: Double)]) -> Bool {
            let countBeforeFetch = rankedPredictions.count
            for item in prefixes {
                fetch(prefix: item.prefix, multiplier: item.multiplier)
            }
            return rankedPredictions.count > countBeforeFetch
        }

        var hasExactMatchPredictions = false

        if history.count >= 2 {
            let previousPreviousText = history[history.count - 2]
            let previousLength = Self.characterCount(lastText)
            let previousPreviousLength = Self.characterCount(previousPreviousText)
            if previousLength <= configuration.maxCommitLength,
               previousPreviousLength + previousLength <= 5 {
                let prefixes = [("2\t\(previousPreviousText)\t\(lastText)\t", 10_000.0)]
                hasExactMatchPredictions = fetchTier(prefixes: prefixes)
            }
        }

        if !hasExactMatchPredictions,
           rankedPredictions.count < configuration.maxCandidates {
            let characters = Array(lastText)
            let maxLength = min(characters.count, configuration.maxCommitLength)
            let minLength = characters.count >= 2 ? 2 : 1
            if maxLength >= minLength {
                var prefixes: [(prefix: String, multiplier: Double)] = []
                for length in stride(from: maxLength, through: minLength, by: -1) {
                    let suffix = String(characters.suffix(length))
                    prefixes.append(("1\t\(suffix)\t", 100.0))
                }
                hasExactMatchPredictions = fetchTier(prefixes: prefixes)
            }
        }

        if !hasExactMatchPredictions,
           rankedPredictions.count < configuration.maxCandidates {
            let characters = Array(lastText)
            var prefixes: [(prefix: String, multiplier: Double)] = []
            for suffixLength in Self.suffixLengths(for: characters.count) {
                let suffix = String(characters.suffix(suffixLength))
                prefixes.append(("P\t\(suffix)\t", 1.0))
            }
            _ = fetchTier(prefixes: prefixes)
        }

        if !expiredKeys.isEmpty {
            expiredKeys.forEach { entries.removeValue(forKey: $0) }
            persist()
        }

        return rankedPredictions
            .map { LocalPredictionCandidate(text: $0.key, score: $0.value.score) }
            .sorted {
                let left = rankedPredictions[$0.text]
                let right = rankedPredictions[$1.text]

                if $0.score == $1.score,
                   left?.timestamp == right?.timestamp {
                    return $0.text < $1.text
                }
                if $0.score == $1.score {
                    return (left?.timestamp ?? 0) > (right?.timestamp ?? 0)
                }
                return $0.score > $1.score
            }
            .prefix(configuration.maxCandidates)
            .map { $0 }
    }

    private static func suffixLengths(for characterCount: Int) -> [Int] {
        switch characterCount {
        case 4...:
            return [4, 3, 2]
        case 3:
            return [3, 2]
        case 2:
            return [2]
        case 1:
            return [1]
        default:
            return []
        }
    }

    private static func isValidCommitText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (value >= 0x3400 && value <= 0x4DBF)
                || (value >= 0x4E00 && value <= 0x9FFF)
                || (value >= 0xF900 && value <= 0xFAFF)
                || (value >= 0x20000 && value <= 0x2CEAF)
                || (value >= 0x30000 && value <= 0x3134F)
        }
    }

    private static func characterCount(_ text: String) -> Int {
        text.count
    }

    private func resetContextLocked() {
        history.removeAll()
        lastCommitTimestamp = 0
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let storageURL,
              let data = try? Data(contentsOf: storageURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return
        }
        entries = snapshot.entries
        pruneExpiredEntries(now: Date().timeIntervalSince1970)
    }

    private func pruneExpiredEntries(now: TimeInterval) {
        entries = entries.filter { key, entry in
            let expiry = key.hasPrefix("P\t") ? configuration.pGramExpiry : configuration.expiry
            return now - entry.timestamp <= expiry
        }

        guard entries.count > configuration.maxEntries else { return }
        let keysToRemove = entries
            .sorted { $0.value.timestamp < $1.value.timestamp }
            .prefix(entries.count - configuration.maxEntries)
            .map(\.key)
        keysToRemove.forEach { entries.removeValue(forKey: $0) }
    }

    private func persist() {
        guard let storageURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let snapshot = Snapshot(version: 1, entries: entries)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            NSLog("[LocalPredictionStore] failed to persist predictions: %@", error.localizedDescription)
        }
    }
}
