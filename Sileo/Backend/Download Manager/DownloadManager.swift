//
//  DownloadManager.swift
//  Sileo
//
//  Created by CoolStar on 8/2/19.
//  Copyright © 2022 Sileo Team. All rights reserved.
//

import Foundation
import Evander

public enum DownloadManagerQueue: Int {
    case upgrades
    case installations
    case uninstallations
    case installdeps
    case uninstalldeps
    case none
}

final class DownloadManager {
    public static let lockStateChangeNotification = Notification.Name("SileoDownloadManagerLockStateChanged")
    
    private static let aptQueueContext = 50
    private static let aptQueueKey = DispatchSpecificKey<Int>()
    public static let aptQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "Sileo.AptQueue", qos: .userInteractive)
        queue.setSpecific(key: aptQueueKey, value: aptQueueContext)
        return queue
    }()
    
    enum Error: LocalizedError {
        case hashMismatch(packageHash: String, refHash: String)
        case untrustedPackage(packageID: String)
        case debugNotAllowed
        
        public var errorDescription: String? {
            switch self {
            case let .hashMismatch(packageHash, refHash):
                return String(format: String(localizationKey: "Download_Hash_Mismatch", type: .error), packageHash, refHash)
            case let .untrustedPackage(packageID):
                return String(format: String(localizationKey: "Untrusted_Package", type: .error), packageID)
            case .debugNotAllowed:
                return String(localizationKey: "Queue_Locked_During_Install", type: .error)
            }
        }
    }
    
    enum PackageHashType: String, CaseIterable {
        case sha256
        case sha512
        
        var hashType: HashType {
            switch self {
            case .sha256: return .sha256
            case .sha512: return .sha512
            }
        }
    }
    
    public static let shared = DownloadManager()
    
    public var aptRunning = false
    public var aptFinished = false
    public var queueRunning = false
    // Reserved by backup restore until the user clears the completed batch.
    var restoreBatch: BackupRestoreBatch?
    var backupTaskPanel: BackupProgressAlert?
    public var totalProgress = CGFloat(0)
    
//    private static let dataQueueContext = 50
//    private static let dataQueueKey = DispatchSpecificKey<Int>()
//    private static let dataQueue: DispatchQueue = {
//        let queue = DispatchQueue(label: "Sileo.dataQueue", qos: .userInitiated)
//        queue.setSpecific(key: dataQueueKey, value: dataQueueContext)
//        return queue
//    }()
        private static let dataQueueContext = aptQueueContext
        private static let dataQueueKey = aptQueueKey
        private static let dataQueue = aptQueue
    
    struct TSyncVars {
        public var upgrades = SafeSet<DownloadPackage>(queue: dataQueue, key: dataQueueKey, context: dataQueueContext)
        public var installations = SafeSet<DownloadPackage>(queue: dataQueue, key: dataQueueKey, context: dataQueueContext)
        public var uninstallations = SafeSet<DownloadPackage>(queue: dataQueue, key: dataQueueKey, context: dataQueueContext)
        public var installdeps = SafeSet<DownloadPackage>(queue: dataQueue, key: dataQueueKey, context: dataQueueContext)
        public var uninstalldeps = SafeSet<DownloadPackage>(queue: dataQueue, key: dataQueueKey, context: dataQueueContext)
        public var errors = SafeSet<APTBrokenPackage>(queue: dataQueue, key: dataQueueKey, context: dataQueueContext)
        
        public var queuedDownloads = SafeDictionary<String,Download>(queue: dataQueue, key: dataQueueKey, context: dataQueueContext)
        public var cachedDownloadFiles = SafeArray<URL>(queue: dataQueue, key: dataQueueKey, context: dataQueueContext)
        
        public var repoDownloadOverrideProviders = SafeDictionary<String, Set<AnyHashable>>(queue: dataQueue, key: dataQueueKey, context: dataQueueContext)
    }
    
    public var vars = TSyncVars()
    
    public lazy var viewController: DownloadsTableViewController = DownloadsTableViewController(nibName: "DownloadsTableViewController", bundle: nil)
    
    public var currentDownloads = 0
    public var maxParallelDownloads = 5
    public var currentDownloadSession:UInt32 = 0
    private(set) var downloadsCancelled = false
    
    public func installingPackages() -> Int {
        self.vars.upgrades.count + self.vars.installations.count + self.vars.installdeps.count
    }
    
    public func uninstallingPackages() -> Int {
        self.vars.uninstallations.count + self.vars.uninstalldeps.count
    }
    
    public func operationCount() -> Int {
        self.vars.upgrades.count + self.vars.installations.count + self.vars.uninstallations.count + self.vars.installdeps.count + self.vars.uninstalldeps.count
    }
        
    public func downloadingPackages() -> Int {
        var downloadsCount = 0
        for keyValue in self.vars.queuedDownloads.raw where keyValue.value.progress < 1 {
            downloadsCount += 1
        }
        return downloadsCount
    }
    
    public func readyPackages() -> Int {
        var readyCount = 0
        for keyValue in self.vars.queuedDownloads.raw {
            let download = keyValue.value
            if download.progress == 1 && download.success == true {
                readyCount += 1
            }
        }
        return readyCount
    }
    
    public func verifyComplete() -> Bool {
        let allRawDownloads = self.vars.upgrades.raw.union(self.vars.installations.raw).union(self.vars.installdeps.raw)
        if let batch = restoreBatch {
            return allRawDownloads.allSatisfy {
                guard let download = self.vars.queuedDownloads[$0.package.package] else { return false }
                return (download.success && download.progress == 1) || !(download.failureReason ?? "").isEmpty
            } && !batch.preparing
        }
        for dlPackage in allRawDownloads {
            guard let download = self.vars.queuedDownloads[dlPackage.package.package],
                  download.success else { return false }
        }
        return true
    }
    
    private func publishDownloadStatus(_ download: Download) {
        guard restoreBatch == nil else { return }
        viewController.updateDownloadStatus(download: download)
    }

    private func startPackageDownload(download: Download) {
        NSLog("SileoLog: startPackageDownload \(download.package.package)")
        
        let package = download.package
        download.session = self.currentDownloadSession
        download.phase = .preparing
        download.failedPhase = nil
        download.usedNetwork = false
        download.needsConversion = DownloadManager.needsConversion(package)
        download.failureReason = nil
        download.message = nil
        download.progress = 0
        download.totalBytesWritten = 0
        download.totalBytesExpectedToWrite = 0
        download.success = false
        download.completed = false
        download.started = false
        
        // If it's a local file we can verify it immediately
        if package.local_deb != nil {
            if self.verifyLocalPackage(package: package) {
                if DownloadManager.needsConversion(package), let localDeb = package.local_deb {
                    // Converted here, inside the queue run, instead of with a
                    // download alert when the package was queued.
                    download.phase = .converting
                    self.convertDownloaded(download: download, fileURL: URL(fileURLWithPath: localDeb))
                    return
                }
                download.progress = 1
                download.success = true
                download.completed = true
                download.phase = .ready
            } else {
                download.failureReason = String(localizationKey: "Unknown", type: .error)
                download.markFailed()
            }
            
            self.publishDownloadStatus(download)
            
            NSLog("SileoLog: startMoreDownloads (startPackageDownload) 1")
            self.currentDownloads -= 1
            self.startMoreDownloads()
            return
        }
        
        if let savedCopy = savedPackageCopy(for: package) {
            let needsConversion = DownloadManager.needsConversion(package)
            do {
                if try verifyRepoPackage(package: package, fileURL: savedCopy, moveToCache: !needsConversion) {
                    if needsConversion {
                        download.phase = .converting
                        convertDownloaded(download: download, fileURL: savedCopy)
                        return
                    }
                    download.progress = 1
                    download.success = true
                    download.completed = true
                    download.phase = .ready
                    download.message = String(localizationKey: "Auto_Save_Packages_Using_Local")
                    publishDownloadStatus(download)
                    currentDownloads -= 1
                    startMoreDownloads()
                    return
                }
            } catch {
                NSLog("SileoLog: saved archive rejected for %@: %@", package.package, error.localizedDescription)
            }
            try? FileManager.default.removeItem(at: savedCopy)
        }

        guard let filename = package.filename, let repo = package.sourceRepo, let repoURL = URL(string: repo.rawURL) else {
            
            download.failureReason = String(localizationKey: "Unknown", type: .error)
            download.markFailed()
            
            self.publishDownloadStatus(download)
            
            NSLog("SileoLog: startMoreDownloads (startPackageDownload) 2")
            self.currentDownloads -= 1
            self.startMoreDownloads()
            
            return
        }
        
        download.beginBackgroundTask()
        
        var packageURL = filename
        if !packageURL.hasPrefix("https://") && !packageURL.hasPrefix("http://") {
            packageURL = repoURL.appendingPathComponent(filename).absoluteString
        }
        
        download.started = true
        self.publishDownloadStatus(download)
        
        // See if theres an overriding web URL for downloading the package from
        self.overrideDownloadURL(package: package, repo: repo) { errorMessage, overrideURL in DownloadManager.aptQueue.async {
            guard download.session == self.currentDownloadSession, !self.downloadsCancelled else { download.endBackgroundTask(); return }
            if overrideURL == nil && errorMessage != nil {
                
                download.endBackgroundTask()
                
                download.failureReason = errorMessage
                download.markFailed()
                
                self.publishDownloadStatus(download)
                
                NSLog("SileoLog: startMoreDownloads (startPackageDownload) 3")
                self.currentDownloads -= 1
                self.startMoreDownloads()
                
                return
            }
            
            let downloadURL = overrideURL ?? URL(string: packageURL)
            
            download.task = RepoManager.shared.queue(from: downloadURL, progress: { task, progress in DownloadManager.aptQueue.async {
                NSLog("SileoLog: download progress \(task.task)")
                
                guard download.session == self.currentDownloadSession, !self.downloadsCancelled else {
                    return
                }
                
                download.message = nil
                download.progress = CGFloat(progress.fractionCompleted)
                download.totalBytesWritten = progress.total
                download.totalBytesExpectedToWrite = progress.expected
                self.restoreBatch?.taskSession?.update(package.package,
                    fraction: progress.expected > 0 ? progress.fractionCompleted * 0.5 : 0,
                    detail: String(localizationKey: "Backup_Task_Downloading") + " · \(progress.total)/\(progress.expected > 0 ? String(progress.expected) : "?") B")
                
                self.publishDownloadStatus(download)
                
            }}, success: { task, status, fileURL in DownloadManager.aptQueue.async {
                NSLog("SileoLog: download success \(task.task)")
                
                download.endBackgroundTask()
                
                guard download.session == self.currentDownloadSession, !self.downloadsCancelled else {
                    try? FileManager.default.removeItem(at: fileURL)
                    return
                }
                
                let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                let fileSize = attributes?[FileAttributeKey.size] as? Int
                let fileSizeStr = String(format: "%ld", fileSize ?? 0)
                
                download.message = nil
                if fileSizeStr != package.size {
                    download.failureReason = String(format: String(localizationKey: "Download_Size_Mismatch", type: .error),
                                                    package.size ?? "nil", fileSizeStr)
                    download.success = false
                    download.progress = 0
                    download.markFailed()
                    
                } else {
                    
                    let needsConversion = DownloadManager.needsConversion(package)
                    do {
                        download.success = try self.verifyRepoPackage(package: package, fileURL: fileURL, moveToCache: !needsConversion)
                        download.progress = 1
                        if download.success {
                            download.phase = .ready
                        } else {
                            download.markFailed()
                        }
                        if needsConversion && download.success {
                            download.phase = .converting
                            self.convertDownloaded(download: download, fileURL: fileURL)
                            return
                        }
                    } catch let error {
                        download.success = false
                        download.progress = 0
                        download.failureReason = error.localizedDescription
                        download.markFailed()
                    }
                    
#if TARGET_SANDBOX || targetEnvironment(simulator)
                    try? FileManager.default.removeItem(at: fileURL)
#endif
                }
                
                self.publishDownloadStatus(download)
                
                NSLog("SileoLog: startMoreDownloads (startPackageDownload) 4")
                self.currentDownloads -= 1
                self.startMoreDownloads()
                
            }}, failure: { task, statusCode, error in DownloadManager.aptQueue.async {
                NSLog("SileoLog: download failure \(task?.task)")
                
                download.endBackgroundTask()
                
                guard download.session == self.currentDownloadSession, !self.downloadsCancelled else {
                    return
                }
                
                download.failureReason = error?.localizedDescription ?? String(format: String(localizationKey: "Download_Failing_Status_Code", type: .error), statusCode)
                download.markFailed()
                download.message = nil
                
                self.publishDownloadStatus(download)
                
                NSLog("SileoLog: startMoreDownloads (startPackageDownload) 5")
                self.currentDownloads -= 1
                self.startMoreDownloads()
                
            }}, waiting: { task, message in DownloadManager.aptQueue.async {
                NSLog("SileoLog: download waiting \(task.task)")
                
                guard download.session == self.currentDownloadSession, !self.downloadsCancelled else {
                    return
                }
                
                download.message = message
                self.publishDownloadStatus(download)
            }})
            
            download.phase = .downloading
            download.usedNetwork = true
            download.task?.resume()
        }}
    }
    
    private static let incompatibleHosts = ["apt.procurs.us", "ellekit.space"]
    
    // A rootless/rootful package that is queued as it is and converted once it
    // has been downloaded, or when the queue runs for a local .deb
    static func needsConversion(_ package: Package) -> Bool {
        guard !checkRootHide(package),
              UserDefaults.standard.bool(forKey: compatModeKey, fallback: true),
              !incompatibleHosts.contains(package.sourceRepo?.url?.host ?? "")
        else { return false }
        return RootlessConverter.isConvertible(package: package)
    }
    
    // running in aptQueue; the download keeps its slot until the conversion has finished
    private func convertDownloaded(download: Download, fileURL: URL) {
        let package = download.package
        download.success = false
        download.phase = .converting
        download.progress = 0.99
        download.message = String(localizationKey: "Compat_Converting")
        self.publishDownloadStatus(download)
        
        DispatchQueue.global(qos: .userInitiated).async {
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).deb")
            var converted: Package?
            var failure: String?
            do {
                try RootlessConverter.convert(deb: fileURL, to: output)
                guard let newPackage = PackageListManager.shared.package(url: output), checkRootHide(newPackage) else {
                    throw RootlessConverter.Failure.step(String(localizationKey: "Compat_Convert_Failed"), "")
                }
                newPackage.origArchitecture = package.architecture
                newPackage.originalSourceFile = package.sourceFile ?? package.originalSourceFile
                converted = newPackage
            } catch {
                NSLog("SileoLog: convertDownloaded failed \(error)")
                failure = error.localizedDescription
            }
            try? FileManager.default.removeItem(at: fileURL)
            
            DownloadManager.aptQueue.async {
                self.finishConversion(download: download, original: package, converted: converted, failure: failure, output: output)
            }
        }
    }
    
    private func finishConversion(download: Download, original: Package, converted: Package?, failure: String?, output: URL) {
        guard download.session == self.currentDownloadSession, !self.downloadsCancelled else {
            try? FileManager.default.removeItem(at: output)
            return
        }
        download.message = nil
        
        func fail(_ reason: String) {
            download.failureReason = reason
            download.success = false
            download.progress = 0
            download.markFailed()
            self.publishDownloadStatus(download)
            self.currentDownloads -= 1
            self.startMoreDownloads()
        }
        
        guard let newPackage = converted, failure == nil else {
            try? FileManager.default.removeItem(at: output)
            fail(failure ?? String(localizationKey: "Compat_Convert_Failed"))
            return
        }
        guard self.verifyLocalPackage(package: newPackage) else {
            try? FileManager.default.removeItem(at: output)
            fail(String(localizationKey: "Unknown", type: .error))
            return
        }
        
        if restoreBatch != nil {
            download.package = newPackage
            download.success = true
            download.progress = 1
            download.phase = .ready
            self.currentDownloads -= 1
            return
        }

        // The converted package takes the place of the original one in the queue
        let originalEntry = DownloadPackage(package: original)
        let newEntry = DownloadPackage(package: newPackage)
        if self.vars.upgrades.contains(originalEntry) {
            self.vars.upgrades.remove(originalEntry)
            self.vars.upgrades.insert(newEntry)
        } else {
            self.vars.installations.remove(originalEntry)
            self.vars.installations.insert(newEntry)
        }
        download.package = newPackage
        
        do {
            try self.recheckTotalOps()
        } catch {
            fail(error.localizedDescription)
            DispatchQueue.main.async { self.viewController.reloadData() }
            return
        }
        
        download.success = true
        download.progress = 1
        download.phase = .ready
        DispatchQueue.main.async { self.viewController.reloadData() }
        self.publishDownloadStatus(download)
        self.currentDownloads -= 1
        self.startMoreDownloads()
    }
    
    // The restore worker calls this off-main, once per dependency-ready item.
    // Existing verification/conversion callbacks still run on aptQueue.
    func prepareRestoreDownload(_ package: Package) -> Download? {
        var download: Download!
        DownloadManager.aptQueue.sync {
            if self.currentDownloadSession == 0 {
                self.downloadsCancelled = false
                self.currentDownloadSession = max(1, arc4random())
            }
            download = Download(package: package, session: self.currentDownloadSession)
            download.queued = true
            self.vars.queuedDownloads[package.package] = download
            self.currentDownloads = 1
            self.startPackageDownload(download: download)
        }
        while true {
            var done = false
            var cancelled = false
            DownloadManager.aptQueue.sync {
                let sessionExpired = download.session != self.currentDownloadSession
                let managerCancelled = self.downloadsCancelled
                let restoreCancelled = BackupManager.shared.isCancelled
                cancelled = sessionExpired || managerCancelled || restoreCancelled
                if cancelled {
                    download.task?.cancel()
                    download.endBackgroundTask()
                    if !sessionExpired && !managerCancelled {
                        self.currentDownloadSession = 0
                        self.downloadsCancelled = true
                        download.failureReason = String(localizationKey: "Restore_Isolation_Cancelled")
                        download.markFailed()
                    }
                }
                done = download.success || !(download.failureReason ?? "").isEmpty || self.currentDownloads == 0
                if !cancelled && done && !download.success && (download.failureReason ?? "").isEmpty {
                    download.failureReason = String(localizationKey: "Restore_Isolation_Unavailable")
                    download.markFailed()
                }
            }
            if cancelled { return nil }
            if done { return download }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func startMoreDownloads() {
        guard restoreBatch == nil else { return }
        NSLog("SileoLog: startMoreDownloads")
//        Thread.callStackSymbols.forEach{NSLog("SileoLog: callstack=\($0)")}
        DownloadManager.aptQueue.async { [self] in
            guard self.currentDownloadSession != 0 else { return }
            // We don't want more than one download at a time
            guard currentDownloads <= maxParallelDownloads else { return }
            // Get a list of downloads that need to take place
            let allRawDownloads = self.vars.upgrades.raw.union(self.vars.installations.raw).union(self.vars.installdeps.raw)
            for dlPackage in allRawDownloads {
                // Get the download object, we don't want to create multiple
                let download: Download
                let package = dlPackage.package
                if let tmp = self.vars.queuedDownloads[package.package] {
                    download = tmp
                } else {
                    download = Download(package: package, session: self.currentDownloadSession)
                    self.vars.queuedDownloads[package.package] = download
                }
                
                // Means download has already started / completed
                if download.queued { continue }
                download.queued = true
                
                currentDownloads += 1
                startPackageDownload(download: download)
                
                guard currentDownloads <= maxParallelDownloads else { break }
            }
        }
    }
    
    public func startDownloads() {
        DownloadManager.aptQueue.async {
            assert(self.currentDownloadSession == 0)
            self.downloadsCancelled = false
            self.currentDownloadSession = max(1, arc4random())
            NSLog("SileoLog: startMoreDownloads (startDownloads)")
            self.startMoreDownloads()
        }
    }
    
    public func retryDownload(package: String) {
        NSLog("SileoLog: startMoreDownloads (retryDownload)")
        self.vars.queuedDownloads.removeValue(forKey: package)
        self.startMoreDownloads()
    }
 
    public func queuedDownload(package: String) -> Download? {
        self.vars.queuedDownloads[package]
    }
    
    private func aptEncoded(string: String, isArch: Bool) -> String {
        var encodedString = string.replacingOccurrences(of: "_", with: "%5f")
        encodedString = encodedString.replacingOccurrences(of: ":", with: "%3a")
        if isArch {
            encodedString = encodedString.replacingOccurrences(of: ".", with: "%2e")
        }
        return encodedString
    }
    
    func restoreArchive(for package: Package) -> String? {
        let filename = "\(aptEncoded(string: package.package, isArch: false))_\(aptEncoded(string: package.version, isArch: false))_\(aptEncoded(string: package.architecture ?? "", isArch: true)).deb"
        let path = package.local_deb ?? "\(CommandPath.prefix)/var/cache/apt/archives/\(filename)"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private func verifyLocalPackage(package: Package) -> Bool {
        let packageID = aptEncoded(string: package.package, isArch: false)
        let version = aptEncoded(string: package.version, isArch: false)
        let architecture = aptEncoded(string: package.architecture ?? "", isArch: true)
        
        let destFileName = "\(CommandPath.prefix)/var/cache/apt/archives/\(packageID)_\(version)_\(architecture).deb"
        let destURL = URL(fileURLWithPath: destFileName)
        
        guard let local_deb = package.local_deb else { return false }
        
        if restoreBatch != nil && local_deb != destFileName {
            // Backups are reusable; never move their only archive into apt's cache.
            let (status, _, _) = spawnAsRoot(args: [CommandPath.cp, rootfs(local_deb), rootfs(destFileName)])
            guard status == 0 else { return false }
        } else if local_deb != destFileName {
            moveFileAsRoot(from: URL(fileURLWithPath: local_deb), to: URL(fileURLWithPath: destFileName))
        }
        
        guard FileManager.default.fileExists(atPath: destFileName) else { return false }
        
        self.vars.cachedDownloadFiles.append(URL(fileURLWithPath: restoreBatch == nil ? local_deb : destFileName))
        package.local_deb = destFileName
        
        return true
    }
    
    /// Only consult saved exports when explicitly enabled. Validate against the
    /// selected repository, not just the filename, and never consume the export.
    private func savedPackageCopy(for package: Package) -> URL? {
        guard UserDefaults.standard.bool(forKey: "AutoSavePackages") else { return nil }
        let manager = FileManager.default
        let directory = URL(fileURLWithPath: "/var/mobile/Downloads", isDirectory: true)
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return nil }
        for file in files where file.pathExtension.lowercased() == "deb" {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let saved = PackageListManager.shared.package(url: file),
                  saved.package == package.package, saved.version == package.version,
                  saved.architecture == package.architecture else { continue }
            let copy = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".deb")
            do {
                try manager.copyItem(at: file, to: copy)
                let attributes = try manager.attributesOfItem(atPath: copy.path)
                if let expectedSize = package.size {
                    guard let size = attributes[.size] as? NSNumber, size.stringValue == expectedSize else {
                        try? manager.removeItem(at: copy)
                        continue
                    }
                }
                guard try verifyRepoPackage(package: package, fileURL: copy, moveToCache: false) else {
                    try? manager.removeItem(at: copy)
                    continue
                }
                return copy
            } catch {
                try? manager.removeItem(at: copy)
            }
        }
        return nil
    }

    // Run after all downloads/conversions finish, before starting dpkg.
    func checkSavedPackages(_ packages: [Package], progress: @escaping (String) -> Void, completion: @escaping () -> Void) {
        DownloadManager.aptQueue.async {
            let directory = URL(fileURLWithPath: "/var/mobile/Downloads", isDirectory: true)
            let existing = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            var saved = Set<String>()
            func identity(_ package: Package) -> String {
                [package.package, package.version, package.architecture ?? ""].joined(separator: "\n")
            }
            for url in existing where url.pathExtension.lowercased() == "deb" {
                if let package = PackageListManager.shared.package(url: url) { saved.insert(identity(package)) }
            }
            for package in packages {
                let key = identity(package)
                if saved.contains(key) {
                    progress(String(format: String(localizationKey: "Auto_Save_Packages_Exists"), package.name ?? package.package))
                    continue
                }
                let filename = "\(self.aptEncoded(string: package.package, isArch: false))_\(self.aptEncoded(string: package.version, isArch: false))_\(self.aptEncoded(string: package.architecture ?? "", isArch: true)).deb"
                let source = URL(fileURLWithPath: package.local_deb ?? "\(CommandPath.prefix)/var/cache/apt/archives/\(filename)")
                progress(String(format: String(localizationKey: "Auto_Save_Packages_Saving"), package.name ?? package.package))
                if self.saveDownloadedPackage(package: package, fileURL: source, progress: progress) { saved.insert(key) }
            }
            DispatchQueue.main.async { completion() }
        }
    }

    private func saveDownloadedPackage(package: Package, fileURL: URL, progress: (String) -> Void) -> Bool {
        let directory = URL(fileURLWithPath: "/var/mobile/Downloads", isDirectory: true)
        func component(_ value: String) -> String {
            // File URLs handle Unicode directly; percent escaping here becomes
            // literal %XX text in Files and can be truncated mid-escape.
            let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
            let cleaned = value.precomposedStringWithCanonicalMapping.unicodeScalars.map {
                forbidden.contains($0) ? "_" : String($0)
            }.joined()
            var result = ""
            for character in cleaned {
                let next = String(character)
                guard result.utf8.count + next.utf8.count <= 64 else { break }
                result += next
            }
            return result.isEmpty || result == "." || result == ".." ? "package" : result
        }
        let filename = [package.package, package.version, package.architecture ?? "unknown"].map(component).joined(separator: "_")
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            var destination = directory.appendingPathComponent(filename + ".deb")
            // Preserve existing exports, including same-version archives from other sources.
            if manager.fileExists(atPath: destination.path) {
                destination = directory.appendingPathComponent(filename + "_" + UUID().uuidString + ".deb")
            }
            try manager.copyItem(at: fileURL, to: destination)
            return true
        } catch {
            progress(String(localizationKey: "Auto_Save_Packages_Failed") + " " + error.localizedDescription)
            return false
        }
    }

    private func verifyRepoPackage(package: Package, fileURL: URL, moveToCache: Bool = true) throws -> Bool {
        let packageControl = package.rawControl
    
        let supportedHashTypes = PackageHashType.allCases.compactMap { type in packageControl[type.rawValue].map { (type, $0) } }
        let packageContainsHashes = !supportedHashTypes.isEmpty
        
        guard packageContainsHashes else {
            throw Error.untrustedPackage(packageID: package.package)
        }
        
        var badHash = ""
        var badRefHash = ""
        
        let packageIsValid = supportedHashTypes.allSatisfy {
            let hash = $1
            guard let refHash = fileURL.hash(ofType: $0.hashType) else { return false }
          
            if hash != refHash {
                badHash = hash
                badRefHash = refHash
                return false
            } else {
                return true
            }
        }
        guard packageIsValid else {
            throw Error.hashMismatch(packageHash: badHash, refHash: badRefHash)
        }
        
        guard moveToCache else { return true }
        
        #if !TARGET_SANDBOX && !targetEnvironment(simulator)
        let packageID = aptEncoded(string: package.package, isArch: false)
        let version = aptEncoded(string: package.version, isArch: false)
        let architecture = aptEncoded(string: package.architecture ?? "", isArch: true)
        
        let destFileName = "\(CommandPath.prefix)/var/cache/apt/archives/\(packageID)_\(version)_\(architecture).deb"
        let destURL = URL(fileURLWithPath: destFileName)

        moveFileAsRoot(from: fileURL, to: destURL)
        #endif
        self.vars.cachedDownloadFiles.append(fileURL)
        return true
    }
    
    //running in aptQueue
    private func recheckTotalOps() throws {
        NSLog("SileoLog: recheckTotalOps")
        if restoreBatch != nil { return }
        if Thread.isMainThread {
            fatalError("This cannot be called from the main thread!")
        }
        
        // Clear any current depends
        self.vars.installdeps.removeAll()
        self.vars.uninstalldeps.removeAll()
        self.vars.errors.removeAll()
        
        // Get a total of depends to be installed and break if empty
        let allInstalls = self.vars.installations.raw.union(self.vars.upgrades.raw)
        // Packages that still have to be converted are resolved once the conversion has finished
        let pendingConversion = allInstalls.filter { DownloadManager.needsConversion($0.package) }
        let installationsAndUpgrades = allInstalls.subtracting(pendingConversion)
        guard !(installationsAndUpgrades.isEmpty && self.vars.uninstallations.isEmpty) else {
            return
        }

        do {
            // Run the dep accelerator for any packages that have not already been cared about
            try DependencyResolverAccelerator.shared.getDependencies(packages: installationsAndUpgrades.map { $0.package })
        } catch {
            throw error
        }
        #if TARGET_SANDBOX || targetEnvironment(simulator)
        return
        #endif

        var aptOutput: APTOutput
        do {
            // Get the full list of packages to be installed and removed from apt
            aptOutput = try APTWrapper.operationList(installList: installationsAndUpgrades, removeList: self.vars.uninstallations.raw)
            NSLog("SileoLog: aptOutput=\(aptOutput.operations), \(aptOutput.conflicts)")
        } catch {
            throw error
        }
        
        // Get every package to be uninstalled
        var uninstallIdentifiers = [String]()
        for operation in aptOutput.operations where operation.type == .remove {
            uninstallIdentifiers.append(operation.packageID)
        }
        
        var uninstallations = self.vars.uninstallations.raw
        let rawUninstalls = PackageListManager.shared.packages(identifiers: uninstallIdentifiers, sorted: false, packages: Array(PackageListManager.shared.installedPackages.values))
        guard rawUninstalls.count == uninstallIdentifiers.count else {
            rawUninstalls.map({NSLog("SileoLog: rawUninstalls=\($0.package) \($0.package)")})
            uninstallIdentifiers.map({NSLog("SileoLog: uninstallIdentifiers=\($0)")})
            throw APTParserErrors.blankJsonOutput(error: String(localizationKey: "APT_Uninstall_Mismatch", type: .error))
        }
        var uninstallDeps = Set<DownloadPackage>(rawUninstalls.compactMap { DownloadPackage(package: $0) })
        
        // Get the list of packages to be installed, including depends
        var installDepOperation = [String: (String, [String])]()
        for operation in aptOutput.operations where operation.type == .install {

            //there may be multiple repos in the release: \
            //{"Version":"2021.07.18","Package":"chariz-keyring","Release":"192.168.2.171, local-deb [all]","Type":"Inst"}
            //{"Version":"62","Package":"lsof","Release":"roothide.github.io, iosjb.top [iphoneos-arm64e]","Type":"Inst"}
            //{"Version":"0.3.8","Package":"com.nan.dpkg-fill","Release":"invalidunit.github.io [iphoneos-arm64e]","Type":"Inst"}
            
            var hosts = [String]()
            if let releases = operation.release?.split(separator: ",") {
                for release in releases {
                    guard let host = release.trimmingCharacters(in: .whitespaces).split(separator: " ").first else { continue }
                    hosts.append(String(host))
                }
            }

            installDepOperation[operation.packageID] = (operation.version, hosts)
        }
        NSLog("SileoLog: installDepOperation=\(installDepOperation)")
        var rawInstalls = ContiguousArray<Package>()
        for (packageID, (packageVersion,hosts)) in installDepOperation {
                
            if hosts.contains("local-deb") { //preferred local package
                if let localPackage = PackageListManager.shared.localPackages[packageID] {
                    if checkRootHide(localPackage) {
                        if localPackage.version == packageVersion {
                            NSLog("SileoLog: using local package=\(localPackage.package),\(localPackage.version),\(localPackage.local_deb)")
                            rawInstalls.append(localPackage)
                        }
                    }
                }
            } else {
                //hosts may be empty?
                hostLoop: for host in hosts {
                    // there may be multiple repos with the same host
                    for repo in RepoManager.shared.repoList where repo.url?.host == host {
                        if let repoPackage = repo.getPackage(identifier: packageID, version: packageVersion)
                        {
                            NSLog("SileoLog: using repoPackage=\(repoPackage.package),\(repoPackage.version),\(repoPackage.sourceRepo?.url)")
                            if checkRootHide(repoPackage) {
                                rawInstalls.append(repoPackage)
                                break hostLoop
                            }
                        }
                    }
                }
            }
        }
        
        rawInstalls.map({NSLog("SileoLog: rawInstalls: \($0.package)=\($0.version) \($0.local_deb ?? $0.sourceRepo?.url)")})

        guard rawInstalls.count == installDepOperation.count else {
            throw APTParserErrors.blankJsonOutput(error: String(localizationKey: "APT_Install_Mismatch", type: .error))
        }
        var installDeps = Set<DownloadPackage>(rawInstalls.compactMap { DownloadPackage(package: $0) })
        var installations = self.vars.installations.raw
        var upgrades = self.vars.upgrades.raw

        //Remove the package resolved by apt from the user-specified installation packages
        if aptOutput.conflicts.isEmpty {
            installations.removeAll { uninstallDeps.contains($0) }
            uninstallations.removeAll { installDeps.contains($0) }
            
            installations.removeAll { !installDeps.contains($0) && !pendingConversion.contains($0) }
            upgrades.removeAll { !installDeps.contains($0) && !pendingConversion.contains($0) }
            uninstallations.removeAll { !uninstallDeps.contains($0) }
            uninstallDeps.removeAll { uninstallations.contains($0) }
            installDeps.removeAll { installations.contains($0) }
            installDeps.removeAll { upgrades.contains($0) }
        }
  
        self.vars.upgrades.setTo(upgrades)
        self.vars.installations.setTo(installations)
        self.vars.installdeps.setTo(installDeps)
        self.vars.uninstallations.setTo(uninstallations)
        self.vars.uninstalldeps.setTo(uninstallDeps)
        self.vars.errors.setTo(Set<APTBrokenPackage>(aptOutput.conflicts))
        
        NSLog("SileoLog: upgrades=\(self.vars.upgrades.count), installations=\(self.vars.installations.count), installdeps=\(self.vars.installdeps.count) uninstallations=\(self.vars.uninstallations.count) uninstalldeps=\(self.vars.uninstalldeps.count) errors=\(self.vars.errors.count)")
        for p in self.vars.upgrades.raw { NSLog("SileoLog: self.upgrades: \(p.package.package)=\(p.package.version), \(p.package.local_deb ?? p.package.sourceRepo?.url)") }
        for p in self.vars.installations.raw { NSLog("SileoLog: self.installations: \(p.package.package)=\(p.package.version), \(p.package.local_deb ?? p.package.sourceRepo?.url)") }
        for p in self.vars.installdeps.raw { NSLog("SileoLog: self.installdeps: \(p.package.package)=\(p.package.version), \(p.package.local_deb ?? p.package.sourceRepo?.url)") }
        for p in self.vars.uninstallations.raw { NSLog("SileoLog: self.uninstallations: \(p.package.package)=\(p.package.version), \(p.package.local_deb ?? p.package.sourceRepo?.url)") }
        for p in self.vars.uninstalldeps.raw { NSLog("SileoLog: self.uninstalldeps: \(p.package.package)=\(p.package.version), \(p.package.local_deb ?? p.package.sourceRepo?.url)") }
    }
    
    private func checkInstalled()
    {
        if restoreBatch != nil { return }
        var reinstallPackages = [Package]()
        var uninstallPackages = [Package]()
        
        let installedPackages = PackageListManager.shared.installedPackages.values
        for package in installedPackages
        {
            if package.eFlag == .reinstreq {
                reinstallPackages.append(package)
            } else if package.eFlag == .ok {
                if package.wantInfo == .deinstall || package.wantInfo == .purge {
                    uninstallPackages.append(package)
                } else if package.status == .halfconfigured || package.status == .unpacked || package.status == .halfinstalled {
                    if package.essential == "yes" {
                        reinstallPackages.append(package)
                    } else {
                        /* remove broken packages(status=unpacked) so that apt can correctly resolve the dependencies of the packages to be installed. */
                        uninstallPackages.append(package)
                    }
                }
            }
        }
        
        for package in reinstallPackages {
            guard let newestPackage = PackageListManager.shared.newestPackage(identifier: package.package, repoContext: nil) else {
                uninstallPackages.append(package)
                continue
            }

            if !checkRootHide(newestPackage) {
                uninstallPackages.append(package)
                continue
            }

            let downloadPackage = DownloadPackage(package: newestPackage)
        
            if !self.vars.installations.contains(downloadPackage) && !self.vars.uninstallations.contains(downloadPackage) {
                NSLog("SileoLog: wantInfo \(downloadPackage.package.package) = \(downloadPackage.package.wantInfo.rawValue)")
                self.vars.installations.insert(downloadPackage)
            }
        }
        
        for package in uninstallPackages
        {
            let downloadPackage = DownloadPackage(package: package)
            if !self.vars.installations.contains(downloadPackage) && !self.vars.uninstallations.contains(downloadPackage) {
                NSLog("SileoLog: wantInfo \(downloadPackage.package.package) = \(downloadPackage.package.wantInfo.rawValue)")
                self.vars.uninstallations.insert(downloadPackage)
            }
        }
    }
    
    public func cancelDownloads() {
        if DispatchQueue.getSpecific(key: DownloadManager.aptQueueKey) == DownloadManager.aptQueueContext {
            self.currentDownloadSession = 0
            self.downloadsCancelled = true
        } else {
            DownloadManager.aptQueue.sync {
                self.currentDownloadSession = 0
                self.downloadsCancelled = true
            }
        }
        
        for download in self.vars.queuedDownloads.raw.values {
            download.task?.cancel()
            download.endBackgroundTask()
        }
        //how about cachedDownloadFiles?
        self.vars.queuedDownloads.removeAll()
        currentDownloads = 0
    }
    
    public func removeAllItems() {
        NSLog("SileoLog: DownloadManager.removeAllItems")
        restoreBatch = nil
        self.vars.upgrades.removeAll()
        self.vars.installdeps.removeAll()
        self.vars.installations.removeAll()
        self.vars.uninstalldeps.removeAll()
        self.vars.uninstallations.removeAll()
        self.vars.errors.removeAll()
        self.cancelDownloads()
    }
    
    public func reloadData(recheckPackages: Bool) {
        reloadData(recheckPackages: recheckPackages, completion: nil)
    }
    
    public func reloadData(recheckPackages: Bool, completion: (() -> Void)?) {
        NSLog("SileoLog: DownloadManager.reloadData \(recheckPackages) \(completion)")
        assert(recheckPackages==true)
        
        DownloadManager.aptQueue.async { [self] in
            assert(queueRunning==false)
            
            do {
                self.checkInstalled()
                try self.recheckTotalOps()
            } catch {
                removeAllItems()
                checkInstalled()
                TabBarController.singleton?.displayError(error.localizedDescription)
            }
            
            DispatchQueue.main.async {
                self.viewController.reloadData()
                TabBarController.singleton?.updatePopup(completion: completion)
                NotificationCenter.default.post(name: PackageListManager.stateChange, object: nil)
            }
        }
    }
    
    public func findDownloadPackage(package: Package) -> DownloadPackage? {
        let downloadPackage = DownloadPackage(package: package)
        if let found = self.vars.installations.filter( { $0.package.package == package.package }).first {
            return found
        } else if let found = self.vars.uninstallations.filter( { $0.package.package == package.package }).first {
            return found
        } else if let found = self.vars.upgrades.filter( { $0.package.package == package.package }).first {
            return found
        } else if let found = self.vars.installdeps.filter( { $0.package.package == package.package }).first {
            return found
        } else if let found = self.vars.uninstalldeps.filter( { $0.package.package == package.package }).first {
            return found
        }
        return nil
    }
    
    public func find(package: Package) -> DownloadManagerQueue {
        let downloadPackage = DownloadPackage(package: package)
        if self.vars.installations.contains(downloadPackage) {
            return .installations
        } else if self.vars.uninstallations.contains(downloadPackage) {
            return .uninstallations
        } else if self.vars.upgrades.contains(downloadPackage) {
            return .upgrades
        } else if self.vars.installdeps.contains(downloadPackage) {
            return .installdeps
        } else if self.vars.uninstalldeps.contains(downloadPackage) {
            return .uninstalldeps
        }
        return .none
    }
    
    public func find(package: String) -> DownloadManagerQueue {
        if self.vars.installations.contains(where: { $0.package.package == package }) {
            return .installations
        } else if self.vars.uninstallations.contains(where: { $0.package.package == package }) {
            return .uninstallations
        } else if self.vars.upgrades.contains(where: { $0.package.package == package }) {
            return .upgrades
        } else if self.vars.installdeps.contains(where: { $0.package.package == package }) {
            return .installdeps
        } else if self.vars.uninstalldeps.contains(where: { $0.package.package == package }) {
            return .uninstalldeps
        }
        return .none
    }
    
    public func remove(package: String) {
        self.vars.installations.remove { $0.package.package == package }
        self.vars.upgrades.remove { $0.package.package == package }
        self.vars.installdeps.remove { $0.package.package == package }
        self.vars.uninstallations.remove { $0.package.package == package }
        self.vars.uninstalldeps.remove { $0.package.package == package }
    }
    
    
    private func checkRootlessV2(package: Package, fileURL: URL) {
        NSLog("SileoLog: checkRootlessV2 \(package.package) \(fileURL)")
        
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false, attributes: nil)
        
        var (status, output, errorOutput) = spawn(command: CommandPath.dpkgdeb, args: ["dpkg-deb", "-R", rootfs(fileURL.path), rootfs(temp.path)], root: true)
        guard status==0 else {return}
        
        let controlFilePath = temp.path.appending("/DEBIAN/control")
        
        spawn(command: CommandPath.chmod, args: ["chmod", "0666", rootfs(controlFilePath)], root: true)
        spawn(command: CommandPath.chmod, args: ["chmod", "0777", rootfs(temp.path.appending("/DEBIAN"))], root: true)
        
        guard var controlFileData = try? String(contentsOfFile: controlFilePath, encoding: .utf8) else {
            NSLog("SileoLog: read err \(controlFilePath)")
            return
        }
        
        let pattern = "^Architecture:\\s*(.+)\\s*$"
        let regexp = try! NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
        let range = NSRange(location: 0, length: controlFileData.count)
        let archNSRange = regexp.rangeOfFirstMatch(in: controlFileData, range: range)
        guard let archRange = Range(archNSRange, in: controlFileData) else { return }
        let archString = String(controlFileData[archRange])
        let archStringRange = NSRange(location: 0, length: archString.count)
        let origArch = regexp.stringByReplacingMatches(in: archString, range: archStringRange, withTemplate: "$1")
        
        controlFileData = regexp.stringByReplacingMatches(in: controlFileData, range: range, withTemplate: "Architecture: all")
        NSLog("SileoLog: origArch=\(origArch) controlFileData=\(controlFileData)")

        do {
            try controlFileData.write(toFile: controlFilePath, atomically: true, encoding: .utf8)
        } catch {
            NSLog("SileoLog: write err \(error)")
            return
        }
        
        spawn(command: CommandPath.chmod, args: ["chmod", "0644", rootfs(controlFilePath)], root: true)
        spawn(command: CommandPath.chmod, args: ["chmod", "0755", rootfs(temp.path.appending("/DEBIAN"))], root: true)
        
        var newPkgPath = temp.path
        if FileManager.default.fileExists(atPath: temp.path.appending("/var/jb")) {
            newPkgPath = temp.path.appending("/var/jb")
            spawn(command: CommandPath.mv, args: ["mv", "-f", rootfs(temp.path.appending("/DEBIAN")), rootfs(newPkgPath)], root: true)
        }
        
        let outPath = temp.path.appending(".deb")
        
        (status, output, errorOutput) = spawn(command: CommandPath.dpkgdeb, args: ["dpkg-deb", "-b", rootfs(newPkgPath), rootfs(outPath)], root: true)
        guard status==0 else {return}

        guard let newPackage = PackageListManager.shared.package(url: URL(fileURLWithPath: outPath)) else {
            return
        }
        
        if checkRootHide(newPackage) {
            newPackage.origArchitecture = origArch
            self.add(package: newPackage, queue: .installations) {
                self.reloadData(recheckPackages: true)
            }
        }
    }
    
    private static let compatModeKey = "CompatibilityMode"
    
    // call in main queue
    func downloadDeb(package: Package, msg: String, showsProgress: Bool = false, handler: @escaping ((Package,URL) -> Void)) {
        var task:EvanderDownloader?
        
        let alert = UIAlertController(title: msg, message: showsProgress ? "\n\n\n\n" : msg, preferredStyle: .alert)
        let progressView = UIProgressView(progressViewStyle: .default)
        let percentLabel = UILabel()
        var percentLeading: NSLayoutConstraint?
        if showsProgress {
            progressView.translatesAutoresizingMaskIntoConstraints = false
            percentLabel.translatesAutoresizingMaskIntoConstraints = false
            percentLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            percentLabel.textAlignment = .center
            percentLabel.text = "0%"
            alert.view.addSubview(progressView)
            alert.view.addSubview(percentLabel)
            let leading = percentLabel.leadingAnchor.constraint(equalTo: progressView.leadingAnchor)
            percentLeading = leading
            NSLayoutConstraint.activate([
                progressView.leadingAnchor.constraint(equalTo: alert.view.leadingAnchor, constant: 24),
                progressView.trailingAnchor.constraint(equalTo: alert.view.trailingAnchor, constant: -24),
                progressView.bottomAnchor.constraint(equalTo: alert.view.bottomAnchor, constant: -66),
                percentLabel.bottomAnchor.constraint(equalTo: progressView.topAnchor, constant: -6),
                percentLabel.widthAnchor.constraint(equalToConstant: 48),
                leading
            ])
        }
        
        func updateProgress(_ fraction: Double) {
            DispatchQueue.main.async {
                let value = max(0, min(1, fraction))
                progressView.setProgress(Float(value), animated: true)
                percentLabel.text = "\(Int(value * 100))%"
                let travel = max(0, progressView.bounds.width - 48)
                percentLeading?.constant = CGFloat(value) * travel
                UIView.animate(withDuration: 0.15) { alert.view.layoutIfNeeded() }
            }
        }

        // A server that sends no length leaves the fraction at zero for the
        // whole download; the size in the control file is used instead, and
        // without that the bar walks on its own so it is never frozen.
        var lastFraction: Double = 0
        func reportProgress(_ progress: DownloadProgress) {
            let declared = Int64(package.size ?? "") ?? 0
            if progress.expected != NSURLSessionTransferSizeUnknown, progress.expected > 0 {
                lastFraction = max(0, min(1, progress.fractionCompleted))
            } else if declared > 0 {
                lastFraction = max(0, min(1, Double(progress.total) / Double(declared)))
            } else {
                lastFraction = min(0.95, lastFraction + max(0.01, (0.95 - lastFraction) * 0.08))
            }
            updateProgress(lastFraction)
        }
        
        let cancel = UIAlertAction(title: String(localizationKey: "Cancel"), style: .cancel) { _ in
            alert.dismiss(animated: true, completion: nil)
            task?.cancel()
        }
        alert.addAction(cancel)
        
        SileoAppDelegate.presentController(alert)
        
        func updateMsg(msg: String) {
            NSLog("SileoLog: updateMsg=\(msg)")
            DispatchQueue.main.async {
                alert.message = "\n \(msg) \n"
            }
        }
        
        func showFailure(msg: String) {
            DispatchQueue.main.async {
                progressView.isHidden = true
                percentLabel.isHidden = true
            }
            updateMsg(msg: msg)
        }
        
        func finishDownload(fileURL: URL) {
            NSLog("SileoLog: finishDownload=\(fileURL.path)")
            DispatchQueue.main.async {
                // The bar is taken all the way to 100% before the card goes,
                // so a finished download never just disappears.
                if showsProgress {
                    progressView.setProgress(1, animated: true)
                    percentLabel.text = "100%"
                    let travel = max(0, progressView.bounds.width - 48)
                    percentLeading?.constant = travel
                    alert.view.layoutIfNeeded()
                }
                let delay: TimeInterval = showsProgress ? 0.35 : 0
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    alert.dismiss(animated: true, completion: {
                        handler(package,fileURL)
                    })
                }
            }
        }
        
        if let local_deb = package.local_deb {
            finishDownload(fileURL: URL(fileURLWithPath: local_deb))
            return
        }
        
        guard let filename = package.filename, let repo = package.sourceRepo, let repoURL = URL(string: repo.rawURL) else {
            updateMsg(msg: String(localizationKey: "Unknown", type: .error))
            return
        }
        
        var packageURL = filename
        if !packageURL.hasPrefix("https://") && !packageURL.hasPrefix("http://") {
            packageURL = repoURL.appendingPathComponent(filename).absoluteString
        }
        
        // See if theres an overriding web URL for downloading the package from
        self.overrideDownloadURL(package: package, repo: repo) { errorMessage, overrideURL in
            if overrideURL == nil && errorMessage != nil {
                showFailure(msg: "\(errorMessage)")
                return
            }
            let downloadURL = overrideURL ?? URL(string: packageURL)
            NSLog("SileoLog: downloadURL=\(downloadURL)")
            task = RepoManager.shared.queue(from: downloadURL, progress: { task, progress in
                if showsProgress {
                    reportProgress(progress)
                    return
                }
                var msg:String
                if progress.expected==NSURLSessionTransferSizeUnknown {
                    msg = "\(progress.total) bytes ..."
                } else {
                    msg = "\(Int(progress.fractionCompleted * 100))% ..."
                }
                updateMsg(msg: msg)
            }, success: { task, status, fileURL in
                
                let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                let fileSize = attributes?[FileAttributeKey.size] as? Int
                let fileSizeStr = String(format: "%ld", fileSize ?? 0)
                
                if package.local_deb==nil && (fileSizeStr != package.size) {
                    let failureReason = String(format: String(localizationKey: "Download_Size_Mismatch", type: .error),
                                               package.size ?? "nil", fileSizeStr)
                    showFailure(msg: "\(failureReason)")
                } else {
                    finishDownload(fileURL: fileURL)
                }
                
            }, failure: { task, statusCode, error in
                let failureReason = error?.localizedDescription ?? String(format: String(localizationKey: "Download_Failing_Status_Code", type: .error), statusCode)
                
                showFailure(msg: "\(failureReason)")
                
            }, waiting: { task, message in
                updateMsg(msg: "\(message)")
            })
            task?.resume()
        }
    }
    
    public func add(package: Package, queue: DownloadManagerQueue, approved: Bool = false, completion: (() -> Void)?=nil) {
        guard restoreBatch == nil else { completion?(); return }
        NSLog("SileoLog: addPackage=\(package.name), queue=\(queue.rawValue), approved=\(approved) package=\(package.package), repo=\(package.sourceRepo?.url) depends=\(package.rawControl["depends"]) arch=\(package.architecture)")
//        Thread.callStackSymbols.forEach{NSLog("SileoLog: callstack=\($0)")}

        CanisterResolver.shared.ingest(packages: [package])
        
        var package = package
        if queue == .uninstallations || queue == .uninstalldeps {
            guard let installedPackage = PackageListManager.shared.installedPackage(identifier: package.package) else {
                return
            }
            package = installedPackage
        }
        
        if queue != .uninstallations && queue != .uninstalldeps {
            if !checkRootHide(package) {
                
                if Bootstrap.roothide && package.tags.contains(.roothide) && FileManager.default.fileExists(atPath: jbroot("/usr/lib/libroot.dylib")) {
                    NSLog("SileoLog: roothide suppport: \(package.package)")
                    self.downloadDeb(package:package, msg: String(localizationKey: "Loading"), handler: self.checkRootlessV2)
                    return
                }
                
                // A convertible rootless/rootful package waits in the queue and
                // is converted when the queue runs, so nothing is shown here.
                // Only one that cannot be converted is turned away.
                if !DownloadManager.needsConversion(package) {
                    NSLog("SileoLog: not updated for roothide: \(package.package) \(package.architecture)")
                    
                    let IncompatibleRepo = DownloadManager.incompatibleHosts.contains(package.sourceRepo?.url?.host ?? "")
                    let convertible = !IncompatibleRepo && RootlessConverter.isConvertible(package: package)
                    
                    let title = String(localizationKey: "Not_Supported")
                    let msg: String
                    if IncompatibleRepo {
                        msg = String(localizationKey: "please contact @roothideDev to update it")
                    } else if !convertible {
                        msg = String(localizationKey: "Compat_Not_Updated_Message")
                    } else {
                        msg = String(localizationKey: "Compat_Disabled_Message")
                    }
                    
                    let alert = UIAlertController(title: title, message: "\n" + msg, preferredStyle: .alert)
                    
                    let okAction = UIAlertAction(title: (package.sourceRepo?.url?.host == "apt.procurs.us") ? String(localizationKey: "OK") : String(localizationKey: "Cancel"), style: .cancel) { _ in
                        alert.dismiss(animated: true, completion: nil)
                    }
                    alert.addAction(okAction)
                    
                    SileoAppDelegate.presentController(alert)
                    return
                }
            }
        }
        
        if queue == .uninstallations {
            if approved == false && isEssential(package) {
                let message = String(format: String(localizationKey: "Essential_Warning"),
                                     "\n\(package.name ?? package.package)")
                let alert = UIAlertController(title: String(localizationKey: "Warning"),
                                              message: message,
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localizationKey: "Cancel"), style: .default, handler: { _ in
                    alert.dismiss(animated: true)
                }))
                alert.addAction(UIAlertAction(title: String(localizationKey: "Dangerous_Repo.Last_Chance.Continue"), style: .destructive, handler: { _ in
                    self.add(package: package, queue: .uninstallations, approved: true, completion: completion)
                }))
                SileoAppDelegate.presentController(alert)
                return
            }
        }

        let downloadPackage = DownloadPackage(package: package)
        let found = find(package: downloadPackage.package)
        if found != .none {
            remove(downloadPackage: downloadPackage, queue: found)
        }

        switch queue {
        case .none:
            return
        case .installations:
            self.vars.installations.insert(downloadPackage)
        case .uninstallations:
            self.vars.uninstallations.insert(downloadPackage)
        case .upgrades:
            self.vars.upgrades.insert(downloadPackage)
        case .installdeps:
            self.vars.installdeps.insert(downloadPackage)
        case .uninstalldeps:
            self.vars.uninstalldeps.insert(downloadPackage)
        }
        
        completion?()
    }
    
    public func upgradeAll(packages: Set<Package>, _ completion: @escaping () -> ()) {
        Self.aptQueue.async { [self] in
            guard restoreBatch == nil else { completion(); return }
            
            if queueRunning {
                completion()
                return
            }
            
            var packages = packages
            let mapped = self.vars.upgrades.map { $0.package.package }
            packages.removeAll { mapped.contains($0.package) }
            for package in packages {
                let downloadPackage = DownloadPackage(package: package)
                let found = find(package: package.package)
                if found == .upgrades { continue }
                remove(downloadPackage: downloadPackage, queue: found)
                self.vars.upgrades.insert(downloadPackage)
            }
            completion()
        }
    }
  
    public func remove(package: Package, queue: DownloadManagerQueue) {
        let downloadPackage = DownloadPackage(package: package)
        remove(downloadPackage: downloadPackage, queue: queue)
    }
    
    public func remove(downloadPackage: DownloadPackage, queue: DownloadManagerQueue) {
        switch queue {
        case .none:
            return
        case .installations:
            self.vars.installations.remove(downloadPackage)
        case .uninstallations:
            self.vars.uninstallations.remove(downloadPackage)
        case .upgrades:
            self.vars.upgrades.remove(downloadPackage)
        case .installdeps:
            self.vars.installdeps.remove(downloadPackage)
        case .uninstalldeps:
            self.vars.uninstalldeps.remove(downloadPackage)
        }
    }

    public func register(downloadOverrideProvider: DownloadOverrideProviding, repo: Repo) {
        if self.vars.repoDownloadOverrideProviders[repo.repoURL] == nil {
            self.vars.repoDownloadOverrideProviders[repo.repoURL] = Set()
        }
        self.vars.repoDownloadOverrideProviders[repo.repoURL]?.insert(downloadOverrideProvider.hashableObject)
    }
    
    public func deregister(downloadOverrideProvider: DownloadOverrideProviding, repo: Repo) {
        self.vars.repoDownloadOverrideProviders[repo.repoURL]?.remove(downloadOverrideProvider.hashableObject)
    }
    
    public func deregister(downloadOverrideProvider: DownloadOverrideProviding) {
        for keyVal in self.vars.repoDownloadOverrideProviders.raw {
            self.vars.repoDownloadOverrideProviders[keyVal.key]?.remove(downloadOverrideProvider.hashableObject)
        }
    }
    
    private func overrideDownloadURL(package: Package, repo: Repo, completionHandler: @escaping (String?, URL?) -> Void) {
        guard  let providers = self.vars.repoDownloadOverrideProviders[repo.repoURL], !providers.isEmpty else {
            return completionHandler(nil, nil)
        }

        // The number of providers checked so far
        var checked = 0
        let total = providers.count
        for obj in providers {
            guard let downloadProvider = obj as? DownloadOverrideProviding else {
                continue
            }
            var willProvideURL = false
            willProvideURL = downloadProvider.downloadURL(for: package, from: repo, completionHandler: { errorMessage, url in
                // Ensure that this provider didn't say no and then try to call the completion handler
                if willProvideURL {
                    completionHandler(errorMessage, url)
                }
            })
            checked += 1
            if willProvideURL {
                break
            } else if checked >= total {
                // No providers offered an override URL for this download
                completionHandler(nil, nil)
            }
        }
    }
    
    public func repoRefresh() {
        NSLog("SileoLog: repoRefresh lock=\(aptRunning) upgrades=\(self.vars.upgrades.count) installations=\(self.vars.installations.count) installdeps=\(self.vars.installdeps.count) errors=\(self.vars.errors.count)")
        
        if queueRunning { return }
        
        var reloadNeeded = false
        
        if self.vars.errors.count > 0 {
            reloadNeeded = true
        }
        
        // Check for essential
        var allowedHosts = [String]()
        #if targetEnvironment(macCatalyst)
        allowedHosts = ["apt.procurs.us"]
        #else
        if Jailbreak.bootstrap == .procursus {
            allowedHosts = ["apt.procurs.us", "roothide.github.io"]
        } else {
            allowedHosts = [
                "apt.bingner.com",
                "test.apt.bingner.com",
                "apt.elucubratus.com"
            ]
        }
        #endif
        
        let installedPackages = PackageListManager.shared.installedPackages
        
        for repo in allowedHosts {
            if let repo = RepoManager.shared.repoList.first(where: { $0.url?.host == repo }) {
                for package in repo.packageArray where package.essential == "yes" &&
                                                            installedPackages[package.package] == nil &&
                                                            find(package: package) == .none {
                                                                if checkRootHide(package) {
                                                                    reloadNeeded = true
                                                                    add(package: package, queue: .installdeps)
                                                                }
                }
            }
        }
        
        // Don't bother to reloadData if there's nothing to reload, it's a waste of resources
        if reloadNeeded {
            reloadData(recheckPackages: true)
        }
    }
    
    public func isEssential(_ package: Package) -> Bool {
        // Check for essential
        var allowedHosts = [String]()
        #if targetEnvironment(macCatalyst)
        allowedHosts = ["apt.procurs.us"]
        #else
        if Jailbreak.bootstrap == .procursus {
            allowedHosts = ["apt.procurs.us","roothide.github.io"]
        } else {
            allowedHosts = [
                "apt.bingner.com",
                "test.apt.bingner.com",
                "apt.elucubratus.com"
            ]
        }
        #endif
        var inAllowedRepos = false
        var inDisallowedRepos = false
        for repo in RepoManager.shared.repoList where repo.packageArray.count > 0 {
            if repo.newestPackage(identifier: package.package) != nil {
                if let host=repo.url?.host, allowedHosts.contains(host) {
                    inAllowedRepos = true
                } else {
                    inDisallowedRepos = true
                }
            }
        }
        return (inAllowedRepos || !inDisallowedRepos) && package.essential == "yes"
    }
    
    private func performOperations(progressCallback: @escaping (Double, Bool, String, String) -> Void,
                                  outputCallback: @escaping (String, Int) -> Void,
                                  completionCallback: @escaping (Int, APTWrapper.FINISH, Bool) -> Void) {
        var installs = Array(self.vars.installations.raw)
        installs += self.vars.upgrades.raw
        let removals = Array(self.vars.uninstallations.raw) + Array(self.vars.uninstalldeps.raw)
        let installdeps = Array(self.vars.installdeps.raw)
        APTWrapper.performOperations(installs: installs,
                                     removals: removals,
                                     installDeps: installdeps,
                                     progressCallback: progressCallback,
                                     outputCallback: outputCallback,
                                     completionCallback: completionCallback)
    }
}

