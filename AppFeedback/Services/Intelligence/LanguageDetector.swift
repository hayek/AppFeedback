import Foundation
import NaturalLanguage

enum LanguageDetector {
    /// Detect the dominant language of `text`. Returns BCP-47 language code or
    /// nil if the input is too short or detection lacks confidence.
    static func detect(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let language = recognizer.dominantLanguage else { return nil }
        let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
        if let confidence = hypotheses[language], confidence < 0.5 { return nil }
        return language.rawValue
    }
}
