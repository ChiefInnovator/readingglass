import Foundation
import NaturalLanguage

/// The accepted keys come from the pinned translation template, never an
/// invented assumption about which languages the loaded model supports.
struct LanguageCatalog: Sendable {
    let languageNames: [String: String]

    init(languageNames: [String: String]) { self.languageNames = languageNames }

    func normalize(_ tag: String) -> String? {
        let parts = tag.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let base = parts.first, !base.isEmpty else { return nil }
        let language = base.lowercased()
        var script: String?
        var region: String?
        var canonical = [language]
        for part in parts.dropFirst() {
            if part.count == 4 && part.unicodeScalars.allSatisfy(CharacterSet.letters.contains) {
                let value = part.prefix(1).uppercased() + part.dropFirst().lowercased()
                script = value
                canonical.append(value)
            } else if part.count == 2 || (part.count == 3 && part.allSatisfy(\.isNumber)) {
                let value = part.uppercased()
                region = value
                canonical.append(value)
            } else {
                canonical.append(part.lowercased())
            }
        }
        let exact = canonical.joined(separator: "-")
        if languageNames[exact] != nil { return exact }
        if language == "zh" && script == nil {
            if ["CN", "SG"].contains(region) { script = "Hans" }
            if ["TW", "HK", "MO"].contains(region) { script = "Hant" }
        }
        if let script {
            let scripted = language + "-" + script
            if languageNames[scripted] != nil { return scripted }
        }
        // A Chinese script must not silently collapse into a different model
        // language. Other locales may use their accepted base-language key.
        guard language != "zh" else { return nil }
        return languageNames[language] == nil ? nil : language
    }

    func language(for region: TextRegion, pageText: String, manual: String?) -> String? {
        if let manual { return normalize(manual) }
        let letterCount = region.text.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count
        guard letterCount >= 3 else { return nil }
        if let language = detect(region.text, minimumConfidence: letterCount < 12 ? 0.85 : 0.65) {
            return normalize(language.rawValue)
        }
        // A short label on a mixed-language page must not inherit the prose's language.
        guard letterCount >= 12, region.kind == .paragraph else { return nil }
        return detect(pageText).flatMap { normalize($0.rawValue) }
    }

    private func detect(_ text: String, minimumConfidence: Double = 0.65) -> NLLanguage? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let hypothesis = recognizer.languageHypotheses(withMaximum: 1).first,
              hypothesis.value >= minimumConfidence else { return nil }
        return hypothesis.key
    }
}
