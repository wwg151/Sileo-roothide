//
//  BackupManager.swift
//  Sileo
//
//  Backs up installed third-party packages and the device's tweak
//  configuration into /var/mobile/Documents, and restores them through
//  Sileo's install queue.
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
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            var done = 0
            var failed = 0
            let total = Double(packages.count)
            for (index, package) in packages.enumerated() {
                let detail = "\(index + 1)/\(packages.count)"
                DispatchQueue.main.async {
                    progress(Double(index) / total, package.name, detail)
                }
                let fileName = [
                    package.package,
                    BackupManager.safeName(package.version),
                    BackupManager.safeName(package.architecture ?? "all")
                ].joined(separator: "_") + ".deb"
                let destination = directory.appendingPathComponent(fileName)
                do {
                    _ = try PackageRepacker.repack(package: package, to: destination)
                    done += 1
                } catch {
                    failed += 1
                    NSLog("SileoLog: backup failed \(package.package): \(error)")
                    try? fileManager.removeItem(at: destination)
                }
            }
            DispatchQueue.main.async {
                progress(1, "", "")
                completion(.success((done, failed)))
            }
        }
    }

    func restorePackages(
        from folder: BackupFolder,
        progress: @escaping ProgressHandler,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            PackageListManager.shared.initWait()
            let fileManager = FileManager.default
            let contents = (try? fileManager.contentsOfDirectory(
                at: folder.packagesURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            let debs = contents
                .filter { $0.pathExtension.lowercased() == "deb" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard !debs.isEmpty else {
                DispatchQueue.main.async { completion(.failure(BackupError.nothingToRestore)) }
                return
            }

            var packages: [Package] = []
            let total = Double(debs.count)
            for (index, url) in debs.enumerated() {
                DispatchQueue.main.async {
                    progress(Double(index) / total, url.lastPathComponent, "\(index + 1)/\(debs.count)")
                }
                if let package = PackageListManager.shared.package(url: url) {
                    packages.append(package)
                }
            }

            DispatchQueue.main.async {
                progress(1, "", "")
                guard !packages.isEmpty else {
                    completion(.failure(BackupError.nothingToRestore))
                    return
                }
                let manager = DownloadManager.shared
                for package in packages {
                    manager.add(package: package, queue: .installations)
                }
                if !manager.queueRunning {
                    manager.reloadData(recheckPackages: true)
                }
                NotificationCenter.default.post(name: PackageQueueButton.actionPerformedNotification, object: nil)
                completion(.success(packages.count))
            }
        }
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
