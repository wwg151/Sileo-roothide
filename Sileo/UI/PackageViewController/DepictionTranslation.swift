import Foundation
import NaturalLanguage
import os

/// Only native package prose is sent to Apple's engine. UI labels, actions,
/// raw HTML depictions and the original repository data stay untouched.
enum DepictionTranslation {
    static let settingKey = "AutoTranslateDepictions"
    static let changed = Notification.Name(settingKey)
    static let defaultTarget = "zh-Hans"

    enum Mode: CaseIterable {
        case original, translated, compared

        var title: String {
            switch self {
            case .original: return String(localizationKey: "Depiction_Translation_Original")
            case .translated: return String(localizationKey: "Depiction_Translation_Translated")
            case .compared: return String(localizationKey: "Depiction_Translation_Compared")
            }
        }
    }

    struct Result {
        let translated: [String: Any]
        let compared: [String: Any]
    }
    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 500
        return cache
    }()
    private static var knownPairs: [[String]]?
    private static let protectedInline = try! NSRegularExpression(pattern:
        #"https?://[^\s<>]+|&(?:#[0-9]+|#x[0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]+);|\\[[:punct:]]|[*_~]+|\|"#)
    private static let prefix = try! NSRegularExpression(pattern:
        #"^(?:[ \t]*)(?:(?:#{1,6}|>|[-+*]|[0-9]+[.)])[ \t]+)*"#)
    private static let fixedLine = try! NSRegularExpression(pattern:
        #"^\s*(?:\[[^\]]+\]:|<|[-=_*]{3,}\s*$|\|?(?:[ :|-]+)\|\s*$)"#)

    static var supportedPlatform: Bool {
#if targetEnvironment(macCatalyst) || targetEnvironment(simulator)
        return false
#else
        if #available(iOS 15.0, *) { return true }
        return false
#endif
    }

    static var isEnabled: Bool {
        supportedPlatform && UserDefaults.standard.bool(forKey: settingKey)
    }

    static func verify(_ completion: @escaping (Bool) -> Void) {
        availablePairs { pairs in
            completion(pairs?.contains(where: { $0.count == 2 && score($0[1], defaultTarget) > 0 }) == true)
        }
    }

    static func languages(choosingSource: Bool, source: String?, target: String,
                          completion: @escaping ([String]) -> Void) {
        availablePairs { pairs in
            let options = (pairs ?? []).compactMap { pair -> String? in
                guard pair.count == 2 else { return nil }
                if choosingSource {
                    return score(pair[1], target) > 0 ? pair[0] : nil
                }
                return source.map { score(pair[0], $0) > 0 } != false ? pair[1] : nil
            }
            completion(Set(options).sorted())
        }
    }

    static func languageName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    static func matchesLanguage(_ lhs: String, _ rhs: String) -> Bool {
        score(lhs, rhs) > 0
    }

    private static func availablePairs(_ completion: @escaping ([[String]]?) -> Void) {
        if let pairs = knownPairs { completion(pairs); return }
        SileoSystemTranslationPairs { pairs in
            if let pairs = pairs { knownPairs = pairs }
            completion(pairs)
        }
    }

    private static func parts(_ identifier: String) -> Locale {
        Locale(identifier: Locale.canonicalIdentifier(from: identifier))
    }

    private static func script(of locale: Locale) -> String? {
        if let script = locale.scriptCode { return script }
        if locale.languageCode == "zh" {
            return ["TW", "HK", "MO"].contains(locale.regionCode ?? "") ? "Hant" : "Hans"
        }
        return nil
    }

    private static func score(_ actual: String, _ wanted: String) -> Int {
        let lhs = parts(actual), rhs = parts(wanted)
        guard let language = lhs.languageCode, language == rhs.languageCode else { return 0 }
        if let a = script(of: lhs), let b = script(of: rhs), a != b { return 0 }
        return lhs.identifier == rhs.identifier ? 2 : 1
    }

    private struct Piece {
        let text: String
        let source: String
    }

    @available(iOS 15.0, *)
    private static let log = Logger(subsystem: "org.coolstar.SileoStore", category: "DepictionTranslation")

    /// One line per fragment the engine would not translate, so a page that
    /// stays partly English can be traced in the device log.
    @available(iOS 15.0, *)
    private static func failed(_ piece: Piece, pair: [String]?) {
        let preview = String(piece.text.prefix(60)).replacingOccurrences(of: "\n", with: " ")
        let line = "untranslated pair=\(pair?.joined(separator: ">") ?? "none") source=\(piece.source) text=\(preview)"
        log.notice("\(line, privacy: .public)")
    }

    /// Apply the available translations together, keeping original prose for failed fragments.
    /// Stop submitting work when the request is no longer current.
    static func translate(_ depiction: [String: Any], source: String?, target: String,
                          isCurrent: @escaping () -> Bool, completion: @escaping (Result?, Bool) -> Void) {
        guard isCurrent(), SileoSystemTranslationAvailable() else { completion(nil, true); return }
        var seen = Set<String>()
        var fragments = [String]()
        var pieces = [Piece]()
        let placeholder = String(localizationKey: "Package_Changelogs_Unavailable")
        let noDescription = String(localizationKey: "Package_No_Description_Available")
        guard #available(iOS 15.0, *) else { completion(nil, true); return }
        let recognizer = NLLanguageRecognizer()
        func detect(_ text: String) -> String? {
            recognizer.reset()
            recognizer.processString(text)
            guard let detected = recognizer.dominantLanguage, detected != .undetermined,
                  recognizer.languageHypotheses(withMaximum: 1)[detected, default: 0] >= 0.55 else { return nil }
            return detected.rawValue
        }
        _ = rewrite(depiction) { text, _ in
            if fragments.count < 160, text.utf16.count <= 3000, text.filter(\.isLetter).count >= 4,
               text != placeholder, text != noDescription, seen.insert(text).inserted {
                fragments.append(text)
            }
            return text
        }
        let pageLanguage = source == nil ? detect(fragments.prefix(24).joined(separator: "\n")) : nil
        for text in fragments {
            guard let detected = source ?? detect(text) ?? pageLanguage, !matchesLanguage(detected, target) else { continue }
            // Do not use an English page-wide fallback to translate existing Chinese.
            let han = text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0x20000...0x323AF).contains($0.value) }
            if source == nil, parts(target).languageCode == "zh",
               parts(detected).languageCode == "zh" || (han && detected != "ja" && detected != "ko") { continue }
            pieces.append(Piece(text: text, source: detected))
        }
        guard !pieces.isEmpty else { completion(nil, false); return }
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        availablePairs { pairs in
            guard isCurrent(), let pairs = pairs else { completion(nil, true); return }
            var translations = [String: String]()
            var incomplete = false
            func finish() {
                guard !translations.isEmpty else { completion(nil, incomplete); return }
                let replace: (String, Bool) -> String = { text, markdown in
                    guard let answer = translations[text] else { return text }
                    return markdown ? escapeMarkdown(answer) : answer
                }
                completion(Result(translated: rewrite(depiction, replace: replace),
                                  compared: rewrite(depiction, compared: true, replace: replace)), incomplete)
            }
            func next(_ index: Int) {
                guard isCurrent() else { return }
                guard index < pieces.count else { finish(); return }
                guard ProcessInfo.processInfo.systemUptime < deadline else { incomplete = true; finish(); return }
                let piece = pieces[index]
                let pair = pairs.filter { $0.count == 2 && score($0[0], piece.source) > 0 && score($0[1], target) > 0 }
                    .max { score($0[0], piece.source) * 4 + score($0[1], target) < score($1[0], piece.source) * 4 + score($1[1], target) }
                guard let pair = pair else {
                    failed(piece, pair: nil)
                    incomplete = true
                    next(index + 1)
                    return
                }
                let key = (pair[0] + ">" + pair[1] + "\n" + piece.text) as NSString
                func record(_ translated: String) {
                    if translated != piece.text { translations[piece.text] = translated }
                    next(index + 1)
                }
                if let answer = cache.object(forKey: key) {
                    record(answer as String)
                    return
                }
                func request(_ onlyOffline: Bool) {
                    guard isCurrent() else { return }
                    guard ProcessInfo.processInfo.systemUptime < deadline else { incomplete = true; finish(); return }
                    SileoSystemTranslate(piece.text, pair[0], pair[1], onlyOffline) { answer in
                        guard isCurrent() else { return }
                        if let answer = answer, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let cleanAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                            cache.setObject(cleanAnswer as NSString, forKey: key)
                            record(cleanAnswer)
                        } else if !onlyOffline {
                            // This piece, not the rest of the page: one failure used to
                            // send every later fragment to an offline model that most
                            // devices do not have.
                            request(true)
                        } else {
                            failed(piece, pair: pair)
                            incomplete = true
                            next(index + 1)
                        }
                    }
                }
                request(false)
            }
            next(0)
        }
    }

    private static func rewrite(_ depiction: [String: Any], compared: Bool = false,
                                replace: (String, Bool) -> String) -> [String: Any] {
        var result = depiction
        switch depiction["class"] as? String {
        case "DepictionMarkdownView":
            if depiction["useRawFormat"] as? Bool != true, let markdown = depiction["markdown"] as? String {
                let translated = rewriteMarkdown(markdown) { replace($0, true) }
                if translated != markdown {
                    result["markdown"] = translated
                    if compared { return comparison(original: depiction, translated: result) }
                }
            }
        case "DepictionLabelView":
            if let text = depiction["text"] as? String {
                let translated = translateText(text) { replace($0, false) }
                if translated != text {
                    result["text"] = translated
                    result["_sileoTranslatedLabel"] = true
                    if compared { return comparison(original: depiction, translated: result) }
                }
            }
        case "DepictionTabView":
            if let tabs = depiction["tabs"] as? [[String: Any]] {
                result["tabs"] = tabs.map { tab -> [String: Any] in
                    var copy = rewrite(tab, compared: compared, replace: replace)
                    // The tab button's own title is the only prose outside a view.
                    if let name = tab["tabname"] as? String, !name.isEmpty {
                        let translated = translateText(name) { replace($0, false) }
                        if translated != name { copy["tabname"] = translated }
                    }
                    return copy
                }
            }
        case "DepictionStackView", "DepictionAutoStackView", "DepictionLayerView":
            if let views = depiction["views"] as? [[String: Any]] {
                result["views"] = views.map { rewrite($0, compared: compared, replace: replace) }
            }
        case "DepictionMinVersionForceView":
            if let view = depiction["view"] as? [String: Any] {
                result["view"] = rewrite(view, compared: compared, replace: replace)
            }
        default:
            break
        }
        return result
    }

    private static func comparison(original: [String: Any], translated: [String: Any]) -> [String: Any] {
        var stack: [String: Any] = ["class": "DepictionStackView", "views": [original, translated]]
        // A Markdown or label node can itself be a tab, not just a child of one.
        stack["tabname"] = original["tabname"]
        stack["tintColor"] = original["tintColor"]
        return stack
    }

    private static func rewriteMarkdown(_ markdown: String, replace: (String) -> String) -> String {
        var fence: (marker: Character, length: Int)?
        // A code span can cross a newline. Leave any such span untouched,
        // including lines that do not themselves contain a backtick.
        var inlineCodeLength: Int?
        return markdown.components(separatedBy: "\n").map { line in
            let body = line.drop(while: \.isWhitespace)
            if let marker = body.first, marker == "`" || marker == "~" {
                let count = body.prefix(while: { $0 == marker }).count
                if count >= 3 {
                    if let open = fence {
                        if marker == open.marker && count >= open.length && body.dropFirst(count).allSatisfy(\.isWhitespace) { fence = nil }
                    } else {
                        fence = (marker, count)
                    }
                    return line
                }
            }
            let wasInCode = inlineCodeLength != nil
            if fence == nil {
                var ticks = 0
                var escaped = false
                for character in line + " " {
                    if character == "`", !escaped {
                        ticks += 1
                        continue
                    }
                    if ticks > 0 {
                        if inlineCodeLength == nil { inlineCodeLength = ticks }
                        else if inlineCodeLength == ticks { inlineCodeLength = nil }
                        ticks = 0
                    }
                    escaped = character == "\\" && !escaped && inlineCodeLength == nil
                }
            }
            let span = NSRange(line.startIndex..., in: line)
            // Keep complex inline markup intact rather than risk changing a URL,
            // reference label or code span (which can span multiple lines).
            guard fence == nil, !wasInCode, inlineCodeLength == nil, !line.hasPrefix("    "), !line.hasPrefix("\t"),
                  !line.contains(where: { "<>[]`".contains($0) }),
                  fixedLine.firstMatch(in: line, range: span) == nil else { return line }
            let start = prefix.firstMatch(in: line, range: span).flatMap { Range($0.range, in: line)?.upperBound } ?? line.startIndex
            return String(line[..<start]) + translateText(String(line[start...]), replace: replace)
        }.joined(separator: "\n")
    }

    private static func translateText(_ text: String, replace: (String) -> String) -> String {
        func prose(_ fragment: Substring) -> String {
            guard let first = fragment.firstIndex(where: { !$0.isWhitespace }),
                  let last = fragment.lastIndex(where: { !$0.isWhitespace }) else { return String(fragment) }
            return String(fragment[..<first]) + replace(String(fragment[first...last])) + String(fragment[fragment.index(after: last)...])
        }
        var start = text.startIndex
        var result = ""
        for match in protectedInline.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += prose(text[start..<range.lowerBound]) + String(text[range])
            start = range.upperBound
        }
        return result + prose(text[start...])
    }

    private static func escapeMarkdown(_ text: String) -> String {
        let syntax = Set("\\`*_{}[]<>#|~!()+-.&")
        return text.split(whereSeparator: \.isNewline).joined(separator: " ").reduce(into: "") { result, char in
            if syntax.contains(char) { result.append("\\") }
            result.append(char)
        }
    }
}
