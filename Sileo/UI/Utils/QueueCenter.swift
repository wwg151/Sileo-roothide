//
//  QueueCenter.swift
//  Sileo
//
//  The queue's new front end: a floating capsule above the tab bar while a
//  task runs away from its page, a native sheet to manage the queue, and an
//  in-place ring on the button that started a task. The legacy popup bar is
//  retired; DownloadManager itself is untouched.
//

import UIKit

// MARK: - Snapshot types

enum QueueItemState {
    case waiting
    case downloading(CGFloat)
    case converting
    case installing
    case uninstalling
    case failed(String?)
}

struct QueueItem {
    let identifier: String
    let name: String
    let version: String
    let isRemoval: Bool
    let state: QueueItemState
    /// 0…1 while apt works through the batch
    var aptFraction: CGFloat = 0
    /// 0…1 while the roothide conversion runs
    var convertingFraction: CGFloat = 0
    /// a failed task whose log has been read: it can be removed now
    var failureRead = false
    /// 0 for the package the user queued, 1 for a dependency queued for it
    var groupRank = 0
    /// the order the entry was added in, so rows keep their place
    var sequence = 0
    /// 0…1 across the whole task: the download, its conversion, then apt
    var taskFraction: CGFloat?
    /// "1.2 MB/s" while a download moves
    var speedText: String?
    /// what apt says is missing or in the way, for a task that cannot run
    var hint: String?
    /// the download is held
    var isPaused = false

    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    var statusText: String {
        switch state {
        case .waiting: return String(localizationKey: "Queue_Waiting")
        case .downloading: return String(localizationKey: "Queue_Downloading")
        case .converting: return String(localizationKey: "Queue_Converting")
        case .installing: return String(localizationKey: "Queue_Installing")
        case .uninstalling: return String(localizationKey: "Queue_Uninstalling")
        case .failed(let reason): return reason ?? String(localizationKey: "Queue_Failed")
        }
    }

    var progress: CGFloat? {
        taskFraction
    }
}

// MARK: - Snapshot from DownloadManager

/// Byte samples for the speed readout; only touched on the snapshot queue.
private var queueSpeedSamples: [String: (bytes: Int64, at: Date)] = [:]

extension DownloadManager {

    /// Every entry of the queue, with the state the new UI shows, and whether
    /// every download is already in. The sets live on the apt queue, so the
    /// snapshot is built off the main thread — mid-download that queue can be
    /// busy for seconds.
    func queueSnapshot(elapsed: TimeInterval, downloadElapsed: TimeInterval, paused: Set<String>,
                       _ completion: @escaping ([QueueItem], Bool, Bool, Bool) -> Void) {
        // read on the main thread: the centre's own set is not thread safe
        let readFailures = QueueCenter.shared.readFailuresSnapshot()
        QueueCenter.snapshotQueue.async {
            let result = self.buildSnapshot(readFailures: readFailures, paused: paused,
                                            elapsed: elapsed, downloadElapsed: downloadElapsed)
            DispatchQueue.main.async { completion(result.0, result.1, result.2, result.3) }
        }
    }

    /// Bytes per second, from the samples of the last snapshot.
    private func downloadSpeedText(for identifier: String, download: Download, now: Date) -> String? {
        let bytes = download.totalBytesWritten
        guard let last = queueSpeedSamples[identifier] else {
            queueSpeedSamples[identifier] = (bytes, now)
            return nil
        }
        let interval = now.timeIntervalSince(last.at)
        guard interval >= 0.4 else { return nil }
        queueSpeedSamples[identifier] = (bytes, now)
        let speed = Double(bytes - last.bytes) / interval
        guard speed > 0 else { return nil }
        if speed >= 1024 * 1024 {
            return String(format: "%.1f MB/s", speed / 1024 / 1024)
        }
        return String(format: "%.0f KB/s", speed / 1024)
    }

    /// The download's share of the bar: the reported fraction, or the bytes
    /// when a server sends no length at all.
    private func downloadFraction(_ download: Download) -> CGFloat {
        if download.progress > 0 { return min(1, download.progress) }
        guard download.totalBytesExpectedToWrite > 0 else { return 0 }
        return min(1, CGFloat(download.totalBytesWritten) / CGFloat(download.totalBytesExpectedToWrite))
    }

    private func buildSnapshot(readFailures: Set<String>, paused: Set<String>, elapsed: TimeInterval,
                               downloadElapsed: TimeInterval) -> ([QueueItem], Bool, Bool, Bool) {
        var items: [QueueItem] = []
        let downloads = vars.queuedDownloads.raw
        let aptActive = aptRunning && !aptFinished
        let sampledAt = Date()
        // an empty download map means the downloads have not been queued yet —
        // apt names what is missing or in the way for a package it refuses
        let broken = vars.errors.raw
        func brokenHint(for identifier: String) -> String? {
            guard let error = broken.first(where: { $0.packageID == identifier }) else { return nil }
            let parts = error.conflictingPackages.map { conflict -> String in
                var name = conflict.package
                if let summary = conflict.versionSummary { name += "(\(summary))" }
                return "\(conflict.conflict.localizedName) \(name)"
            }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        // only an uninstall-only batch is truly ready at that point
        let installCount = vars.installations.raw.count + vars.upgrades.raw.count + vars.installdeps.raw.count
        let allDownloaded: Bool
        if downloads.isEmpty {
            allDownloaded = installCount == 0
        } else {
            // success is set once the file is in place: progress alone can be
            // 1 while the archive is still being moved, and apt would read a
            // file that is not there yet
            allDownloaded = downloads.values.allSatisfy { $0.success }
        }

        let aptFraction = QueueCenter.shared.aptFraction
        let hasConversion = downloads.values.contains { $0.converting || $0.didConvert }
        // The bar belongs to the whole task and follows real time: what is
        // already behind us over what is left, where what is left comes from
        // the download's own speed and, once apt runs, from its own rate. So a
        // download that took a tenth of the task leaves the bar at a tenth,
        // and one that took a fifth leaves it at a fifth.
        let now = max(0.001, elapsed)
        var remaining: Double
        if aptActive {
            // everything after the downloads belongs to apt
            let aptElapsed = max(0.3, now - max(0, downloadElapsed))
            let progress = Double(max(aptFraction, 0.03))
            remaining = aptElapsed * (1 - progress) / progress
        } else {
            // still downloading, or converting: the install has not been timed
            // yet, so it is guessed from the number of packages
            var guess = Double(max(installCount, 1)) * 1.2
            let expected = downloads.values.reduce(0.0) { $0 + Double($1.totalBytesExpectedToWrite) }
            let written = downloads.values.reduce(0.0) { $0 + Double($1.totalBytesWritten) }
            if expected > 0, written > 0, now > 0.6 {
                let speed = written / now
                guess += max(0, (expected - written) / max(speed, 1))
            } else {
                guess += 3
            }
            remaining = guess
        }
        let batchFraction = CGFloat(min(0.99, max(0, now / (now + max(remaining, 0.2)))))
        func taskFraction(for state: QueueItemState) -> CGFloat? {
            switch state {
            case .downloading, .converting, .installing, .uninstalling:
                return batchFraction
            case .waiting, .failed:
                return nil
            }
        }
        var sequence = 0
        func add(_ set: Set<DownloadPackage>, removal: Bool, group: Int) {
            for entry in set.sorted(by: { ($0.package.name ?? $0.package.package) < ($1.package.name ?? $1.package.package) }) {
                let package = entry.package
                let identifier = package.package
                let state: QueueItemState
                if let download = downloads[identifier] {
                    if download.failureReason != nil {
                        state = .failed(download.failureReason)
                    } else if download.converting || (download.message != nil && !download.completed) {
                        // the roothide conversion runs inside the download's slot
                        state = .converting
                    } else if download.started && !download.completed && !download.success {
                        state = .downloading(downloadFraction(download))
                    } else if aptActive {
                        state = removal ? .uninstalling : .installing
                    } else {
                        state = .waiting
                    }
                } else if aptActive {
                    state = removal ? .uninstalling : .installing
                } else {
                    state = .waiting
                }
                let converting = { if case .converting = state { return true }; return false }()
                let downloading = { if case .downloading = state { return true }; return false }()
                let speed = downloading
                    ? downloads[identifier].flatMap { downloadSpeedText(for: identifier, download: $0, now: sampledAt) }
                    : nil
                items.append(QueueItem(identifier: identifier,
                                       name: package.name ?? identifier,
                                       version: package.version,
                                       isRemoval: removal,
                                       state: state,
                                       aptFraction: aptActive ? aptFraction : 0,
                                       convertingFraction: converting ? 0.99 : 0,
                                       failureRead: readFailures.contains(identifier),
                                       groupRank: group,
                                       sequence: sequence,
                                       taskFraction: taskFraction(for: state),
                                       speedText: speed,
                                       hint: brokenHint(for: identifier),
                                       isPaused: paused.contains(identifier)))
                sequence += 1
            }
        }

        add(vars.installations.raw, removal: false, group: 0)
        add(vars.upgrades.raw, removal: false, group: 0)
        add(vars.uninstallations.raw, removal: true, group: 0)
        add(vars.installdeps.raw, removal: false, group: 1)
        add(vars.uninstalldeps.raw, removal: true, group: 1)

        // a download that lost its slot in the sets still shows while it runs
        let known = Set(items.map { $0.identifier })
        for (identifier, download) in downloads where !known.contains(identifier) {
            let state: QueueItemState
            if download.failureReason != nil {
                state = .failed(download.failureReason)
            } else if download.converting || (download.message != nil && !download.completed) {
                state = .converting
            } else if download.started && !download.completed && !download.success {
                state = .downloading(downloadFraction(download))
            } else {
                state = .waiting
            }
            items.append(QueueItem(identifier: identifier,
                                   name: download.package.name ?? identifier,
                                   version: download.package.version,
                                   isRemoval: false,
                                   state: state,
                                   convertingFraction: { if case .converting = state { return 0.99 }; return 0 }(),
                                   failureRead: readFailures.contains(identifier),
                                   groupRank: 1,
                                   sequence: sequence,
                                   taskFraction: taskFraction(for: state),
                                   speedText: { if case .downloading = state {
                                       return downloadSpeedText(for: identifier, download: download, now: sampledAt)
                                   }; return nil }(),
                                   hint: brokenHint(for: identifier),
                                   isPaused: paused.contains(identifier)))
            sequence += 1
        }

        let rank: (QueueItem) -> Int = { item in
            switch item.state {
            case .failed: return 0
            case .installing, .uninstalling: return 1
            case .converting: return 2
            case .downloading: return 3
            case .waiting: return 4
            }
        }
        return (items.sorted { a, b in
            // the package the user asked for stays on top, its dependencies
            // follow, and only then does the state decide
            if a.groupRank != b.groupRank { return a.groupRank < b.groupRank }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return a.sequence < b.sequence
        }, allDownloaded, !downloads.isEmpty, hasConversion)
    }
}

// MARK: - Center

final class QueueCenter {
    static let shared = QueueCenter()
    static let queueChangedNotification = Notification.Name("QueueCenterQueueChanged")

    static let snapshotQueue = DispatchQueue(label: "QueueCenter.snapshot", qos: .utility)

    private var capsule: QueueCapsuleView?
    private weak var sheetController: QueueSheetController?
    private var window: UIWindow?
    private var timer: Timer?
    private var timerInterval: TimeInterval = 0
    private var doneShownAt: Date?
    private var installFailed = false
    private(set) var sheetVisible = false
    private(set) var lastItems: [QueueItem] = []
    private var downloadPhase = false
    private var downloadPhaseSince: Date?
    private var handoffScheduled = false
    private var handedOff = false
    private var handoffAt: Date?
    private var autoSheetPending = false
    private(set) var holdForConfirmation = false
    private var readFailures: Set<String> = []
    private(set) var pausedDownloads: Set<String> = []
    private var batchStartedAt: Date?
    private var downloadEndedAt: Date?
    private var displayedFraction: CGFloat = 0
    private var lastAllDownloaded = false
    private var suspended = false
    private var aptTotal = 0
    private var aptCounted: Set<String> = []
    private var aptPartial: [String: CGFloat] = [:]
    private(set) var aptFraction: CGFloat = 0
    private var origins: [String: ObjectIdentifier] = [:]

    private init() {}

    // MARK: wiring

    /// The capsule lives in its own window: always centred, above the app's
    /// content, and it cannot be buried by a pushed page.
    func activate() {
        guard window == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive })
                as? UIWindowScene ?? UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let queueWindow = QueueWindow(windowScene: scene)
        queueWindow.windowLevel = .normal + 1
        queueWindow.backgroundColor = .clear
        let rootView = QueueWindowRootView()
        queueWindow.rootViewController = UIViewController()
        queueWindow.rootViewController?.view = rootView
        // touches that miss the capsule fall through to the app below

        let capsuleView = QueueCapsuleView(frame: .zero)
        capsuleView.onTap = { [weak self] in self?.presentSheet() }
        capsuleView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(capsuleView)
        rootView.hitTarget = capsuleView
        NSLayoutConstraint.activate([
            capsuleView.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            // the pill sits just above the floating tab bar, close to it
            capsuleView.bottomAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.bottomAnchor, constant: -82),
            capsuleView.heightAnchor.constraint(equalToConstant: 44)
        ])
        queueWindow.isHidden = true
        // the app's own window keeps the keyboard and the focus
        TabBarController.singleton?.view.window?.makeKey()
        window = queueWindow
        capsule = capsuleView

        // a respring (or the app going away) turns the screen black while this
        // process is still alive: the capsule must not float over that
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func appWillResignActive() {
        suspended = true
        window?.isHidden = true
    }

    @objc private func appDidBecomeActive() {
        suspended = false
        sync()
    }

    // MARK: states

    /// Called wherever the legacy popup was updated, and on a timer while busy.
    func sync() {
        DispatchQueue.main.async { self.syncNow() }
    }

    /// The result of one apt run: success clears the queue, a failure keeps
    /// the entries on screen with their reasons.
    func aptFinished(ok: Bool) {
        DispatchQueue.main.async {
            let manager = DownloadManager.shared
            manager.aptRunning = false
            manager.queueRunning = false
            manager.aptFinished = false
            if ok {
                self.doneShownAt = Date()
                self.installFailed = false
                // a finished batch leaves nothing behind
                manager.removeAllItems()
            } else {
                self.installFailed = true
                // the batch is kept: the user takes out what failed, and 重试
                // runs the rest again
            }
            self.downloadPhase = false
            self.handedOff = false
            self.handoffAt = nil
            self.autoSheetPending = false
            self.holdForConfirmation = false
            self.readFailures.removeAll()
            self.pausedDownloads.removeAll()
            self.batchStartedAt = nil
            self.downloadEndedAt = nil
            self.displayedFraction = 0
            self.aptFraction = ok ? 1 : self.aptFraction
            self.aptTotal = 0
            self.aptCounted.removeAll()
            self.aptPartial.removeAll()
            self.syncNow()
        }
    }

    /// A new apt run began: the previous result no longer applies.
    func installStarted() {
        DispatchQueue.main.async {
            self.installFailed = false
            self.doneShownAt = nil
            // a second apt pass in the same batch must not start the bar over
            let continuing = self.aptFraction > 0 || !self.aptCounted.isEmpty || !self.aptPartial.isEmpty
            if !continuing {
                self.aptTotal = max(DownloadManager.shared.operationCount(), 1)
                self.aptCounted.removeAll()
                self.aptPartial.removeAll()
                self.aptFraction = 0
            } else {
                self.aptTotal = max(self.aptTotal, DownloadManager.shared.operationCount())
            }
            self.syncNow()
        }
    }

    /// dpkg's own percentage for one package of the batch (0…1).
    func aptPackageProgress(_ identifier: String, fraction: CGFloat) {
        DispatchQueue.main.async {
            guard !identifier.isEmpty else { return }
            let clamped = max(0, min(1, fraction))
            if clamped >= 0.999 {
                self.aptPartial.removeValue(forKey: identifier)
                self.aptCounted.insert(identifier)
            } else {
                self.aptPartial[identifier] = clamped
            }
            let done = CGFloat(self.aptCounted.count) + self.aptPartial.values.reduce(0, +)
            // the last package of the batch takes the ring to 100%, before apt
            // exits and the queue clears
            var next = min(0.99, done / CGFloat(max(self.aptTotal, 1)))
            if self.aptTotal > 0, self.aptCounted.count >= self.aptTotal, self.aptPartial.isEmpty {
                next = 1
            }
            // dpkg reports very often: only redraw when the ring moves visibly
            guard abs(next - self.aptFraction) >= 0.005 else { return }
            // never backwards: a second pass in the same batch keeps the bar
            self.aptFraction = max(self.aptFraction, next)
            self.syncNow()
        }
    }

    /// Cancel everything, including the result still on screen.
    func cancelAll() {
        DispatchQueue.main.async {
            let manager = DownloadManager.shared
            manager.removeAllItems()
            manager.queueRunning = false
            manager.aptRunning = false
            manager.aptFinished = false
            self.downloadPhase = false
            self.handedOff = false
            self.handoffAt = nil
            self.autoSheetPending = false
            self.holdForConfirmation = false
            self.readFailures.removeAll()
            self.pausedDownloads.removeAll()
            self.batchStartedAt = nil
            self.downloadEndedAt = nil
            self.displayedFraction = 0
            self.installFailed = false
            self.doneShownAt = nil
            self.origins.removeAll()
            self.lastItems = []
            self.notifyPackageStateChanged()
            self.syncNow()
        }
    }

    /// The package lists draw a badge from the queue: tell them it moved.
    private func notifyPackageStateChanged() {
        NotificationCenter.default.post(name: PackageListManager.stateChange, object: false)
    }

    // MARK: execution

    private func startQueueIfNeeded(_ items: [QueueItem]) {
        let manager = DownloadManager.shared
        // one download phase per batch: after the handoff the sets still hold
        // the packages, and starting over would restart the downloads
        guard !handedOff else { return }
        // a failed batch waits for 重试: it must not start itself again
        guard !installFailed else { return }
        guard !items.isEmpty, !manager.queueRunning, !manager.aptRunning else { return }

        // a list, the news, a file or a batch import has no button to draw a
        // ring on: the queue opens and waits for 确认 before it runs anything
        if !QueueCenter.isButtonPage(QueueCenter.currentPageController()) {
            if !holdForConfirmation {
                holdForConfirmation = true
                autoSheetPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.presentSheetWhenSettled(3)
                }
            }
            return
        }
        beginDownloadPhase()
    }

    /// 确认 in the queue sheet: the batch the user has just read starts now.
    func confirmBatch() {
        DispatchQueue.main.async {
            guard self.holdForConfirmation else { return }
            self.holdForConfirmation = false
            // the downloads are already in: go straight to apt
            if self.downloadPhase, self.lastAllDownloaded {
                self.downloadPhaseSince = Date(timeIntervalSinceNow: -5)
                self.syncNow()
                return
            }
            self.beginDownloadPhase()
            self.syncNow()
        }
    }

    /// 取消 in the queue sheet: nothing of the batch runs.
    func discardBatch() {
        DispatchQueue.main.async {
            let manager = DownloadManager.shared
            self.holdForConfirmation = false
            self.autoSheetPending = false
            self.readFailures.removeAll()
            self.pausedDownloads.removeAll()
            self.batchStartedAt = nil
            self.downloadEndedAt = nil
            self.displayedFraction = 0
            self.downloadPhase = false
            self.handedOff = false
            self.handoffAt = nil
            manager.removeAllItems()
            manager.queueRunning = false
            manager.aptRunning = false
            manager.aptFinished = false
            self.lastItems = []
            self.origins.removeAll()
            self.notifyPackageStateChanged()
            self.syncNow()
        }
    }

    private func beginDownloadPhase() {
        let manager = DownloadManager.shared
        holdForConfirmation = false
        readFailures.removeAll()
        pausedDownloads.removeAll()
        batchStartedAt = Date()
        downloadEndedAt = nil
        displayedFraction = 0
        lastAllDownloaded = false
        manager.queueRunning = true
        manager.currentDownloads = 0
        manager.aptRunning = false
        manager.aptFinished = false
        downloadPhase = true
        downloadPhaseSince = Date()
        NotificationCenter.default.post(name: DownloadManager.lockStateChangeNotification, object: nil)
        manager.startDownloads()
    }

    /// Downloads are all in: hand the batch to apt. Nothing is presented for
    /// it: the capsule counts the install, and its sheet carries the log.
    private func checkAptHandoff(allDownloaded: Bool) {
        guard downloadPhase, !handoffScheduled, !handedOff, allDownloaded else { return }
        // a batch waiting for 确认 does not go on by itself
        guard !holdForConfirmation else { return }
        // a stale, fully-finished download map from the previous batch must not
        // hand off before this batch's downloads are even queued
        guard let since = downloadPhaseSince,
              Date().timeIntervalSince(since) >= 1.2 else { return }
        let manager = DownloadManager.shared
        guard manager.queueRunning, !manager.aptRunning, !manager.aptFinished,
              manager.operationCount() > 0 else { return }

        // never present while a page or a panel is mid-transition: UIKit
        // throws and the app dies. Wait a moment, then look again.
        handoffScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self = self else { return }
            self.handoffScheduled = false
            guard self.downloadPhase,
                  manager.queueRunning, !manager.aptRunning, !manager.aptFinished,
                  manager.operationCount() > 0 else { return }

            guard let tab = TabBarController.singleton, tab.view.window != nil else { return }
            var host: UIViewController = tab
            while let presented = host.presentedViewController { host = presented }
            guard host.viewIfLoaded?.window != nil,
                  !host.isBeingPresented, !host.isBeingDismissed else { return }
            // a page or a sheet still animating in would make UIKit throw
            guard host.transitionCoordinator == nil, tab.transitionCoordinator == nil else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.checkAptHandoff(allDownloaded: allDownloaded)
                }
                return
            }

            let controller = manager.viewController
            self.downloadPhase = false
            // straight into the install phase: confirmQueued would start the
            // downloads over again, and they are all in already
            let beginInstall: () -> Void = { [weak self, weak controller] in
                guard let self = self, let controller = controller else { return }
                self.handedOff = true
                self.handoffAt = Date()
                self.downloadEndedAt = Date()
                // a previous run leaves the page's own flags set; without this
                // transferToAction answers at once and apt never starts
                controller.prepareForQueueRun()
                controller.reloadData()
                controller.transferToAction()
            }
            let removals = manager.vars.uninstallations.raw.map { $0.package }
                + manager.vars.uninstalldeps.raw.map { $0.package }
            let essentials = removals.filter { manager.isEssential($0) }
            if essentials.isEmpty {
                beginInstall()
                return
            }
            let names = essentials.map { $0.name ?? $0.package }.joined(separator: "\n")
            let message = String(format: String(localizationKey: "Essential_Warning"), names)
            SileoPanelViewController.confirm(title: String(localizationKey: "Warning"),
                                             message: message,
                                             confirmTitle: String(localizationKey: "Dangerous_Repo.Last_Chance.Continue")) {
                beginInstall()
            }.present(from: host)
        }
    }

    func state(for identifier: String) -> QueueItemState? {
        guard let item = lastItems.first(where: { $0.identifier == identifier }) else { return nil }
        // a failure whose log has been read no longer holds the page's ring
        if item.isFailed && item.failureRead { return nil }
        return item.state
    }

    /// The task's share of its bar, for the ring on the page's own button.
    func progress(for identifier: String) -> CGFloat? {
        lastItems.first(where: { $0.identifier == identifier })?.progress
    }

    /// Pause or resume one download. The connection is held, not dropped, so
    /// resuming carries on from the bytes already received.
    func togglePause(_ identifier: String) {
        DispatchQueue.main.async {
            if self.pausedDownloads.contains(identifier) {
                self.pausedDownloads.remove(identifier)
                DownloadManager.shared.resumeDownload(package: identifier)
            } else {
                self.pausedDownloads.insert(identifier)
                DownloadManager.shared.pauseDownload(package: identifier)
            }
            self.syncNow()
        }
    }

    /// Whether every download of the batch is held.
    var allDownloadsPaused: Bool {
        let downloading = lastItems.filter {
            if case .downloading = $0.state { return true }
            return false
        }
        guard !downloading.isEmpty else { return false }
        return downloading.allSatisfy { self.pausedDownloads.contains($0.identifier) }
    }

    func setDownloadsPaused(_ paused: Bool) {
        DispatchQueue.main.async {
            for item in self.lastItems {
                guard case .downloading = item.state else { continue }
                if paused {
                    self.pausedDownloads.insert(item.identifier)
                    DownloadManager.shared.pauseDownload(package: item.identifier)
                } else {
                    self.pausedDownloads.remove(item.identifier)
                    DownloadManager.shared.resumeDownload(package: item.identifier)
                }
            }
            self.syncNow()
        }
    }

    /// Whether the batch on screen ended in a failure.
    var lastRunFailed: Bool {
        installFailed || lastItems.contains { $0.isFailed }
    }

    /// The result has been read: drop it, so the page's ring returns to its
    /// own button and the capsule goes away.
    func clearResult() {
        DispatchQueue.main.async {
            self.installFailed = false
            self.doneShownAt = nil
            self.lastItems = []
            self.origins.removeAll()
            self.handedOff = false
            self.handoffAt = nil
            self.downloadPhase = false
            self.autoSheetPending = false
            self.holdForConfirmation = false
            self.readFailures.removeAll()
            self.pausedDownloads.removeAll()
            self.batchStartedAt = nil
            self.downloadEndedAt = nil
            self.displayedFraction = 0
            self.syncNow()
        }
    }

    /// ✕ on a row: the package leaves the batch. A dependency takes the
    /// package that asked for it along; a package on its own leaves its
    /// dependencies where they are.
    func removeFromBatch(_ identifier: String) {
        DispatchQueue.main.async {
            let manager = DownloadManager.shared
            let dependencies = manager.vars.installdeps.raw.map { $0.package }
                + manager.vars.uninstalldeps.raw.map { $0.package }
            let isDependency = dependencies.contains { $0.package == identifier }
            if isDependency {
                // a dependency does not go on its own: the package that asked
                // for it leaves too
                let mains = manager.vars.installations.raw.map { $0.package }
                    + manager.vars.upgrades.raw.map { $0.package }
                let all = mains + dependencies
                var dependent = mains.filter { self.depends($0, on: identifier, among: all) }
                if dependent.isEmpty { dependent = mains }
                for main in dependent {
                    manager.remove(package: main.package)
                }
            }
            manager.forgetDownload(package: identifier)
            manager.remove(package: identifier)
            // a failed row lives only in the centre's own list, not in apt's
            if self.lastItems.contains(where: { $0.identifier == identifier && $0.isFailed }) {
                self.lastItems.removeAll { $0.identifier == identifier }
                self.readFailures.remove(identifier)
                if !self.lastItems.contains(where: { $0.isFailed }) {
                    self.installFailed = false
                    self.doneShownAt = nil
                }
            }
            if isDependency, !manager.queueRunning, !manager.aptRunning {
                // the package that asked for it is gone: let apt work the
                // remaining dependencies out again
                manager.reloadData(recheckPackages: true)
            }
            // a download failed while the rest went on: with the bad one gone
            // the batch waits for 确认 instead of installing by itself
            if self.downloadPhase, !self.installFailed,
               !self.lastItems.contains(where: { $0.isFailed }) {
                self.holdForConfirmation = true
                self.autoSheetPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.presentSheetWhenSettled(3)
                }
            }
            self.notifyPackageStateChanged()
            self.syncNow()
        }
    }

    /// Whether the log of this failed task has been read: its row offers ✕.
    func hasReadFailure(_ identifier: String) -> Bool {
        readFailures.contains(identifier)
    }

    /// The snapshot is built off the main thread, so it takes a copy.
    func readFailuresSnapshot() -> Set<String> {
        readFailures
    }

    /// 完成 in the log sheet: the failure is read, and its row can be removed.
    func markFailureRead() {
        DispatchQueue.main.async {
            for item in self.lastItems where item.isFailed {
                self.readFailures.insert(item.identifier)
            }
            self.syncNow()
        }
    }

    /// Names a package depends on, whatever the case of the field and however
    /// the alternatives are written.
    private func dependencyNames(of package: Package) -> [String] {
        var names: [String] = []
        for key in ["depends", "pre-depends", "Depends", "Pre-Depends"] {
            guard let raw = package.rawControl[key], !raw.isEmpty else { continue }
            for group in raw.components(separatedBy: ",") {
                for alternative in group.components(separatedBy: "|") {
                    let name = alternative
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .components(separatedBy: CharacterSet(charactersIn: " (:[<"))
                        .first ?? ""
                    if !name.isEmpty { names.append(name) }
                }
            }
        }
        return names
    }

    /// Whether this package needs `identifier`, directly or through the other
    /// packages of the batch.
    private func depends(_ package: Package, on identifier: String, among all: [Package]) -> Bool {
        var seen = Set<String>()
        var pending = dependencyNames(of: package)
        while let name = pending.popLast() {
            if name == identifier { return true }
            guard seen.insert(name).inserted else { continue }
            if let next = all.first(where: { $0.package == name }) {
                pending += dependencyNames(of: next)
            }
        }
        return false
    }

    private func syncNow() {
        // Building the snapshot touches the apt queue's containers: never do
        // that on the main thread, the queue can be busy for seconds mid-download.
        let elapsed = batchStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let downloadElapsed = downloadEndedAt.map { $0.timeIntervalSince(batchStartedAt ?? $0) } ?? 0
        DownloadManager.shared.queueSnapshot(elapsed: elapsed, downloadElapsed: downloadElapsed,
                                             paused: pausedDownloads) {
            [weak self] items, allDownloaded, hadDownloads, hadConversion in
            self?.applySnapshot(items, allDownloaded: allDownloaded,
                                hadDownloads: hadDownloads, hadConversion: hadConversion)
        }
    }

    private func applySnapshot(_ snapshot: [QueueItem], allDownloaded: Bool,
                               hadDownloads: Bool, hadConversion: Bool) {
        var items = snapshot
        lastAllDownloaded = allDownloaded
        // between the last download and apt the task is on its way to install:
        // show it as installing instead of flashing 等待开始
        if downloadPhase && allDownloaded {
            // the bar keeps where the download left it until apt reports
            let handedShare = hadDownloads ? displayedFraction : 0
            items = items.map { item in
                guard case .waiting = item.state else { return item }
                return QueueItem(identifier: item.identifier,
                                 name: item.name,
                                 version: item.version,
                                 isRemoval: item.isRemoval,
                                 state: item.isRemoval ? .uninstalling : .installing,
                                 aptFraction: 0,
                                 failureRead: item.failureRead,
                                 taskFraction: handedShare)
            }
        }
        // the bar of a running task never stands still and never goes back: it
        // walks on with every tick, whatever the estimate does
        // a held task does not move: the bar stays where the user stopped it
        let active = items.filter { $0.taskFraction != nil }
        let everyTaskHeld = !active.isEmpty && active.allSatisfy { $0.isPaused }
        if everyTaskHeld {
            items = items.map { item in
                guard item.taskFraction != nil else { return item }
                var copy = item
                copy.taskFraction = displayedFraction
                return copy
            }
        } else if let estimate = items.compactMap({ $0.taskFraction }).max() {
            // a small share of what is left, so it never overtakes the end
            let creep = displayedFraction + (1 - displayedFraction) * 0.004
            let next = min(0.995, max(estimate, creep))
            displayedFraction = next
            items = items.map { item in
                guard item.taskFraction != nil else { return item }
                var copy = item
                copy.taskFraction = next
                return copy
            }
        }
        for item in items where origins[item.identifier] == nil {
            origins[item.identifier] = QueueCenter.currentPageIdentifier()
        }

        // The batch was handed to apt, apt is not running any more, and its
        // completion never came back: without this the ring and the capsule
        // would sit on 等待开始 forever.
        let manager = DownloadManager.shared
        let aptActive = manager.aptRunning && !manager.aptFinished
        if handedOff, !downloadPhase, !aptActive,
           let at = handoffAt, Date().timeIntervalSince(at) > 3 {
            handedOff = false
            handoffAt = nil
            manager.removeAllItems()
            items = []
            installFailed = true
        }

        let hasFailure = installFailed || items.contains { $0.isFailed }

        // the batch was emptied while it waited (each row can be removed):
        // nothing is left to confirm
        if holdForConfirmation, items.isEmpty {
            holdForConfirmation = false
        }

        // The legacy popup carried the 开始 button that started the queue;
        // the queue now starts itself the moment something is queued.
        startQueueIfNeeded(items)

        if !items.isEmpty && !installFailed {
            // a new run supersedes the previous result
            doneShownAt = nil
        } else if let done = doneShownAt, Date().timeIntervalSince(done) >= 2 {
            doneShownAt = nil
        }

        // downloads all in: hand the batch to apt
        checkAptHandoff(allDownloaded: allDownloaded)

        // The capsule yields to the page that shows the task's own ring.
        // The capsule is the queue's door: it is there whenever the queue has
        // something in it, so the sheet can always be opened again after it
        // was swiped away.
        // the sheet is what hides it: trust the screen, not a flag
        if sheetVisible, let sheet = sheetController, sheet.presentingViewController == nil {
            sheetVisible = false
        }
        // only a queue with something in it, and only while its sheet is away
        let showCapsule = !items.isEmpty && !sheetVisible

        // Without entries the failure note stands alone until the queue runs again.
        if installFailed {
            // the run failed: every row of the batch shows it, whether the
            // manager still holds the packages or they were cleared
            if items.isEmpty {
                items = lastItems
            }
            items = items.map { item in
                let read = hasReadFailure(item.identifier)
                if case .failed = item.state {
                    var copy = item
                    copy.failureRead = read
                    return copy
                }
                return QueueItem(identifier: item.identifier, name: item.name, version: item.version,
                                 isRemoval: item.isRemoval, state: .failed(nil), failureRead: read)
            }
        }
        lastItems = items

        if items.isEmpty && !hasFailure {
            origins.removeAll()
        }

        // nothing left to watch: the sheet closes by itself, unless the batch
        // failed and its log is the point
        if sheetVisible, items.isEmpty, !hasFailure, let sheet = sheetController,
           sheet.presentingViewController != nil {
            sheet.dismiss(animated: true)
        }

        updateCapsule(visible: showCapsule, count: items.count)
        NotificationCenter.default.post(name: QueueCenter.queueChangedNotification, object: nil)
        restartTimer()
    }

    // The page a task came from is remembered the first time it is seen, so a
    // single task hides the capsule while its own page is on screen.

    static func currentPageIdentifier() -> ObjectIdentifier? {
        currentPageController().map { ObjectIdentifier($0) }
    }

    static func currentPageController() -> UIViewController? {
        guard let tab = TabBarController.singleton else { return nil }
        var controller = tab.selectedViewController
        if let navigation = controller as? UINavigationController {
            controller = navigation.topViewController
        }
        if let split = controller as? UISplitViewController {
            controller = split.viewControllers.first
            if let navigation = controller as? UINavigationController {
                controller = navigation.topViewController
            }
        }
        return controller
    }

    /// The pages that carry the install button themselves: there the ring on
    /// the button is the progress, and no sheet is thrown over the page.
    static func isButtonPage(_ controller: UIViewController?) -> Bool {
        controller is PackageViewController || controller is FeaturedViewController
    }

    private func restartTimer() {
        // keep polling while anything is queued, even when the capsule is
        // hidden: the button on the page draws its own ring from these ticks
        let busy = !lastItems.isEmpty || sheetVisible || capsule?.isHidden == false
        let downloading = lastItems.contains {
            if case .downloading = $0.state { return true }
            return false
        }
        let interval: TimeInterval = downloading ? 0.35 : 0.8
        if busy {
            if timer == nil || timerInterval != interval {
                timer?.invalidate()
                let fresh = Timer(timeInterval: interval, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
                RunLoop.main.add(fresh, forMode: .common)
                timer = fresh
                timerInterval = interval
            }
        } else if let running = timer {
            running.invalidate()
            timer = nil
        }
    }

    @objc private func tick() {
        syncNow()
    }

    // MARK: capsule

    private func updateCapsule(visible: Bool, count: Int) {
        guard let capsule = capsule else { return }
        // the app is leaving (respring): nothing of ours stays on the screen
        if suspended {
            window?.isHidden = true
            capsule.isHidden = true
            return
        }
        if visible {
            capsule.configure(count: count)
            if window?.isHidden != false {
                window?.isHidden = false
                // showing a window can take the key: hand it back to the app
                TabBarController.singleton?.view.window?.makeKey()
            }
            if capsule.isHidden || capsule.alpha < 1 {
                // a hide that was cut short can leave it visible but clear:
                // either way it has to come back
                capsule.isHidden = false
                capsule.alpha = max(capsule.alpha, 0)
                UIView.animate(withDuration: 0.3, delay: 0,
                               usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
                               options: [.curveEaseOut, .beginFromCurrentState]) {
                    capsule.alpha = 1
                    capsule.transform = .identity
                }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        } else if !capsule.isHidden {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseIn], animations: {
                capsule.alpha = 0
                capsule.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
            }, completion: { _ in
                capsule.isHidden = true
                capsule.transform = .identity
                // nothing to show: the overlay window goes away entirely
                self.window?.isHidden = true
            })
        }
        restartTimer()
    }

    // MARK: sheet

    @discardableResult
    func presentSheet() -> Bool {
        guard !sheetVisible else { return false }
        guard let host = TabBarController.singleton else { return false }
        // whatever is already up (the log page, for instance) must not be
        // replaced by UIKit's "already presenting" exception
        var top: UIViewController = host
        while let presented = top.presentedViewController { top = presented }
        guard !top.isBeingPresented, !top.isBeingDismissed, top.viewIfLoaded?.window != nil else { return false }
        let sheet = QueueSheetController()
        sheet.modalPresentationStyle = .pageSheet
        if let presentation = sheet.sheetPresentationController {
            presentation.detents = [.medium(), .large()]
            presentation.prefersGrabberVisible = true
        }
        sheetVisible = true
        autoSheetPending = false
        sheetController = sheet
        top.present(sheet, animated: true) {
            self.restartTimer()
        }
        return true
    }

    /// A batch started somewhere without a button to show it on: open the
    /// queue, and try again if the page was still animating.
    private func presentSheetWhenSettled(_ attempts: Int) {
        guard autoSheetPending, attempts > 0 else { return }
        // an empty queue has nothing to show: never open a blank sheet
        guard !lastItems.isEmpty else {
            autoSheetPending = false
            return
        }
        if presentSheet() { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.presentSheetWhenSettled(attempts - 1)
        }
    }

    func sheetClosed() {
        sheetVisible = false
        autoSheetPending = false
        // the batch waits where it is: the capsule brings the sheet back, and
        // 确认 is still there when it opens
        syncNow()
        restartTimer()
    }

    func sheetReappeared() {
        sheetVisible = true
        restartTimer()
    }
}

// MARK: - Capsule window root

/// A window that lets every touch it cannot place fall through to the app.
final class QueueWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // UIView.hitTest answers the window itself when nothing inside claims
        // the point; that would swallow the touch, so hand it back instead.
        return hit === self ? nil : hit
    }
}

/// The root view of the capsule's window: every touch that is not on the
/// capsule itself is passed on to the windows below.
final class QueueWindowRootView: UIView {

    weak var hitTarget: UIView?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let target = hitTarget, !target.isHidden, target.alpha > 0.01 else { return nil }
        let local = convert(point, to: target)
        return target.hitTest(local, with: event)
    }
}

// MARK: - Capsule view

final class QueueCapsuleView: UIView {

    var onTap: (() -> Void)?

    private let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .systemBackground
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 5)
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.separator.withAlphaComponent(0.5).cgColor

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 1
        addSubview(titleLabel)

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isHidden = true
        configure(count: 0)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func tapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onTap?()
    }

    /// The pill is only the door to the queue: no state, no progress.
    func configure(count: Int) {
        titleLabel.text = String(localizationKey: "Queue_Entry") + " "
            + String(format: String(localizationKey: "Queue_Items"), count)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: max(88, ceil(titleLabel.intrinsicContentSize.width) + 44), height: 44)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = ceil(titleLabel.intrinsicContentSize.height)
        titleLabel.frame = CGRect(x: 22, y: (bounds.height - height) / 2,
                                  width: max(0, bounds.width - 44), height: height)
    }
}

// MARK: - In-place ring overlay

final class QueueRingOverlay: UIView {

    private let trackLayer = CAShapeLayer()
    private let ringLayer = CAShapeLayer()
    private let percentLayer = CATextLayer()
    private let captionLayer = CATextLayer()

    private static let lineWidth: CGFloat = 8
    private static let captionHeight: CGFloat = 18

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        // the design: a large ring, the percentage inside it, the state below
        trackLayer.fillColor = UIColor.clear.cgColor
        trackLayer.strokeColor = UIColor.tertiarySystemFill.cgColor
        trackLayer.lineWidth = QueueRingOverlay.lineWidth
        layer.addSublayer(trackLayer)

        ringLayer.fillColor = UIColor.clear.cgColor
        ringLayer.strokeColor = UIColor.tintColor.cgColor
        ringLayer.lineWidth = QueueRingOverlay.lineWidth
        ringLayer.lineCap = .round
        layer.addSublayer(ringLayer)

        percentLayer.string = ""
        percentLayer.fontSize = 20
        percentLayer.alignmentMode = .center
        percentLayer.contentsScale = UIScreen.main.scale
        percentLayer.foregroundColor = UIColor.tintColor.cgColor
        layer.addSublayer(percentLayer)

        captionLayer.string = ""
        captionLayer.fontSize = 13
        captionLayer.alignmentMode = .center
        captionLayer.contentsScale = UIScreen.main.scale
        captionLayer.foregroundColor = UIColor.secondaryLabel.cgColor
        layer.addSublayer(captionLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var fraction: CGFloat = 0

    func configure(percent: String?, caption: String, fraction: CGFloat?, failed: Bool) {
        let accent: UIColor = failed ? .systemRed : .tintColor
        ringLayer.strokeColor = accent.cgColor
        percentLayer.string = percent
        percentLayer.foregroundColor = accent.cgColor
        captionLayer.string = caption
        captionLayer.foregroundColor = (failed ? UIColor.systemRed : UIColor.secondaryLabel).cgColor

        let target = fraction ?? 0
        if abs(target - self.fraction) > 0.001 {
            let animation = CABasicAnimation(keyPath: "strokeEnd")
            animation.fromValue = ringLayer.presentation()?.strokeEnd ?? self.fraction
            animation.toValue = target
            animation.duration = 0.3
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ringLayer.add(animation, forKey: "strokeEnd")
        }
        self.fraction = target
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // a compact ring with its caption underneath, always both
        let captionHeight: CGFloat = 16
        let diameter = max(24, min(bounds.width, bounds.height - captionHeight - 6))
        let lineWidth: CGFloat = 4
        let radius = max(6, diameter / 2 - lineWidth / 2)
        let center = CGPoint(x: bounds.midX, y: diameter / 2 + 2)
        let path = UIBezierPath(arcCenter: center, radius: radius,
                                startAngle: -.pi / 2, endAngle: .pi * 3 / 2,
                                clockwise: true).cgPath
        trackLayer.frame = bounds
        ringLayer.frame = bounds
        trackLayer.lineWidth = lineWidth
        ringLayer.lineWidth = lineWidth
        trackLayer.path = path
        ringLayer.path = path
        ringLayer.strokeEnd = fraction

        percentLayer.fontSize = diameter >= 44 ? 13 : 11
        percentLayer.frame = CGRect(x: center.x - diameter / 2,
                                    y: center.y - 9,
                                    width: diameter,
                                    height: 18)
        captionLayer.isHidden = false
        captionLayer.fontSize = 12
        captionLayer.frame = CGRect(x: 0,
                                    y: diameter + 6,
                                    width: bounds.width,
                                    height: captionHeight)
    }
}

// MARK: - Sheet

final class QueueSheetController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let table = UITableView(frame: .zero, style: .plain)
    private var items: [QueueItem] = []
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private let clearButton = UIButton(type: .system)
    private var rowTimer: Timer?
    private let pauseAllButton = UIButton(type: .system)
    private var actionFullConstraints: [NSLayoutConstraint] = []
    private var actionSplitConstraints: [NSLayoutConstraint] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationController?.setNavigationBarHidden(true, animated: false)

        titleLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = .label
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabel
        let header = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        header.axis = .vertical
        header.spacing = 2
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        pauseAllButton.translatesAutoresizingMaskIntoConstraints = false
        pauseAllButton.titleLabel?.font = .systemFont(ofSize: 15)
        pauseAllButton.setTitleColor(.tintColor, for: .normal)
        pauseAllButton.isHidden = true
        pauseAllButton.addAction(UIAction { _ in
            QueueCenter.shared.setDownloadsPaused(!QueueCenter.shared.allDownloadsPaused)
        }, for: .touchUpInside)
        view.addSubview(pauseAllButton)

        table.translatesAutoresizingMaskIntoConstraints = false
        table.dataSource = self
        table.delegate = self
        table.separatorStyle = .none
        table.backgroundColor = .clear
        // without this the table holds every touch for a moment, and a button
        // inside a row needs a second tap to answer
        table.delaysContentTouches = false
        // a touch that drifts a pixel must not be taken away from the button
        table.canCancelContentTouches = false
        table.register(UITableViewCell.self, forCellReuseIdentifier: "QueueCard")
        view.addSubview(table)

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        actionButton.backgroundColor = .tintColor
        actionButton.setTitleColor(.white, for: .normal)
        actionButton.layer.cornerRadius = 22
        actionButton.layer.cornerCurve = .continuous
        actionButton.addAction(UIAction { [weak self] _ in self?.primaryAction() }, for: .touchUpInside)
        view.addSubview(actionButton)

        // the left button empties the queue in one go; 确认 keeps its place
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        clearButton.setTitle(String(localizationKey: "Queue_Clear"), for: .normal)
        clearButton.setTitleColor(.label, for: .normal)
        clearButton.backgroundColor = .tertiarySystemFill
        clearButton.layer.cornerRadius = 22
        clearButton.layer.cornerCurve = .continuous
        clearButton.addAction(UIAction { [weak self] _ in
            QueueCenter.shared.cancelAll()
            self?.dismiss(animated: true)
        }, for: .touchUpInside)
        clearButton.isHidden = true
        view.addSubview(clearButton)

        actionFullConstraints = [
            actionButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            actionButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ]
        actionSplitConstraints = [
            clearButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            clearButton.widthAnchor.constraint(equalTo: actionButton.widthAnchor),
            clearButton.heightAnchor.constraint(equalTo: actionButton.heightAnchor),
            clearButton.centerYAnchor.constraint(equalTo: actionButton.centerYAnchor),
            actionButton.leadingAnchor.constraint(equalTo: clearButton.trailingAnchor, constant: 10),
            actionButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ]

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            header.trailingAnchor.constraint(lessThanOrEqualTo: pauseAllButton.leadingAnchor, constant: -8),
            pauseAllButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            pauseAllButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            table.bottomAnchor.constraint(equalTo: actionButton.topAnchor, constant: -12),
            actionButton.heightAnchor.constraint(equalToConstant: 44),
            actionButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ] + actionFullConstraints)

        NotificationCenter.default.addObserver(forName: QueueCenter.queueChangedNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        QueueCenter.shared.sheetReappeared()
        reload()
        startRowRefresh()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        rowTimer?.invalidate()
        rowTimer = nil
        QueueCenter.shared.sheetClosed()
    }

    /// The bars are moved in place on a short timer: rebuilding the rows three
    /// times a second made the progress look frozen between two snapshots.
    private func startRowRefresh() {
        rowTimer?.invalidate()
        rowTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshVisibleRows()
        }
        if let rowTimer = rowTimer {
            RunLoop.main.add(rowTimer, forMode: .common)
        }
    }

    private func refreshVisibleRows() {
        let snapshot = QueueCenter.shared.lastItems
        guard snapshot.map({ $0.identifier }) == items.map({ $0.identifier }) else {
            reload()
            return
        }
        items = snapshot
        updateVisibleRows()
    }

    private func reload() {
        // the centre keeps the last snapshot, failures included, even after
        // the manager has emptied the queue
        let snapshot = QueueCenter.shared.lastItems
        // a new hint changes the row height, so the table has to be told
        let rowsChanged = snapshot.map { "\($0.identifier)|\($0.hint ?? "")" }
            != items.map { "\($0.identifier)|\($0.hint ?? "")" }
        items = snapshot
        let failed = snapshot.filter { $0.isFailed }.count
        let allHeld = !snapshot.isEmpty && snapshot.allSatisfy { $0.isPaused }
        titleLabel.text = String(localizationKey: "Queue_Title")
        if failed > 0 {
            subtitleLabel.text = String(format: String(localizationKey: "Queue_Failed_N"), failed)
            subtitleLabel.textColor = .systemRed
        } else if allHeld {
            subtitleLabel.text = String(format: String(localizationKey: "Queue_Paused_N"), snapshot.count)
            subtitleLabel.textColor = .secondaryLabel
        } else {
            subtitleLabel.text = String(format: String(localizationKey: "Queue_Items"), snapshot.count)
            subtitleLabel.textColor = .secondaryLabel
        }
        let hasDownloading = snapshot.contains {
            if case .downloading = $0.state { return true }
            return false
        }
        pauseAllButton.isHidden = !hasDownloading
        pauseAllButton.setTitle(QueueCenter.shared.allDownloadsPaused
            ? String(localizationKey: "Queue_Resume_All")
            : String(localizationKey: "Queue_Pause_All"), for: .normal)
        let held = QueueCenter.shared.holdForConfirmation && !snapshot.isEmpty
        let anyFailed = snapshot.contains { $0.isFailed }
        // the left button clears everything, and is there whenever a row is
        let showClear = !snapshot.isEmpty
        if showClear {
            NSLayoutConstraint.deactivate(actionFullConstraints)
            NSLayoutConstraint.activate(actionSplitConstraints)
            clearButton.isHidden = false
        } else {
            NSLayoutConstraint.deactivate(actionSplitConstraints)
            NSLayoutConstraint.activate(actionFullConstraints)
            clearButton.isHidden = true
        }
        if held {
            actionButton.setTitle(String(localizationKey: "Queue_Confirm_Button"), for: .normal)
            actionButton.backgroundColor = .tintColor
            actionButton.setTitleColor(.white, for: .normal)
        } else if snapshot.isEmpty {
            actionButton.setTitle(String(localizationKey: "Done"), for: .normal)
            actionButton.backgroundColor = .tertiarySystemFill
            actionButton.setTitleColor(.label, for: .normal)
        } else if anyFailed {
            actionButton.setTitle(String(localizationKey: "Queue_View_Log"), for: .normal)
            actionButton.backgroundColor = .tintColor
            actionButton.setTitleColor(.white, for: .normal)
        } else if hasDownloading {
            actionButton.setTitle(QueueCenter.shared.allDownloadsPaused
                ? String(localizationKey: "Queue_Resume_All")
                : String(localizationKey: "Queue_Pause_All"), for: .normal)
            actionButton.backgroundColor = .tintColor
            actionButton.setTitleColor(.white, for: .normal)
        } else {
            // nothing to hold and nothing to retry: the left button is enough
            NSLayoutConstraint.deactivate(actionSplitConstraints)
            NSLayoutConstraint.activate(actionFullConstraints)
            clearButton.isHidden = true
            actionButton.setTitle(String(localizationKey: "Queue_Clear"), for: .normal)
            actionButton.backgroundColor = .tertiarySystemFill
            actionButton.setTitleColor(.label, for: .normal)
        }
        // rebuilding the rows on every tick cancels a swipe the user has begun:
        // only a different set of rows needs a new table
        if rowsChanged {
            table.reloadData()
        } else {
            updateVisibleRows()
        }
    }

    /// Refresh the rows in place, so a swipe or a bar animation is not cut off.
    private func updateVisibleRows() {
        for cell in table.visibleCells {
            guard let indexPath = table.indexPath(for: cell), indexPath.row < items.count,
                  let card = cell.contentView.subviews.first as? QueueCardCell else { continue }
            card.configure(item: items[indexPath.row])
            card.animateProgress()
        }
    }

    private func primaryAction() {
        if QueueCenter.shared.holdForConfirmation, !items.isEmpty {
            // the batch runs now; the sheet stays to show it
            QueueCenter.shared.confirmBatch()
            return
        }
        if items.isEmpty {
            dismiss(animated: true)
            return
        }
        if items.contains(where: { $0.isFailed }) {
            // a failure is read in the log; the rows are taken out by hand
            openLog()
            return
        }
        let downloading = items.contains {
            if case .downloading = $0.state { return true }
            return false
        }
        if downloading {
            QueueCenter.shared.setDownloadsPaused(!QueueCenter.shared.allDownloadsPaused)
            return
        }
        // nothing else to offer: empty the queue
        QueueCenter.shared.cancelAll()
        dismiss(animated: true)
    }

    private func openLog() {
        // one log sheet at a time: a second tap while it is opening must not
        // be swallowed by UIKit
        guard presentedViewController == nil else { return }
        // the legacy log page is built for the old popup bar, so the queue
        // shows the apt output itself, in a sheet that always has it
        let log = QueueLogSheetController()
        log.modalPresentationStyle = .pageSheet
        if let presentation = log.sheetPresentationController {
            presentation.detents = [.large()]
            presentation.prefersGrabberVisible = true
        }
        present(log, animated: true)
    }

    // MARK: table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        // a row that carries apt hint needs one more line
        indexPath.row < items.count && items[indexPath.row].hint != nil ? 106 : 90
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "QueueCard", for: indexPath)
        cell.backgroundColor = .clear
        cell.selectionStyle = .none
        cell.contentView.subviews.forEach { $0.removeFromSuperview() }

        let item = items[indexPath.row]
        let card = QueueCardCell()
        card.configure(item: item)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.tag = indexPath.row
        cell.contentView.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
            card.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 5),
            card.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -5)
        ])
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if items[indexPath.row].isFailed {
            openLog()
        }
    }

    /// Swipe a row to take it out of the batch: the right-hand button now
    /// holds the download instead.
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.row < items.count else { return nil }
        let identifier = items[indexPath.row].identifier
        let action = UIContextualAction(style: .destructive,
                                        title: String(localizationKey: "Queue_Remove")) { [weak self] _, _, done in
            QueueCenter.shared.removeFromBatch(identifier)
            done(true)
            self?.reload()
        }
        action.backgroundColor = .systemRed
        return UISwipeActionsConfiguration(actions: [action])
    }
}

// MARK: - Log sheet

extension Notification.Name {
    static let queueLogDidChange = Notification.Name("QueueCenterLogDidChange")
}

/// The apt/dpkg output, in a sheet of its own. The legacy log page belongs to
/// the old popup bar and shows its placeholder text when it is opened after a
/// run, so the queue reads the output straight from it instead.
final class QueueLogSheetController: UIViewController {

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let textView = UITextView()
    private let doneButton = UIButton(type: .system)
    private let respringButton = UIButton(type: .system)
    private var observer: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        titleLabel.text = String(localizationKey: "Queue_Log_Title")
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        let failed = QueueCenter.shared.lastRunFailed
            ? max(1, QueueCenter.shared.lastItems.filter { $0.isFailed }.count)
            : 0
        subtitleLabel.text = failed > 0
            ? String(format: String(localizationKey: "Queue_Failed_N"), failed)
            : String(localizationKey: "Queue_Log_Hint")
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = failed > 0 ? .systemRed : .secondaryLabel
        subtitleLabel.numberOfLines = 0
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(subtitleLabel)

        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .secondarySystemBackground
        textView.layer.cornerRadius = 14
        textView.layer.cornerCurve = .continuous
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        textView.font = UIFont(name: "Menlo-Regular", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .label
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        doneButton.setTitle(String(localizationKey: "Done"), for: .normal)
        doneButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        doneButton.setTitleColor(.label, for: .normal)
        doneButton.backgroundColor = .tertiarySystemFill
        doneButton.layer.cornerRadius = 22
        doneButton.layer.cornerCurve = .continuous
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            // reading the result is what closes it: the ring goes back to the
            // button and the capsule goes away
            guard failed > 0 else {
                self.dismiss(animated: true)
                return
            }
            // the failure is read: its row turns back into ✕, so the task can
            // be removed, and the queue sheet stays where it is
            QueueCenter.shared.markFailureRead()
            self.dismiss(animated: true)
        }, for: .touchUpInside)
        view.addSubview(doneButton)

        respringButton.setTitle(String(localizationKey: "After_Install_Respring"), for: .normal)
        respringButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        respringButton.setTitleColor(.white, for: .normal)
        respringButton.backgroundColor = .tintColor
        respringButton.layer.cornerRadius = 22
        respringButton.layer.cornerCurve = .continuous
        respringButton.translatesAutoresizingMaskIntoConstraints = false
        respringButton.addAction(UIAction { [weak self] _ in self?.respring() }, for: .touchUpInside)
        // a failed batch has nothing to respring for
        respringButton.isHidden = failed > 0
        view.addSubview(respringButton)

        var constraints: [NSLayoutConstraint] = [
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 14),
            textView.bottomAnchor.constraint(equalTo: doneButton.topAnchor, constant: -14),

            doneButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            doneButton.heightAnchor.constraint(equalToConstant: 44),
            doneButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -14)
        ]
        if failed > 0 {
            // one answer only
            constraints.append(doneButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20))
        } else {
            constraints += [
                respringButton.leadingAnchor.constraint(equalTo: doneButton.trailingAnchor, constant: 10),
                respringButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
                respringButton.widthAnchor.constraint(equalTo: doneButton.widthAnchor),
                respringButton.heightAnchor.constraint(equalTo: doneButton.heightAnchor),
                respringButton.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor)
            ]
        }
        NSLayoutConstraint.activate(constraints)

        observer = NotificationCenter.default.addObserver(forName: .queueLogDidChange, object: nil,
                                                          queue: .main) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func refresh() {
        let log = DownloadManager.shared.viewController.logText
        let failed = QueueCenter.shared.lastItems.filter { $0.isFailed }
        var text = ""
        if !failed.isEmpty {
            // name the rows that failed, so the log is not an anonymous dump
            text += String(localizationKey: "Queue_Log_Failed_Header") + "\n"
            for item in failed {
                text += "· \(item.name) (\(item.identifier))\n"
                if let reason = reasonLine(for: item.identifier, in: log) {
                    text += "  \(reason)\n"
                }
            }
            text += "\n"
        }
        text += log.isEmpty ? String(localizationKey: "Queue_Log_Empty") : log
        textView.text = text
        textView.textColor = log.isEmpty && failed.isEmpty ? .secondaryLabel : .label
        guard !text.isEmpty else { return }
        let end = NSRange(location: (text as NSString).length, length: 0)
        textView.scrollRangeToVisible(end)
    }

    /// The line of apt's output that names this package, if there is one.
    private func reasonLine(for identifier: String, in log: String) -> String? {
        log.components(separatedBy: "\n")
            .first { $0.contains(identifier) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func respring() {
        dismiss(animated: true) {
            spawnAsRoot(args: [jbroot("/usr/bin/sbreload")])
        }
    }
}

// MARK: - Card

final class QueueCardCell: UIView {

    private let iconView = UIView()
    private let iconLabel = UILabel()
    private let nameLabel = UILabel()
    private let statusLabel = UILabel()
    private let hintLabel = UILabel()
    private let barTrack = UIView()
    private let barFill = UIView()
    private let headLabel = UILabel()
    private var barFillWidth: NSLayoutConstraint?
    private var progressFraction: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 14
        // the row itself is not a control: a tap belongs to the cell
        isUserInteractionEnabled = false
        layer.cornerCurve = .continuous

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.layer.cornerRadius = 11
        iconView.layer.cornerCurve = .continuous
        iconView.backgroundColor = .tintColor
        addSubview(iconView)

        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        iconLabel.font = .systemFont(ofSize: 18, weight: .bold)
        iconLabel.textColor = .white
        iconLabel.textAlignment = .center
        iconView.addSubview(iconLabel)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        nameLabel.textColor = .label
        nameLabel.numberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabel
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .systemRed
        hintLabel.numberOfLines = 1
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.isHidden = true
        addSubview(hintLabel)

        addSubview(statusLabel)

        barTrack.translatesAutoresizingMaskIntoConstraints = false
        barTrack.backgroundColor = .tertiarySystemFill
        barTrack.layer.cornerRadius = 1.75
        addSubview(barTrack)

        barFill.translatesAutoresizingMaskIntoConstraints = false
        barFill.backgroundColor = .tintColor
        barFill.layer.cornerRadius = 1.75
        addSubview(barFill)
        let width = barFill.widthAnchor.constraint(equalToConstant: 0)
        barFillWidth = width
        width.isActive = true

        // the percentage rides the head of the bar
        headLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        headLabel.textColor = .secondaryLabel
        headLabel.isHidden = true
        addSubview(headLabel)


        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 44),
            iconView.heightAnchor.constraint(equalToConstant: 44),
            iconLabel.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            iconLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),

            statusLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),

            hintLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            hintLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 2),

            barTrack.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            barTrack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            barTrack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            barTrack.heightAnchor.constraint(equalToConstant: 3.5),
            barFill.leadingAnchor.constraint(equalTo: barTrack.leadingAnchor),
            barFill.topAnchor.constraint(equalTo: barTrack.topAnchor),
            barFill.bottomAnchor.constraint(equalTo: barTrack.bottomAnchor),

        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        positionBar(animated: false)
    }

    /// The fill and the percentage that rides its head.
    private func positionBar(animated: Bool) {
        let width = barTrack.bounds.width * progressFraction
        if let constraint = barFillWidth, abs(constraint.constant - width) > 0.5 {
            constraint.constant = width
            if animated {
                UIView.animate(withDuration: 0.24, delay: 0,
                               options: [.curveLinear, .beginFromCurrentState]) {
                    self.layoutIfNeeded()
                }
            }
        } else {
            barFillWidth?.constant = width
        }
        guard !headLabel.isHidden else { return }
        let head = barTrack.frame.minX + width
        let size = headLabel.intrinsicContentSize
        let maxX = bounds.width - 12
        let x = min(max(head - size.width / 2, barTrack.frame.minX), maxX - size.width)
        headLabel.frame = CGRect(x: x,
                                 y: barTrack.frame.minY - size.height - 2,
                                 width: size.width, height: size.height)
    }

    /// Called while the sheet is open: the bar walks to the new value instead
    /// of jumping to it.
    func animateProgress() {
        positionBar(animated: true)
    }



    func configure(item: QueueItem) {
        // only a failed row answers a tap on its body

        nameLabel.text = item.name
        var status = item.statusText
        if item.isPaused {
            status = String(localizationKey: "Queue_Paused")
        } else if let speed = item.speedText {
            status += " · " + speed
        }
        statusLabel.text = status
        statusLabel.textColor = item.isFailed ? .systemRed : .secondaryLabel
        iconLabel.text = String(item.name.prefix(1)).uppercased()
        // apt says what is missing: the row carries it under the status
        hintLabel.text = item.hint
        hintLabel.isHidden = item.hint == nil
        iconView.backgroundColor = item.isFailed ? .systemRed : .tintColor

        if let progress = item.progress {
            progressFraction = progress
        } else if case .failed = item.state {
            progressFraction = 0.3
        } else if case .waiting = item.state {
            progressFraction = 0
        } else {
            progressFraction = 1
        }
        // a number that rides the bar's head while the task has one
        if let progress = item.progress, !item.isFailed {
            headLabel.text = String(format: "%.0f%%", progress * 100)
            headLabel.isHidden = false
        } else {
            headLabel.text = nil
            headLabel.isHidden = true
        }
        barFill.backgroundColor = item.isFailed ? .systemRed
            : (progressFraction >= 1 ? .systemGreen : .tintColor)
        barFill.isHidden = progressFraction <= 0
        setNeedsLayout()
    }
}
