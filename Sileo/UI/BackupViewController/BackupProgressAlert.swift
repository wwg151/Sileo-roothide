//
//  BackupProgressAlert.swift
//  Sileo
//

import Foundation
import UIKit

final class BackupTaskSession {
    struct Task: Equatable {
        let id: String
        var name: String
        var fraction: Double = 0
        var detail: String = ""
        var outcome: Bool?
        var active = false
    }

    struct RemovedResult: Equatable {
        let id: String
        let name: String
        let outcome: Bool
    }

    private var storedTasks: [Task] = []
    private(set) var tasks: [Task] {
        get { Thread.isMainThread ? storedTasks : DispatchQueue.main.sync { self.storedTasks } }
        set { storedTasks = newValue }
    }
    private(set) var removedResults: [RemovedResult] = []
    private let pauseCondition = NSCondition()
    private var pausedIDs = Set<String>()

    func isPaused(_ id: String) -> Bool {
        pauseCondition.lock()
        defer { pauseCondition.unlock() }
        return pausedIDs.contains(id)
    }

    func togglePause(_ id: String) {
        pauseCondition.lock()
        if pausedIDs.contains(id) { pausedIDs.remove(id) }
        else { pausedIDs.insert(id) }
        pauseCondition.broadcast()
        pauseCondition.unlock()
        onChange?()
    }

    // Only called by workers at safe boundaries, never while dpkg is running.
    @discardableResult
    func waitUntilResumed(_ id: String) -> Bool {
        pauseCondition.lock()
        defer { pauseCondition.unlock() }
        while pausedIDs.contains(id) && !storedRemovedIDs.contains(id) && !BackupManager.shared.isCancelled {
            _ = pauseCondition.wait(until: Date(timeIntervalSinceNow: 0.2))
        }
        return !storedRemovedIDs.contains(id)
    }

    var activeIDs = Set<String>()
    private var storedRemovedIDs = Set<String>()
    var removedIDs: Set<String> {
        pauseCondition.lock()
        defer { pauseCondition.unlock() }
        return storedRemovedIDs
    }
    var closed = false
    var backupFolder: BackupManager.BackupFolder?
    var completionTitle = ""
    var completionPath: String?
    var accumulatedFinish: APTWrapper.FINISH = .back
    var accumulatedRefresh = false
    var onRoundFinished: (() -> Void)?
    var lastSummary: String?
    var onChange: (() -> Void)?
    var message: String { lastSummary ?? "" }
    var finished: Bool { !hasPendingTasks }
    var hasWaitingTasks: Bool { hasPendingTasks }

    func closeSession() { closed = true; onChange = nil; onRoundFinished = nil }

    var hasPendingTasks: Bool { tasks.contains { $0.outcome == nil } }
    var hasActiveTasks: Bool { !activeIDs.isEmpty }

    func register(_ values: [(String, String)]) {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.register(values) }; return }
        guard !closed else { return }
        defer { onChange?() }
        for (id, name) in values where !removedIDs.contains(id) {
            if let index = tasks.firstIndex(where: { $0.id == id }) {
                if tasks[index].name.isEmpty { tasks[index].name = name }
            } else {
                tasks.append(Task(id: id, name: name))
            }
        }
    }

    func order(_ ids: [String]) {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.order(ids) }; return }
        guard !closed else { return }
        var rank: [String: Int] = [:]
        for (index, id) in ids.enumerated() where rank[id] == nil { rank[id] = index }
        tasks = tasks.enumerated().sorted {
            let a = rank[$0.element.id] ?? Int.max
            let b = rank[$1.element.id] ?? Int.max
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
        onChange?()
    }

    func update(_ id: String, fraction: Double, detail: String, outcome: Bool? = nil) {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.update(id, fraction: fraction, detail: detail, outcome: outcome) }; return }
        guard !closed, let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].outcome == nil else { return }
        defer { onChange?() }
        tasks[index].fraction = outcome == true ? 1 : max(tasks[index].fraction, max(0, min(0.99, fraction.isFinite ? fraction : 0)))
        tasks[index].detail = detail
        if let outcome = outcome {
            tasks[index].outcome = outcome
            if outcome { tasks[index].fraction = 1 }
            activeIDs.remove(id)
        }
    }

    /// Retry only failed rows; successful and removed tasks remain untouched.
    func resetFailure(_ id: String) {
        precondition(Thread.isMainThread)
        guard !closed, !activeIDs.contains(id),
              let index = tasks.firstIndex(where: { $0.id == id && $0.outcome == false }) else { return }
        tasks[index].outcome = nil
        tasks[index].fraction = 0
        tasks[index].detail = String(localizationKey: "Backup_Task_Waiting")
        tasks[index].active = false
        lastSummary = nil
        pauseCondition.lock()
        pausedIDs.remove(id)
        pauseCondition.broadcast()
        pauseCondition.unlock()
        onChange?()
    }

    func begin(_ ids: Set<String>) {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.begin(ids) }; return }
        guard !closed else { return }
        defer { onChange?() }
        pauseCondition.lock()
        pausedIDs.subtract(ids)
        pauseCondition.broadcast()
        pauseCondition.unlock()
        for index in tasks.indices where ids.contains(tasks[index].id) && tasks[index].outcome == nil {
            tasks[index].active = true
            activeIDs.insert(tasks[index].id)
        }
    }

    func finish(_ summary: String) {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.finish(summary) }; return }
        guard !closed else { return }
        for index in tasks.indices where tasks[index].outcome == nil && activeIDs.contains(tasks[index].id) {
            tasks[index].detail = summary.isEmpty ? String(localizationKey: "Backup_Task_Not_Executed") : summary
            tasks[index].outcome = false
        }
        activeIDs.removeAll()
        lastSummary = [lastSummary ?? "", summary].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let succeeded = tasks.filter { $0.outcome == true }.count + removedResults.filter { $0.outcome }.count
        let failed = tasks.filter { $0.outcome == false }.count + removedResults.filter { !$0.outcome }.count
        let title = String(format: String(localizationKey: "Backup_Task_Completion_Title"), completionTitle)
        let counts = String(format: String(localizationKey: "Backup_Task_Completion_Counts"), succeeded, failed)
        let path = backupFolder?.url.path ?? completionPath
        BackupCompletionToast.show([title, counts, path].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
        onRoundFinished?()
        onChange?()
    }

    func remove(ids: Set<String>) {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.remove(ids: ids) }; return }
        guard !closed else { return }
        defer { onChange?() }
        pauseCondition.lock()
        storedRemovedIDs.formUnion(ids)
        pausedIDs.subtract(ids)
        pauseCondition.broadcast()
        pauseCondition.unlock()
        activeIDs.subtract(ids)
        for task in tasks where ids.contains(task.id) {
            if let outcome = task.outcome {
                removedResults.append(RemovedResult(id: task.id, name: task.name, outcome: outcome))
            }
        }
        tasks.removeAll { ids.contains($0.id) }
    }

    func clear() {
        remove(ids: Set(tasks.map(\.id)))
    }

    func pendingIDs(matching id: String?) -> Set<String> {
        guard let id = id else { return Set(tasks.filter { $0.outcome == nil }.map(\.id)) }
        return Set(tasks.filter { $0.id == id && $0.outcome == nil }.map(\.id))
    }

    func startSingleTask(name: String) {
        register([("archive", name)])
        begin(["archive"])
        update("archive", fraction: 0.01, detail: String(localizationKey: "Backup_Task_Running"))
    }

    func finishSingleTask(message: String, success: Bool) {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.finishSingleTask(message: message, success: success) }; return }
        update("archive", fraction: success ? 1 : 0, detail: message, outcome: success)
        finish(message)
    }
}

private enum BackupCompletionToast {
    private static var overlay: UIWindow?
    private static var dismissal: DispatchWorkItem?

    private final class ToastWindow: UIWindow {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }

    static func show(_ message: String) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        dismissal?.cancel()
        overlay?.isHidden = true
        let window = ToastWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        window.rootViewController = controller
        let card = UIVisualEffectView(effect: nil)
        card.contentView.backgroundColor = .systemGreen
        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.cornerRadius = 18
        card.clipsToBounds = true
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = message
        label.textColor = .white
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textAlignment = .center
        card.contentView.addSubview(label)
        controller.view.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            card.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor, constant: 12),
            card.widthAnchor.constraint(equalTo: controller.view.widthAnchor, constant: -32),
            label.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 14),
            label.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -14)
        ])
        overlay = window
        window.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: message)
        let hide = DispatchWorkItem {
            window.isHidden = true
            if overlay === window { overlay = nil }
            dismissal = nil
        }
        dismissal = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: hide)
    }
}

private final class BackupTaskRow: UIView {
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let percentLabel = UILabel()
    private let resultImage = UIImageView()
    private var fraction: CGFloat = 0
    private var percentCenter: NSLayoutConstraint!

    override func layoutSubviews() {
        super.layoutSubviews()
        let half = max(12, percentLabel.intrinsicContentSize.width / 2)
        percentCenter.constant = max(half, min(max(half, progress.bounds.width - half), progress.bounds.width * fraction))
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        [nameLabel, detailLabel, progress, percentLabel, resultImage].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.numberOfLines = 2
        detailLabel.font = .preferredFont(forTextStyle: .caption1)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 3
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        percentLabel.textColor = .secondaryLabel
        resultImage.contentMode = .scaleAspectFit
        percentCenter = percentLabel.centerXAnchor.constraint(equalTo: progress.leadingAnchor)
        percentCenter.isActive = true
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: resultImage.leadingAnchor, constant: -8),
            resultImage.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            resultImage.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            resultImage.widthAnchor.constraint(equalToConstant: 20),
            resultImage.heightAnchor.constraint(equalToConstant: 20),
            progress.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            percentLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 6),
            progress.topAnchor.constraint(equalTo: percentLabel.bottomAnchor, constant: 4),
            progress.heightAnchor.constraint(equalToConstant: 4),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: progress.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 6),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ task: BackupTaskSession.Task, paused: Bool = false) {
        fraction = CGFloat(task.fraction)
        setNeedsLayout()
        nameLabel.text = task.name
        detailLabel.text = task.outcome == true ? nil : (paused && task.outcome == nil ? String(localizationKey: "Backup_Task_Pause_Requested") : (task.detail.isEmpty ? String(localizationKey: "Backup_Task_Waiting") : task.detail))
        progress.progressTintColor = task.outcome == false ? .systemRed : .systemBlue
        progress.setProgress(Float(task.fraction), animated: true)
        percentLabel.text = "\(Int(task.fraction * 100))%"
        resultImage.image = task.outcome == false ? UIImage(systemName: "xmark.circle.fill") : nil
        resultImage.tintColor = .systemRed
        progress.isHidden = false
        percentLabel.isHidden = false
    }
}

final class BackupProgressAlert: SileoPanelViewController {
    var alert: UIViewController { self }
    let session = BackupTaskSession()
    var onFinishedClose: (() -> Void)?

    private let cardTitle: String
    private let firstMessage: String
    private let cancellable: Bool
    private var onCancel: (() -> Void)?
    private let filters = UISegmentedControl(items: [
        String(format: String(localizationKey: "Backup_Task_All"), 0),
        String(format: String(localizationKey: "Backup_Task_Success"), 0),
        String(format: String(localizationKey: "Backup_Task_Failure"), 0)
    ])
    private let resultLabel = UILabel()
    private let search = UITextField()
    private var startAllButton: UIButton?
    private var managing = false
    private var renderedTasks: [BackupTaskSession.Task] = []
    private var renderedSelection = Set<String>()
    private var renderedManaging = false
    private var renderedRunning = false
    private var renderedReady = false
    private var taskRows: [String: BackupTaskRow] = [:]
    private var deletionEntries: [(folder: BackupManager.BackupFolder, title: String, date: String?)]?
    private var deletingBackups = false

    func configureBackupDeletion(_ entries: [(folder: BackupManager.BackupFolder, title: String, date: String?)]) {
        deletionEntries = entries
        resultMessage = ""
        if isViewLoaded { render() }
    }

    var isRunning: Bool { roundRunning || deletingBackups }
    var hasUnfinishedTasks: Bool { deletingBackups || roundRunning || (startHandler == nil && resultMessage == nil) || session.hasPendingTasks }
    var hasPendingCompletion: Bool { onFinishedClose != nil }
    private let manage = UIButton(type: .system)
    private let clear = UIButton(type: .system)
    private let action = UIButton(type: .system)
    private var footer: UIStackView!
    private var renderScheduled = false
    private var startHandler: ((String?) -> Void)?
    private var currentFilter = 0
    private var selectedIDs = Set<String>()
    private var resultMessage: String?
    private var roundRunning = false
    private var queuedStarts: [String] = []
    private var allTasksPaused = false
    private var cancelling = false

    init(title: String, message: String, cancellable: Bool, onCancel: (() -> Void)?) {
        cardTitle = title
        firstMessage = message
        self.cancellable = cancellable
        self.onCancel = onCancel
        super.init(title: title, subtitle: nil, icon: "archivebox")
        session.completionTitle = title
        let listBody = UIStackView(arrangedSubviews: [search, filters, table])
        listBody.axis = .vertical
        listBody.spacing = 10
        listBody.isLayoutMarginsRelativeArrangement = true
        listBody.layoutMargins = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        search.heightAnchor.constraint(equalToConstant: 36).isActive = true
        filters.heightAnchor.constraint(equalToConstant: 32).isActive = true
        setBody(listBody)
        let start = Self.headerButton(title: String(localizationKey: "Backup_Task_Start_All")) { [weak self] in self?.toggleAllTasks() }
        styleTaskButton(start)
        start.accessibilityLabel = String(localizationKey: "Backup_Task_Start_All")
        start.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        start.heightAnchor.constraint(equalToConstant: 44).isActive = true
        headerAccessory = start
        startAllButton = start
        session.onRoundFinished = { [weak self] in
            self?.roundRunning = false
            self?.cancelling = false
            self?.resultMessage = self?.session.lastSummary
            self?.render()
            // Wait until the current completion callback has finished resetting
            // download state before starting the next serial operation.
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.startNextQueuedTask()
                guard !self.roundRunning, !self.session.hasPendingTasks,
                      !self.restoreCompletionFailed,
                      !self.session.tasks.isEmpty,
                      self.session.tasks.allSatisfy({ $0.outcome == true }),
                      self.session.removedResults.allSatisfy({ $0.outcome }) else { return }
                // Closing never invokes the optional, explicitly tapped finish action.
                self.close()
            }
        }
    }

    private func startNextQueuedTask() {
        guard !session.closed, !roundRunning, !cancelling, !allTasksPaused else { return }
        while !queuedStarts.isEmpty {
            let id = queuedStarts.removeFirst()
            guard !session.pendingIDs(matching: id).isEmpty else { continue }
            startTask(id)
            break
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func scheduleRender() {
        guard !renderScheduled, !session.closed else { return }
        renderScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            self.renderScheduled = false
            self.render()
        }
    }

    private func styleTaskButton(_ button: UIButton) {
        button.backgroundColor = .secondarySystemFill
        button.layer.cornerRadius = 12
        button.layer.cornerCurve = .continuous
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        filters.selectedSegmentIndex = 0
        filters.addTarget(self, action: #selector(filterChanged), for: .valueChanged)
        action.heightAnchor.constraint(equalToConstant: 40).isActive = true
        action.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
        resultLabel.font = .preferredFont(forTextStyle: .caption1)
        resultLabel.textColor = .secondaryLabel
        resultLabel.numberOfLines = 3
        search.placeholder = String(localizationKey: "Backup_Task_Search")
        search.borderStyle = .roundedRect
        search.clearButtonMode = .whileEditing
        search.returnKeyType = .done
        search.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        manage.setTitle(String(localizationKey: "Backup_Task_Manage"), for: .normal)
        manage.addTarget(self, action: #selector(manageTapped), for: .touchUpInside)
        clear.setTitle(String(localizationKey: "Backup_Task_Clear"), for: .normal)
        clear.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)
        for button in [manage, clear] {
            styleTaskButton(button)
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        }
        let management = UIStackView(arrangedSubviews: [manage, clear])
        management.axis = .horizontal
        management.spacing = 12
        management.distribution = .fillEqually
        footer = UIStackView(arrangedSubviews: [management, action])
        footer.axis = .vertical
        footer.spacing = 8
        setFooter(footer)
        table.onRemoveRow = { [weak self] row in self?.removeVisibleRow(row) }
        render()
        session.onChange = { [weak self] in self?.scheduleRender() }
    }

    override var allowsInteractiveDismissal: Bool { true }

    func prepareStart(_ handler: @escaping (String?) -> Void) {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.prepareStart(handler) }; return }
        guard !session.closed, !roundRunning else { return }
        startHandler = handler
        render()
    }

    func update(fraction: Double, message: String, detail: String) {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.update(fraction: fraction, message: message, detail: detail) }; return }
        if session.activeIDs.contains("archive") {
            session.update("archive", fraction: fraction, detail: [message, detail].filter { !$0.isEmpty }.joined(separator: " · "))
        }
        scheduleRender()
    }

    func finish(message: String) {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.finish(message: message) }; return }
        resultMessage = message
        session.finish(message)
        roundRunning = false
        render()
    }

    // This panel owns restore execution and completion; the ordinary install
    // controller must never acquire restore rows or a completed transaction.
    func runRestoreBatch() {
        let manager = DownloadManager.shared
        guard let batch = manager.restoreBatch, batch.taskSession === session,
              !manager.aptRunning else { return }
        manager.aptRunning = true
        NotificationCenter.default.post(name: DownloadManager.lockStateChangeNotification, object: nil)
        batch.perform(progress: { _, _, _, _ in }, output: { text, _ in
            NSLog("SileoLog: restore: %@", text)
        }, completion: { status, finish, refresh in
            DispatchQueue.main.async {
                self.restoreCompletionFailed = status != 0 || BackupManager.shared.isCancelled
                if finish.rawValue > self.session.accumulatedFinish.rawValue {
                    self.session.accumulatedFinish = finish
                }
                self.session.accumulatedRefresh = self.session.accumulatedRefresh || refresh
                if self.session.accumulatedRefresh {
                    UserDefaults.standard.set(true, forKey: "uicacheRequired")
                }
                DownloadManager.aptQueue.sync { manager.cancelDownloads() }
                manager.restoreBatch = nil
                manager.aptRunning = false
                NotificationCenter.default.post(name: DownloadManager.lockStateChangeNotification, object: nil)
                NotificationCenter.default.post(name: PackageListManager.stateChange, object: nil)
                NotificationCenter.default.post(name: PackageListManager.installChange, object: nil)
                UIApplication.shared.applicationIconBadgeNumber = PackageListManager.shared.availableUpdates()
                    .filter { $0.1?.wantInfo != .hold }.count
                self.onFinishedClose = (self.session.accumulatedFinish != .back || self.session.accumulatedRefresh)
                    ? { [weak self] in self?.showRestoreCompletion() } : nil
                // Release the restore lock before finish starts the next queued round.
                self.session.finish(batch.summary)
            }
        })
    }

    private var finishingRestore = false
    private var restoreCompletionFailed = false

    private func showRestoreCompletion() {
        guard !roundRunning, !finishingRestore else { return }
        let finish = session.accumulatedFinish
        let refresh = session.accumulatedRefresh
        let key: String
        switch finish {
        case .back: key = refresh ? "After_Install_Relaunch" : "Done"
        case .uicache: key = "Refresh"
        case .reopen: key = "After_Install_Relaunch"
        case .reload, .restart: key = "After_Install_Respring"
        case .reboot, .usreboot: key = "After_Install_Reboot"
        }
        let alert = UIAlertController(title: String(localizationKey: "Backup_Task_Complete_Action"),
                                      message: session.lastSummary, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localizationKey: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localizationKey: key), style: .default) { [weak self] _ in
            self?.performRestoreCompletion(finish, refresh: refresh)
        })
        present(alert, animated: true)
    }

    private func performRestoreCompletion(_ finish: APTWrapper.FINISH, refresh: Bool) {
        guard !finishingRestore, !roundRunning, !DownloadManager.shared.aptRunning,
              !DownloadManager.shared.queueRunning else { return }
        finishingRestore = true
        let restart = finish == .reload || finish == .restart || finish == .reboot || finish == .usreboot
        if restart && refresh {
            UserDefaults.standard.set(false, forKey: "uicacheRequired")
            UserDefaults.standard.synchronize()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var result: (Int, String, String) = (0, "", "")
            switch finish {
            case .uicache:
                result = spawnAsRoot(args: [jbroot("/usr/bin/uicache"), "-a"])
            case .reload, .restart:
                result = spawnAsRoot(args: [jbroot("/usr/bin/sbreload")])
            case .reboot, .usreboot:
                spawnAsRoot(args: [jbroot("/usr/bin/sync")])
                result = spawnAsRoot(args: [jbroot("/usr/bin/launchctl"), "reboot", "userspace"])
            case .back, .reopen:
                if refresh {
                    result = spawnAsRoot(args: [jbroot("/usr/bin/uicache"), "-p", rootfs(Bundle.main.bundlePath)])
                    if result.0 == 0 { UserDefaults.standard.set(false, forKey: "uicacheRequired") }
                }
                if result.0 == 0 && (finish == .reopen || refresh) { exit(0) }
            }
            let status = result.0
            let error = result.2
            DispatchQueue.main.asyncAfter(deadline: .now() + (status == 0 && restart ? 3 : 0)) {
                self.finishingRestore = false
                if restart && refresh { UserDefaults.standard.set(true, forKey: "uicacheRequired") }
                if status == 0 && !restart {
                    self.session.accumulatedFinish = .back
                    self.session.accumulatedRefresh = false
                    self.onFinishedClose = nil
                    self.render()
                } else {
                    let alert = UIAlertController(title: String(localizationKey: "Task_Attention"),
                        message: String(localizationKey: "Task_Finish_Action_Failed") + (error.isEmpty ? "" : "\n" + error),
                        preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: String(localizationKey: "Done"), style: .default))
                    self.present(alert, animated: true)
                }
            }
        }
    }

    func startSingleTask(name: String) {
        session.startSingleTask(name: name)
        roundRunning = true
        render()
    }

    func finishSingleTask(message: String, success: Bool) {
        session.finishSingleTask(message: message, success: success)
    }

    override func present(from host: UIViewController) {
        guard !session.closed else { return }
        if let previous = DownloadManager.shared.backupTaskPanel, previous !== self {
            guard !previous.hasUnfinishedTasks, !previous.hasPendingCompletion else {
                previous.present(from: host)
                return
            }
            previous.session.closeSession()
        }
        DownloadManager.shared.backupTaskPanel = self
        super.present(from: host)
        if isViewLoaded { render() }
    }

    @objc private func filterChanged() {
        currentFilter = filters.selectedSegmentIndex
        render()
    }

    @objc private func searchChanged() { render() }

    @objc private func manageTapped() {
        managing.toggle()
        selectedIDs.removeAll()
        render()
    }

    @objc private func removeSelectedTapped() {
        guard !roundRunning, !selectedIDs.isEmpty else { return }
        managing = false
        session.remove(ids: selectedIDs)
        selectedIDs.removeAll()
        render()
    }

    @objc private func clearTapped() {
        if managing { removeSelectedTapped(); return }
        guard !roundRunning, !session.tasks.isEmpty else { return }
        let alert = UIAlertController(title: String(localizationKey: "Backup_Task_Clear"),
                                      message: String(localizationKey: "Backup_Task_Clear_Message"),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localizationKey: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localizationKey: "Backup_Task_Clear"), style: .destructive) { [weak self] _ in
            self?.session.clear()
            self?.selectedIDs.removeAll()
            self?.render()
        })
        present(alert, animated: true)
    }

    @objc private func actionTapped() {
        if roundRunning { cancelWorkTapped(); return }
        if let callback = onFinishedClose {
            callback()
        } else { close() }
    }

    private func toggleAllTasks() {
        if deletionEntries != nil { confirmBackupDeletion(); return }
        if managing {
            selectedIDs = Set(session.tasks.map(\.id))
            render()
            return
        }
        guard !cancelling else { return }
        if roundRunning && !allTasksPaused {
            allTasksPaused = true
            for id in session.activeIDs where !session.isPaused(id) { session.togglePause(id) }
        } else {
            allTasksPaused = false
            for task in session.tasks where session.isPaused(task.id) { session.togglePause(task.id) }
            if !roundRunning { queuedStarts.removeAll() }
            startTask(nil)
        }
        renderedReady = false
        render()
    }

    private func retryTask(_ id: String) {
        guard !session.closed, startHandler != nil, !roundRunning, !cancelling, !finishingRestore,
              session.tasks.contains(where: { $0.id == id && $0.outcome == false }) else { return }
        let manager = DownloadManager.shared
        guard !manager.aptRunning, !manager.queueRunning, manager.operationCount() == 0,
              manager.restoreBatch == nil else {
            resultMessage = String(localizationKey: "Restore_Isolation_Busy")
            render()
            return
        }
        session.resetFailure(id)
        allTasksPaused = false
        // Keep the retry visible after it leaves the failure category.
        currentFilter = 0
        filters.selectedSegmentIndex = 0
        startTask(id)
    }

    private func startTask(_ id: String?) {
        guard !session.closed, let handler = startHandler, !cancelling, !finishingRestore else { return }
        if roundRunning {
            for task in session.tasks where task.outcome == nil && (id == nil || task.id == id)
                && !session.activeIDs.contains(task.id) && !queuedStarts.contains(task.id) {
                queuedStarts.append(task.id)
                session.update(task.id, fraction: task.fraction, detail: String(localizationKey: "Backup_Task_Queued"))
            }
            renderedReady = false
            render()
            return
        }
        let manager = DownloadManager.shared
        let ownBatch = manager.restoreBatch?.taskSession === session
        guard !manager.aptRunning,
              ownBatch || (!manager.queueRunning && manager.operationCount() == 0 && manager.restoreBatch == nil) else {
            resultMessage = String(localizationKey: "Restore_Isolation_Busy")
            render()
            return
        }
        let ids = session.pendingIDs(matching: id)
        guard !ids.isEmpty else { return }
        session.begin(ids)
        roundRunning = true
        cancelling = false
        managing = false
        selectedIDs.removeAll()
        view.endEditing(true)
        resultMessage = nil
        render()
        handler(id)
    }

    private func removeVisibleRow(_ index: Int) {
        let rows = visibleTasks()
        guard rows.indices.contains(index) else { return }
        session.remove(ids: [rows[index].id])
        render()
    }

    private func visibleTasks() -> [BackupTaskSession.Task] {
        let query = (search.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return session.tasks.filter { task in
            let filterMatches = currentFilter == 0 || (currentFilter == 1 && task.outcome == true) || (currentFilter == 2 && task.outcome == false)
            let queryMatches = query.isEmpty || task.name.localizedCaseInsensitiveContains(query) || task.id.localizedCaseInsensitiveContains(query)
            return filterMatches && queryMatches
        }
    }

    private func renderBackupDeletion() {
        guard let entries = deletionEntries else { return }
        filters.isHidden = true
        footer.isHidden = true
        table.onRemoveRow = nil
        startAllButton?.setTitle(String(localizationKey: "Backup_Delete_Action"), for: .normal)
        startAllButton?.accessibilityLabel = String(localizationKey: "Backup_Delete_Action")
        startAllButton?.setTitleColor(.systemRed, for: .normal)
        startAllButton?.isHidden = false
        startAllButton?.isEnabled = !deletingBackups && !selectedIDs.isEmpty
        search.isEnabled = !deletingBackups
        let query = (search.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let offset = table.contentOffset
        table.setItems(entries.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || ($0.date ?? "").localizedCaseInsensitiveContains(query) }.map { entry in
            let id = entry.folder.url.path
            let row = Self.choiceRow(title: entry.title, detail: entry.date, selected: selectedIDs.contains(id)) { [weak self] in
                guard let self = self, !self.deletingBackups else { return }
                if !self.selectedIDs.insert(id).inserted { self.selectedIDs.remove(id) }
                self.render()
            }
            row.isEnabled = !deletingBackups
            return SileoPanelTable.Item(row)
        })
        table.contentOffset = offset
    }

    private func confirmBackupDeletion() {
        guard !deletingBackups, let entries = deletionEntries else { return }
        let chosen = entries.filter { selectedIDs.contains($0.folder.url.path) }.map { $0.folder }
        guard !chosen.isEmpty else { return }
        let confirmation = UIAlertController(title: String(localizationKey: "Backup_Delete_Title"),
            message: String(format: String(localizationKey: "Backup_Delete_Message"), chosen.count), preferredStyle: .alert)
        confirmation.addAction(UIAlertAction(title: String(localizationKey: "Cancel"), style: .cancel))
        confirmation.addAction(UIAlertAction(title: String(localizationKey: "Backup_Delete_Action"), style: .destructive) { [weak self] _ in
            guard let self = self, !self.deletingBackups else { return }
            self.deletingBackups = true
            self.render()
            DispatchQueue.global(qos: .userInitiated).async {
                _ = BackupManager.shared.deleteBackups(folders: chosen)
                let deleted = Set(chosen.filter { !FileManager.default.fileExists(atPath: $0.url.path) }.map { $0.url.path })
                DispatchQueue.main.async {
                    self.deletingBackups = false
                    self.deletionEntries?.removeAll { deleted.contains($0.folder.url.path) }
                    self.selectedIDs.subtract(deleted)
                    self.render()
                    if deleted.count != chosen.count {
                        let error = UIAlertController(title: String(localizationKey: "Backup_Delete_Title"), message: String(localizationKey: "Backup_Delete_Failed"), preferredStyle: .alert)
                        error.addAction(UIAlertAction(title: String(localizationKey: "OK"), style: .default))
                        self.present(error, animated: true)
                    }
                }
            }
        })
        present(confirmation, animated: true)
    }

    private func render() {
        guard isViewLoaded else { return }
        if deletionEntries != nil { renderBackupDeletion(); return }
        let successCount = session.tasks.filter { $0.outcome == true }.count
        let failureCount = session.tasks.filter { $0.outcome == false }.count
        let total = session.tasks.count
        filters.setTitle(String(format: String(localizationKey: "Backup_Task_All"), total), forSegmentAt: 0)
        filters.setTitle(String(format: String(localizationKey: "Backup_Task_Success"), successCount), forSegmentAt: 1)
        filters.setTitle(String(format: String(localizationKey: "Backup_Task_Failure"), failureCount), forSegmentAt: 2)
        let rows = visibleTasks()
        let structureChanged = rows.map(\.id) != renderedTasks.map(\.id) || rows.map(\.outcome) != renderedTasks.map(\.outcome)
        if structureChanged || selectedIDs != renderedSelection || managing != renderedManaging || roundRunning != renderedRunning || (startHandler != nil) != renderedReady {
            let offset = table.contentOffset
            table.setItems(rows.map { task in
                let row = taskRows[task.id] ?? BackupTaskRow(frame: .zero)
                taskRows[task.id] = row
                row.configure(task, paused: session.isPaused(task.id))
                row.setContentHuggingPriority(.defaultLow, for: .horizontal)
                let controls = UIStackView()
                controls.axis = .vertical
                controls.alignment = .center
                controls.setContentHuggingPriority(.required, for: .horizontal)
                controls.setContentCompressionResistancePriority(.required, for: .horizontal)
                if managing {
                    let isSelected = selectedIDs.contains(task.id)
                    let select = UIButton(type: .system)
                    select.translatesAutoresizingMaskIntoConstraints = false
                    select.accessibilityLabel = String(localizationKey: isSelected ? "Backup_Task_Deselect_Visible" : "Backup_Task_Select_Visible")
                    select.addAction(UIAction { [weak self] _ in
                        guard let self = self, !self.roundRunning else { return }
                        if self.selectedIDs.contains(task.id) { self.selectedIDs.remove(task.id) }
                        else { self.selectedIDs.insert(task.id) }
                        self.render()
                    }, for: .touchUpInside)
                    select.widthAnchor.constraint(equalToConstant: 44).isActive = true
                    select.heightAnchor.constraint(equalToConstant: 44).isActive = true
                    let dot = UIView()
                    dot.translatesAutoresizingMaskIntoConstraints = false
                    dot.isUserInteractionEnabled = false
                    dot.layer.cornerRadius = 12
                    dot.layer.borderWidth = isSelected ? 0 : 2
                    dot.layer.borderColor = UIColor.tertiaryLabel.cgColor
                    dot.backgroundColor = isSelected ? .systemGreen : .clear
                    if isSelected {
                        let check = UIImageView(image: UIImage(systemName: "checkmark"))
                        check.translatesAutoresizingMaskIntoConstraints = false
                        check.tintColor = .white
                        dot.addSubview(check)
                        NSLayoutConstraint.activate([
                            check.centerXAnchor.constraint(equalTo: dot.centerXAnchor),
                            check.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
                            check.widthAnchor.constraint(equalToConstant: 12),
                            check.heightAnchor.constraint(equalToConstant: 12)
                        ])
                    }
                    select.addSubview(dot)
                    NSLayoutConstraint.activate([
                        dot.centerXAnchor.constraint(equalTo: select.centerXAnchor),
                        dot.centerYAnchor.constraint(equalTo: select.centerYAnchor),
                        dot.widthAnchor.constraint(equalToConstant: 24),
                        dot.heightAnchor.constraint(equalToConstant: 24)
                    ])
                    controls.addArrangedSubview(select)
                } else if task.outcome == false, startHandler != nil {
                    let retry = Self.headerButton(title: String(localizationKey: "Backup_Task_Retry")) { [weak self] in
                        self?.retryTask(task.id)
                    }
                    retry.setTitle(nil, for: .normal)
                    retry.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
                    retry.accessibilityLabel = String(localizationKey: "Backup_Task_Retry")
                    retry.isEnabled = !roundRunning && !cancelling && !finishingRestore
                    retry.widthAnchor.constraint(equalToConstant: 44).isActive = true
                    retry.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
                    controls.addArrangedSubview(retry)
                } else if task.outcome == nil, startHandler != nil {
                    let inRound = roundRunning && session.activeIDs.contains(task.id)
                    let paused = session.isPaused(task.id)
                    let key = inRound && !paused ? "Backup_Task_Pause" : "Backup_Task_Start"
                    let control = Self.headerButton(title: String(localizationKey: key)) { [weak self] in
                        guard let self = self else { return }
                        if inRound {
                            self.session.togglePause(task.id)
                            self.renderedReady = false
                            self.render()
                        } else {
                            self.startTask(task.id)
                        }
                    }
                    control.setTitle(nil, for: .normal)
                    let queued = queuedStarts.contains(task.id)
                    control.setImage(UIImage(systemName: queued ? "clock" : (inRound && !paused ? "pause.fill" : "play.fill")), for: .normal)
                    control.accessibilityLabel = String(localizationKey: queued ? "Backup_Task_Queued" : key)
                    control.isEnabled = !cancelling && !queued && (!inRound || task.id != "archive")
                    control.widthAnchor.constraint(equalToConstant: 44).isActive = true
                    control.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
                    controls.addArrangedSubview(control)
                }
                controls.widthAnchor.constraint(equalToConstant: 44).isActive = true
                let stack = UIStackView(arrangedSubviews: [row, controls])
                stack.axis = .horizontal
                stack.alignment = .center
                stack.spacing = 0
                let separator = UIView()
                separator.backgroundColor = .separator
                separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
                let item = UIStackView(arrangedSubviews: task.id == rows.last?.id ? [stack] : [stack, separator])
                item.axis = .vertical
                return SileoPanelTable.Item(item)
            })
            table.layoutIfNeeded()
            let minimumY = -table.adjustedContentInset.top
            let maximumY = max(minimumY, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
            table.setContentOffset(CGPoint(x: offset.x, y: min(maximumY, max(minimumY, offset.y))), animated: false)
            renderedTasks = rows
            renderedSelection = selectedIDs
            renderedManaging = managing
            renderedRunning = roundRunning
            renderedReady = startHandler != nil
            view.setNeedsLayout()
        } else if rows != renderedTasks {
            for task in rows { taskRows[task.id]?.configure(task, paused: session.isPaused(task.id)) }
            renderedTasks = rows
        }
        let retainedIDs = Set(session.tasks.map(\.id))
        taskRows = taskRows.filter { retainedIDs.contains($0.key) }
        manage.setTitle(String(localizationKey: managing ? "Done" : "Backup_Task_Manage"), for: .normal)
        let selectedCount = selectedIDs.count
        let editingAllowed = !roundRunning && !session.hasActiveTasks
        manage.isEnabled = editingAllowed
        clear.setTitle(String(localizationKey: managing ? "Backup_Task_Clear_Selected" : "Backup_Task_Clear"), for: .normal)
        clear.isEnabled = editingAllowed && (managing ? selectedCount > 0 : !session.tasks.isEmpty)
        if !session.tasks.isEmpty {
            resultLabel.text = resultMessage ?? (roundRunning
                ? String(localizationKey: cancelling ? "Backup_Task_Cancelling" : "Backup_Task_Running")
                : (session.hasPendingTasks ? String(localizationKey: "Backup_Task_Ready") : String(localizationKey: "Backup_Task_Empty")))
        } else {
            resultLabel.text = resultMessage ?? String(localizationKey: "Backup_Task_Empty")
        }
        let ready = startHandler != nil && (roundRunning || session.hasPendingTasks)
        let allKey = managing ? "Backup_Task_Select_All" : (roundRunning && !allTasksPaused ? "Backup_Task_Pause_All" : "Backup_Task_Start_All")
        startAllButton?.setTitle(String(localizationKey: allKey), for: .normal)
        startAllButton?.accessibilityLabel = String(localizationKey: allKey)
        startAllButton?.isEnabled = managing ? (editingAllowed && !session.tasks.isEmpty) : (ready && !cancelling)
        startAllButton?.isHidden = !managing && !ready
        action.isHidden = roundRunning ? !cancellable : onFinishedClose == nil
        action.isEnabled = !cancelling
        action.setTitle(String(localizationKey: roundRunning ? "Cancel" : (onFinishedClose != nil ? "Backup_Task_Complete_Action" : "Close")), for: .normal)
    }

    override func close(completion: (() -> Void)? = nil) {
        super.close(completion: completion)
    }

    @objc func cancelWorkTapped() {
        guard cancellable, roundRunning, !cancelling else { return }
        cancelling = true
        for id in queuedStarts {
            session.update(id, fraction: 0, detail: String(localizationKey: "Backup_Task_Waiting"))
        }
        queuedStarts.removeAll()
        renderedReady = false
        render()
        onCancel?()
    }
}
