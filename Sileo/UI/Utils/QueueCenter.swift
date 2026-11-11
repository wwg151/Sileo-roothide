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
        if case .downloading(let fraction) = state { return fraction }
        if case .installing = state { return aptFraction }
        if case .uninstalling = state { return aptFraction }
        return nil
    }
}

// MARK: - Snapshot from DownloadManager

extension DownloadManager {

    /// Every entry of the queue, with the state the new UI shows, and whether
    /// every download is already in. The sets live on the apt queue, so the
    /// snapshot is built off the main thread — mid-download that queue can be
    /// busy for seconds.
    func queueSnapshot(_ completion: @escaping ([QueueItem], Bool) -> Void) {
        QueueCenter.snapshotQueue.async {
            let result = self.buildSnapshot()
            DispatchQueue.main.async { completion(result.0, result.1) }
        }
    }

    private func buildSnapshot() -> ([QueueItem], Bool) {
        var items: [QueueItem] = []
        let downloads = vars.queuedDownloads.raw
        let aptActive = aptRunning && !aptFinished
        // an empty download map means the downloads have not been queued yet —
        // only an uninstall-only batch is truly ready at that point
        let installCount = vars.installations.raw.count + vars.upgrades.raw.count + vars.installdeps.raw.count
        let allDownloaded: Bool
        if downloads.isEmpty {
            allDownloaded = installCount == 0
        } else {
            allDownloaded = downloads.values.allSatisfy { $0.success || $0.progress >= 1 }
        }

        let aptFraction = QueueCenter.shared.aptFraction
        func add(_ set: Set<DownloadPackage>, removal: Bool) {
            for entry in set {
                let package = entry.package
                let identifier = package.package
                let state: QueueItemState
                if let download = downloads[identifier] {
                    if download.failureReason != nil {
                        state = .failed(download.failureReason)
                    } else if download.message != nil && !download.completed {
                        // the roothide conversion runs inside the download's slot
                        state = .converting
                    } else if download.started && !download.completed && !download.success {
                        state = .downloading(download.progress)
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
                items.append(QueueItem(identifier: identifier,
                                       name: package.name ?? identifier,
                                       version: package.version,
                                       isRemoval: removal,
                                       state: state,
                                       aptFraction: aptActive ? aptFraction : 0))
            }
        }

        add(vars.installations.raw, removal: false)
        add(vars.upgrades.raw, removal: false)
        add(vars.installdeps.raw, removal: false)
        add(vars.uninstallations.raw, removal: true)
        add(vars.uninstalldeps.raw, removal: true)

        // a download that lost its slot in the sets still shows while it runs
        let known = Set(items.map { $0.identifier })
        for (identifier, download) in downloads where !known.contains(identifier) {
            let state: QueueItemState
            if download.failureReason != nil {
                state = .failed(download.failureReason)
            } else if download.message != nil && !download.completed {
                state = .converting
            } else if download.started && !download.completed && !download.success {
                state = .downloading(download.progress)
            } else {
                state = .waiting
            }
            items.append(QueueItem(identifier: identifier,
                                   name: download.package.name ?? identifier,
                                   version: download.package.version,
                                   isRemoval: false,
                                   state: state))
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
        return (items.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0.identifier < $1.identifier },
                allDownloaded)
    }
}

// MARK: - Center

final class QueueCenter {
    static let shared = QueueCenter()
    static let queueChangedNotification = Notification.Name("QueueCenterQueueChanged")

    static let snapshotQueue = DispatchQueue(label: "QueueCenter.snapshot", qos: .utility)

    private var capsule: QueueCapsuleView?
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
            // the floating pill sits 12pt above the 64pt tab bar; the capsule
            // keeps 12pt of air above the bar's top edge
            capsuleView.bottomAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.bottomAnchor, constant: -88),
            capsuleView.heightAnchor.constraint(equalToConstant: 52)
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
            } else {
                self.installFailed = true
            }
            // the queue is emptied either way: a failure stays on screen from
            // the snapshot, and new work can be queued straight away
            manager.removeAllItems()
            self.downloadPhase = false
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
            self.aptTotal = max(DownloadManager.shared.operationCount(), 1)
            self.aptCounted.removeAll()
            self.aptPartial.removeAll()
            self.aptFraction = 0
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
            let next = min(0.99, done / CGFloat(max(self.aptTotal, 1)))
            // dpkg reports very often: only redraw when the ring moves visibly
            guard abs(next - self.aptFraction) >= 0.005 else { return }
            self.aptFraction = next
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
            self.installFailed = false
            self.doneShownAt = nil
            self.origins.removeAll()
            self.lastItems = []
            self.syncNow()
        }
    }

    // MARK: execution

    private func startQueueIfNeeded(_ items: [QueueItem]) {
        let manager = DownloadManager.shared
        guard !items.isEmpty, !manager.queueRunning, !manager.aptRunning else { return }
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
        guard downloadPhase, !handoffScheduled, allDownloaded else { return }
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
            let beginInstall: () -> Void = { [weak controller] in
                guard let controller = controller else { return }
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
        lastItems.first { $0.identifier == identifier }?.state
    }

    private func syncNow() {
        // Building the snapshot touches the apt queue's containers: never do
        // that on the main thread, the queue can be busy for seconds mid-download.
        DownloadManager.shared.queueSnapshot { [weak self] items, allDownloaded in
            self?.applySnapshot(items, allDownloaded: allDownloaded)
        }
    }

    private func applySnapshot(_ snapshot: [QueueItem], allDownloaded: Bool) {
        var items = snapshot
        // between the last download and apt the task is on its way to install:
        // show it as installing instead of flashing 等待开始
        if downloadPhase && allDownloaded {
            items = items.map { item in
                guard case .waiting = item.state else { return item }
                return QueueItem(identifier: item.identifier,
                                 name: item.name,
                                 version: item.version,
                                 isRemoval: item.isRemoval,
                                 state: item.isRemoval ? .uninstalling : .installing)
            }
        }
        for item in items where origins[item.identifier] == nil {
            origins[item.identifier] = QueueCenter.currentPageIdentifier()
        }
        let hasFailure = installFailed || items.contains { $0.isFailed }

        // The legacy popup carried the 开始 button that started the queue;
        // the queue now starts itself the moment something is queued.
        startQueueIfNeeded(items)

        if !items.isEmpty {
            // a new run supersedes the previous result
            doneShownAt = nil
            installFailed = false
        } else if let done = doneShownAt, Date().timeIntervalSince(done) >= 2 {
            doneShownAt = nil
        }

        // downloads all in: hand the batch to apt
        checkAptHandoff(allDownloaded: allDownloaded)

        // The capsule yields to the page that shows the task's own ring.
        var showCapsule = false
        if hasFailure {
            showCapsule = true
        } else if !items.isEmpty {
            if items.count == 1, let origin = origins[items[0].identifier],
               QueueCenter.currentPageIdentifier() == origin {
                showCapsule = false
            } else {
                showCapsule = true
            }
        } else if doneShownAt != nil {
            showCapsule = true
        }
        // an open sheet already carries the same information
        showCapsule = showCapsule && !sheetVisible

        // Without entries the failure note stands alone until the queue runs again.
        if items.isEmpty && installFailed {
            items = lastItems.map { item in
                if case .failed = item.state { return item }
                return QueueItem(identifier: item.identifier, name: item.name, version: item.version,
                                 isRemoval: item.isRemoval, state: .failed(nil))
            }
        }
        lastItems = items

        if items.isEmpty && !hasFailure {
            origins.removeAll()
        }

        updateCapsule(visible: showCapsule, items: items, failure: hasFailure && !items.isEmpty,
                      done: items.isEmpty && doneShownAt != nil && !installFailed)
        NotificationCenter.default.post(name: QueueCenter.queueChangedNotification, object: nil)
        restartTimer()
    }

    // The page a task came from is remembered the first time it is seen, so a
    // single task hides the capsule while its own page is on screen.

    static func currentPageIdentifier() -> ObjectIdentifier? {
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
        return controller.map { ObjectIdentifier($0) }
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

    private func updateCapsule(visible: Bool, items: [QueueItem], failure: Bool, done: Bool) {
        guard let capsule = capsule else { return }
        // the app is leaving (respring): nothing of ours stays on the screen
        if suspended {
            window?.isHidden = true
            capsule.isHidden = true
            return
        }
        if visible {
            capsule.configure(items: items, failure: failure, done: done)
            if window?.isHidden != false {
                window?.isHidden = false
                // showing a window can take the key: hand it back to the app
                TabBarController.singleton?.view.window?.makeKey()
            }
            if capsule.isHidden {
                capsule.alpha = 0
                capsule.isHidden = false
                UIView.animate(withDuration: 0.3, delay: 0,
                               usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
                               options: [.curveEaseOut]) {
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

    func presentSheet() {
        guard !sheetVisible else { return }
        guard let host = TabBarController.singleton else { return }
        // whatever is already up (the log page, for instance) must not be
        // replaced by UIKit's "already presenting" exception
        var top: UIViewController = host
        while let presented = top.presentedViewController { top = presented }
        guard !top.isBeingPresented, !top.isBeingDismissed, top.viewIfLoaded?.window != nil else { return }
        let sheet = QueueSheetController()
        sheet.modalPresentationStyle = .pageSheet
        if let presentation = sheet.sheetPresentationController {
            presentation.detents = [.medium(), .large()]
            presentation.prefersGrabberVisible = true
        }
        sheetVisible = true
        top.present(sheet, animated: true) {
            self.restartTimer()
        }
    }

    func sheetClosed() {
        sheetVisible = false
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

    private let ringLayer = CAShapeLayer()
    private let trackLayer = CAShapeLayer()
    private let titleLabel = UILabel()
    private let percentLabel = UILabel()
    private let badgeLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .systemBackground
        layer.cornerRadius = 26
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 5)
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.separator.withAlphaComponent(0.5).cgColor

        trackLayer.fillColor = UIColor.clear.cgColor
        trackLayer.strokeColor = UIColor.tertiaryLabel.withAlphaComponent(0.35).cgColor
        trackLayer.lineWidth = 3.5
        trackLayer.lineCap = .round
        layer.addSublayer(trackLayer)

        ringLayer.fillColor = UIColor.clear.cgColor
        ringLayer.strokeColor = UIColor.tintColor.cgColor
        ringLayer.lineWidth = 3.5
        ringLayer.lineCap = .round
        layer.addSublayer(ringLayer)

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        percentLabel.font = .systemFont(ofSize: 14)
        percentLabel.textColor = .secondaryLabel
        addSubview(percentLabel)

        badgeLabel.font = .systemFont(ofSize: 13, weight: .heavy)
        badgeLabel.textAlignment = .center
        badgeLabel.isHidden = true
        addSubview(badgeLabel)

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func tapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onTap?()
    }

    override var intrinsicContentSize: CGSize {
        let title = ceil(titleLabel.intrinsicContentSize.width)
        let hasPercent = percentLabel.text?.isEmpty == false
        let percent = hasPercent ? ceil(percentLabel.intrinsicContentSize.width) + 10 : 0
        return CGSize(width: max(132, 52 + title + percent + 18), height: 52)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let ringCenter = CGPoint(x: 30, y: bounds.height / 2)
        let path = UIBezierPath(arcCenter: ringCenter, radius: 10.5, startAngle: -.pi / 2,
                                endAngle: .pi * 3 / 2, clockwise: true)
        trackLayer.frame = bounds
        ringLayer.frame = bounds
        trackLayer.path = path.cgPath
        ringLayer.path = path.cgPath

        let hasPercent = percentLabel.text?.isEmpty == false
        let percentWidth = hasPercent ? ceil(percentLabel.intrinsicContentSize.width) : 0
        let rightInset: CGFloat = 18
        let titleWidth = max(0, bounds.width - 52 - rightInset - (hasPercent ? percentWidth + 10 : 0))
        let titleHeight = ceil(titleLabel.intrinsicContentSize.height)
        titleLabel.frame = CGRect(x: 52, y: (bounds.height - titleHeight) / 2,
                                  width: titleWidth, height: titleHeight)
        percentLabel.isHidden = !hasPercent
        if hasPercent {
            let height = ceil(percentLabel.intrinsicContentSize.height)
            percentLabel.frame = CGRect(x: bounds.width - rightInset - percentWidth,
                                        y: (bounds.height - height) / 2,
                                        width: percentWidth, height: height)
        }
        if !badgeLabel.isHidden {
            badgeLabel.frame = CGRect(x: ringCenter.x - 12, y: ringCenter.y - 10, width: 24, height: 20)
        }
    }

    func configure(items: [QueueItem], failure: Bool, done: Bool) {
        let ringColor: UIColor
        badgeLabel.isHidden = true
        badgeLabel.text = nil
        if done {
            titleLabel.text = String(localizationKey: "Queue_Done")
            percentLabel.text = "›"
            percentLabel.textColor = .tertiaryLabel
            ringColor = .systemGreen
            badgeLabel.text = "✓"
            badgeLabel.textColor = .systemGreen
            badgeLabel.isHidden = false
            setRing(1, ringColor)
        } else if failure || items.contains(where: { $0.isFailed }) {
            let failed = max(1, items.filter { $0.isFailed }.count)
            titleLabel.text = String(format: String(localizationKey: "Queue_Failed_N"), failed)
            percentLabel.text = "›"
            percentLabel.textColor = .tertiaryLabel
            ringColor = .systemRed
            badgeLabel.text = "!"
            badgeLabel.textColor = .systemRed
            badgeLabel.isHidden = false
            setRing(1, ringColor)
        } else {
            let downloading = items.filter {
                if case .downloading = $0.state { return true }
                return false
            }
            let fractions = items.compactMap { $0.progress }
            let progress = fractions.isEmpty ? 0 : fractions.reduce(0, +) / CGFloat(fractions.count)
            let title: String
            if items.contains(where: { if case .installing = $0.state { return true }; return false }) {
                title = String(localizationKey: "Queue_Installing")
            } else if items.contains(where: { if case .uninstalling = $0.state { return true }; return false }) {
                title = String(localizationKey: "Queue_Uninstalling")
            } else if items.contains(where: { if case .converting = $0.state { return true }; return false }) {
                title = String(localizationKey: "Queue_Converting")
            } else if !downloading.isEmpty {
                title = String(localizationKey: "Queue_Downloading")
            } else {
                title = String(localizationKey: "Queue_Waiting")
            }
            titleLabel.text = title + " " + String(format: String(localizationKey: "Queue_Items"), items.count)
            percentLabel.text = fractions.isEmpty ? nil : String(format: "%.0f%%", progress * 100)
            percentLabel.textColor = .secondaryLabel
            ringColor = .tintColor
            // a waiting queue shows the bare track; a busy one the real share
            if !fractions.isEmpty {
                setRing(max(0.02, min(1, progress)), ringColor)
            } else if title == String(localizationKey: "Queue_Waiting") {
                setRing(0.12, ringColor)
            } else {
                setRing(1, ringColor)
            }
        }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func setRing(_ fraction: CGFloat, _ color: UIColor) {
        ringLayer.strokeColor = color.cgColor
        ringLayer.strokeEnd = fraction
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

        let logButton = UIButton(type: .system)
        logButton.setTitle(String(localizationKey: "Queue_View_Log"), for: .normal)
        logButton.titleLabel?.font = .systemFont(ofSize: 15)
        logButton.translatesAutoresizingMaskIntoConstraints = false
        logButton.addAction(UIAction { [weak self] _ in self?.openLog() }, for: .touchUpInside)
        view.addSubview(logButton)

        table.translatesAutoresizingMaskIntoConstraints = false
        table.dataSource = self
        table.delegate = self
        table.separatorStyle = .none
        table.backgroundColor = .clear
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

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            logButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            logButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            table.bottomAnchor.constraint(equalTo: actionButton.topAnchor, constant: -12),
            actionButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            actionButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            actionButton.heightAnchor.constraint(equalToConstant: 44),
            actionButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])

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
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        QueueCenter.shared.sheetClosed()
    }

    private func reload() {
        // the centre keeps the last snapshot, failures included, even after
        // the manager has emptied the queue
        let snapshot = QueueCenter.shared.lastItems
        items = snapshot
        let failed = snapshot.filter { $0.isFailed }.count
        titleLabel.text = String(localizationKey: "Queue_Title")
        if failed > 0 {
            subtitleLabel.text = String(format: String(localizationKey: "Queue_Failed_N"), failed)
            subtitleLabel.textColor = .systemRed
        } else {
            subtitleLabel.text = String(format: String(localizationKey: "Queue_Items"), snapshot.count)
            subtitleLabel.textColor = .secondaryLabel
        }
        if snapshot.isEmpty {
            actionButton.setTitle(String(localizationKey: "Done"), for: .normal)
            actionButton.backgroundColor = .tertiarySystemFill
            actionButton.setTitleColor(.label, for: .normal)
        } else if failed > 0 {
            actionButton.setTitle(String(localizationKey: "Queue_View_Log"), for: .normal)
            actionButton.backgroundColor = .tintColor
            actionButton.setTitleColor(.white, for: .normal)
        } else {
            actionButton.setTitle(String(localizationKey: "Queue_Cancel_All"), for: .normal)
            actionButton.backgroundColor = .tintColor
            actionButton.setTitleColor(.white, for: .normal)
        }
        table.reloadData()
    }

    private func primaryAction() {
        if items.isEmpty {
            dismiss(animated: true)
            return
        }
        if items.contains(where: { $0.isFailed }) {
            openLog()
            return
        }
        SileoPanelViewController.confirm(title: String(localizationKey: "Queue_Cancel_All"),
                                         message: String(localizationKey: "Queue_Cancel_All_Message"),
                                         confirmTitle: String(localizationKey: "Queue_Cancel_All")) { [weak self] in
            QueueCenter.shared.cancelAll()
            self?.dismiss(animated: true)
        }.present(from: self)
    }

    private func openLog() {
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
        74
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
        card.cancelHandler = { [weak self] in
            DownloadManager.shared.remove(package: item.identifier)
            QueueCenter.shared.sync()
        }
        card.logHandler = { [weak self] in self?.openLog() }
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

        let failed = QueueCenter.shared.lastItems.filter { $0.isFailed }.count
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
        doneButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        view.addSubview(doneButton)

        respringButton.setTitle(String(localizationKey: "After_Install_Respring"), for: .normal)
        respringButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        respringButton.setTitleColor(.white, for: .normal)
        respringButton.backgroundColor = .tintColor
        respringButton.layer.cornerRadius = 22
        respringButton.layer.cornerCurve = .continuous
        respringButton.translatesAutoresizingMaskIntoConstraints = false
        respringButton.addAction(UIAction { [weak self] _ in self?.respring() }, for: .touchUpInside)
        view.addSubview(respringButton)

        NSLayoutConstraint.activate([
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
            doneButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -14),

            respringButton.leadingAnchor.constraint(equalTo: doneButton.trailingAnchor, constant: 10),
            respringButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            respringButton.widthAnchor.constraint(equalTo: doneButton.widthAnchor),
            respringButton.heightAnchor.constraint(equalTo: doneButton.heightAnchor),
            respringButton.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor)
        ])

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
        let text = DownloadManager.shared.viewController.logText
        textView.text = text.isEmpty ? String(localizationKey: "Queue_Log_Empty") : text
        textView.textColor = text.isEmpty ? .secondaryLabel : .label
        guard !text.isEmpty else { return }
        let end = NSRange(location: (text as NSString).length, length: 0)
        textView.scrollRangeToVisible(end)
    }

    private func respring() {
        dismiss(animated: true) {
            spawnAsRoot(args: [jbroot("/usr/bin/sbreload")])
        }
    }
}

// MARK: - Card

final class QueueCardCell: UIView {

    var cancelHandler: (() -> Void)?
    var logHandler: (() -> Void)?

    private let iconView = UIView()
    private let iconLabel = UILabel()
    private let nameLabel = UILabel()
    private let statusLabel = UILabel()
    private let barTrack = UIView()
    private let barFill = UIView()
    private var barFillWidth: NSLayoutConstraint?
    private var progressFraction: CGFloat = 0
    private let actionButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 14
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

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.layer.cornerRadius = 15
        actionButton.layer.borderWidth = 1.4
        actionButton.layer.borderColor = UIColor.separator.cgColor
        actionButton.setTitleColor(.label, for: .normal)
        actionButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        actionButton.tintColor = .label
        actionButton.setTitleColor(.label, for: .normal)
        actionButton.setTitleColor(.label, for: .normal)
        addSubview(actionButton)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 44),
            iconView.heightAnchor.constraint(equalToConstant: 44),
            iconLabel.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
            iconLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -12),

            statusLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -12),

            barTrack.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            barTrack.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -12),
            barTrack.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            barTrack.heightAnchor.constraint(equalToConstant: 3.5),
            barFill.leadingAnchor.constraint(equalTo: barTrack.leadingAnchor),
            barFill.topAnchor.constraint(equalTo: barTrack.topAnchor),
            barFill.bottomAnchor.constraint(equalTo: barTrack.bottomAnchor),
            barFill.widthAnchor.constraint(equalTo: barTrack.widthAnchor, multiplier: 0),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.widthAnchor.constraint(equalToConstant: 30),
            actionButton.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        barFillWidth?.constant = barTrack.bounds.width * progressFraction
    }

    func configure(item: QueueItem) {
        nameLabel.text = item.name
        statusLabel.text = item.statusText
        statusLabel.textColor = item.isFailed ? .systemRed : .secondaryLabel
        iconLabel.text = String(item.name.prefix(1)).uppercased()
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
        barFill.backgroundColor = item.isFailed ? .systemRed
            : (progressFraction >= 1 ? .systemGreen : .tintColor)
        barFill.isHidden = progressFraction <= 0
        setNeedsLayout()

        let title: String?
        switch item.state {
        case .waiting, .downloading:
            title = "✕"
            actionButton.layer.borderColor = UIColor.separator.cgColor
            actionButton.setTitleColor(.label, for: .normal)
        case .failed:
            title = String(localizationKey: "Queue_View_Log_Short")
            actionButton.layer.borderColor = UIColor.systemRed.withAlphaComponent(0.5).cgColor
            actionButton.setTitleColor(.systemRed, for: .normal)
        default:
            title = nil
        }
        actionButton.setTitle(title, for: .normal)
        actionButton.isHidden = title == nil
    }
}
