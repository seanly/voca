import Foundation
import CoreServices

/// Validates English words against Apple’s built-in Dictionary using Dictionary Services.
final class DictionaryValidator {
    static let shared = DictionaryValidator()

    private init() {}

    /// Check whether a single word exists in the active Apple dictionaries.
    func isValidEnglishWord(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .punctuationCharacters)
                         .trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let definition = DCSCopyTextDefinition(
            nil,
            trimmed as CFString,
            CFRange(location: 0, length: trimmed.utf16.count)
        )
        return definition != nil
    }

    /// Validate every English-word-like token in the given text.
    /// Returns a list of tokens that are **not** found in the active dictionaries.
    func validateEnglishWords(in text: String) -> [String] {
        let pattern = "[A-Za-z]+"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        var unknown: [String] = []
        for match in matches {
            guard let wordRange = Range(match.range, in: text) else { continue }
            let word = String(text[wordRange])
            // Skip all-caps acronyms and very short tokens
            if word.count <= 1 || word == word.uppercased() { continue }
            if !isValidEnglishWord(word) {
                unknown.append(word)
            }
        }
        return unknown
    }
}
