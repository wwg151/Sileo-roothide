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
    func waitUntilResumed(_ id: String) {
        pauseCondition.lock()
        while pausedIDs.contains(id) && !BackupManager.shared.isCancelled {
            _ = pauseCondition.wait(until: Date(timeIntervalSinceNow: 0.2))
        }
        pauseCondition.unlock()
    }

    var activeIDs = Set<String>()
    var removedIDs = Set<String>()
    var closed = false
    var backupFolder: BackupManager.BackupFolder?
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
        onRoundFinished?()
        onChange?()
    }

    func remove(ids: Set<String>) {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.remove(ids: ids) }; return }
        guard !closed, activeIDs.isEmpty else { return }
        defer { onChange?() }
        for task in tasks where ids.contains(task.id) {
            removedIDs.insert(task.id)
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
        detailLabel.text = paused && task.outcome == nil ? String(localizationKey: "Backup_Task_Pause_Requested") : (task.detail.isEmpty ? String(localizationKey: "Backup_Task_Waiting") : task.detail)
        progress.progressTintColor = task.outcome == false ? .systemRed : .systemBlue
        progress.setProgress(Float(task.fraction), animated: true)
        percentLabel.text = "\(Int(task.fraction * 100))%"
        if let outcome = task.outcome {
            resultImage.image = UIImage(systemName: outcome ? "checkmark.circle.fill" : "xmark.circle.fill")
            resultImage.tintColor = outcome ? .systemGreen : .systemRed
            progress.isHidden = outcome == true
            percentLabel.isHidden = outcome == true
        } else {
            resultImage.image = nil
            progress.isHidden = false
            percentLabel.isHidden = false
        }
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
    var isRunning: Bool { roundRunning }
    var hasUnfinishedTasks: Bool { roundRunning || (startHandler == nil && resultMessage == nil) || session.hasPendingTasks }
    var hasPendingCompletion: Bool { onFinishedClose != nil }
    private let manage = UIButton(type: .system)
    private let selectVisible = UIButton(type: .system)
    private let removeSelected = UIButton(type: .system)
    private let clear = UIButton(type: .system)
    private let action = UIButton(type: .system)
    private var footer: UIStackView!
    private var selectionRow: UIStackView?
    private var renderScheduled = false
    private var startHandler: ((String?) -> Void)?
    private var currentFilter = 0
    private var selectedIDs = Set<String>()
    private var resultMessage: String?
    private var roundRunning = false
    private var cancelling = false

    init(title: String, message: String, cancellable: Bool, onCancel: (() -> Void)?) {
        cardTitle = title
        firstMessage = message
        self.cancellable = cancellable
        self.onCancel = onCancel
        super.init(title: title, subtitle: nil, icon: "archivebox")
        let listBody = UIStackView(arrangedSubviews: [search, filters, table])
        listBody.axis = .vertical
        listBody.spacing = 10
        listBody.isLayoutMarginsRelativeArrangement = true
        listBody.layoutMargins = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        search.heightAnchor.constraint(equalToConstant: 36).isActive = true
        filters.heightAnchor.constraint(equalToConstant: 32).isActive = true
        setBody(listBody)
        let start = Self.headerButton(title: String(localizationKey: "Backup_Task_Start_All")) { [weak self] in self?.startTask(nil) }
        let hide = Self.headerButton(title: String(localizationKey: "Close")) { [weak self] in self?.close() }
        headerAccessory = UIStackView(arrangedSubviews: [start, hide])
        startAllButton = start
        session.onRoundFinished = { [weak self] in
            self?.roundRunning = false
            self?.cancelling = false
            self?.resultMessage = self?.session.lastSummary
            self?.render()
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
        selectVisible.addTarget(self, action: #selector(selectVisibleTapped), for: .touchUpInside)
        removeSelected.addTarget(self, action: #selector(removeSelectedTapped), for: .touchUpInside)
        clear.setTitle(String(localizationKey: "Backup_Task_Clear"), for: .normal)
        clear.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)
        let management = UIStackView(arrangedSubviews: [manage, clear])
        management.axis = .horizontal
        management.distribution = .fillEqually
        let selection = UIStackView(arrangedSubviews: [selectVisible, removeSelected])
        selection.axis = .horizontal
        selection.distribution = .fillEqually
        selectionRow = selection
        footer = UIStackView(arrangedSubviews: [resultLabel, management, selection, action])
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
        render()
    }

    @objc private func selectVisibleTapped() {
        let visible = visibleTasks()
        let ids = Set(visible.map(\.id))
        if ids.isSubset(of: selectedIDs) { selectedIDs.subtract(ids) }
        else { selectedIDs.formUnion(ids) }
        render()
    }

    @objc private func removeSelectedTapped() {
        guard !roundRunning, !selectedIDs.isEmpty else { return }
        session.remove(ids: selectedIDs)
        selectedIDs.removeAll()
        render()
    }

    @objc private func clearTapped() {
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
            onFinishedClose = nil
            close(completion: callback)
        } else { close() }
    }

    private func startTask(_ id: String?) {
        guard !session.closed, let handler = startHandler, !roundRunning else { return }
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
        guard rows.indices.contains(index), !roundRunning else { return }
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

    private func render() {
        guard isViewLoaded else { return }
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
                    let select = Self.headerButton(title: selectedIDs.contains(task.id) ? "☑︎" : "☐") { [weak self] in
                        guard let self = self, !self.roundRunning else { return }
                        if self.selectedIDs.contains(task.id) { self.selectedIDs.remove(task.id) }
                        else { self.selectedIDs.insert(task.id) }
                        self.render()
                    }
                    controls.addArrangedSubview(select)
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
                    control.isEnabled = !cancelling && (!roundRunning || (inRound && task.id != "archive"))
                    control.widthAnchor.constraint(equalToConstant: 56).isActive = true
                    control.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
                    controls.addArrangedSubview(control)
                }
                let stack = UIStackView(arrangedSubviews: controls.arrangedSubviews.isEmpty ? [row] : [row, controls])
                stack.axis = .horizontal
                stack.alignment = .center
                stack.spacing = 2
                return SileoPanelTable.Item(stack)
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
        selectVisible.isHidden = !managing
        removeSelected.isHidden = !managing
        selectionRow?.isHidden = !managing
        manage.setTitle(String(localizationKey: managing ? "Done" : "Backup_Task_Manage"), for: .normal)
        let selectedCount = selectedIDs.count
        let visibleIDs = Set(rows.map(\.id))
        selectVisible.setTitle(String(localizationKey: !visibleIDs.isEmpty && visibleIDs.isSubset(of: selectedIDs) ? "Backup_Task_Deselect_Visible" : "Backup_Task_Select_Visible"), for: .normal)
        removeSelected.setTitle(String(format: String(localizationKey: "Backup_Task_Remove_Count"), selectedCount), for: .normal)
        let editingAllowed = !roundRunning && !session.hasActiveTasks
        manage.isEnabled = editingAllowed
        clear.isEnabled = editingAllowed && !session.tasks.isEmpty
        selectVisible.isEnabled = editingAllowed
        removeSelected.isEnabled = editingAllowed && selectedCount > 0
        if !session.tasks.isEmpty {
            resultLabel.text = resultMessage ?? (roundRunning
                ? String(localizationKey: cancelling ? "Backup_Task_Cancelling" : "Backup_Task_Running")
                : (session.hasPendingTasks ? String(localizationKey: "Backup_Task_Ready") : String(localizationKey: "Backup_Task_Empty")))
        } else {
            resultLabel.text = resultMessage ?? String(localizationKey: "Backup_Task_Empty")
        }
        let ready = startHandler != nil && !roundRunning && session.hasPendingTasks
        startAllButton?.isEnabled = ready
        // No pending work means nothing to start: an always-visible button
        // reads as a second, useless action next to 关闭.
        startAllButton?.isHidden = !ready
        action.isHidden = roundRunning && !cancellable
        action.isEnabled = !cancelling
        action.setTitle(String(localizationKey: roundRunning ? "Cancel" : (onFinishedClose != nil ? "Backup_Task_Complete_Action" : "Close")), for: .normal)
    }

    override func close(completion: (() -> Void)? = nil) {
        super.close(completion: completion)
    }

    @objc func cancelWorkTapped() {
        guard cancellable, roundRunning, !cancelling else { return }
        cancelling = true
        renderedReady = false
        render()
        onCancel?()
    }
}
