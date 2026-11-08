//
//  PinnedSources.swift
//  Sileo
//
//  The sources the user put at the top of the list. Kept in the app's
//  defaults as the source addresses, so a source stays pinned across a
//  refresh, a rename or a launch.
//

import Foundation

final class PinnedSources {

    static let shared = PinnedSources()

    private static let defaultsKey = "SileoPinnedSources"
    private var cache: [String]?

    /// Pinned addresses, newest pin first.
    private var keys: [String] {
        if let cache = cache {
            return cache
        }
        let stored = UserDefaults.standard.stringArray(forKey: PinnedSources.defaultsKey) ?? []
        cache = stored
        return stored
    }

    private func key(for repo: Repo) -> String {
        (repo.url?.absoluteString ?? repo.rawURL).lowercased()
    }

    func isPinned(_ repo: Repo) -> Bool {
        keys.contains(key(for: repo))
    }

    /// Pins a source, or unpins it. Answers whether it is pinned afterwards.
    @discardableResult
    func toggle(_ repo: Repo) -> Bool {
        let identifier = key(for: repo)
        var list = keys
        if let index = list.firstIndex(of: identifier) {
            list.remove(at: index)
            store(list)
            return false
        }
        list.insert(identifier, at: 0)
        store(list)
        return true
    }

    func remove(_ repo: Repo) {
        var list = keys
        list.removeAll { $0 == key(for: repo) }
        store(list)
    }

    /// The pinned sources first, in the order they were pinned, then the rest.
    func sorted(_ repos: [Repo]) -> [Repo] {
        let order = keys
        guard !order.isEmpty else {
            return repos
        }
        var pinned: [Repo] = []
        var others: [Repo] = []
        for repo in repos {
            if order.contains(key(for: repo)) {
                pinned.append(repo)
            } else {
                others.append(repo)
            }
        }
        pinned.sort {
            (order.firstIndex(of: key(for: $0)) ?? Int.max) < (order.firstIndex(of: key(for: $1)) ?? Int.max)
        }
        return pinned + others
    }

    private func store(_ list: [String]) {
        cache = list
        UserDefaults.standard.set(list, forKey: PinnedSources.defaultsKey)
        UserDefaults.standard.synchronize()
    }
}
