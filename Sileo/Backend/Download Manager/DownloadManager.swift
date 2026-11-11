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
        for dlPackage in allRawDownloads {
            guard let download = self.vars.queuedDownloads[dlPackage.package.package],
                  download.success else { return false }
        }
        return true
    }
    
    private func startPackageDownload(download: Download) {
        NSLog("SileoLog: startPackageDownload \(download.package.package)")
        
        let package = download.package
        
        // If it's a local file we can verify it immediately
        if package.local_deb != nil {
            if self.verifyLocalPackage(package: package) {
                if DownloadManager.needsConversion(package), let localDeb = package.local_deb {
                    // Converted here, inside the queue run, instead of with a
                    // download alert when the package was queued.
                    self.convertDownloaded(download: download, fileURL: URL(fileURLWithPath: localDeb))
                    return
                }
                download.progress = 1
                download.success = true
                download.completed = true
            } else {
                download.failureReason = String(localizationKey: "Unknown", type: .error)
            }
            
            self.viewController.updateDownloadStatus(download: download)
            
            NSLog("SileoLog: startMoreDownloads (startPackageDownload) 1")
            self.currentDownloads -= 1
            self.startMoreDownloads()
            return
        }
        
        guard let filename = package.filename, let repo = package.sourceRepo, let repoURL = URL(string: repo.rawURL) else {
            
            download.failureReason = String(localizationKey: "Unknown", type: .error)
            
            self.viewController.updateDownloadStatus(download: download)
            
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
        self.viewController.updateDownloadStatus(download: download)
        
        // See if theres an overriding web URL for downloading the package from
        self.overrideDownloadURL(package: package, repo: repo) { errorMessage, overrideURL in DownloadManager.aptQueue.async {
            if overrideURL == nil && errorMessage != nil {
                
                download.endBackgroundTask()
                
                download.failureReason = errorMessage
                
                self.viewController.updateDownloadStatus(download: download)
                
                NSLog("SileoLog: startMoreDownloads (startPackageDownload) 3")
                self.currentDownloads -= 1
                self.startMoreDownloads()
                
                return
            }
            
            let downloadURL = overrideURL ?? URL(string: packageURL)
            
            download.task = RepoManager.shared.queue(from: downloadURL, progress: { task, progress in DownloadManager.aptQueue.async {
                NSLog("SileoLog: download progress \(task.task)")
                
                guard download.session == self.currentDownloadSession else {
                    return
                }
                
                download.message = nil
                download.progress = CGFloat(progress.fractionCompleted)
                download.totalBytesWritten = progress.total
                download.totalBytesExpectedToWrite = progress.expected
                
                self.viewController.updateDownloadStatus(download: download)
                
            }}, success: { task, status, fileURL in DownloadManager.aptQueue.async {
                NSLog("SileoLog: download success \(task.task)")
                
                download.endBackgroundTask()
                
                guard download.session == self.currentDownloadSession else {
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
                    
                } else {
                    
                    let needsConversion = DownloadManager.needsConversion(package)
                    do {
                        download.success = try self.verifyRepoPackage(package: package, fileURL: fileURL, moveToCache: !needsConversion)
                        download.progress = 1
                        if needsConversion && download.success {
                            self.convertDownloaded(download: download, fileURL: fileURL)
                            return
                        }
                    } catch let error {
                        download.success = false
                        download.progress = 0
                        download.failureReason = error.localizedDescription
                    }
                    
#if TARGET_SANDBOX || targetEnvironment(simulator)
                    try? FileManager.default.removeItem(at: fileURL)
#endif
                }
                
                self.viewController.updateDownloadStatus(download: download)
                
                NSLog("SileoLog: startMoreDownloads (startPackageDownload) 4")
                self.currentDownloads -= 1
                self.startMoreDownloads()
                
            }}, failure: { task, statusCode, error in DownloadManager.aptQueue.async {
                NSLog("SileoLog: download failure \(task?.task)")
                
                download.endBackgroundTask()
                
                guard download.session == self.currentDownloadSession else {
                    return
                }
                
                download.failureReason = error?.localizedDescription ?? String(format: String(localizationKey: "Download_Failing_Status_Code", type: .error), statusCode)
                download.message = nil
                
                self.viewController.updateDownloadStatus(download: download)
                
                NSLog("SileoLog: startMoreDownloads (startPackageDownload) 5")
                self.currentDownloads -= 1
                self.startMoreDownloads()
                
            }}, waiting: { task, message in DownloadManager.aptQueue.async {
                NSLog("SileoLog: download waiting \(task.task)")
                
                guard download.session == self.currentDownloadSession else {
                    return
                }
                
                download.message = message
                self.viewController.updateDownloadStatus(download: download)
            }})
            
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
        download.progress = 0.99
        download.converting = true
        download.message = String(localizationKey: "Compat_Converting")
        self.viewController.updateDownloadStatus(download: download)
        
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
        download.message = nil
        download.converting = false
        
        guard download.session == self.currentDownloadSession else {
            try? FileManager.default.removeItem(at: output)
            return
        }
        
        func fail(_ reason: String) {
            download.failureReason = reason
            download.success = false
            download.progress = 0
            self.viewController.updateDownloadStatus(download: download)
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
        DispatchQueue.main.async { self.viewController.reloadData() }
        self.viewController.updateDownloadStatus(download: download)
        self.currentDownloads -= 1
        self.startMoreDownloads()
    }
    
    private func startMoreDownloads() {
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
            self.currentDownloadSession = arc4random()
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
    
    private func verifyLocalPackage(package: Package) -> Bool {
        let packageID = aptEncoded(string: package.package, isArch: false)
        let version = aptEncoded(string: package.version, isArch: false)
        let architecture = aptEncoded(string: package.architecture ?? "", isArch: true)
        
        let destFileName = "\(CommandPath.prefix)/var/cache/apt/archives/\(packageID)_\(version)_\(architecture).deb"
        let destURL = URL(fileURLWithPath: destFileName)
        
        guard let local_deb = package.local_deb else { return false }
        
        moveFileAsRoot(from: URL(fileURLWithPath: local_deb), to: URL(fileURLWithPath: destFileName))
        
        guard FileManager.default.fileExists(atPath: destFileName) else { return false }
        
        self.vars.cachedDownloadFiles.append(URL(fileURLWithPath: local_deb))
        package.local_deb = destFileName
        
        return true
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
        // What the removal would take with it, worked out before apt is asked,
        // so an apt failure cannot leave the dependencies behind.
        var orphaned: [Package] = []
        if installationsAndUpgrades.isEmpty && !self.vars.uninstallations.isEmpty {
            let removing = self.vars.uninstallations.raw.map { $0.package }
            orphaned = OrphanDependencies.orphaned(by: removing,
                                                   installed: PackageListManager.shared.installedPackages)
        }

        var aptOutput: APTOutput
        do {
            // Get the full list of packages to be installed and removed from apt
            aptOutput = try APTWrapper.operationList(installList: installationsAndUpgrades, removeList: self.vars.uninstallations.raw)
            NSLog("SileoLog: aptOutput=\(aptOutput.operations), \(aptOutput.conflicts)")
        } catch {
            if !orphaned.isEmpty {
                self.vars.uninstalldeps.setTo(Set(orphaned.map { DownloadPackage(package: $0) }))
            }
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
        // apt says which dependencies nothing else needs any more. Only those
        // are checked against the system list: a package the user asked to
        // remove goes whatever it is, that is their call.
        let askedFor = Set(self.vars.uninstallations.raw.map { $0.package.package })
        uninstallDeps = Set(uninstallDeps.filter { downloadPackage in
            askedFor.contains(downloadPackage.package.package) || !DownloadManager.isSystemPackage(downloadPackage.package)
        })
        
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

        // The dependencies worked out above join apt's own answer.
        for orphan in orphaned
        where !uninstallations.contains(where: { $0.package.package == orphan.package })
            && !uninstallDeps.contains(where: { $0.package.package == orphan.package }) {
            uninstallDeps.insert(DownloadPackage(package: orphan))
        }

        // apt's own list is put through the same question: nothing a package
        // that stays still needs goes along with it, and once something is kept
        // what it needs is kept too.
        let removingIdentifiers = Set(uninstallations.map { $0.package.package })
        var changed = true
        while changed {
            let identifiers = Set(uninstallDeps.map { $0.package.package })
            let needed = OrphanDependencies.neededByStaying(identifiers,
                                                            removing: removingIdentifiers,
                                                            installed: PackageListManager.shared.installedPackages)
            changed = false
            if !needed.isEmpty {
                let before = uninstallDeps.count
                uninstallDeps = Set(uninstallDeps.filter { !needed.contains($0.package.package) })
                changed = uninstallDeps.count != before
                if changed {
                }
            }
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
            DownloadManager.shared.currentDownloadSession = 0
        } else {
            DownloadManager.aptQueue.sync {
                DownloadManager.shared.currentDownloadSession = 0
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
                
                if package.tags.contains(.roothide) && FileManager.default.fileExists(atPath: jbroot("/usr/lib/libroot.dylib")) {
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
    
    /// Packages that are never taken along, whatever the control files say.
    /// Everything else the control files answer for themselves: `Essential: yes`
    /// or `Priority: required` is the device's own word on what it needs, and a
    /// compression tool that came in with Filza is not on that list.
    private static let systemPackages: Set<String> = [
        "sileo", "org.coolstar.sileo", "roothide", "ellekit", "com.roothide.patchloader",
        "rootless-compat", "mobilesubstrate", "substrate", "libhooker", "org.coolstar.libhooker"
    ]

    static func isSystemPackage(_ package: Package) -> Bool {
        if package.essential == "yes" {
            return true
        }
        let priority = (package.rawControl["priority"] ?? package.rawControl["Priority"] ?? "").lowercased()
        if priority == "required" {
            return true
        }
        return DownloadManager.systemPackages.contains(package.package)
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

/// Works out which packages came along as dependencies of the ones being
/// removed and are wanted by nothing else, so that taking a package off the
/// device takes what it dragged in with it.
///
/// It reads the control files of what is installed — the dependencies, the
/// alternatives inside them, and the names a package provides — rather than
/// leaning on apt's own answer, which never covers a package installed from a
/// local file.
enum OrphanDependencies {

    /// The package name in one way of writing a dependency, with its version
    /// and architecture qualifier taken off.
    static func packageName(fromDependency dependency: String) -> String? {
        var name = dependency.trimmingCharacters(in: .whitespaces)
        if let bracket = name.firstIndex(of: "(") {
            name = String(name[..<bracket])
        }
        if let colon = name.firstIndex(of: ":") {
            name = String(name[..<colon])
        }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// A package's dependencies, one clause at a time. The ways of satisfying a
    /// clause are alternatives: `openssh-server | wiki.qaq.irisin` is met by
    /// either of them, so neither has to stay if the other does.
    static func dependencyClauses(of package: Package) -> [[String]] {
        var clauses = [[String]]()
        // Control fields are kept with lowercased keys, but both spellings are
        // read so a field kept as written cannot be missed.
        for key in ["depends", "pre-depends", "Depends", "Pre-Depends"] {
            guard let raw = package.rawControl[key] else { continue }
            for clause in raw.components(separatedBy: ",") {
                let alternatives = clause.components(separatedBy: "|").compactMap {
                    packageName(fromDependency: $0)
                }
                if !alternatives.isEmpty {
                    clauses.append(alternatives)
                }
            }
        }
        return clauses
    }

    /// Every name a package asks for, whichever way it is written.
    static func dependencyNames(of package: Package) -> Set<String> {
        var names = Set<String>()
        for clause in dependencyClauses(of: package) {
            for name in clause {
                names.insert(name)
            }
        }
        return names
    }

    /// The names a package answers to besides its own, from Provides.
    static func providedNames(of package: Package) -> Set<String> {
        var names = Set<String>()
        for key in ["provides", "Provides"] {
            guard let raw = package.rawControl[key] else { continue }
            for clause in raw.components(separatedBy: ",") {
                if let name = packageName(fromDependency: clause) {
                    names.insert(name)
                }
            }
        }
        return names
    }

    /// Which package carries each name: its own, and the ones it provides.
    static func providers(among identifiers: Set<String>, installed: [String: Package]) -> [String: Set<String>] {
        var providers = [String: Set<String>]()
        for (identifier, package) in installed where identifiers.contains(identifier) {
            providers[identifier, default: []].insert(identifier)
            for provided in providedNames(of: package) {
                providers[provided, default: []].insert(identifier)
            }
        }
        return providers
    }

    /// What would be left behind, and unwanted, if these packages went.
    ///
    /// A package installed from a local file never reaches apt's record of what
    /// came in automatically, so that record is not what decides here: being a
    /// dependency of the package that goes, and being wanted by nothing that
    /// stays, is enough. Wanted is counted again after each package is dropped,
    /// because what a kept package needs must stay as well: libpam2 needs
    /// libpam-modules, and sudo needs libpam2.
    static func orphaned(by removing: [Package], installed: [String: Package]) -> [Package] {
        guard !removing.isEmpty else { return [] }
        let removedIdentifiers = Set(removing.map { $0.package })

        // Everything those packages pulled in, and what that pulled in.
        var candidates = Set<String>()
        var visited = removedIdentifiers
        var queue = Array(removedIdentifiers)
        while !queue.isEmpty {
            let identifier = queue.removeFirst()
            guard let package = installed[identifier] else { continue }
            for dependency in dependencyNames(of: package) {
                guard installed[dependency] != nil,
                      !removedIdentifiers.contains(dependency),
                      candidates.insert(dependency).inserted else {
                    continue
                }
                if visited.insert(dependency).inserted {
                    queue.append(dependency)
                }
            }
        }
        guard !candidates.isEmpty else { return [] }
        let carriers = providers(among: Set(installed.keys), installed: installed)

        // Drop what anything that stays still needs, and look again, since what
        // that needs must stay too.
        var changed = true
        while changed {
            changed = false
            for (identifier, package) in installed
            where !removedIdentifiers.contains(identifier) && !candidates.contains(identifier) {
                for clause in dependencyClauses(of: package) {
                    // One way of meeting the clause that stays is enough.
                    let met = clause.contains { name in
                        (carriers[name] ?? []).contains { !candidates.contains($0) && !removedIdentifiers.contains($0) }
                    }
                    guard !met else { continue }
                    for name in clause {
                        for carrier in carriers[name] ?? [] where candidates.remove(carrier) != nil {
                            changed = true
                        }
                    }
                }
            }
        }

        // A dependency is never taken along if the device cannot do without it.
        return candidates.compactMap { identifier in
            guard let package = installed[identifier] else { return nil }
            return DownloadManager.isSystemPackage(package) ? nil : package
        }
    }

    /// Of these packages, the ones a package that stays still needs, directly or
    /// through a name they provide.
    static func neededByStaying(_ identifiers: Set<String>,
                                removing: Set<String>,
                                installed: [String: Package]) -> Set<String> {
        guard !identifiers.isEmpty else { return [] }
        let carriers = providers(among: Set(installed.keys), installed: installed)
        var needed = Set<String>()
        for (identifier, package) in installed
        where !removing.contains(identifier) && !identifiers.contains(identifier) {
            for clause in dependencyClauses(of: package) {
                let met = clause.contains { name in
                    (carriers[name] ?? []).contains { !identifiers.contains($0) && !removing.contains($0) }
                }
                guard !met else { continue }
                for name in clause {
                    for carrier in carriers[name] ?? [] where identifiers.contains(carrier) {
                        needed.insert(carrier)
                    }
                }
            }
        }
        return needed
    }
}
