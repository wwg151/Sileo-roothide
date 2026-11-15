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

// A conservative restore planner, not an apt repair loop. Only explicit,
// acyclic dependencies are scheduled; dpkg remains the final authority.
final class BackupRestoreBatch {
    var preparing = true
    var ownsTaskPresentation = true
    var taskSession: BackupTaskSession?
    var packages: [Package] = []
    var results: [String: String] = [:] {
        didSet {
            for (id, reason) in results {
                taskSession?.update(id, fraction: 0, detail: reason, outcome: false)
            }
        }
    }
    private(set) var succeeded = Set<String>()
    private var roots = Set<String>()
    private var selected: [String: Package] = [:]

    struct Relation {
        let name: String
        let op: String
        let version: String

        static func parse(_ text: String) -> Relation? {
            let pattern = #"^\s*([a-z0-9][a-z0-9+.-]*)(?:\s*\(\s*(<<|<=|=|>=|>>)\s*([^\s()]+)\s*\))?\s*$"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            func field(_ index: Int) -> String {
                guard let range = Range(match.range(at: index), in: text) else { return "" }
                return String(text[range])
            }
            return Relation(name: field(1), op: field(2), version: field(3))
        }

        func accepts(_ value: String) -> Bool {
            if op.isEmpty { return true }
            // compareVersion returns zero on parse errors; reject malformed
            // versions before asking it to compare an equality constraint.
            let syntax = #"^(?:[0-9]+:)?[0-9][A-Za-z0-9.+:~\-]*$"#
            guard value.range(of: syntax, options: .regularExpression) != nil,
                  version.range(of: syntax, options: .regularExpression) != nil else { return false }
            let comparison = compareVersion(value, Int32(value.utf8.count + 1), version, Int32(version.utf8.count + 1))
            switch op {
            case "=": return comparison == 0
            case ">=": return comparison >= 0
            case "<=": return comparison <= 0
            case ">>": return comparison > 0
            case "<<": return comparison < 0
            default: return false
            }
        }

        func matches(_ package: Package) -> Bool {
            if package.package == name { return accepts(package.version) }
            return (package.rawControl["provides"] ?? "").components(separatedBy: ",").contains {
                guard let provided = Relation.parse($0), provided.name == name else { return false }
                return op.isEmpty || (provided.op == "=" && accepts(provided.version))
            }
        }
    }

    static func groups(_ package: Package) -> [[Relation]]? {
        var groups: [[Relation]] = []
        for key in ["pre-depends", "depends"] {
            guard let text = package.rawControl[key], !text.isEmpty else { continue }
            for clause in text.components(separatedBy: ",") {
                let alternatives = clause.components(separatedBy: "|")
                let parsed = alternatives.compactMap { Relation.parse($0) }
                guard parsed.count == alternatives.count else { return nil }
                groups.append(parsed)
            }
        }
        return groups
    }

    static func archivePackage(at url: URL) -> Package? {
        guard let text = try? DpkgWrapper.rawFields(packageURL: url),
              let fields = try? ControlFileParser.dictionary(controlFile: text, isReleaseFile: true),
              let package = PackageListManager.package(packageEnum: fields) else { return nil }
        package.local_deb = url.path
        return package
    }

    static var hasPendingTriggers: Bool {
        PackageListManager.shared.installedPackages.values.contains {
            $0.status == .triggerspending || $0.status == .triggersawaited
                || !(($0.rawControl["triggers-pending"] ?? "").isEmpty)
                || !(($0.rawControl["triggers-awaited"] ?? "").isEmpty)
        }
    }

    static func healthy(_ package: Package) -> Bool {
        package.status == .installed && package.eFlag == .ok
    }

    var removedIDs = Set<String>()

    func prepare(roots: [Package], local: [Package], excluding: Set<String> = []) {
        // Resolution failures recorded before planning are requested packages too.
        self.roots = Set(roots.map { $0.package }).union(results.keys)
        var universe = roots + local
        for repo in RepoManager.shared.repoList {
            universe.append(contentsOf: repo.packageArray.flatMap { $0.allVersions() })
        }
        let installed = Array(PackageListManager.shared.installedPackages.values).filter { Self.healthy($0) && !excluding.contains($0.package) }
        var visiting = Set<String>()
        var missingReason: String?
        var removedDependencyReason: String?
        func visit(_ package: Package) -> Bool {
            if let existing = selected[package.package] { return existing.version == package.version }
            guard !removedIDs.contains(package.package), !excluding.contains(package.package), !visiting.contains(package.package),
                  checkRootHide(package) || DownloadManager.needsConversion(package),
                  package.essential != "yes", !package.commercial,
                  PackageListManager.shared.installedPackages[package.package]?.wantInfo != .hold,
                  !["conflicts", "breaks", "replaces"].contains(where: { !(package.rawControl[$0] ?? "").isEmpty }),
                  // Changing an installed provider's version needs a full reverse-
                  // dependency solver; skip it rather than break unrelated packages.
                  !installed.contains(where: { $0.package == package.package && $0.version != package.version }),
                  let groups = Self.groups(package) else { return false }
            visiting.insert(package.package)
            defer { visiting.remove(package.package) }
            for alternatives in groups {
                if installed.contains(where: { item in alternatives.contains { $0.matches(item) } }) { continue }
                var found = false
                for relation in alternatives {
                    for candidate in universe where relation.matches(candidate) {
                        // Roll back speculative choices when an alternative cannot be planned.
                        let saved = selected
                        if visit(candidate) { found = true; break }
                        selected = saved
                    }
                    if found { break }
                }
                if !found {
                    let clause = alternatives.map { $0.name + ($0.op.isEmpty ? "" : " (\($0.op) \($0.version))") }.joined(separator: " | ")
                    let removedCandidates = Set(universe.filter { candidate in
                        removedIDs.contains(candidate.package) && alternatives.contains { $0.matches(candidate) }
                    }.map { $0.package })
                    missingReason = removedCandidates.isEmpty
                        ? String(format: String(localizationKey: "Backup_Task_Dependency_Unavailable"), clause)
                        : String(format: String(localizationKey: "Backup_Task_Dependency_Removed"), clause, removedCandidates.sorted().joined(separator: ", "))
                    if !removedCandidates.isEmpty { removedDependencyReason = missingReason }
                    return false
                }
            }
            selected[package.package] = package
            return true
        }
        for root in roots.sorted(by: { $0.package < $1.package }) {
            missingReason = nil
            removedDependencyReason = nil
            let saved = selected
            if !visit(root) {
                selected = saved
                results[root.package] = removedDependencyReason ?? missingReason ?? String(localizationKey: "Restore_Isolation_Unsupported")
            }
        }
        packages = selected.values.sorted { $0.package < $1.package }
        preparing = false
    }

    var summary: String {
        let failed = Set(results.keys)
        func section(_ key: String, _ identifiers: Set<String>, failures: Bool) -> String {
            let header = String(format: String(localizationKey: key), identifiers.count)
            let lines = identifiers.sorted().map { identifier in
                failures ? "\(identifier): \(results[identifier] ?? "")" : identifier
            }
            return ([header] + lines).joined(separator: "\n")
        }
        return [
            String(localizationKey: "Restore_Isolation_Summary"),
            section("Restore_Isolation_Targets_Succeeded", roots.intersection(succeeded), failures: false),
            section("Restore_Isolation_Targets_Failed", roots.intersection(failed), failures: true),
            section("Restore_Isolation_Dependencies_Succeeded", succeeded.subtracting(roots), failures: false),
            section("Restore_Isolation_Dependencies_Failed", failed.subtracting(roots), failures: true)
        ].joined(separator: "\n\n")
    }

    // Runs one dependency-ready download/verification/install cycle at a time.
    func perform(progress: @escaping (Double, Bool, String, String) -> Void,
                 output: @escaping (String, Int) -> Void,
                 completion: @escaping (Int, APTWrapper.FINISH, Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let manager = DownloadManager.shared
            var pending = (manager.vars.installations.raw.union(manager.vars.upgrades.raw)
                .union(manager.vars.installdeps.raw)).map { $0.package }.sorted { $0.package < $1.package }
            var finish = APTWrapper.FINISH.back
            var refresh = false
            var changedApps = Set<String>()
            var stopped: String?
            let total = max(1, pending.count)
            var completed = 0
            PackageListManager.shared.reloadInstalled()
            if DpkgWrapper.dpkgInterrupted() || Self.hasPendingTriggers {
                stopped = String(localizationKey: "Restore_Isolation_Global")
            }
            while !pending.isEmpty && stopped == nil {
                PackageListManager.shared.reloadInstalled()
                if Self.hasPendingTriggers || DpkgWrapper.dpkgInterrupted() {
                    stopped = String(localizationKey: "Restore_Isolation_Global")
                    break
                }
                if BackupManager.shared.isCancelled {
                    stopped = String(localizationKey: "Restore_Isolation_Cancelled")
                    break
                }
                let installed = Array(PackageListManager.shared.installedPackages.values).filter {
                    Self.healthy($0) && self.results[$0.package] == nil
                }
                // Remove failed downloads first; dependency consumers wait until their
                // alternatives have either succeeded or become unavailable.
                if let index = pending.firstIndex(where: {
                    !(manager.queuedDownload(package: $0.package)?.failureReason ?? "").isEmpty
                }) {
                    let package = pending.remove(at: index)
                    self.results[package.package] = manager.queuedDownload(package: package.package)?.failureReason
                    completed += 1
                    continue
                }
                guard let index = pending.firstIndex(where: { package in
                    guard let groups = Self.groups(package) else { return false }
                    return groups.allSatisfy { group in
                        installed.contains { item in
                            group.contains { $0.matches(item) }
                                && !pending.contains { $0.package == item.package && $0.package != package.package }
                        }
                    }
                }) else {
                    // Re-resolve against current installed state and configured
                    // sources: a dependency may have vanished since preparation.
                    let replanned = BackupRestoreBatch()
                    replanned.removedIDs = self.removedIDs
                    replanned.prepare(roots: pending, local: self.packages, excluding: Set(self.results.keys))
                    let known = Set(pending.map { $0.package }).union(self.results.keys).union(self.succeeded)
                    let additions = replanned.packages.filter { !known.contains($0.package) }
                    if !additions.isEmpty {
                        self.packages.append(contentsOf: additions)
                        pending.append(contentsOf: additions)
                        self.taskSession?.register(additions.map { ($0.package, $0.name ?? $0.package) })
                        DispatchQueue.main.async { self.taskSession?.activeIDs.formUnion(additions.map { $0.package }) }
                        DownloadManager.aptQueue.sync {
                            manager.vars.installations.setTo(manager.vars.installations.raw.union(Set(additions.map { DownloadPackage(package: $0) })))
                        }
                        continue
                    }
                    for package in pending {
                        self.results[package.package] = replanned.results[package.package] ?? String(localizationKey: "Restore_Isolation_Dependency")
                            + " " + [package.rawControl["pre-depends"], package.rawControl["depends"]].compactMap { $0 }.joined(separator: ", ")
                    }
                    pending.removeAll()
                    break
                }
                let package = pending.remove(at: index)
                completed += 1
                if let current = installed.first(where: { $0.package == package.package }), current.version != package.version {
                    self.results[package.package] = String(localizationKey: "Restore_Isolation_Unsupported")
                    continue
                }
                // These relations can modify an installed provider or another root.
                // A restoration never removes or replaces other packages implicitly.
                if !checkRootHide(package) || ["conflicts", "breaks", "replaces"].contains(where: {
                    !(package.rawControl[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }) {
                    self.results[package.package] = String(localizationKey: "Restore_Isolation_Unsupported")
                    continue
                }
                guard let download = manager.prepareRestoreDownload(package) else {
                    self.results[package.package] = String(localizationKey: "Restore_Isolation_Cancelled")
                    stopped = String(localizationKey: "Restore_Isolation_Cancelled")
                    break
                }
                guard download.success else {
                    self.results[package.package] = download.failureReason ?? String(localizationKey: "Restore_Isolation_Unavailable")
                    continue
                }
                guard let archive = manager.restoreArchive(for: package),
                      let actual = Self.archivePackage(at: URL(fileURLWithPath: archive)),
                      actual.package == package.package, actual.version == package.version,
                      actual.architecture == package.architecture,
                      actual.rawControl["depends"] == package.rawControl["depends"],
                      actual.rawControl["pre-depends"] == package.rawControl["pre-depends"],
                      actual.rawControl["provides"] == package.rawControl["provides"],
                      actual.essential != "yes",
                      !["conflicts", "breaks", "replaces"].contains(where: { !(actual.rawControl[$0] ?? "").isEmpty }) else {
                    self.results[package.package] = String(localizationKey: "Restore_Isolation_Unavailable")
                    continue
                }
                if UserDefaults.standard.bool(forKey: "AutoSavePackages") {
                    let saved = DispatchSemaphore(value: 0)
                    manager.checkSavedPackages([package], progress: { output($0 + "\n", APTWrapper.debugFD) }, completion: { saved.signal() })
                    saved.wait()
                }
                if BackupManager.shared.isCancelled {
                    self.results[package.package] = String(localizationKey: "Restore_Isolation_Cancelled")
                    stopped = String(localizationKey: "Restore_Isolation_Cancelled")
                    break
                }
                self.taskSession?.update(package.package, fraction: 0.55, detail: String(localizationKey: "Restore_Isolation_Installing"))
                progress(Double(completed - 1) / Double(total) * 100, true,
                         String(localizationKey: "Restore_Isolation_Installing"), package.package)
                let wait = DispatchSemaphore(value: 0)
                let logLock = NSLock()
                var diagnostics = ""
                var exitStatus = -1
                APTWrapper.performOperations(installs: [DownloadPackage(package: package)], removals: [], installDeps: [],
                    progressCallback: { _, valid, stage, _ in
                        guard valid else { return }
                        let fraction: Double
                        if stage.hasPrefix("Configuring") || stage.hasPrefix("Setting up") { fraction = 0.85 }
                        else if stage.hasPrefix("Unpacking") { fraction = 0.7 }
                        else { fraction = 0.55 }
                        self.taskSession?.update(package.package, fraction: fraction, detail: APTLogTranslator.localize(stage))
                    }, outputCallback: { text, pipe in
                        logLock.lock(); diagnostics += text; logLock.unlock()
                        output(text, pipe)
                    }, completionCallback: { status, requestedFinish, needsRefresh in
                        exitStatus = status
                        if requestedFinish.rawValue > finish.rawValue { finish = requestedFinish }
                        refresh = refresh || needsRefresh
                        wait.signal()
                    }, restoreArchive: archive, restoreIconChanges: { changedApps.formUnion($0) })
                wait.wait()
                PackageListManager.shared.reloadInstalled()
                if Self.hasPendingTriggers {
                    stopped = String(localizationKey: "Restore_Isolation_Global")
                }
                let state = PackageListManager.shared.installedPackages[package.package]
                if exitStatus == 0, let state = state, Self.healthy(state), state.version == package.version {
                    self.succeeded.insert(package.package)
                    self.taskSession?.update(package.package, fraction: 1, detail: String(localizationKey: "Done"), outcome: true)
                    InstalledSourceStore.record(package)
                } else {
                    self.results[package.package] = String(localizationKey: "Restore_Isolation_Failed")
                    // Only dpkg's documented package processing exit (1), with a
                    // positively identified maintainer-script failure, is local.
                    // Unknown errors are global, never guessed from stderr alone.
                    let scriptFailure = diagnostics.contains("subprocess returned error exit status")
                        && diagnostics.contains(package.package)
                    let globalError = ["No space left", "Read-only file system", "Input/output error",
                        "lock", "database", "unable to access", "failed to write"].contains { diagnostics.contains($0) }
                    if exitStatus != 256 || !scriptFailure || globalError || DpkgWrapper.dpkgInterrupted() {
                        stopped = String(localizationKey: "Restore_Isolation_Global")
                    }
                }
            }
            // Refresh other applications independently of FINISH, so a restart
            // request cannot discard their icon-cache updates. Refreshing Sileo
            // itself may terminate this process; keep that in the existing finish flow.
            let otherApps = changedApps.subtracting([Bundle.main.bundleURL.lastPathComponent])
            if !otherApps.isEmpty {
                output(String(localizationKey: "Updating_Icon_Cache") + "\n", APTWrapper.debugFD)
                for app in otherApps.sorted() {
                    let result = spawnAsRoot(args: [jbroot("/usr/bin/uicache"), "-p",
                        rootfs(URL(fileURLWithPath: jbroot("/Applications")).appendingPathComponent(app).path)])
                    if result.0 != 0 {
                        stopped = String(localizationKey: "Restore_Isolation_Global")
                        output(result.2 + "\n", Int(STDERR_FILENO))
                    }
                }
            }
            if let reason = stopped {
                for package in pending { self.results[package.package] = reason }
                output(reason + "\n", Int(STDERR_FILENO))
            }
            output(self.summary + "\n", APTWrapper.debugFD)
            completion(self.results.isEmpty && stopped == nil ? 0 : 1, finish, refresh)
        }
    }
}

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
        taskSession: BackupTaskSession? = nil,
        completion: @escaping (Result<(Int, [String]), Error>) -> Void
    ) {
        guard !packages.isEmpty else {
            completion(.failure(BackupError.noPackages))
            return
        }
        let directory = folder.packagesURL
        taskSession?.register(packages.map { ($0.package, $0.name ?? $0.package) })
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
            let previousEntries: [ManifestEntry]
            do {
                if fileManager.fileExists(atPath: manifestURL.path) {
                    previousEntries = try JSONDecoder().decode([ManifestEntry].self, from: Data(contentsOf: manifestURL))
                } else { previousEntries = [] }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            var failures: [String] = []
            let total = Double(packages.count)

            for (index, package) in packages.enumerated() {
                if self.isCancelled { break }
                let detail = "\(index + 1)/\(packages.count)"
                func report(_ phase: Double) {
                    taskSession?.update(package.package, fraction: phase, detail: String(localizationKey: "Backup_Task_Archiving"))
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
                    taskSession?.update(package.package, fraction: 0.99, detail: String(localizationKey: "Backup_Task_Processing"))
                    report(1)
                    continue
                }

                do {
                    _ = try PackageRepacker.repack(package: package, to: destination) { phase in
                        report(phase)
                    }
                    entry.deb = fileName
                    entries.append(entry)
                    taskSession?.update(package.package, fraction: 0.99, detail: String(localizationKey: "Backup_Task_Processing"))
                } catch {
                    taskSession?.update(package.package, fraction: 0, detail: error.localizedDescription, outcome: false)
                    failures.append("\(package.name) (\(package.package)): \(error.localizedDescription)")
                    NSLog("SileoLog: backup failed \(package.package): \(error)")
                    try? fileManager.removeItem(at: destination)
                }
            }

            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let updatedIDs = Set(entries.map { $0.package })
                let merged = previousEntries.filter { !updatedIDs.contains($0.package) } + entries
                try encoder.encode(merged).write(to: manifestURL, options: .atomic)
            } catch {
                for entry in entries {
                    taskSession?.update(entry.package, fraction: 0.99, detail: error.localizedDescription, outcome: false)
                }
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            for entry in entries {
                taskSession?.update(entry.package, fraction: 1, detail: String(localizationKey: "Done"), outcome: true)
            }
            if self.isCancelled {
                DispatchQueue.main.async { completion(.failure(BackupError.cancelled)) }
                return
            }

            if !failures.isEmpty {
                let reportURL = folder.url.appendingPathComponent("失败记录.txt")
                let report = ((try? String(contentsOf: reportURL, encoding: .utf8)) ?? "") + failures.joined(separator: "\n") + "\n"
                try? report.write(
                    to: reportURL,
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
        taskSession: BackupTaskSession? = nil,
        preview: ((BackupRestoreBatch) -> Void)? = nil,
        selectedID: String? = nil,
        selectedPackage: Package? = nil,
        completion: @escaping (Result<(Int, Int), Error>) -> Void
    ) {
        let manager = DownloadManager.shared
        guard !manager.queueRunning, !manager.aptRunning, manager.operationCount() == 0,
              manager.restoreBatch == nil else {
            completion(.failure(BackupError.failed(String(localizationKey: "Restore_Isolation_Busy"))))
            return
        }
        let batch = BackupRestoreBatch()
        let waitingIDs = taskSession.map { Set($0.tasks.filter { $0.outcome == nil }.map { $0.id }) }
        batch.taskSession = taskSession
        batch.removedIDs = taskSession?.removedIDs ?? []
        guard taskSession?.closed != true else { completion(.failure(BackupError.cancelled)); return }
        if preview == nil { manager.restoreBatch = batch; beginOperation() }
        DispatchQueue.global(qos: .userInitiated).async {
            PackageListManager.shared.initWait()
            let entries = BackupManager.manifestEntries(in: folder)
            taskSession?.register(entries.map { ($0.package, $0.name) })
            guard !entries.isEmpty else {
                DispatchQueue.main.async {
                    if preview == nil { manager.restoreBatch = nil }
                    completion(.failure(BackupError.nothingToRestore))
                }
                return
            }

            var queued: [Package] = []
            let total = Double(entries.count)

            for (index, entry) in entries.enumerated() {
                if preview == nil && (waitingIDs?.contains(entry.package) == false || (selectedID != nil && selectedID != entry.package)) { continue }
                if preview == nil && self.isCancelled {
                    DispatchQueue.main.async {
                        manager.restoreBatch = nil
                        completion(.failure(BackupError.cancelled))
                    }
                    return
                }
                DispatchQueue.main.async {
                    progress(Double(index) / total, entry.name, "\(index + 1)/\(entries.count)")
                }
                if let package = BackupManager.resolve(entry: entry, in: folder) {
                    queued.append(package)
                } else {
                    batch.results[entry.package] = String(localizationKey: "Restore_Isolation_Unavailable")
                    NSLog("SileoLog: restore skipped \(entry.package) \(entry.version)")
                }
            }

            // Include every local archive in the dependency universe, even if
            // it is not a manifest root. No reliance on localPackages' last value.
            let archives = (try? FileManager.default.contentsOfDirectory(at: folder.packagesURL,
                includingPropertiesForKeys: nil)) ?? []
            let locals = archives.filter { $0.pathExtension.lowercased() == "deb" }
                .compactMap { BackupRestoreBatch.archivePackage(at: $0) }
            var requested = queued.filter { preview != nil || waitingIDs?.contains($0.package) != false }
            if preview == nil { batch.results = batch.results.filter { waitingIDs?.contains($0.key) != false } }
            if let selectedID = selectedID {
                if let selectedPackage = selectedPackage, selectedPackage.package == selectedID {
                    requested = [selectedPackage]
                } else {
                    requested = Array(queued.filter { $0.package == selectedID }.prefix(1))
                }
                batch.results = batch.results.filter { $0.key == selectedID }
                if requested.isEmpty { batch.results[selectedID] = String(localizationKey: "Restore_Isolation_Unavailable") }
            }
            batch.prepare(roots: requested, local: locals)
            taskSession?.register(batch.packages.map { ($0.package, $0.name ?? $0.package) })
            if preview == nil {
                DispatchQueue.main.async { taskSession?.activeIDs.formUnion(batch.packages.map { $0.package }) }
            }
            taskSession?.order(batch.packages.map { $0.package })
            for (id, reason) in batch.results { taskSession?.update(id, fraction: 0, detail: reason, outcome: false) }
            DispatchQueue.main.async {
                if taskSession?.closed == true {
                    if preview == nil && manager.restoreBatch === batch { manager.restoreBatch = nil }
                    return
                }
                progress(1, "", "")
                if let preview = preview { preview(batch); return }
                if self.isCancelled {
                    manager.restoreBatch = nil
                    completion(.failure(BackupError.cancelled))
                    return
                }
                guard !batch.packages.isEmpty else {
                    manager.restoreBatch = nil
                    completion(.failure(BackupError.failed(batch.summary)))
                    return
                }
                guard manager.restoreBatch === batch else {
                    completion(.failure(BackupError.cancelled))
                    return
                }
                manager.vars.errors.removeAll()
                manager.vars.installations.setTo(Set(batch.packages.map { DownloadPackage(package: $0) }))
                manager.reloadData(recheckPackages: true)
                NotificationCenter.default.post(name: PackageQueueButton.actionPerformedNotification, object: nil)
                completion(.success((batch.packages.count, batch.results.count)))
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
            if let package = BackupRestoreBatch.archivePackage(at: url) {
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
