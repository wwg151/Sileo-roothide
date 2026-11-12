// Local functional search. No query or package metadata is sent to a service.
import Foundation

struct FunctionalSearchQuery {
    struct Term {
        let text: String
        let alternatives: [String]
    }
    let text: String
    let terms: [Term]

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // Concepts are deliberately narrow: related features are not synonyms.
    static let concepts: [[String]] = [
        ["状态栏", "status bar", "statusbar"], ["锁屏", "锁定屏幕", "lock screen", "lockscreen"],
        ["桌面", "主屏幕", "home screen", "homescreen", "springboard"],
        ["控制中心", "control center", "control centre", "controlcenter"],
        ["通知中心", "notification center", "notification centre"],
        ["通知", "推送", "notification", "notifications"], ["图标", "icon", "icons"],
        ["角标", "小红点", "badge", "badges"], ["标签", "label", "labels"],
        ["隐藏", "去掉", "不显示", "hide", "hidden", "hiding"],
        ["显示", "show", "display"], ["位置", "摆放", "position", "placement"],
        ["布局", "排列", "layout", "arrangement"], ["自由", "随意", "随便", "freely", "freeform"],
        ["大小", "尺寸", "size", "resize"], ["颜色", "配色", "color", "colour"],
        ["透明", "透明度", "transparent", "transparency", "opacity"],
        ["模糊", "磨砂", "blur", "blurring"], ["动画", "动效", "animation", "animations"],
        ["手势", "gesture", "gestures"], ["双击", "double tap", "doubletap"],
        ["长按", "long press", "longpress"], ["滑动", "swipe", "swiping"],
        ["电池", "电量", "battery"], ["百分比", "percentage", "percent"],
        ["充电", "charging", "charge"], ["时间", "时钟", "clock", "time"],
        ["日期", "date"], ["天气", "weather"], ["壁纸", "wallpaper", "wallpapers"],
        ["字体", "font", "fonts"], ["键盘", "keyboard"], ["输入法", "input method"],
        ["剪贴板", "剪切板", "clipboard"], ["音量", "volume"], ["音乐", "music"],
        ["播放器", "player"], ["歌词", "lyrics"], ["蓝牙", "bluetooth"],
        ["无线网络", "无线网", "wifi", "wi-fi"], ["网络", "network"],
        ["广告", "advertisement", "advertisements", "adblock", "ads"],
        ["屏蔽", "拦截", "阻止", "block", "blocking"], ["去广告", "移除广告", "adblock", "remove ads"],
        ["截图", "截屏", "screenshot", "screenshots"], ["录屏", "screen recording", "screen recorder"],
        ["相机", "camera"], ["照片", "相片", "photo", "photos"],
        ["文件夹", "folder", "folders"], ["文件", "file", "files"],
        ["小组件", "小部件", "widget", "widgets"], ["后台", "background"],
        ["多任务", "应用切换器", "app switcher", "multitasking"],
        ["分屏", "split screen", "splitscreen"], ["画中画", "picture in picture", "pip"],
        ["悬浮", "浮动", "floating"], ["底栏", "程序坞", "dock"],
        ["振动", "震动", "触觉", "haptic", "haptics", "vibration"],
        ["解锁", "unlock", "unlocking"], ["面容", "面容识别", "face id", "faceid"],
        ["指纹", "touch id", "touchid"], ["深色模式", "暗黑模式", "dark mode"],
        ["圆角", "rounded corners", "corner radius"], ["全面屏", "全屏", "full screen", "fullscreen"]
    ]
    private static let aliases: [(String, [String])] = concepts.flatMap { group in
        group.map { ($0, group) }
    }.sorted { $0.0.count > $1.0.count }
    private static let filler: Set<String> = ["我", "想", "要", "把", "将", "让", "的", "了", "掉", "能", "可以", "一个", "插件", "功能", "如何", "怎么", "帮我", "有没有", "是否", "实现", "调整", "设置", "进行", "the", "a", "an", "to", "of", "for", "and", "i", "want", "tweak", "please"]

    init(_ raw: String) {
        text = Self.normalize(raw)
        let chars = Array(text.prefix(256))
        var result: [Term] = []
        var index = 0
        while index < chars.count {
            let rest = String(chars[index...])
            if let alias = Self.aliases.first(where: { entry in
                guard rest.hasPrefix(entry.0) else { return false }
                let count = entry.0.count
                // English concepts must occupy whole words ("time" != "runtime").
                if entry.0.first?.isASCII == true {
                    if index > 0 && chars[index - 1].isLetter { return false }
                    if index + count < chars.count && chars[index + count].isLetter { return false }
                }
                return true
            }) {
                result.append(Term(text: alias.0, alternatives: alias.1))
                index += alias.0.count
            } else if let filler = Self.filler.filter({ $0.first?.isASCII == false }).sorted(by: { $0.count > $1.count }).first(where: { rest.hasPrefix($0) }) {
                index += filler.count
            } else if chars[index].isASCII && (chars[index].isLetter || chars[index].isNumber) {
                let start = index
                while index < chars.count && chars[index].isASCII && (chars[index].isLetter || chars[index].isNumber || chars[index] == "." || chars[index] == "-" || chars[index] == "_") { index += 1 }
                let word = String(chars[start..<index])
                if !Self.filler.contains(word) { result.append(Term(text: word, alternatives: [word])) }
            } else if chars[index].isLetter {
                // Preserve unknown CJK phrases instead of inventing meanings for them.
                let start = index
                index += 1
                while index < chars.count && chars[index].isLetter && !chars[index].isASCII {
                    let remaining = String(chars[index...])
                    if Self.aliases.contains(where: { remaining.hasPrefix($0.0) }) { break }
                    if Self.filler.contains(String(chars[index])) { break }
                    index += 1
                }
                let word = String(chars[start..<index])
                if !Self.filler.contains(word) { result.append(Term(text: word, alternatives: [word])) }
            } else {
                index += 1
            }
        }
        var seen = Set<String>()
        terms = Array(result.filter { seen.insert($0.alternatives.sorted().joined(separator: "|")).inserted }.prefix(16))
    }

    static func contains(_ haystack: String, _ needle: String) -> Bool {
        // Avoid short English aliases matching inside unrelated words, e.g. ads/pip.
        if needle.count <= 3 && needle.allSatisfy({ $0.isASCII && $0.isLetter }) {
            return haystack.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0 == needle }
        }
        return haystack.contains(needle)
    }

    func score(name: String, identifier: String, summary: String, detail: String) -> Int {
        if text.isEmpty { return 0 }
        var total = 0
        var direct = false
        if name == text { total += 2000; direct = true }
        else if name.hasPrefix(text) { total += 1200; direct = true }
        else if name.contains(text) { total += 900; direct = true }
        if identifier.contains(text) { total += 700; direct = true }
        if summary.contains(text) { total += 350; direct = true }
        if !detail.isEmpty && detail.contains(text) { total += 200; direct = true }
        if terms.isEmpty { return direct ? total : 0 }
        for term in terms {
            var best = 0
            for alias in term.alternatives {
                let literal = alias == term.text ? 30 : 0
                if Self.contains(name, alias) { best = max(best, 220 + literal) }
                if Self.contains(identifier, alias) { best = max(best, 160 + literal) }
                if Self.contains(summary, alias) { best = max(best, 100 + literal) }
                if !detail.isEmpty && Self.contains(detail, alias) { best = max(best, 65 + literal) }
            }
            // A precise literal phrase still wins even if the tokenizer split it differently.
            if best == 0 && !direct { return fuzzyScore(name: name, identifier: identifier) }
            total += best
        }
        return total
    }

    private func fuzzyScore(name: String, identifier: String) -> Int {
        guard terms.count == 1, let term = terms.first, term.text.count >= 5,
              term.text.count <= 48, term.text.allSatisfy({ $0.isASCII && $0.isLetter }) else { return 0 }
        let words = (name + " " + identifier).split(whereSeparator: { !$0.isLetter }).map(String.init)
        return words.contains(where: { Self.oneEditApart(term.text, $0) }) ? 25 : 0
    }

    static func oneEditApart(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs), b = Array(rhs)
        guard abs(a.count - b.count) <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if a.count == b.count {
                if i + 1 < a.count && a[i] == b[j + 1] && a[i + 1] == b[j] {
                    i += 2; j += 2
                } else { i += 1; j += 1 }
            } else if a.count > b.count { i += 1 }
            else { j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) <= 1
    }

    var highlightTerms: [String] { Array(Set([text] + terms.flatMap { $0.alternatives })).filter { !$0.isEmpty }.sorted { $0.count > $1.count } }

    func snippet(summary: String, detail: String) -> String {
        let needles = highlightTerms
        for source in [summary, detail] where !source.isEmpty {
            let normalized = Self.normalize(source)
            if let needle = needles.first(where: { Self.contains(normalized, $0) }),
               let range = source.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) {
                let start = source.index(range.lowerBound, offsetBy: -45, limitedBy: source.startIndex) ?? source.startIndex
                let end = source.index(start, offsetBy: 180, limitedBy: source.endIndex) ?? source.endIndex
                return (start == source.startIndex ? "" : "…") + source[start..<end] + (end == source.endIndex ? "" : "…")
            }
        }
        return summary
    }
}

// Kept separate from ranking so the pure search core can be tested with Foundation.
final class PackageSearchIndex {
    static let shared = PackageSearchIndex()
    static let changed = Notification.Name("SileoSearchDetailsChanged")
    private struct Detail: Codable {
        let text: String
        let date: Date
    }
    private final class Document {
        let name: String, identifier: String, summary: String
        init(_ package: Package) {
            name = FunctionalSearchQuery.normalize(package.name)
            identifier = FunctionalSearchQuery.normalize(package.package)
            summary = FunctionalSearchQuery.normalize(package.description ?? "")
        }
    }
    private let documents = NSCache<NSString, Document>()
    private let lock = NSLock()
    private let diskQueue = DispatchQueue(label: "Sileo.search-details")
    private var details: [String: Detail] = [:]
    private var revision = 0
    private var savePending = false
    private let cacheURL: URL?

    private init() {
        documents.countLimit = 20000
        cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("SileoFunctionalSearch-v1.json")
        if let url = cacheURL, let data = try? Data(contentsOf: url), data.count <= 12_000_000,
           let saved = try? JSONDecoder().decode([String: Detail].self, from: data) {
            let cutoff = Date().addingTimeInterval(-30 * 86400)
            details = Dictionary(uniqueKeysWithValues: saved.filter { $0.value.date > cutoff }.sorted { $0.value.date > $1.value.date }.prefix(300).map { ($0.key, $0.value) })
        }
    }
    private func key(_ package: Package) -> String {
        [package.package, package.version, package.sourceFile ?? "", package.sileoDepiction?.absoluteString ?? ""].joined(separator: "\u{1f}")
    }
    func detail(for package: Package) -> String {
        lock.lock(); defer { lock.unlock() }
        guard let entry = details[key(package)], entry.date > Date().addingTimeInterval(-30 * 86400) else { return "" }
        return entry.text
    }
    var generation: Int { lock.lock(); defer { lock.unlock() }; return revision }

    func ranked(_ packages: [Package], query: String) -> [Package] {
        let parsed = FunctionalSearchQuery(query)
        return packages.enumerated().compactMap { index, package -> (Int, Int, Package)? in
            // Source/version and field contents prevent stale documents after a refresh.
            let cacheKey = (key(package) + "\u{1f}" + package.name + "\u{1f}" + (package.description ?? "")) as NSString
            let doc: Document
            if let cached = documents.object(forKey: cacheKey) { doc = cached }
            else { doc = Document(package); documents.setObject(doc, forKey: cacheKey) }
            let score = parsed.score(name: doc.name, identifier: doc.identifier, summary: doc.summary,
                                     detail: FunctionalSearchQuery.normalize(detail(for: package)))
            return score > 0 ? (score, index, package) : nil
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }.map { $0.2 }
    }

    func capture(_ json: [String: Any], for package: Package) {
        let cacheKey = key(package)
        diskQueue.async {
            var parts: [String] = []
            var budget = 16000
            func visit(_ value: Any, depth: Int) {
                guard depth < 24, budget > 0 else { return }
                if let array = value as? [Any] {
                    for item in array.prefix(200) { visit(item, depth: depth + 1) }
                } else if let dict = value as? [String: Any] {
                    let type = dict["class"] as? String ?? ""
                    // Index readable text only; never actions, links, images or WebView scripts.
                    let textClasses = ["DepictionMarkdownView", "DepictionLabelView", "DepictionHeaderView", "DepictionSubheaderView", "DepictionTableTextView"]
                    if textClasses.contains(type) {
                        for field in ["markdown", "text", "title", "subtitle"] {
                            if let text = dict[field] as? String {
                                let clean = text.replacingOccurrences(of: "<[^>]+>|!\\[[^\\]]*\\]\\([^)]*\\)", with: " ", options: .regularExpression)
                                    .replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
                                    .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                                if !clean.isEmpty { let piece = String(clean.prefix(budget)); parts.append(piece); budget -= piece.count }
                            }
                        }
                    }
                    for field in ["views", "tabs", "children"] { if let child = dict[field] { visit(child, depth: depth + 1) } }
                }
            }
            visit(json, depth: 0)
            let text = parts.joined(separator: " ")
            guard !text.isEmpty else { return }
            self.lock.lock()
            let changed = self.details[cacheKey]?.text != text
            self.details[cacheKey] = Detail(text: text, date: Date())
            if self.details.count > 300 {
                let oldest = self.details.min { $0.value.date < $1.value.date }?.key
                if let oldest = oldest { self.details.removeValue(forKey: oldest) }
            }
            if changed { self.revision += 1 }
            let needsSave = !self.savePending
            self.savePending = true
            self.lock.unlock()
            if changed {
                DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
            }
            if needsSave {
                self.diskQueue.asyncAfter(deadline: .now() + 2) {
                    self.lock.lock()
                    let snapshot = self.details
                    self.savePending = false
                    self.lock.unlock()
                    if let url = self.cacheURL, let data = try? JSONEncoder().encode(snapshot) {
                        try? data.write(to: url, options: .atomic)
                    }
                }
            }
        }
    }
}
