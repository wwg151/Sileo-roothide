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

    // MARK: - Cancelling

    private let cancelLock = NSLock()
    private var cancelRequested = false

    /// A running backup or restore reads this between steps and stops.
    var isCancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelRequested
    }

    func beginOperation() {
        cancelLock.lock()
        cancelRequested = false
        cancelLock.unlock()
    }

    func cancelCurrentOperation() {
        cancelLock.lock()
        cancelRequested = true
        cancelLock.unlock()
    }

    /// A cancelled backup leaves nothing behind: the folder it made goes.
    private func discard(_ folder: BackupFolder) {
        try? FileManager.default.removeItem(at: folder.url)
    }

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
            url.appendingPathComponent("源备份", isDirectory: true)
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
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noBackupFound:
                return String(localizationKey: "Backup_No_Backup", type: .error)
            case .noPackages:
                return String(localizationKey: "Backup_No_Packages", type: .error)
            case .nothingToRestore:
                return String(localizationKey: "Backup_Nothing_To_Restore", type: .error)
            case .cancelled:
                return String(localizationKey: "Backup_Cancelled", type: .error)
            case .failed(let message):
                return message
            }
        }
    }

    enum BackupKind {
        case packages
        case configuration
        case sources

        var folderPrefix: String {
            switch self {
            case .packages: return "Sileo插件备份_"
            case .configuration: return "Sileo配置备份_"
            case .sources: return "Sileo源备份_"
            }
        }
    }

    typealias ProgressHandler = (_ fraction: Double, _ message: String, _ detail: String) -> Void

    private let rootURL = URL(fileURLWithPath: "/var/mobile/Documents", isDirectory: true)
    private let legacyFolderPrefix = "Sileo备份_"

    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    // MARK: - Folders

    func backupFolders(kind: BackupKind) -> [BackupFolder] {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return contents
            .filter { url in
                let name = url.lastPathComponent
                return name.hasPrefix(kind.folderPrefix) || name.hasPrefix(legacyFolderPrefix)
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { BackupFolder(url: $0) }
    }

    func createBackupFolder(kind: BackupKind) throws -> BackupFolder {
        let folder = rootURL.appendingPathComponent(
            kind.folderPrefix + timestampFormatter.string(from: Date()),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return BackupFolder(url: folder)
    }

    /// Every backup folder, whatever it holds, newest first.
    func allBackupFolders() -> [BackupFolder] {
        var seen = Set<String>()
        var all: [BackupFolder] = []
        for kind in [BackupKind.packages, .configuration, .sources] {
            for folder in backupFolders(kind: kind) where !seen.contains(folder.url.path) {
                seen.insert(folder.url.path)
                all.append(folder)
            }
        }
        return all.sorted { $0.name > $1.name }
    }

    /// Removes only explicitly selected, currently recognized backup folders.
    /// A backup may hold root-owned files, so the folders go as root.
    func deleteBackups(folders: [BackupFolder]) -> Int {
        let allowed = Set(allBackupFolders().map { $0.url.standardizedFileURL.path })
        var seen = Set<String>()
        var removed = 0
        for folder in folders {
            let path = folder.url.standardizedFileURL.path
            guard allowed.contains(path), seen.insert(path).inserted else { continue }
            let (status, _, _) = spawnAsRoot(args: [CommandPath.rm, "-rf", rootfs(path)])
            if status == 0 || !FileManager.default.fileExists(atPath: folder.url.path) {
                removed += 1
            }
        }
        return removed
    }

    // MARK: - Packages

    /// Third-party packages: everything dpkg knows that the device's exclude
    /// list, dpkg's own Essential/Priority fields, and the bootstrap's own
    /// packages do not claim.
    func userInstalledPackages() -> [Package] {
        let excluded = excludedPackageNames()
        let bootstrapTime = bootstrapInstallTime()
        let packages = PackageListManager.shared.installedPackages.values.filter { package in
            if excluded.contains(package.package) {
                return false
            }
            // The bootstrap's libraries, keyrings and its own tools are not
            // the user's packages, however dpkg marks them.
            if BackupManager.isBootstrapPackage(package, bootstrapTime: bootstrapTime) {
                return false
            }
            let raw = package.rawControl
            if (raw["essential"] ?? "").lowercased() == "yes" {
                return false
            }
            // Only dpkg's "required" is the bootstrap's own: a package marked
            // "important" can be one the user added (zip, unzip).
            let priority = (raw["priority"] ?? "").lowercased()
            if priority == "required" {
                return false
            }
            return true
        }
        return packages.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// The moment the bootstrap unpacked its packages: the largest group dpkg
    /// installed at once. Everything later came from a source or a .deb the
    /// user added, even when it carries a name the bootstrap also uses.
    private func bootstrapInstallTime() -> Date? {
        var batches: [Date: Int] = [:]
        for package in PackageListManager.shared.installedPackages.values {
            guard let date = package.installDate else { continue }
            let minute = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
            batches[minute, default: 0] += 1
        }
        return batches.max { $0.value < $1.value }?.key
    }

    /// A library, a keyring, or one of the packages the roothide bootstrap
    /// itself puts there. A package with such a name that was installed after
    /// the bootstrap's own batch is the user's.
    private static func isBootstrapPackage(_ package: Package, bootstrapTime: Date?) -> Bool {
        let identifier = package.package
        if identifier.hasPrefix("lib") {
            return true
        }
        let section = (package.rawControl["section"] ?? "").lowercased()
        if section == "libraries" || section == "keyrings" {
            return true
        }
        guard bootstrapPackages.contains(identifier) else {
            return false
        }
        if let installDate = package.installDate,
           let bootstrapTime = bootstrapTime,
           installDate > bootstrapTime.addingTimeInterval(120) {
            return false
        }
        return true
    }

    private static let bootstrapPackages: Set<String> = [
        "apt", "base", "bash", "ca-certificates", "chariz-keyring", "coreutils",
        "dash", "darwintools", "debianutils", "diffutils", "diskdev-cmds", "dpkg",
        "dopamine-basebin-link", "ellekit", "essential", "file-cmds", "findutils",
        "firmware", "gawk", "gpgv", "grep", "gzip", "havoc-keyring", "launchctl",
        "ldid", "ncurses-bin", "ncurses-term", "p7zip", "procursus-keyring",
        "profile.d", "roothide", "rootless-compat", "sed", "shell-cmds",
        "snaputil", "sudo", "system-cmds", "tar", "uikittools", "unrar", "unzip",
        "vi", "xz-utils", "zip", "zsh", "com.roothide.patchloader"
    ]

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
        completion: @escaping (Result<(Int, [String]), Error>) -> Void
    ) {
        guard !packages.isEmpty else {
            completion(.failure(BackupError.noPackages))
            return
        }
        let directory = folder.packagesURL
        let manifestURL = folder.manifestURL
        beginOperation()
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
            var failures: [String] = []
            let total = Double(packages.count)

            for (index, package) in packages.enumerated() {
                if self.isCancelled {
                    self.discard(folder)
                    DispatchQueue.main.async { completion(.failure(BackupError.cancelled)) }
                    return
                }
                let detail = "\(index + 1)/\(packages.count)"
                func report(_ phase: Double) {
                    let value = (Double(index) + phase) / total
                    DispatchQueue.main.sync {
                        progress(value, package.name, detail)
                    }
                }
                report(0)
                // A cached copy is done in a moment; a repack reports its own
                // phases, and the pause keeps each step on screen.
                Thread.sleep(forTimeInterval: 0.05)
                var entry = ManifestEntry(
                    package: package.package,
                    name: package.name,
                    version: package.version,
                    architecture: package.architecture,
                    repo: nil,
                    deb: nil
                )

                // Kept locally, always: the installed build may be newer than
                // anything a source offers, so nothing is fetched again on
                // restore. apt's own copy first, a repack when it is gone.
                let fileName = [
                    package.package,
                    BackupManager.safeName(package.version),
                    BackupManager.safeName(package.architecture ?? "all")
                ].joined(separator: "_") + ".deb"
                let destination = directory.appendingPathComponent(fileName)

                if BackupManager.copyCachedPackage(package: package, to: destination) {
                    entry.deb = fileName
                    entries.append(entry)
                    report(1)
                    continue
                }

                do {
                    _ = try PackageRepacker.repack(package: package, to: destination) { phase in
                        report(phase)
                    }
                    entry.deb = fileName
                    entries.append(entry)
                } catch {
                    failures.append("\(package.name) (\(package.package)): \(error.localizedDescription)")
                    NSLog("SileoLog: backup failed \(package.package): \(error)")
                    try? fileManager.removeItem(at: destination)
                }
            }

            if self.isCancelled {
                self.discard(folder)
                DispatchQueue.main.async { completion(.failure(BackupError.cancelled)) }
                return
            }

            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(entries).write(to: manifestURL, options: .atomic)
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            if !failures.isEmpty {
                let report = failures.joined(separator: "\n") + "\n"
                try? report.write(
                    to: folder.url.appendingPathComponent("失败记录.txt"),
                    atomically: true,
                    encoding: .utf8
                )
            }

            DispatchQueue.main.async {
                progress(1, "", "")
                completion(.success((entries.count, failures)))
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
        beginOperation()
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
                if self.isCancelled {
                    DispatchQueue.main.async { completion(.failure(BackupError.cancelled)) }
                    return
                }
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
                if self.isCancelled {
                    completion(.failure(BackupError.cancelled))
                    return
                }
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

    private static func package(in repo: Repo, identifier: String, version: String) -> Package? {
        repo.packageArray.first { $0.package == identifier && $0.version == version }
    }

    private static func package(offering identifier: String, version: String) -> Package? {
        for repo in RepoManager.shared.repoList {
            if let package = package(in: repo, identifier: identifier, version: version) {
                return package
            }
        }
        return nil
    }

    /// The package to install for a manifest entry: the exact version from the
    /// recorded source, then the same version from any other source, then the
    /// kept .deb, and only when none of those exist, whatever source is newest.
    private static func resolve(entry: ManifestEntry, in folder: BackupFolder) -> Package? {
        if let repoURL = entry.repo,
           let repo = RepoManager.shared.repoList.first(where: { $0.rawURL == repoURL }),
           let package = package(in: repo, identifier: entry.package, version: entry.version) {
            return package
        }
        if !entry.version.isEmpty,
           let package = package(offering: entry.package, version: entry.version) {
            return package
        }
        if let deb = entry.deb {
            let url = folder.packagesURL.appendingPathComponent(deb)
            if let package = PackageListManager.shared.package(url: url) {
                return package
            }
        }
        if let package = PackageListManager.shared.newestPackage(identifier: entry.package),
           package.sourceRepo != nil {
            return package
        }
        return nil
    }

    // MARK: - Configuration

    func backupConfiguration(
        to folder: BackupFolder,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        beginOperation()
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            do {
                try fileManager.createDirectory(at: folder.configurationURL, withIntermediateDirectories: true)
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            // Roothide preferences live inside its bootstrap; rootless preferences
            // remain in the system mobile home.
            let libraryParent = CommandPath.configurationHome
            let archive = folder.configurationURL.appendingPathComponent("Library.tar")
            try? fileManager.removeItem(at: archive)
            let (status, _, errorOutput) = spawnAsRoot(args: [
                PackageRepacker.tarPath, "-cf", rootfs(archive.path),
                "-C", rootfs(libraryParent),
                "--exclude=Library/Caches",
                "--exclude=Library/Filza",
                "Library"
            ])
            guard status == 0 else {
                DispatchQueue.main.async {
                    completion(.failure(BackupError.failed(errorOutput.isEmpty ? "tar exited with \(status)" : errorOutput)))
                }
                return
            }
            if self.isCancelled {
                self.discard(folder)
                DispatchQueue.main.async { completion(.failure(BackupError.cancelled)) }
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
        beginOperation()
        DispatchQueue.global(qos: .userInitiated).async {
            let archive = folder.configurationURL.appendingPathComponent("Library.tar")
            guard FileManager.default.fileExists(atPath: archive.path) else {
                DispatchQueue.main.async { completion(.failure(BackupError.nothingToRestore)) }
                return
            }
            let libraryParent = CommandPath.configurationHome
            guard !self.isCancelled else {
                DispatchQueue.main.async { completion(.failure(BackupError.cancelled)) }
                return
            }
            let (status, _, errorOutput) = spawnAsRoot(args: [
                PackageRepacker.tarPath, "-xpf", rootfs(archive.path),
                "-C", rootfs(libraryParent)
            ])
            guard status == 0 else {
                DispatchQueue.main.async {
                    completion(.failure(BackupError.failed(errorOutput.isEmpty ? "tar exited with \(status)" : errorOutput)))
                }
                return
            }
            spawnAsRoot(args: [CommandPath.chown, "-R", "501:501", rootfs("\(libraryParent)/Library")])
            DispatchQueue.main.async { completion(.success(())) }
        }
    }

    // MARK: - Sources

    /// `/etc/apt` inside the bootstrap, packed as one tar: sources lists, keys
    /// and preferences.
    func backupSources(
        to folder: BackupFolder,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        beginOperation()
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            do {
                try fileManager.createDirectory(at: folder.sourcesURL, withIntermediateDirectories: true)
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            let archive = folder.sourcesURL.appendingPathComponent("apt.tar")
            try? fileManager.removeItem(at: archive)
            let etc = "\(CommandPath.prefix)/etc"
            let (status, _, errorOutput) = spawnAsRoot(args: [
                PackageRepacker.tarPath, "-cf", rootfs(archive.path),
                "-C", rootfs(etc),
                "apt"
            ])
            guard status == 0 else {
                DispatchQueue.main.async {
                    completion(.failure(BackupError.failed(errorOutput.isEmpty ? "tar exited with \(status)" : errorOutput)))
                }
                return
            }
            if self.isCancelled {
                self.discard(folder)
                DispatchQueue.main.async { completion(.failure(BackupError.cancelled)) }
                return
            }
            spawnAsRoot(args: [CommandPath.chown, "501:501", rootfs(archive.path)])
            DispatchQueue.main.async { completion(.success(())) }
        }
    }

    func restoreSources(
        from folder: BackupFolder,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        beginOperation()
        DispatchQueue.global(qos: .userInitiated).async {
            let archive = folder.sourcesURL.appendingPathComponent("apt.tar")
            guard FileManager.default.fileExists(atPath: archive.path) else {
                DispatchQueue.main.async { completion(.failure(BackupError.nothingToRestore)) }
                return
            }
            let etc = "\(CommandPath.prefix)/etc"
            guard !self.isCancelled else {
                DispatchQueue.main.async { completion(.failure(BackupError.cancelled)) }
                return
            }
            let (status, _, errorOutput) = spawnAsRoot(args: [
                PackageRepacker.tarPath, "-xpf", rootfs(archive.path),
                "-C", rootfs(etc)
            ])
            guard status == 0 else {
                DispatchQueue.main.async {
                    completion(.failure(BackupError.failed(errorOutput.isEmpty ? "tar exited with \(status)" : errorOutput)))
                }
                return
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: PackageListManager.reloadNotification, object: nil)
                completion(.success(()))
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
