#!/bin/bash
set -euo pipefail
work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir:?}"' EXIT
# Test the exact production query/ranking core without UIKit or app startup.
sed '/^\/\/ Kept separate from ranking/,$d' 'Sileo/Backend/Package Manager/PackageSearch.swift' > "$work_dir/main.swift"
cat >> "$work_dir/main.swift" <<'SWIFT'
func score(_ query: String, _ name: String = "Example", _ summary: String = "", _ detail: String = "") -> Int {
    FunctionalSearchQuery(query).score(name: FunctionalSearchQuery.normalize(name), identifier: "com.example.test", summary: FunctionalSearchQuery.normalize(summary), detail: FunctionalSearchQuery.normalize(detail))
}
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
check(score("状态栏 隐藏", "Example", "Hide icons in the status bar") > 0, "Chinese concepts must match English summaries")
check(score("把状态栏的图标隐藏掉", "Example", "Hide status bar icons") > 0, "Natural Chinese filler must not block concepts")
check(score("锁屏 时间 位置", "Example", "Change the clock position on your lock screen") > 0, "Independent terms must match across a sentence")
check(score("锁屏 时间", "Example", "Clock on the home screen") == 0, "Every functional concept must match")
check(score("锁屏 时钟", "Example", "A tweak", "Custom lockscreen clock") > 0, "Cached details must be searchable")
check(score("状态栏", "状态栏助手", "") > score("状态栏", "Other", "Customize the status bar"), "Name matches must rank above description matches")
check(score("snowboar", "SnowBoard") > 0, "One missing character must be tolerated")
check(score("snowbaord", "SnowBoard") > 0, "Adjacent transposition must be tolerated")
check(score("snowxxxxx", "SnowBoard") == 0, "Unrelated names must not fuzzy match")
check(score("广告", "Example", "Adds a new clock") == 0, "Short English aliases must not match inside words")
check(score("  LOCKSCREEN  CLOCK ", "Example", "Lock screen clock") > 0, "Case and whitespace must normalize")
check(score("ＣＬＯＣＫ", "Clock") > 0, "Full-width Latin text must normalize")
check(score("com.example.test", "Example") > 0, "Package ID search must keep working")
let snippet = FunctionalSearchQuery("锁屏").snippet(summary: "Generic tweak", detail: String(repeating: "A ", count: 150) + "Custom lock screen widgets")
check(snippet.contains("lock screen") && snippet.count <= 182, "Detail snippets must include the matched text and be bounded")
check(score("", "Example") == 0, "Empty searches must not produce scored results")
print("Functional search: 15 checks passed")
SWIFT
swift "$work_dir/main.swift"
