//
//  BackupManager.swift
//  Sileo
//
//  Backs up installed third-party packages and the device's tweak
//  configuration into /var/mobile/Documents, and restores them through
//  Sileo's install queue.
//
//  A package that a configured source still offers is only written down,
//  not copied: the restore downloads it again, verified, and takes the
//  newest version when the installed one is gone. Only a package no source
//  knows (a local .deb, a removed source) is kept as a file, from apt's
//  cache when it is still there and repacked from disk otherwise.
//

import Foundation

final class BackupManager {

    static let shared = BackupManager()

    struct BackupFolder {
        let url: URL

        var name: String {
            url.lastPathComponent
        }

        var packagesURL: URL {
            url.appendingPathComponent("插件备份", isDirectory: true)
        }

        var configurationURL: URL {
            url.appendingPathComponent("配置备份", isDirectory: true)
        }

        var sourcesURL: URL {
            url.appendingPathComponent("源地址备份", isDirectory: true)
        }

        var manifestURL: URL {
            packagesURL.appendingPathComponent("manifest.json")
        }
    }

    struct ManifestEntry: Codable {
        var package: String
        var name: String
        var version: String
        var architecture: String?
        /// The source the package can be downloaded from again, if any.
        var repo: String?
        /// The .deb kept in the backup folder when no source offers it.
        var deb: String?
    }

    enum BackupError: LocalizedError {
        case noBackupFound
        case noPackages
        case nothingToRestore
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noBackupFound:
                return String(localizationKey: "Backup_No_Backup", type: .error)
            case .noPackages:
                return String(localizationKey: "Backup_No_Packages", type: .error)
            case .nothingToRestore:
                return String(localizationKey: "Backup_Nothing_To_Restore", type: .error)
            case .failed(let message):
                return message
            }
        }
    }

    typealias ProgressHandler = (_ fraction: Double, _ message: String, _ detail: String) -> Void

    private let rootURL = URL(fileURLWithPath: "/var/mobile/Documents", isDirectory: true)
    private let folderPrefix = "Sileo备份_"
    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    // MARK: - Folders

    func backupFolders() -> [BackupFolder] {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return contents
            .filter { $0.lastPathComponent.hasPrefix(folderPrefix) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { BackupFolder(url: $0) }
    }

    func createBackupFolder() throws -> BackupFolder {
        let folder = rootURL.appendingPathComponent(
            folderPrefix + timestampFormatter.string(from: Date()),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return BackupFolder(url: folder)
    }

    // MARK: - Packages

    /// Third-party packages: everything dpkg knows that the device's exclude
    /// list and dpkg's own Essential/Priority fields do not claim.
    func userInstalledPackages() -> [Package] {
        let excluded = excludedPackageNames()
        let packages = PackageListManager.shared.installedPackages.values.filter { package in
            if excluded.contains(package.package) {
                return false
            }
            let raw = package.rawControl
            if (raw["essential"] ?? "").lowercased() == "yes" {
                return false
            }
            let priority = (raw["priority"] ?? "").lowercased()
            if priority == "required" || priority == "important" {
                return false
            }
            return true
        }
        return packages.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private func excludedPackageNames() -> Set<String> {
        let path = jbroot("/usr/local/lib/tweak_exclude_list")
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            let names = text
                .components(separatedBy: CharacterSet.newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !names.isEmpty {
                return Set(names)
            }
        }
        return Set(["apt", "bash", "coreutils", "dpkg", "firmware", "grep", "sed", "sudo", "tar", "uikittools"])
    }

    func backupPackages(
        _ packages: [Package],
        to folder: BackupFolder,
        progress: @escaping ProgressHandler,
        completion: @escaping (Result<(Int, Int), Error>) -> Void
    ) {
        guard !packages.isEmpty else {
            completion(.failure(BackupError.noPackages))
            return
        }
        let directory = folder.packagesURL
        let manifestURL = folder.manifestURL
        DispatchQueue.global(qos: .userInitiated).async {
            PackageListManager.shared.initWait()
            let fileManager = FileManager.default
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            var entries: [ManifestEntry] = []
            var failed = 0
            let total = Double(packages.count)

            for (index, package) in packages.enumerated() {
                DispatchQueue.main.async {
                    progress(Double(index) / total, package.name, "\(index + 1)/\(packages.count)")
                }
                var entry = ManifestEntry(
                    package: package.package,
                    name: package.name,
                    version: package.version,
                    architecture: package.architecture,
                    repo: nil,
                    deb: nil
                )

                if let repoPackage = PackageListManager.shared.newestPackage(identifier: package.package),
                   let repo = repoPackage.sourceRepo {
                    entry.repo = repo.rawURL
                    entries.append(entry)
                    continue
                }

                // No source offers it: keep a file, apt's own copy first.
                let fileName = [
                    package.package,
                    BackupManager.safeName(package.version),
                    BackupManager.safeName(package.architecture ?? "all")
                ].joined(separator: "_") + ".deb"
                let destination = directory.appendingPathComponent(fileName)

                if BackupManager.copyCachedPackage(package: package, to: destination) {
                    entry.deb = fileName
                    entries.append(entry)
                    continue
                }

                do {
                    _ = try PackageRepacker.repack(package: package, to: destination)
                    entry.deb = fileName
                    entries.append(entry)
                } catch {
                    failed += 1
                    NSLog("SileoLog: backup failed \(package.package): \(error)")
                    try? fileManager.removeItem(at: destination)
                }
            }

            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(entries).write(to: manifestURL, options: .atomic)
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            DispatchQueue.main.async {
                progress(1, "", "")
                completion(.success((entries.count, failed)))
            }
        }
    }

    /// Copies the .deb apt downloaded for this package, if it is still cached.
    private static func copyCachedPackage(package: Package, to destination: URL) -> Bool {
        let cache = "\(CommandPath.prefix)/var/cache/apt/archives"
        let version = safeName(package.version)
        let architecture = safeName(package.architecture ?? "all")
        let candidates = [
            "\(package.package)_\(version)_\(architecture).deb",
            "\(package.package)_\(package.version)_\(architecture).deb"
        ]
        for candidate in candidates {
            let source = "\(cache)/\(candidate)"
            guard FileManager.default.fileExists(atPath: source) else { continue }
            try? FileManager.default.removeItem(at: destination)
            let (status, _, _) = spawnAsRoot(args: [CommandPath.cp, "-a", rootfs(source), rootfs(destination.path)])
            guard status == 0 else { continue }
            spawnAsRoot(args: [CommandPath.chown, "501:501", rootfs(destination.path)])
            return true
        }
        return false
    }

    func restorePackages(
        from folder: BackupFolder,
        progress: @escaping ProgressHandler,
        completion: @escaping (Result<(Int, Int), Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            PackageListManager.shared.initWait()
            let entries = BackupManager.manifestEntries(in: folder)
            guard !entries.isEmpty else {
                DispatchQueue.main.async { completion(.failure(BackupError.nothingToRestore)) }
                return
            }

            var queued: [Package] = []
            var skipped = 0
            let total = Double(entries.count)

            for (index, entry) in entries.enumerated() {
                DispatchQueue.main.async {
                    progress(Double(index) / total, entry.name, "\(index + 1)/\(entries.count)")
                }
                if let package = BackupManager.resolve(entry: entry, in: folder) {
                    queued.append(package)
                } else {
                    skipped += 1
                    NSLog("SileoLog: restore skipped \(entry.package) \(entry.version)")
                }
            }

            DispatchQueue.main.async {
                progress(1, "", "")
                guard !queued.isEmpty else {
                    completion(.failure(BackupError.nothingToRestore))
                    return
                }
                let manager = DownloadManager.shared
                for package in queued {
                    manager.add(package: package, queue: .installations)
                }
                if !manager.queueRunning {
                    manager.reloadData(recheckPackages: true)
                }
                NotificationCenter.default.post(name: PackageQueueButton.actionPerformedNotification, object: nil)
                completion(.success((queued.count, skipped)))
            }
        }
    }

    private static func manifestEntries(in folder: BackupFolder) -> [ManifestEntry] {
        let fileManager = FileManager.default
        if let data = try? Data(contentsOf: folder.manifestURL),
           let entries = try? JSONDecoder().decode([ManifestEntry].self, from: data) {
            return entries
        }
        // A backup made before the manifest: whatever debs it holds.
        let contents = (try? fileManager.contentsOfDirectory(
            at: folder.packagesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == "deb" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                ManifestEntry(
                    package: url.deletingPathExtension().lastPathComponent,
                    name: url.lastPathComponent,
                    version: "",
                    architecture: nil,
                    repo: nil,
                    deb: url.lastPathComponent
                )
            }
    }

    /// The package to install for a manifest entry: the recorded source (or
    /// any source, newest) when it offers the package, otherwise the kept .deb.
    private static func resolve(entry: ManifestEntry, in folder: BackupFolder) -> Package? {
        if let repoURL = entry.repo,
           let repo = RepoManager.shared.repoList.first(where: { $0.rawURL == repoURL }),
           let package = exactOrNewest(in: repo, entry: entry) {
            return package
        }
        if let package = PackageListManager.shared.newestPackage(identifier: entry.package),
           package.sourceRepo != nil {
            return package
        }
        if let deb = entry.deb {
            let url = folder.packagesURL.appendingPathComponent(deb)
            if let package = PackageListManager.shared.package(url: url) {
                return package
            }
        }
        return nil
    }

    private static func exactOrNewest(in repo: Repo, entry: ManifestEntry) -> Package? {
        if let exact = repo.packageArray.first(where: {
            $0.package == entry.package && $0.version == entry.version
        }) {
            return exact
        }
        return repo.newestPackage(identifier: entry.package)
    }

    // MARK: - Configuration

    func backupConfiguration(
        to folder: BackupFolder,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            do {
                try fileManager.createDirectory(at: folder.configurationURL, withIntermediateDirectories: true)
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            let archive = folder.configurationURL.appendingPathComponent("Library.tar")
            try? fileManager.removeItem(at: archive)
            let (status, _, errorOutput) = spawnAsRoot(args: [
                PackageRepacker.tarPath, "-cf", rootfs(archive.path),
                "-C", rootfs("/var/mobile"),
                "--exclude=Library/Caches",
                "Library"
            ])
            guard status == 0 else {
                DispatchQueue.main.async {
                    completion(.failure(BackupError.failed(errorOutput.isEmpty ? "tar exited with \(status)" : errorOutput)))
                }
                return
            }
            spawnAsRoot(args: [CommandPath.chown, "501:501", rootfs(archive.path)])
            DispatchQueue.main.async { completion(.success(())) }
        }
    }

    func restoreConfiguration(
        from folder: BackupFolder,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let archive = folder.configurationURL.appendingPathComponent("Library.tar")
            guard FileManager.default.fileExists(atPath: archive.path) else {
                DispatchQueue.main.async { completion(.failure(BackupError.nothingToRestore)) }
                return
            }
            let (status, _, errorOutput) = spawnAsRoot(args: [
                PackageRepacker.tarPath, "-xpf", rootfs(archive.path),
                "-C", rootfs("/var/mobile")
            ])
            guard status == 0 else {
                DispatchQueue.main.async {
                    completion(.failure(BackupError.failed(errorOutput.isEmpty ? "tar exited with \(status)" : errorOutput)))
                }
                return
            }
            spawnAsRoot(args: [CommandPath.chown, "-R", "501:501", rootfs("/var/mobile/Library")])
            DispatchQueue.main.async { completion(.success(())) }
        }
    }

    // MARK: - Sources

    func backupSources(
        to folder: BackupFolder,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            let lines = RepoManager.shared.repoList.compactMap { $0.aptSource }
            guard !lines.isEmpty else {
                DispatchQueue.main.async { completion(.failure(BackupError.nothingToRestore)) }
                return
            }
            do {
                try fileManager.createDirectory(at: folder.sourcesURL, withIntermediateDirectories: true)
                let file = folder.sourcesURL.appendingPathComponent("sources.sources")
                try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
                DispatchQueue.main.async { completion(.success(lines.count)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func restoreSources(
        from folder: BackupFolder,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        let file = folder.sourcesURL.appendingPathComponent("sources.sources")
        guard FileManager.default.fileExists(atPath: file.path) else {
            completion(.failure(BackupError.nothingToRestore))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let manager = RepoManager()
            manager.parseSourcesFile(at: file)
            var added = 0
            for repo in manager.repoList {
                guard let url = URL(string: repo.rawURL) else { continue }
                if RepoManager.shared.addDistRepo(
                    url: url,
                    suites: repo.suite,
                    components: repo.components.joined(separator: " ")
                ) != nil {
                    added += 1
                }
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: PackageListManager.reloadNotification, object: nil)
                completion(.success(added))
            }
        }
    }

    // MARK: - Helpers

    static func safeName(_ text: String) -> String {
        text
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
}
