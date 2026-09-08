import Foundation

enum TextIntelligence {
    private static let actionPrefixes = [
        "todo", "to-do", "action", "follow up", "follow-up", "i will", "i'll",
        "we will", "we'll", "need to", "needs to", "remember to", "must "
    ]

    static func normalizedText(parts: [String?]) -> String {
        let lines = parts
            .compactMap { $0 }
            .flatMap { $0.components(separatedBy: .newlines) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        return lines.filter { seen.insert($0.lowercased()).inserted }.joined(separator: "\n")
    }

    static func summary(app: String, title: String, text: String) -> String {
        let usefulLine = text.components(separatedBy: .newlines)
            .first { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.count >= 12 && trimmed.caseInsensitiveCompare(title) != .orderedSame
            }

        var base = title.isEmpty ? app : "\(app) — \(title)"
        if let usefulLine {
            base += ": \(String(usefulLine.prefix(180)))"
        }
        return base
    }

    static func people(in text: String) -> [String] {
        var values = Set<String>()
        let patterns = [
            #"(?<![\w.])@([A-Za-z][A-Za-z0-9._-]{1,40})"#,
            #"\b([A-Za-z][A-Za-z0-9._%+-]{1,40})@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#,
            #"\b(?:with|from|to|asked by|assigned by)\s+([A-Z][a-z]{2,}(?:\s+[A-Z][a-z]{2,})?)\b"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) where match.numberOfRanges > 1 {
                guard let matchRange = Range(match.range(at: 1), in: text) else { continue }
                let value = String(text[matchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if value.count > 1 { values.insert(value) }
            }
        }
        return values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func actions(in text: String) -> [String] {
        var results: [String] = []
        var seen = Set<String>()

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.count >= 5 else { continue }
            let lower = line.lowercased()
            let isCheckbox = lower.hasPrefix("[ ]") || lower.hasPrefix("☐") || lower.hasPrefix("- [ ]")
            let containsCommitment = actionPrefixes.contains { prefix in
                lower.hasPrefix(prefix + ":") || lower.hasPrefix(prefix + " ") ||
                    lower.contains(" \(prefix) ") || lower.contains(" \(prefix):")
            }
            guard isCheckbox || containsCommitment else { continue }
            let cleaned = line
                .replacingOccurrences(of: "- [ ]", with: "")
                .replacingOccurrences(of: "[ ]", with: "")
                .replacingOccurrences(of: "☐", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let key = cleaned.lowercased()
            if !cleaned.isEmpty, seen.insert(key).inserted {
                results.append(String(cleaned.prefix(300)))
            }
        }
        return Array(results.prefix(12))
    }

    static func project(from context: WindowContext) -> String? {
        if let documentURL = context.documentURL {
            let url = URL(string: documentURL) ?? URL(fileURLWithPath: documentURL)
            let components = url.pathComponents.filter { $0 != "/" }
            if let index = components.lastIndex(where: { $0 == "Documents" || $0 == "Developer" || $0 == "Projects" }),
               components.indices.contains(index + 1) {
                return components[index + 1]
            }
            if components.count >= 2 { return components[components.count - 2] }
        }

        let separators = [" — ", " – ", " - ", " | "]
        for separator in separators {
            let parts = context.windowTitle.components(separatedBy: separator)
            if parts.count > 1, let candidate = parts.first?.trimmingCharacters(in: .whitespaces),
               candidate.count >= 2, candidate.caseInsensitiveCompare(context.appName) != .orderedSame {
                return String(candidate.prefix(120))
            }
        }
        return nil
    }

    static func episodeKey(_ context: WindowContext) -> String {
        let title = context.windowTitle
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(context.bundleIdentifier.lowercased())|\(title)"
    }
}
