import Foundation
import NaturalLanguage
import os

/// Only native depiction text fragments go to the selected engine. Markup,
/// code, link destinations and the original repository data stay untouched.
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

    enum OutputSource: Equatable {
        case ai, system, mixed

        var completionTitle: String {
            switch self {
            case .ai: return String(localizationKey: "Depiction_Translation_Finished_AI")
            case .system: return String(localizationKey: "Depiction_Translation_Finished_System")
            case .mixed: return String(localizationKey: "Depiction_Translation_Finished_Mixed")
            }
        }
    }

    struct Result {
        let translated: [String: Any]
        let compared: [String: Any]
        let outputSource: OutputSource
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
        if DepictionAIProvider.selection != nil { completion(true); return }
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

    /// How a translated answer has to be written back into its container.
    private enum Flavor {
        case plain, markdown, html
    }

    @available(iOS 15.0, *)
    private static let log = Logger(subsystem: "org.coolstar.SileoStore", category: "DepictionTranslation")

    /// One line per fragment the engine would not translate, so a page that
    /// stays partly English can be traced in the device log.
    @available(iOS 15.0, *)
    private static func failed(_ piece: Piece, pair: [String]?) {
        let line = "untranslated pair=\(pair?.joined(separator: ">") ?? "none") language=\(piece.source)"
        log.notice("\(line, privacy: .public)")
    }

    /// Apply the available translations together, keeping original prose for failed fragments.
    /// Stop submitting work when the request is no longer current. Hand translated
    /// text back through `progress` after processing a tab, without waiting for the
    /// rest of the page or subsequent retries.
    static func translate(_ depiction: [String: Any], source: String?, target: String,
                          isCurrent: @escaping () -> Bool, progress: ((Result) -> Void)? = nil,
                          completion: @escaping (Result?, Bool) -> Void) {
        let ai = DepictionAIProvider.selection
        let systemAvailable = SileoSystemTranslationAvailable()
        guard isCurrent(), ai != nil || systemAvailable else { completion(nil, true); return }
        var seen = Set<String>()
        var fragments = [String]()
        var fragmentGroup = [Int]()
        var pieces = [Piece]()
        var pieceGroup = [Int]()
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
        let tabs = depictionGroups(depiction)
        func collect(_ text: String, group: Int) -> String {
            if fragments.count < 240, text.utf16.count <= 3000, text.filter(\.isLetter).count >= 4,
               text != placeholder, text != noDescription, seen.insert(text).inserted {
                fragments.append(text)
                fragmentGroup.append(group)
            }
            return text
        }
        for (index, tab) in tabs.enumerated() {
            _ = rewrite(tab) { text, _ in collect(text, group: index) }
            // A tab's own button title sits outside its views.
            if let name = tab["tabname"] as? String, !name.isEmpty {
                _ = translateText(name) { collect($0, group: index) }
            }
        }
        let pageLanguage = source == nil ? detect(fragments.prefix(24).joined(separator: "\n")) : nil
        for (index, text) in fragments.enumerated() {
            guard let detected = source ?? detect(text) ?? pageLanguage, !matchesLanguage(detected, target) else { continue }
            // Do not use an English page-wide fallback to translate existing Chinese.
            let han = text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0x20000...0x323AF).contains($0.value) }
            if source == nil, parts(target).languageCode == "zh",
               parts(detected).languageCode == "zh" || (han && detected != "ja" && detected != "ko") { continue }
            pieces.append(Piece(text: text, source: detected))
            pieceGroup.append(fragmentGroup[index])
        }
        guard !pieces.isEmpty else { completion(nil, false); return }
        func run() {
            guard isCurrent() else { return }
            var resolvedPairs: [[String]]? = systemAvailable ? nil : []
            var translations = [String: (text: String, fromAI: Bool)]()
            var incomplete = false
            func buildResult() -> Result {
                let replace: (String, Flavor) -> String = { text, flavor in
                    guard let answer = translations[text]?.text else { return text }
                    switch flavor {
                    case .plain: return answer
                    case .markdown: return escapeMarkdown(answer)
                    case .html: return escapeHTML(answer)
                    }
                }
                let hasAI = translations.values.contains { $0.fromAI }
                let hasSystem = translations.values.contains { !$0.fromAI }
                let source: OutputSource = hasAI ? (hasSystem ? .mixed : .ai) : .system
                return Result(translated: rewrite(depiction, replace: replace),
                              compared: rewrite(depiction, compared: true, replace: replace),
                              outputSource: source)
            }
            func finish() {
                guard !translations.isEmpty else { completion(nil, incomplete); return }
                completion(buildResult(), incomplete)
            }
            // A paragraph the engine leaves empty is asked for again at the end,
            // when the session has warmed up: that is where most of the stray
            // untranslated lines on a long page come from.
            // System translation has its own budget, starting only after both AI passes.
            var queue = [Int]()
            var position = 0
            var missed = [Int]()
            var retried = false
            var handedBack = -1
            var lastIndex = -1
            var systemDeadline: TimeInterval = 0
            func aiCacheKey(_ piece: Piece, _ selection: DepictionAIProvider.Selection) -> NSString {
                ("ai:\(selection.cacheID)\n\(piece.source)>\(target)\n\(piece.text)") as NSString
            }
            func carryOn() {
                guard isCurrent() else { return }
                guard position < queue.count else {
                    if !retried, !missed.isEmpty, ProcessInfo.processInfo.systemUptime < systemDeadline {
                        retried = true
                        queue = missed
                        missed = []
                        position = 0
                        carryOn()
                        return
                    }
                    finish()
                    return
                }
                let index = queue[position]
                position += 1
                if !retried, let progress = progress, lastIndex >= 0,
                   pieceGroup[index] != pieceGroup[lastIndex], handedBack != pieceGroup[lastIndex],
                   !translations.isEmpty {
                    handedBack = pieceGroup[lastIndex]
                    progress(buildResult())
                }
                lastIndex = index
                guard ProcessInfo.processInfo.systemUptime < systemDeadline else { incomplete = true; finish(); return }
                let piece = pieces[index]
                guard let pairs = resolvedPairs else {
                    availablePairs { pairs in
                        guard isCurrent() else { return }
                        resolvedPairs = pairs ?? []
                        position -= 1
                        carryOn()
                    }
                    return
                }
                let pair = pairs.filter { $0.count == 2 && score($0[0], piece.source) > 0 && score($0[1], target) > 0 }
                    .max { score($0[0], piece.source) * 4 + score($0[1], target) < score($1[0], piece.source) * 4 + score($1[1], target) }
                guard let pair = pair else {
                    failed(piece, pair: nil)
                    incomplete = true
                    carryOn()
                    return
                }
                let key = (pair[0] + ">" + pair[1] + "\n" + piece.text) as NSString
                func record(_ translated: String) {
                    if translated != piece.text { translations[piece.text] = (translated, fromAI: false) }
                    carryOn()
                }
                if let answer = cache.object(forKey: key) {
                    record(answer as String)
                    return
                }
                func request(_ onlyOffline: Bool) {
                    guard isCurrent() else { return }
                    guard ProcessInfo.processInfo.systemUptime < systemDeadline else { incomplete = true; finish(); return }
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
                            missed.append(index)
                            carryOn()
                        }
                    }
                }
                request(false)
            }
            func startSystemFallback() {
                guard isCurrent() else { return }
                queue = pieces.indices.filter { translations[pieces[$0].text] == nil }
                if !systemAvailable {
                    incomplete = !queue.isEmpty
                    finish()
                    return
                }
                systemDeadline = ProcessInfo.processInfo.systemUptime + min(180, 45 + 0.6 * Double(queue.count))
                carryOn()
            }

            guard let ai = ai else { startSystemFallback(); return }
            var pending = [Int]()
            for index in pieces.indices {
                let piece = pieces[index]
                if let answer = cache.object(forKey: aiCacheKey(piece, ai)) {
                    translations[piece.text] = (answer as String, fromAI: true)
                } else {
                    pending.append(index)
                }
            }
            func batches(_ indices: [Int], limit: Int, sizeLimit: Int) -> [[Int]] {
                var result = [[Int]]()
                var batch = [Int]()
                var size = 0
                for index in indices {
                    let length = pieces[index].text.utf16.count
                    if let first = batch.first,
                       batch.count >= limit || size + length > sizeLimit ||
                        pieceGroup[first] != pieceGroup[index] || pieces[first].source != pieces[index].source {
                        result.append(batch)
                        batch = []
                        size = 0
                    }
                    batch.append(index)
                    size += length
                }
                if !batch.isEmpty { result.append(batch) }
                return result
            }

            let firstPass = batches(pending, limit: 12, sizeLimit: 5000)
            var remainingByGroup = Dictionary(grouping: pending, by: { pieceGroup[$0] }).mapValues { $0.count }
            var showedAIProgress = false
            func showAIProgress() {
                guard let progress = progress, !showedAIProgress, !translations.isEmpty else { return }
                showedAIProgress = true
                progress(buildResult())
            }
            if remainingByGroup[pieceGroup[0]] == nil { showAIProgress() }

            func runAIPass(_ work: [[Int]], retry: Bool, completion: @escaping ([[Int]]) -> Void) {
                guard isCurrent() else { return }
                guard !work.isEmpty else { completion([]); return }
                // Give every batch a chance; a slow batch or consecutive failures must not skip later text.
                // Limit concurrency instead of letting every tab burst requests at once.
                var next = 0
                var inFlight = 0
                var misses = [[Int]](repeating: [], count: work.count)
                func pump() {
                    guard isCurrent() else { return }
                    while inFlight < 3, next < work.count {
                        let slot = next
                        let batch = work[slot]
                        next += 1
                        inFlight += 1
                        DepictionAIProvider.translate(batch.map { pieces[$0].text }, source: pieces[batch[0]].source,
                                                       target: target, using: ai, timeLimit: 30) { result in
                            guard isCurrent() else { return }
                            var reason: String?
                            switch result {
                            case .success(let answers):
                                for (offset, index) in batch.enumerated() {
                                    let piece = pieces[index]
                                    guard let answer = answers[offset]?.trimmingCharacters(in: .whitespacesAndNewlines),
                                          !answer.isEmpty, answer != piece.text else {
                                        misses[slot].append(index)
                                        continue
                                    }
                                    translations[piece.text] = (answer, fromAI: true)
                                    cache.setObject(answer as NSString, forKey: aiCacheKey(piece, ai))
                                }
                                if !misses[slot].isEmpty { reason = "missingTranslations" }
                            case .failure(let error):
                                reason = error.rawValue
                                misses[slot] = batch
                            }
                            if let reason = reason {
                                let line = "AI translation pass=\(retry ? 2 : 1) batch=\(slot + 1) reason=\(reason) missing=\(misses[slot].count)/\(batch.count)"
                                log.notice("\(line, privacy: .public)")
                            }
                            if !retry {
                                let group = pieceGroup[batch[0]]
                                remainingByGroup[group, default: 0] -= batch.count
                                if remainingByGroup[group] == 0,
                                   pieces.indices.contains(where: { pieceGroup[$0] == group && translations[pieces[$0].text] != nil }) {
                                    showAIProgress()
                                }
                            }
                            inFlight -= 1
                            if next == work.count, inFlight == 0 {
                                completion(misses)
                            } else {
                                pump()
                            }
                        }
                    }
                }
                pump()
            }
            runAIPass(firstPass, retry: false) { misses in
                let retryWork = misses.enumerated().flatMap { entry -> [[Int]] in
                    let (slot, missing) = entry
                    return batches(missing, limit: min(4, (firstPass[slot].count + 1) / 2), sizeLimit: 1800)
                }
                runAIPass(retryWork, retry: true) { _ in startSystemFallback() }
            }
        }
        run()
    }

    /// The tabs a depiction shows, so each one's text can be finished and drawn
    /// on its own; anything else is one group.
    private static func depictionGroups(_ depiction: [String: Any]) -> [[String: Any]] {
        if depiction["class"] as? String == "DepictionTabView",
           let tabs = depiction["tabs"] as? [[String: Any]], !tabs.isEmpty {
            return tabs
        }
        return [depiction]
    }

    private static func rewrite(_ depiction: [String: Any], compared: Bool = false,
                                replace: (String, Flavor) -> String) -> [String: Any] {
        var result = depiction
        switch depiction["class"] as? String {
        case "DepictionMarkdownView":
            if let markdown = depiction["markdown"] as? String {
                // useRawFormat carries HTML rather than Markdown, and the engine is
                // asked for the text between the tags only.
                let raw = depiction["useRawFormat"] as? Bool == true
                let translated: String
                if raw {
                    translated = rewriteHTML(markdown) { replace($0, .html) }
                } else {
                    translated = rewriteMarkdown(markdown) { replace($0, .markdown) }
                }
                if translated != markdown {
                    result["markdown"] = translated
                    if compared { return comparison(original: depiction, translated: result) }
                }
            }
        case "DepictionLabelView":
            if let text = depiction["text"] as? String {
                let translated = translateText(text) { replace($0, .plain) }
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
                        let translated = translateText(name) { replace($0, .plain) }
                        if translated != name { copy["tabname"] = translated }
                    }
                    return copy
                }
            }
        case "DepictionSubheaderView":
            // Havoc puts the one-line summary a page opens with in a subheader,
            // not in the Markdown body. Section headers stay as written.
            if let title = depiction["title"] as? String {
                let translated = translateText(title) { replace($0, .plain) }
                if translated != title {
                    result["title"] = translated
                    if compared { return comparison(original: depiction, translated: result) }
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

    private static let htmlOpaqueElements: Set<String> = ["script", "style", "pre", "code", "textarea"]

    /// A raw-format depiction holds HTML, not Markdown. Only the text between tags
    /// is sent to the engine; every tag, attribute, comment and code block is kept
    /// exactly as it was, so links, emphasis and selection keep working.
    private static func rewriteHTML(_ html: String, replace: (String) -> String) -> String {
        var output = ""
        var index = html.startIndex
        while index < html.endIndex {
            guard let open = html[index...].firstIndex(of: "<") else {
                output += translateText(String(html[index...]), replace: replace)
                break
            }
            if open > index {
                output += translateText(String(html[index..<open]), replace: replace)
            }
            if html[open...].hasPrefix("<!--") {
                guard let end = html[open...].range(of: "-->") else {
                    output += String(html[open...])
                    break
                }
                output += String(html[open..<end.upperBound])
                index = end.upperBound
                continue
            }
            // An attribute may hold a ">" inside quotes; the tag ends past it.
            var cursor = html.index(after: open)
            var quote: Character?
            while cursor < html.endIndex {
                let character = html[cursor]
                if let current = quote {
                    if character == current { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == ">" {
                    break
                }
                cursor = html.index(after: cursor)
            }
            guard cursor < html.endIndex else {
                output += String(html[open...])
                break
            }
            let tagEnd = html.index(after: cursor)
            let tag = html[open..<tagEnd]
            output += String(tag)
            index = tagEnd
            guard let name = htmlElementName(tag), htmlOpaqueElements.contains(name) else { continue }
            // Code and style contents are not prose: copy them through untouched.
            let closer = "</" + name
            // An unclosed opaque element consumes the remaining input. Do not
            // pass its code or style text to an external translation provider.
            guard let closing = html[index...].range(of: closer, options: .caseInsensitive) else {
                output += String(html[index...])
                break
            }
            var stop = closing.upperBound
            while stop < html.endIndex, html[stop] != ">" { stop = html.index(after: stop) }
            if stop < html.endIndex { stop = html.index(after: stop) }
            output += String(html[index..<stop])
            index = stop
        }
        return output
    }

    private static func htmlElementName(_ tag: Substring) -> String? {
        let name = tag.dropFirst().prefix { !$0.isWhitespace && $0 != "/" && $0 != ">" }
        return name.isEmpty ? nil : name.lowercased()
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
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
