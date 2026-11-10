//
//  RemovedSources.swift
//  Sileo
//
//  A source taken off the list with a swipe is remembered here, so that it can
//  be put back after a mistake. The record keeps what is needed to add it
//  again: its address, suite and components, and the name it showed.
//

import Foundation

struct RemovedSource: Codable, Equatable {
    var url: String
    var suite: String
    var components: [String]
    var name: String
    var removedAt: Date

    var displayURL: String { url }
}

final class RemovedSourcesStore {

    static let shared = RemovedSourcesStore()

    private let key = "SileoRemovedSources"
    private(set) var items: [RemovedSource] = []

    private init() {
        load()
    }

    // MARK: - Storage

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RemovedSource].self, from: data) else {
            return
        }
        items = decoded.sorted { $0.removedAt > $1.removedAt }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    // MARK: - API

    var isEmpty: Bool { items.isEmpty }

    var count: Int { items.count }

    /// Keeps a source that is being removed, newest first. A source removed
    /// twice is kept once, with the newer date.
    func record(_ repo: Repo) {
        let address = repo.rawURL
        guard !address.isEmpty else { return }
        items.removeAll { $0.url == address && $0.suite == repo.suite }
        items.insert(RemovedSource(url: address,
                                   suite: repo.suite,
                                   components: repo.components,
                                   name: repo.displayName,
                                   removedAt: Date()),
                     at: 0)
        save()
    }

    /// Whether a source at this address was taken off the list and never put
    /// back. It stays off even though the file that carries it is still there:
    /// the bootstrap's own `default.sources` is one Sileo never rewrites.
    func isRemoved(url: String) -> Bool {
        let address = RemovedSourcesStore.normalize(url)
        return items.contains { RemovedSourcesStore.normalize($0.url) == address }
    }

    /// Drops the records of sources that are back on the list, so the same one
    /// is not offered again.
    func forget(_ sources: [RemovedSource]) {
        guard !sources.isEmpty else { return }
        let addresses = Set(sources.map { $0.url + "|" + $0.suite })
        items.removeAll { addresses.contains($0.url + "|" + $0.suite) }
        save()
    }

    /// The same, for a source added on purpose.
    func forget(urls: [URL]) {
        guard !urls.isEmpty else { return }
        let addresses = Set(urls.map { RemovedSourcesStore.normalize($0.absoluteString) })
        items.removeAll { addresses.contains(RemovedSourcesStore.normalize($0.url)) }
        save()
    }

    /// One spelling for an address: no trailing slash difference, no capitals.
    static func normalize(_ url: String) -> String {
        var address = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !address.hasSuffix("/") {
            address += "/"
        }
        return address
    }

    func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        save()
    }

    func removeAll() {
        items.removeAll()
        save()
    }
}
