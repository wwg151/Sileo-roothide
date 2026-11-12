//
//  PinnedSources.swift
//  Sileo
//
//  The order the user gave the sources by dragging them. Kept in the app's
//  defaults as the source addresses, so the order survives a refresh, a
//  rename or a launch.
//

import Foundation

final class PinnedSources {

    static let shared = PinnedSources()

    private static let customOrderKey = "SileoSourceOrder"
    private static let lockedSourcesKey = "SileoLockedSources"

    func isLocked(_ repo: Repo) -> Bool {
        let saved = UserDefaults.standard.stringArray(forKey: Self.lockedSourcesKey) ?? []
        return saved.contains(key(for: repo))
    }

    func setLocked(_ locked: Bool, for repo: Repo) {
        var saved = Set(UserDefaults.standard.stringArray(forKey: Self.lockedSourcesKey) ?? [])
        let identifier = key(for: repo)
        if locked {
            saved.insert(identifier)
        } else {
            saved.remove(identifier)
        }
        UserDefaults.standard.set(saved.sorted(), forKey: Self.lockedSourcesKey)
        UserDefaults.standard.synchronize()
    }

    private func key(for repo: Repo) -> String {
        (repo.url?.absoluteString ?? repo.rawURL).lowercased()
    }

    /// The rows the user moved, in the order they left them, then the sources
    /// the order does not know yet (a newly added source) in their normal order.
    func sorted(_ repos: [Repo]) -> [Repo] {
        let order = UserDefaults.standard.stringArray(forKey: Self.customOrderKey) ?? []
        guard !order.isEmpty else {
            return repos
        }
        let positions = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let remembered = repos.filter { positions[key(for: $0)] != nil }.sorted {
            (positions[key(for: $0)] ?? 0) < (positions[key(for: $1)] ?? 0)
        }
        return remembered + repos.filter { positions[key(for: $0)] == nil }
    }

    func saveOrder(_ repos: [Repo]) {
        UserDefaults.standard.set(repos.map { key(for: $0) }, forKey: Self.customOrderKey)
        UserDefaults.standard.synchronize()
    }

    func remove(_ repo: Repo) {
        guard let saved = UserDefaults.standard.stringArray(forKey: Self.customOrderKey) else {
            return
        }
        let identifier = key(for: repo)
        UserDefaults.standard.set(saved.filter { $0 != identifier }, forKey: Self.customOrderKey)
    }
}
