//
//  DownloadsTableViewController.swift
//  Sileo
//
//  Created by CoolStar on 8/3/19.
//  Copyright © 2022 Sileo Team. All rights reserved.
//

import UIKit
import Evander


class DownloadsTableViewController: SileoViewController {
    @IBOutlet private var footerView: UIView?
    @IBOutlet private var clearButton: UIButton? //clear queue button
    @IBOutlet private var confirmButton: UIButton?
    @IBOutlet private var footerViewHeight: NSLayoutConstraint?
    @IBOutlet private var tableView: UITableView?
    
    @IBOutlet private var detailsView: UIView?
    @IBOutlet private var detailsTextView: UITextView?
    @IBOutlet private var completeButton: DownloadConfirmButton?
    @IBOutlet private var showDetailsButton: UIButton?
    @IBOutlet private var hideDetailsButton: DownloadConfirmButton?
    @IBOutlet private var completeLaterButton: DownloadConfirmButton?
    @IBOutlet private var doneToTop: NSLayoutConstraint?
    @IBOutlet private var laterHeight: NSLayoutConstraint?
    @IBOutlet private var cancelDownload: DownloadConfirmButton?
    
    private var transitionController = false
    private var statusBarView: UIView?
    
    private var upgrades: [DownloadPackage] = []
    private var installations: [DownloadPackage] = []
    private var uninstallations: [DownloadPackage] = []
    private var installdeps: [DownloadPackage] = []
    private var uninstalldeps: [DownloadPackage] = []
    private var errors: ContiguousArray<APTBrokenPackage> = []
    private var taskGroups = Array(repeating: [DownloadPackage](), count: 5)
    private var groupsShowFailures = false

    @discardableResult private func rebuildTaskGroups() -> Bool {
        let manager = DownloadManager.shared
        let installs = installations + upgrades + installdeps
        func download(_ entry: DownloadPackage) -> Download? {
            guard let value = manager.queuedDownload(package: entry.package.package),
                  value.session == manager.currentDownloadSession else { return nil }
            return value
        }
        let failed = installs.filter { !(download($0)?.failureReason ?? "").isEmpty }
        let separateFailures = isDownloading && !isInstalling && !failed.isEmpty
        var groups = Array(repeating: [DownloadPackage](), count: 5)
        groups[1] = uninstallations + uninstalldeps
        if separateFailures {
            groups[0] = failed
            groups[2] = installs.filter {
                guard let value = download($0) else { return false }
                return value.success && value.progress == 1 && (value.failureReason ?? "").isEmpty
            }
            let assigned = Set((groups[0] + groups[2]).map { $0.package.package })
            groups[4] = installs.filter { !assigned.contains($0.package.package) }
        } else {
            groups[0] = installs
        }
        let changed = groupsShowFailures != separateFailures || zip(taskGroups, groups).contains { pair in
            pair.0.map { $0.package.package } != pair.1.map { $0.package.package }
        }
        taskGroups = groups
        groupsShowFailures = separateFailures
        return changed
    }
    
    private var actions = [Action]()
    
    private var isFired = false
    private var isInstalling = false
    private var isDownloading = false
    private var isFinishedInstalling = false
    
    private var returnButtonAction: APTWrapper.FINISH = .back
    private var refreshSileo = false
    private var detailsAttributedString: NSMutableAttributedString?

    private let taskHeader = UIView()
    private let taskCard = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let taskTitle = UILabel()
    private let taskGrabberButton = UIButton(type: .custom)
    private let taskGrabber = UIView()
    private let taskPrimaryButton = UIButton(type: .system)
    private let taskStage = UILabel()
    private let taskHeadline = UILabel()
    private let taskDetail = UILabel()
    private let taskProgress = UIProgressView(progressViewStyle: .bar)
    private let stageActivity = UIActivityIndicatorView(style: .medium)
    private let footerMaterial = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private var installExitStatus: Int32?
    public private(set) var currentOperationTitle: String?
    private var currentTaskStatus: String?
    struct TaskPresentation {
        let title: String
        let detail: String
        let progress: Double?
        let stage: Int
        let failed: Bool
        let rows: [String]
    }

    /// Main-thread snapshot shared by the window, collapsed queue and peek.
    public var taskPresentation: TaskPresentation {
        let manager = DownloadManager.shared
        let entries = installations + upgrades + installdeps
        let downloads = entries.compactMap { manager.queuedDownload(package: $0.package.package) }
            .filter { $0.session == manager.currentDownloadSession }
        let failures = downloads.filter { !($0.failureReason ?? "").isEmpty }
        let blocked = !errors.isEmpty || !failures.isEmpty
        let rows: [String]
        if !actions.isEmpty {
            rows = actions.map { ($0.package.name ?? $0.package.package) + " · " + ($0.status ?? String(localizationKey: "Ready_Status")) }
        } else {
            rows = (entries + uninstallations + uninstalldeps).map { entry in
                let download = downloads.first { $0.package.package == entry.package.package }
                let status = download?.failureReason.flatMap { $0.isEmpty ? nil : $0 }
                    ?? (download?.success == true && download?.progress == 1
                        ? String(localizationKey: "Task_Downloaded")
                        : download?.message ?? String(localizationKey: "Queued_Package_Status"))
                return (entry.package.name ?? entry.package.package) + " · " + status
            }
        }
        // Completion always wins over every running flag and cached message.
        if isFinishedInstalling {
            let failed = installExitStatus != 0
            return TaskPresentation(title: String(localizationKey: failed ? "Task_Install_Issue" : "Task_Completed"),
                detail: String(localizationKey: failed ? "Task_Check_Log" : "Task_Finish_Hint"),
                progress: failed ? (hasAPTProgress ? min(0.99, aptProgress) : nil) : 1,
                stage: failed ? 1 : 2, failed: failed, rows: rows)
        }
        if isInstalling {
            return TaskPresentation(title: currentOperationTitle ?? String(localizationKey: "Deck_Executing"),
                detail: currentTaskStatus ?? String(localizationKey: "Task_Keep_Open"),
                progress: hasAPTProgress ? min(0.99, aptProgress) : nil, stage: 1, failed: false, rows: rows)
        }
        if blocked {
            return TaskPresentation(title: String(localizationKey: "Task_Attention"),
                detail: failures.first?.failureReason ?? String(localizationKey: "Task_Resolve_Dependencies"),
                progress: nil, stage: 0, failed: true, rows: rows)
        }
        if isDownloading && !entries.isEmpty {
            let converting = downloads.contains { $0.message == String(localizationKey: "Compat_Converting") }
            let ready = !entries.isEmpty && downloads.count == entries.count
                && downloads.allSatisfy { $0.success && $0.progress == 1 }
            let network = entries.filter { $0.package.local_deb == nil }
            var written: Double = 0
            var expected: Double = 0
            var known = !network.isEmpty
            for entry in network {
                let download = downloads.first { $0.package.package == entry.package.package }
                let size = download?.presentationExpectedBytes ?? max(0, Int64(entry.package.size ?? "") ?? 0)
                written += Double(download?.presentationWrittenBytes ?? 0)
                expected += Double(size)
                known = known && size > 0
            }
            let fraction = known && expected > 0 ? max(0, min(1, written / expected)) : nil
            let detail = ready ? String(localizationKey: "Ready_Status")
                : converting ? String(localizationKey: "Compat_Converting")
                : known ? String(format: String(localizationKey: "Download_Progress"),
                    ByteCountFormatter.string(fromByteCount: Int64(min(written, Double(Int64.max / 2))), countStyle: .file),
                    ByteCountFormatter.string(fromByteCount: Int64(min(expected, Double(Int64.max / 2))), countStyle: .file))
                : String(localizationKey: "Download_Starting")
            return TaskPresentation(title: String(localizationKey: ready ? "Ready_Status" : converting ? "Compat_Converting" : "Downloading_Package_Status"),
                detail: detail, progress: converting ? nil : ready ? 1 : fraction, stage: 0, failed: false, rows: rows)
        }
        return TaskPresentation(title: String(localizationKey: "Task_Ready"),
            detail: taskOperationSummary,
            progress: nil, stage: 0, failed: false, rows: rows)
    }

    /// Preserve the operation captured before apt changes installed versions.
    private var taskOperationKeys: [String] {
        if !actions.isEmpty { return actions.map { $0.operationKey } }
        return (installations + upgrades + installdeps).map { Action.operationKey(for: $0.package) }
            + (uninstallations + uninstalldeps).map { _ in "Task_Operation_Remove" }
    }

    private var taskOperationSummary: String {
        let keys = taskOperationKeys
        return ["Install", "Update", "Reinstall", "Downgrade", "Remove"].compactMap { operation -> String? in
            let key = "Task_Operation_" + operation
            let count = keys.filter { $0 == key }.count
            return count > 0 ? String(format: String(localizationKey: key), count) : nil
        }.joined(separator: " · ")
    }

    private var taskExecutionLabel: String {
        let keys = Set(taskOperationKeys)
        guard keys.count == 1, let key = keys.first else { return String(localizationKey: "Deck_Execute") }
        return String(localizationKey: key + "_Stage")
    }

    private var hasAPTProgress = false
    private let stageLabels = (0..<3).map { _ in UILabel() }
    private let stageTracks = (0..<3).map { _ in UIProgressView(progressViewStyle: .bar) }
    private let collapseButton = UIButton(type: .system)
    private var overallProgress: Double = 0
    public private(set) var aptProgress: Double = 0
    private let taskPercentage = UILabel()

    public var presentationHasFailed: Bool {
        !errors.isEmpty || (isFinishedInstalling && installExitStatus != 0)
    }

    private func configureTaskPresentation() {
        view.backgroundColor = .systemGroupedBackground
        tableView?.backgroundColor = .clear
        tableView?.contentInset = .zero
        tableView?.sectionHeaderTopPadding = 0
        taskHeader.addSubview(taskTitle)
        taskGrabberButton.accessibilityLabel = String(localizationKey: "Hide_Install_Details")
        taskGrabberButton.addTarget(self, action: #selector(collapseTask), for: .touchUpInside)
        taskGrabber.isUserInteractionEnabled = false
        taskGrabber.backgroundColor = .tertiaryLabel
        taskGrabber.layer.cornerRadius = 2.5
        taskGrabberButton.addSubview(taskGrabber)
        view.addSubview(taskGrabberButton)
        taskPrimaryButton.layer.cornerRadius = 25
        taskPrimaryButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        taskPrimaryButton.addTarget(self, action: #selector(retryFailedTasks), for: .touchUpInside)
        taskHeader.addSubview(taskCard)
        taskCard.layer.cornerRadius = 25
        taskCard.clipsToBounds = true
        taskCard.layer.borderWidth = 0.5
        [taskStage, taskHeadline, taskDetail, taskProgress, taskPercentage, stageActivity].forEach { taskCard.contentView.addSubview($0) }
        taskTitle.font = .systemFont(ofSize: 29, weight: .bold)
        taskTitle.numberOfLines = 0
        taskTitle.textColor = .label
        taskTitle.text = String(localizationKey: "Deck_Title")
        for (index, label) in stageLabels.enumerated() {
            label.text = String(localizationKey: ["Deck_Download", "Deck_Execute", "Done"][index])
            label.font = .systemFont(ofSize: 12, weight: .medium)
            taskCard.contentView.addSubview(label)
            let track = stageTracks[index]
            track.trackTintColor = .tertiarySystemFill
            track.semanticContentAttribute = .forceLeftToRight
            taskCard.contentView.addSubview(track)
        }
        collapseButton.setTitle(String(localizationKey: "Deck_Collapse"), for: .normal)
        collapseButton.addTarget(self, action: #selector(collapseTask), for: .touchUpInside)
        collapseButton.layer.cornerRadius = 25
        collapseButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        footerView?.addSubview(collapseButton)
        taskStage.font = .systemFont(ofSize: 13, weight: .semibold)
        taskHeadline.font = .systemFont(ofSize: 25, weight: .bold)
        taskHeadline.adjustsFontSizeToFitWidth = true
        taskHeadline.minimumScaleFactor = 0.7
        taskHeadline.textColor = .label
        taskDetail.font = .systemFont(ofSize: 13)
        taskDetail.textColor = .secondaryLabel
        taskDetail.numberOfLines = 2
        taskPercentage.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        taskPercentage.textAlignment = .center
        taskProgress.semanticContentAttribute = .forceLeftToRight
        taskPercentage.textColor = .secondaryLabel
        taskProgress.layer.cornerRadius = 2
        taskProgress.clipsToBounds = true
        taskProgress.trackTintColor = .tertiarySystemFill
        stageActivity.hidesWhenStopped = true
        if let footer = footerView {
            NSLayoutConstraint.deactivate(footer.constraints.filter { $0 !== footerViewHeight })
            for button in [clearButton, confirmButton, completeButton, completeLaterButton, showDetailsButton, cancelDownload].compactMap({ $0 }) {
                button.translatesAutoresizingMaskIntoConstraints = true
                NSLayoutConstraint.deactivate(button.constraints)
                button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
                button.titleLabel?.adjustsFontSizeToFitWidth = true
                button.titleLabel?.minimumScaleFactor = 0.7
                button.layer.cornerRadius = 25
                button.layer.cornerCurve = .continuous
            }
            footer.insertSubview(footerMaterial, at: 0)
            footer.addSubview(taskPrimaryButton)
        }
        footerMaterial.isUserInteractionEnabled = false
        detailsView?.backgroundColor = UIColor(red: 30.0/255.0, green: 32.0/255.0, blue: 40.0/255.0, alpha: 1)
        detailsTextView?.backgroundColor = .clear
        detailsTextView?.layer.cornerRadius = 20
        detailsTextView?.textContainerInset = UIEdgeInsets(top: 18, left: 12, bottom: 18, right: 12)
    }

    private func layoutTaskPresentation() {
        guard let table = tableView else { return }
        let width = table.bounds.width
        // Popup containers can report their safe area before their final position.
        // Convert the window's safe area as well, without adding either inset twice.
        var safeTop = max(view.bounds.minY, view.safeAreaLayoutGuide.layoutFrame.minY)
        if let window = view.window {
            let windowSafeArea = view.convert(window.safeAreaLayoutGuide.layoutFrame, from: window)
            safeTop = max(safeTop, windowSafeArea.minY)
        }
        taskGrabberButton.frame = CGRect(x: (view.bounds.width - 72) / 2, y: safeTop, width: 72, height: 44)
        taskGrabber.frame = CGRect(x: 11, y: 16, width: 50, height: 5)
        taskGrabberButton.isHidden = detailsView?.superview === view
        if !taskGrabberButton.isHidden {
            view.bringSubviewToFront(taskGrabberButton)
        }
        // Keep the scrolling content below the fixed grabber on every device.
        // Preserve the user's scroll position when safe areas change on rotation.
        let topInset = max(0, taskGrabberButton.frame.maxY - table.frame.minY)
        let insetChange = topInset - table.contentInset.top
        if abs(insetChange) > 0.5 {
            let offset = table.contentOffset
            table.contentInset.top = topInset
            table.verticalScrollIndicatorInsets.top = topInset
            table.setContentOffset(CGPoint(x: offset.x, y: offset.y - insetChange), animated: false)
        }
        let titleWidth = max(0, width - 48)
        let titleHeight = max(38, ceil(taskTitle.sizeThatFits(CGSize(width: titleWidth, height: .greatestFiniteMagnitude)).height))
        taskTitle.frame = CGRect(x: 24, y: 8, width: titleWidth, height: titleHeight)
        let cardInset = DownloadsTableViewCell.cardHorizontalInset
        let cardWidth = max(0, width - 2 * cardInset)
        let inner = max(0, cardWidth - 40)
        let stageHeight = max(20, ceil(taskStage.sizeThatFits(CGSize(width: max(0, inner - 28), height: .greatestFiniteMagnitude)).height))
        let headlineHeight = max(34, ceil(taskHeadline.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height))
        let detailHeight = max(36, ceil(taskDetail.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height))
        taskStage.frame = CGRect(x: 20, y: 17, width: max(0, inner - 28), height: stageHeight)
        stageActivity.frame = CGRect(x: inner + 1, y: 17, width: 20, height: 20)
        taskHeadline.frame = CGRect(x: 20, y: taskStage.frame.maxY + 7, width: inner, height: headlineHeight)
        taskDetail.frame = CGRect(x: 20, y: taskHeadline.frame.maxY + 3, width: inner, height: detailHeight)
        let percentageWidth: CGFloat = 72
        taskPercentage.frame = CGRect(x: max(20, cardWidth - 92), y: taskStage.frame.maxY + 8, width: percentageWidth, height: 36)
        taskHeadline.frame.size.width = max(0, inner - 80)
        taskProgress.frame = CGRect(x: 20, y: taskDetail.frame.maxY + 14, width: inner, height: 4)
        let segmentWidth = max(0, (inner - 16) / 3)
        for index in 0..<3 {
            let x = 20 + CGFloat(index) * (segmentWidth + 8)
            stageTracks[index].frame = CGRect(x: x, y: taskProgress.frame.minY, width: segmentWidth, height: 4)
            stageLabels[index].frame = CGRect(x: x, y: taskProgress.frame.maxY + 9, width: segmentWidth, height: 20)
        }
        taskCard.frame = CGRect(x: cardInset, y: taskTitle.frame.maxY + 24, width: cardWidth, height: taskProgress.frame.maxY + 43)
        let headerHeight = taskCard.frame.maxY + 14
        if taskHeader.frame.width != width || taskHeader.frame.height != headerHeight {
            taskHeader.frame = CGRect(x: 0, y: 0, width: width, height: headerHeight)
            table.tableHeaderView = taskHeader
        }
        taskCard.layer.borderColor = UIColor.separator.withAlphaComponent(0.12).cgColor
        guard let footer = footerView else { return }
        footerMaterial.frame = footer.bounds
        let w = footer.bounds.width
        let candidates: [UIButton?]
        if isFinishedInstalling {
            candidates = [showDetailsButton, completeLaterButton, completeButton]
        } else if isDownloading || isInstalling {
            candidates = [showDetailsButton, cancelDownload, taskPrimaryButton, collapseButton]
        } else {
            candidates = [clearButton, confirmButton]
        }
        let buttons = candidates.compactMap { $0 }.filter { !$0.isHidden }
        let gap: CGFloat = 8
        let buttonWidth = max(0, (w - 2 * cardInset - gap * CGFloat(max(0, buttons.count - 1))) / CGFloat(max(1, buttons.count)))
        let buttonY = max(0, (footer.bounds.height - 50) / 2)
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: cardInset + CGFloat(index) * (buttonWidth + gap), y: buttonY, width: buttonWidth, height: 50)
            button.contentHorizontalAlignment = .center
            button.layer.cornerRadius = 25
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = 0.7
        }
    }

    private func refreshTaskPresentation() {
        guard isViewLoaded else { return }
        let manager = DownloadManager.shared
        let downloads = Array(manager.vars.queuedDownloads.raw.values).filter { $0.session == manager.currentDownloadSession }
        let failed = downloads.filter { !($0.failureReason ?? "").isEmpty }
        let active = !isFinishedInstalling && (isInstalling || (isDownloading && failed.isEmpty))
        let snapshot = taskPresentation
        let color: UIColor = snapshot.failed ? .systemRed : (UINavigationBar.appearance().tintColor ?? .systemTeal)
        stageActivity.color = color
        taskTitle.text = String(localizationKey: "Deck_Title")
        let hasDownloadTasks = !(installations + upgrades + installdeps).isEmpty
        let preparationLabel = String(localizationKey: "Deck_Prepare")
        stageLabels[0].text = String(localizationKey: hasDownloadTasks ? "Deck_Download" : "Deck_Prepare")
        stageLabels[1].text = taskExecutionLabel
        taskStage.text = snapshot.failed ? String(localizationKey: "Task_Attention")
            : snapshot.stage == 2 ? String(localizationKey: "Done")
            : snapshot.stage == 1 ? taskExecutionLabel
            : isDownloading && hasDownloadTasks ? String(localizationKey: "Deck_Download") : preparationLabel
        taskHeadline.text = snapshot.title
        taskDetail.text = snapshot.detail
        overallProgress = snapshot.progress ?? 0
        taskProgress.isHidden = true
        taskPercentage.isHidden = snapshot.progress == nil
        taskPercentage.text = "\(Int(overallProgress * 100))%"
        taskPercentage.font = .monospacedDigitSystemFont(ofSize: 23, weight: .semibold)
        let accent: UIColor = snapshot.failed ? .systemRed : (view.tintColor ?? .systemTeal)
        taskCard.contentView.backgroundColor = accent.withAlphaComponent(0.06)
        taskStage.textColor = accent
        taskPercentage.textColor = accent
        for index in 0..<3 {
            let value: Double = index < snapshot.stage ? 1 : index == snapshot.stage ? overallProgress : 0
            stageTracks[index].setProgress(Float(value), animated: false)
            stageTracks[index].progressTintColor = accent
            stageLabels[index].textColor = index == snapshot.stage ? accent : .secondaryLabel
        }
        if active && !snapshot.failed { stageActivity.startAnimating() } else { stageActivity.stopAnimating() }
        collapseButton.isHidden = !isInstalling || isFinishedInstalling
        collapseButton.backgroundColor = accent
        collapseButton.setTitleColor(.white, for: .normal)
        let downloadStage = isDownloading && hasDownloadTasks && !isInstalling && !isFinishedInstalling
        taskPrimaryButton.isHidden = !downloadStage || failed.isEmpty
        taskPrimaryButton.isEnabled = downloadStage && !failed.isEmpty
        taskPrimaryButton.setTitle(String(localizationKey: "Task_Retry_Failed"), for: .normal)
        taskPrimaryButton.backgroundColor = color
        taskPrimaryButton.setTitleColor(.white, for: .normal)
        showDetailsButton?.setTitle(String(localizationKey: "Task_View_Log"), for: .normal)
        refreshDownloadLog()
        view.setNeedsLayout()
    }
    
    @objc private func collapseTask() {
        TabBarController.singleton?.dismissPopupController()
    }

    @objc private func retryFailedTasks() {
        guard isDownloading && !isInstalling && !isFinishedInstalling else { return }
        taskPrimaryButton.isEnabled = false
        DownloadManager.aptQueue.async {
            let manager = DownloadManager.shared
            let failed = manager.vars.queuedDownloads.raw.values.filter {
                $0.session == manager.currentDownloadSession && !($0.failureReason ?? "").isEmpty
            }.map { $0.package.package }
            for package in failed {
                manager.retryDownload(package: package)
            }
            DispatchQueue.main.async {
                self.rebuildTaskGroups()
                self.tableView?.reloadData()
                self.refreshTaskPresentation()
                TabBarController.singleton?.updatePopup()
            }
        }
    }

    public var backgroundCallback: (() -> Void)?
    
    public class Action {
        
        // swiftlint:disable nesting
        public enum ActionType {
            case install
            case removal
        }
        
        static func operationKey(for package: Package, removal: Bool = false) -> String {
            if removal { return "Task_Operation_Remove" }
            guard let installed = PackageListManager.shared.installedPackage(identifier: package.package) else {
                return "Task_Operation_Install"
            }
            if DpkgWrapper.isVersion(package.version, greaterThan: installed.version) { return "Task_Operation_Update" }
            if DpkgWrapper.isVersion(installed.version, greaterThan: package.version) { return "Task_Operation_Downgrade" }
            return "Task_Operation_Reinstall"
        }

        let operationKey: String
        var runningStatus: String {
            String(format: String(localizationKey: operationKey + "_Running"), package.name ?? package.package)
        }
        var package: Package
        var type: ActionType
        var progressCounter: CGFloat = 0.0
        var status: String?
        weak var cell: DownloadsTableViewCell?
        
        public var progress: CGFloat {
            transactionProgress
        }
        var isActive = false
        var transactionProgress: CGFloat = 0
        
        init(package: Package, type: ActionType) {
            self.package = package
            self.type = type
            self.operationKey = Self.operationKey(for: package, removal: type == .removal)
            self.progressCounter = 0.0
        }
        
    }
    
    public override var prefersStatusBarHidden: Bool {
        return isFired
    }
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        
        self.detailsTextView?.delegate = self
        
        let statusBarView = SileoRootView(frame: .zero)
        self.view.addSubview(statusBarView)
        self.statusBarView = statusBarView
        
        self.statusBarStyle = UIDevice.current.userInterfaceIdiom == .pad ? .default : .lightContent
        
        self.tableView?.separatorStyle = .none
        self.tableView?.separatorColor = UIColor(red: 234/255, green: 234/255, blue: 236/255, alpha: 1)
        self.tableView?.isEditing = true
        self.tableView?.clipsToBounds = true
        if UIDevice.current.userInterfaceIdiom == .phone {
            self.tableView?.contentInsetAdjustmentBehavior = .never
            self.tableView?.contentInset = UIEdgeInsets(top: 43, left: 0, bottom: 0, right: 0)
        }
        
        confirmButton?.layer.cornerRadius = 10
        
        confirmButton?.setTitle(String(localizationKey: "Queue_Confirm_Button"), for: .normal)
        clearButton?.setTitle(String(localizationKey: "Queue_Clear_Button"), for: .normal)
        completeButton?.setTitle(String(localizationKey: "After_Install_Respring"), for: .normal)
        completeLaterButton?.setTitle(String(localizationKey: "After_Install_Respring_Later"), for: .normal)
        showDetailsButton?.setTitle(String(localizationKey: "Show_Install_Details"), for: .normal)
        hideDetailsButton?.setTitle(String(localizationKey: "Hide_Install_Details"), for: .normal)
        cancelDownload?.setTitle(String(localizationKey: "Queue_Cancel_Downloads"), for: .normal)
        
        completeButton?.layer.cornerRadius = 10
        completeLaterButton?.layer.cornerRadius = 10
        hideDetailsButton?.layer.cornerRadius = 10
        cancelDownload?.layer.cornerRadius = 10
        showDetailsButton?.isHidden = true
        
        //avoid button's backgroundColor changing when presenting a popover
        confirmButton?.tintAdjustmentMode = .normal
        clearButton?.tintAdjustmentMode = .normal
        completeButton?.tintAdjustmentMode = .normal
        completeLaterButton?.tintAdjustmentMode = .normal
        showDetailsButton?.tintAdjustmentMode = .normal
        hideDetailsButton?.tintAdjustmentMode = .normal
        cancelDownload?.tintAdjustmentMode = .normal
        
        tableView?.register(DownloadsTableViewCell.self, forCellReuseIdentifier: "DownloadsTableViewCell")
        
        configureTaskPresentation()
        self.reloadData()
    }
    
    public override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutTaskPresentation()
        
        guard let tableView = self.tableView,
            let clearButton = self.clearButton,
            let confirmButton = self.confirmButton,
            let statusBarView = self.statusBarView else {
                return
        }
        
        statusBarView.frame = CGRect(origin: .zero, size: CGSize(width: self.view.bounds.width, height: tableView.safeAreaInsets.top))
        
        (clearButton as? DownloadConfirmButton)?.pleaseJustLetMeBeClearThankYouLoveYouBye = false
        clearButton.tintColor = .tertiarySystemFill
        clearButton.isHighlighted = confirmButton.isHighlighted
        clearButton.backgroundColor = clearButton.isHighlighted ? .secondarySystemFill : .tertiarySystemFill
        clearButton.setTitleColor(.label, for: .normal)
        confirmButton.tintColor = UINavigationBar.appearance().tintColor
        confirmButton.isHighlighted = confirmButton.isHighlighted
        completeButton?.tintColor = UINavigationBar.appearance().tintColor
        completeButton?.isHighlighted = completeButton?.isHighlighted ?? false
        cancelDownload?.tintColor = UINavigationBar.appearance().tintColor
        cancelDownload?.isHighlighted = completeButton?.isHighlighted ?? false
        completeLaterButton?.tintColor = .clear
        completeLaterButton?.isHighlighted = completeLaterButton?.isHighlighted ?? false
        completeLaterButton?.setTitleColor(.secondaryLabel, for: .normal)
        completeLaterButton?.layer.cornerRadius = 22
        completeButton?.setTitleColor(.white, for: .normal)
        if isFinishedInstalling {
            showDetailsButton?.setTitleColor(.secondaryLabel, for: .normal)
            showDetailsButton?.layer.cornerRadius = 22
        }
 
        hideDetailsButton?.tintColor = UINavigationBar.appearance().tintColor
        hideDetailsButton?.isHighlighted = hideDetailsButton?.isHighlighted ?? false
    }
    
    public func reloadData() {
        if !isInstalling {
            let manager = DownloadManager.shared
            let upgrades = manager.vars.upgrades.raw.sorted(by: { $0.package.name.lowercased() < $1.package.name.lowercased() })
            let installations = manager.vars.installations.raw.sorted(by: { $0.package.name.lowercased() < $1.package.name.lowercased() })
            let uninstallations = manager.vars.uninstallations.raw.sorted(by: { $0.package.name.lowercased() < $1.package.name.lowercased() })
            let installdeps = manager.vars.installdeps.raw.sorted(by: { $0.package.name.lowercased() < $1.package.name.lowercased() })
            let uninstalldeps = manager.vars.uninstalldeps.raw.sorted(by: { $0.package.name.lowercased() < $1.package.name.lowercased() })
            let errors = manager.vars.errors.raw
            
            self.upgrades = upgrades
            self.installations = installations
            self.uninstallations = uninstallations
            self.installdeps = installdeps
            self.uninstalldeps = uninstalldeps
            self.errors = ContiguousArray<APTBrokenPackage>(errors)
        }
        rebuildTaskGroups()
        self.tableView?.reloadData()
        self.reloadControlsOnly()
    }

    //update state/UI and start the installation (if applicable)
    public func reloadControlsOnly() {
        NSLog("SileoLog: reloadControlsOnly")
//        Thread.callStackSymbols.forEach{NSLog("SileoLog: reloadControlsOnly callstack=\($0)")}

        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.reloadControlsOnly()
            }
            return
        }
        
        let manager = DownloadManager.shared
        let waiting = !isDownloading && !isInstalling && !isFinishedInstalling
        clearButton?.isHidden = !waiting
        confirmButton?.isHidden = !waiting
        cancelDownload?.isHidden = !(isDownloading || isInstalling) || isFinishedInstalling
        cancelDownload?.isEnabled = (isDownloading && !isInstalling && !manager.aptRunning)
            || (manager.restoreBatch != nil && isInstalling && !isFinishedInstalling)
        cancelDownload?.alpha = cancelDownload?.isEnabled == true ? 1 : 0.4
        completeButton?.isHidden = !isFinishedInstalling
        completeLaterButton?.isHidden = !isFinishedInstalling || completeLaterButton?.alpha == 0
        if isFinishedInstalling {
            showDetailsButton?.isHidden = installExitStatus == 0
        } else {
            showDetailsButton?.isHidden = !isDownloading && !isInstalling
        }
        confirmButton?.isEnabled = manager.vars.errors.isEmpty
        confirmButton?.alpha = manager.vars.errors.isEmpty ? 1 : 0.5
        let visible = manager.operationCount() > 0 || !errors.isEmpty || isDownloading || isInstalling || isFinishedInstalling
        footerViewHeight?.constant = visible ? 80 : 0
        footerView?.alpha = visible ? 1 : 0
        refreshTaskPresentation()
    }
    
    private func checkReady() {
        let manager = DownloadManager.shared
        if manager.operationCount() > 0 && manager.verifyComplete() && manager.queueRunning && manager.vars.errors.isEmpty {
            isDownloading = false
            cancelDownload?.isHidden = true
            FRUIView.animate(withDuration: 0.25) {
                self.footerViewHeight?.constant = 0
                self.footerView?.alpha = 0
            }
            transferToAction()
            TabBarController.singleton?.presentPopupController()
        }
    }
    
    public func updateDownloadStatus(download: Download) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [self] in
                self.updateDownloadStatus(download: download)
            }
            return
        }
        
        NSLog("SileoLog: updateDownloadStatus \(download.package.package) download=\(download),\(download.progress)")
        
        guard download.session == DownloadManager.shared.currentDownloadSession else {
            return
        }
        
        let groupsChanged = rebuildTaskGroups()
        if groupsChanged {
            tableView?.reloadData()
        }
        var heightChanged = false
        for cell in tableView?.loadedCells ?? [] {
            if let cell = cell as? DownloadsTableViewCell {
                if cell.package?.package == download.package.package {
                    let previousStatus = cell.subtitle
                    if cell.download !== download {
                        cell.download = download
                    }
                    cell.updateStatus()
                    heightChanged = previousStatus != cell.subtitle
                    break
                }
            }
        }
        
        TabBarController.singleton?.updatePopup()
        // Error text can grow while the row remains visible.
        if heightChanged {
            UIView.performWithoutAnimation {
                tableView?.beginUpdates()
                tableView?.endUpdates()
            }
        }
        refreshTaskPresentation()
        self.checkReady()
    }
    
    @IBAction public func cancelDownload(_ sender: Any?) {
        NSLog("SileoLog: ***cancelDownload \(sender)")
        if !Thread.isMainThread {
            fatalError("Wtf are you doing")
        }
        
        if DownloadManager.shared.restoreBatch != nil && isInstalling && !isFinishedInstalling {
            BackupManager.shared.cancelCurrentOperation()
            currentTaskStatus = String(localizationKey: "Restore_Isolation_Cancelling")
            refreshTaskPresentation()
            return
        }
        guard isDownloading && !isInstalling && !isFinishedInstalling,
              !DownloadManager.shared.aptRunning else { return }

        if let sender = sender as? UIButton, sender.isHidden {
            return //UIKit bug: https://stackoverflow.com/questions/37916952/ios-why-does-hidden-button-still-receive-tap-events/37918283#37918283
        }
        
        isInstalling = false
        isDownloading = false
        isFinishedInstalling = false
        returnButtonAction = .back
        refreshSileo = false
        installExitStatus = nil
        currentTaskStatus = nil
        currentOperationTitle = nil
        self.actions.removeAll()
        self.tableView?.setEditing(true, animated: true)
        
        DownloadManager.shared.queueRunning = false
        DownloadManager.shared.cancelDownloads()
        NotificationCenter.default.post(name: DownloadManager.lockStateChangeNotification, object: nil)
        
        self.reloadData()
        TabBarController.singleton?.updatePopup()
    }
    
    @IBAction private func cancelQueued(_ sender: Any?) {
        NSLog("SileoLog: cancelQueued")
        isInstalling = false
        isDownloading = false
        isFinishedInstalling = false
        returnButtonAction = .back
        refreshSileo = false
        installExitStatus = nil
        currentTaskStatus = nil
        currentOperationTitle = nil
        self.actions.removeAll()
        
        DownloadManager.shared.queueRunning = false
        NotificationCenter.default.post(name: DownloadManager.lockStateChangeNotification, object: nil)
        
        DownloadManager.aptQueue.async {
            DownloadManager.shared.removeAllItems()
            DownloadManager.shared.reloadData(recheckPackages: true)
        }

        TabBarController.singleton?.dismissPopupController(completion: { [self] in
            tableView?.setEditing(true, animated: true)
        })
        TabBarController.singleton?.updatePopup(bypass: true)
    }
    
    @IBAction public func confirmQueued(_ sender: Any?) {
        guard DownloadManager.shared.restoreBatch == nil, !DownloadManager.shared.aptRunning else { return }
        NSLog("SileoLog: confirmQueued(\(sender))")
        if sender != nil {
            let actions = uninstallations + uninstalldeps
            let essentialPackages = actions.map { $0.package }.filter { DownloadManager.shared.isEssential($0) }
            if essentialPackages.isEmpty {
                return confirmQueued(nil)
            }
            let formatPackages = essentialPackages.map { "\n\($0.name ?? $0.package)" }.joined()
            let message = String(format: String(localizationKey: "Essential_Warning"), formatPackages)
            let alert = UIAlertController(title: String(localizationKey: "Warning"),
                                          message: message,
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localizationKey: "Cancel"), style: .default, handler: { _ in
                alert.dismiss(animated: true)
            }))
            alert.addAction(UIAlertAction(title: String(localizationKey: "Dangerous_Repo.Last_Chance.Continue"), style: .destructive, handler: { _ in
                self.confirmQueued(nil)
            }))
            self.present(alert, animated: true, completion: nil)
            return
        }
        
        // This controller is reused between transactions. Do not carry an open
        // log overlay from the previous transaction into the new one.
        detailsView?.layer.removeAllAnimations()
        detailsView?.removeFromSuperview()
        detailsView?.alpha = 0
        taskGrabberButton.isHidden = false
        statusBarStyle = UIDevice.current.userInterfaceIdiom == .pad ? .default : .lightContent
        isDownloading = true
        overallProgress = 0
        aptProgress = 0
        hasAPTProgress = false
        installExitStatus = nil
        currentTaskStatus = nil
        currentOperationTitle = nil
        
        DownloadManager.shared.aptRunning = false
        DownloadManager.shared.aptFinished = false
        DownloadManager.shared.queueRunning = true
        DownloadManager.shared.currentDownloads = 0
        NotificationCenter.default.post(name: DownloadManager.lockStateChangeNotification, object: nil)
        
        NSLog("SileoLog: startMoreDownloads (confirmQueued)")
        if DownloadManager.shared.restoreBatch != nil {
            self.reloadData()
            self.transferToAction()
        } else {
            DownloadManager.shared.startDownloads()
            TabBarController.singleton?.updatePopup()
            self.reloadData()
            self.checkReady()
        }
        
        tableView?.setEditing(false, animated: true)
        for cell in tableView?.visibleCells ?? [] {
            if let cell = cell as? DownloadsTableViewCell {
                cell.setEditing(false, animated: true)
            }
        }
    }
    
    override func accessibilityPerformEscape() -> Bool {
        TabBarController.singleton?.dismissPopupController()
        return true
    }
    
    private func transferToAction() {
        NSLog("SileoLog: transferToAction \(isInstalling)")
        if isInstalling {
            return
        }
        isInstalling = true
        aptProgress = 0
        hasAPTProgress = false
        overallProgress = 0
        var earlyBreak = false
        if UIApplication.shared.applicationState == .background || UIApplication.shared.applicationState == .inactive, let completion = backgroundCallback {
            earlyBreak = true
            completion()
        }
        
        detailsAttributedString = NSMutableAttributedString(string: "")
        let installs = installations + upgrades + installdeps
        if UserDefaults.standard.bool(forKey: "CanisterIngest", fallback: false) {
            CanisterResolver.shared.ingest(packages: installs.map { $0.package })
        }
        let removals = uninstallations + uninstalldeps
        self.actions += installs.map {
            let action = Action(package: $0.package, type: .install)
            action.transactionProgress = 0
            return action
        }
        self.actions += removals.map { Action(package: $0.package, type: .removal) }
        
        for cell in tableView?.loadedCells ?? [] {
            if let cell = cell as? DownloadsTableViewCell {
                if let action = actions.first(where: { $0.package.package == cell.package?.package }) {
                    cell.action = action
                }
            }
        }
        
        if rebuildTaskGroups() {
            tableView?.reloadData()
        }
        reloadControlsOnly()
        if !earlyBreak || DownloadManager.shared.restoreBatch != nil {
            //always startInstall after UI update is complete
//            DispatchQueue.main.async {
                self.startAction()
//            }
        }
    }
    
    private func statusWork(package: String, status: String) {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.statusWork(package: package, status: status)
            }
            return
        }
        guard !isFinishedInstalling else { return }
        let matching = actions.first { $0.package.package == package }
        for previous in actions where previous !== matching && previous.isActive {
            previous.isActive = false
            previous.status = String(localizationKey: "Deck_Waiting_Result")
            previous.cell?.updateStatus()
        }
        guard let action = matching else {
            currentOperationTitle = String(localizationKey: "Deck_Executing")
            currentTaskStatus = APTLogTranslator.localize(status)
            return
        }
        action.isActive = true
        action.progressCounter += 1
        let step = status.trimmingCharacters(in: .whitespacesAndNewlines)
        if (action.type == .removal && step.hasPrefix("Removed"))
            || (action.type == .install && step.hasPrefix("Installed")) {
            action.isActive = false
            action.status = String(localizationKey: action.operationKey + "_Completed")
            action.cell?.updateStatus()
            currentOperationTitle = String(localizationKey: "Deck_Executing")
            currentTaskStatus = action.status
            return
        }
        let stepKey: String?
        if step.hasPrefix("Preparing") {
            stepKey = "Task_Step_Preparing"
        } else if step.hasPrefix("Unpacking") {
            stepKey = "Task_Step_Unpacking"
        } else if step.hasPrefix("Configuring") || step.hasPrefix("Setting up") {
            stepKey = "Task_Step_Configuring"
        } else if step.hasPrefix("Removing") {
            stepKey = "Task_Step_Removing"
        } else if step.hasPrefix("Running") || step.hasPrefix("Processing triggers") {
            stepKey = "Task_Step_Triggers"
        } else {
            stepKey = nil
        }
        action.status = stepKey.map {
            String(format: String(localizationKey: $0), action.package.name ?? action.package.package)
        } ?? action.runningStatus
        NSLog("SileoLog: action=\(action) cell=\(action.cell)")
        action.cell?.updateStatus()
        currentTaskStatus = action.status
        currentOperationTitle = String(format: String(localizationKey: action.operationKey + "_Running"), "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func queueCompleted() {
        isInstalling = false
        isFinishedInstalling = false
        returnButtonAction = .back
        refreshSileo = false
        installExitStatus = nil
        currentTaskStatus = nil
        currentOperationTitle = nil
        actions.removeAll()

        TabBarController.singleton?.popupContent?.popupInteractionStyle = .default
        DownloadManager.shared.queueRunning = false
        DownloadManager.aptQueue.async {
            DownloadManager.shared.removeAllItems()
            DownloadManager.shared.reloadData(recheckPackages: true)
        }
        TabBarController.singleton?.dismissPopupController(completion: { [self] in
            tableView?.setEditing(true, animated: true)
        })
        TabBarController.singleton?.updatePopup(bypass: true)
    }
    
    @IBAction private func completeButtonTapped(_ sender: Any?) {
        if returnButtonAction == .back && !refreshSileo {
            queueCompleted()
            return
        }
        
        guard !isFired else { return }
        isFired = true
        completeButton?.isEnabled = false
        completeLaterButton?.isEnabled = false
        let finish = returnButtonAction
        let refresh = refreshSileo
        let restartRequested = finish == .reload || finish == .restart || finish == .reboot || finish == .usreboot
        let clearedRestartReminder = restartRequested && refresh
            && UserDefaults.standard.bool(forKey: "uicacheRequired")
        // Persist before requesting a restart: success terminates this process,
        // so there may never be a completion callback to clear the reminder.
        if clearedRestartReminder {
            UserDefaults.standard.set(false, forKey: "uicacheRequired")
            UserDefaults.standard.synchronize()
        }
        // Keep the window visible and the main thread responsive if a helper fails.
        DispatchQueue.global(qos: .userInitiated).async {
            var result: (Int, String, String) = (0, "", "")
            
            //1: at least since iOS16, "uicache -p sileo.app" will kill the sileo process (when only the bundle mtime changed)
            //2: rebooting userspace immediately after executing uicache may cause jailbreak apps to disappear
            
            switch finish {
            case .uicache:
                result = spawnAsRoot(args: [jbroot("/usr/bin/uicache"), "-a"])
            case .reload, .restart:
                result = spawnAsRoot(args: [jbroot("/usr/bin/sbreload")])
            case .reboot, .usreboot:
                spawnAsRoot(args: [jbroot("/usr/bin/sync")])
                result = spawnAsRoot(args: [jbroot("/usr/bin/launchctl"), "reboot", "userspace"])
            case .reopen, .back:
                if refresh {
                    result = spawnAsRoot(args: [jbroot("/usr/bin/uicache"), "-p", rootfs(Bundle.main.bundlePath)])
                    if result.0 == 0 {
                        UserDefaults.standard.setValue(false, forKey: "uicacheRequired")
                    }
                }
                if result.0 == 0 && (finish == .reopen || refresh) { exit(0) }
            }
            let commandStatus = result.0
            let commandError = result.2
            let delay: TimeInterval = commandStatus == 0 && restartRequested ? 3 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if clearedRestartReminder {
                    UserDefaults.standard.set(true, forKey: "uicacheRequired")
                    UserDefaults.standard.synchronize()
                }
                self.isFired = false
                self.completeButton?.isEnabled = true
                self.completeLaterButton?.isEnabled = true
                self.setNeedsStatusBarAppearanceUpdate()
                if commandStatus == 0 && (finish == .uicache || finish == .back) {
                    self.queueCompleted()
                } else {
                    // A restart normally terminates this process. If it returns,
                    // keep the completion screen available for a manual retry.
                    let alert = UIAlertController(
                        title: String(localizationKey: "Task_Attention"),
                        message: String(localizationKey: "Task_Finish_Action_Failed")
                            + (commandError.isEmpty ? "" : "\n" + commandError),
                        preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: String(localizationKey: "Done"), style: .default))
                    self.present(alert, animated: true)
                }
            }
        }
    }
    
    @IBAction private func completeLaterButtonTapped(_ sender: Any?) {
        queueCompleted()
    }
    
    private func transform(attributedString: NSMutableAttributedString) -> NSMutableAttributedString {
        let font = UIFont(name: "Menlo-Regular", size: 12) ?? UIFont.systemFont(ofSize: 12)
        
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacing = 4
        
        attributedString.addAttributes([
            NSAttributedString.Key.font: font,
            NSAttributedString.Key.paragraphStyle: paragraphStyle
        ], range: NSRange(location: 0, length: attributedString.length))
        return attributedString
    }
    
    private func startAction() {
        if DownloadManager.shared.restoreBatch != nil { performInstallAction(); return }
        let packages = (installations + upgrades + installdeps).map { $0.package }
        guard UserDefaults.standard.bool(forKey: "AutoSavePackages"), !packages.isEmpty else {
            performInstallAction()
            return
        }
        // Lock the transaction during the preparation step as well.
        DownloadManager.shared.aptRunning = true
        func showSaveProgress(_ message: String) {
            DispatchQueue.main.async {
                self.currentTaskStatus = message
                self.detailsAttributedString?.append(NSAttributedString(string: message + "\n"))
                if let details = self.detailsAttributedString {
                    self.detailsTextView?.attributedText = self.transform(attributedString: details)
                }
                self.reloadControlsOnly()
            }
        }
        showSaveProgress(String(localizationKey: "Auto_Save_Packages_Checking"))
        DownloadManager.shared.checkSavedPackages(packages, progress: showSaveProgress) {
            self.currentTaskStatus = nil
            self.performInstallAction()
        }
    }

    private func shouldShow(_ finish: APTWrapper.FINISH) -> Bool {
        finish == .reload || finish == .restart || finish == .reboot || finish == .usreboot
    }

    private func performInstallAction() {
        NSLog("SileoLog: startAction")
        
        if let detailsAttributedString = self.detailsAttributedString {
            detailsTextView?.attributedText = self.transform(attributedString: detailsAttributedString)
        }
        
        DownloadManager.shared.aptRunning = true
        DownloadManager.shared.aptFinished = false
        
        TabBarController.singleton?.updatePopup()

        let installedToRecord = (installations + upgrades + installdeps).map { $0.package }
        let removedToForget = (uninstallations + uninstalldeps).map { $0.package.package }
        let restoreBatch = DownloadManager.shared.restoreBatch
        func execute(progressCallback: @escaping (Double, Bool, String, String) -> Void,
                     outputCallback: @escaping (String, Int) -> Void,
                     completionCallback: @escaping (Int, APTWrapper.FINISH, Bool) -> Void) {
            if let batch = restoreBatch {
                batch.perform(progress: progressCallback, output: outputCallback, completion: completionCallback)
            } else {
                APTWrapper.performOperations(installs: installations + upgrades,
                    removals: uninstallations + uninstalldeps, installDeps: installdeps,
                    progressCallback: progressCallback, outputCallback: outputCallback,
                    completionCallback: completionCallback)
            }
        }
        execute(progressCallback: { progress, statusValid, statusReadable, package in
            NSLog("SileoLog: progressCallback \(statusValid) \(package) \(statusReadable)")
            if statusValid {
                DispatchQueue.main.async {
                    guard !self.isFinishedInstalling else { return }
                    if progress.isFinite {
                        self.hasAPTProgress = true
                        self.aptProgress = max(self.aptProgress, min(1, max(0, progress / 100)))
                    }
                    for action in self.actions {
                        action.transactionProgress = CGFloat(min(0.99, self.aptProgress))
                        action.cell?.updateStatus()
                    }
                    self.statusWork(package: package, status: statusReadable)
                    self.refreshTaskPresentation()
                    // apt also reports transaction-wide steps with no matching
                    // package action; those must advance the collapsed ring too.
                    TabBarController.singleton?.updatePopup()
                }
            }
        }, outputCallback: { output, pipe in
            NSLog("SileoLog: apt outputCallback \(pipe):\(output)")
            var textColor = Dusk.foregroundColor
            if pipe == STDERR_FILENO {
                textColor = Dusk.errorColor
                // stderr also carries warnings and maintainer-script diagnostics.
                // Keep their log colour, but determine failure from apt's result.
            }
            if pipe == APTWrapper.debugFD {
                textColor = Dusk.debugColor
            }
            
            if output.prefix(2) == "W:" || output.contains("dpkg: warning") {
                textColor = Dusk.warningColor
            }
            
            let substring = NSMutableAttributedString(string: APTLogTranslator.localize(output), attributes: [NSAttributedString.Key.foregroundColor: textColor])
            DispatchQueue.main.async {
                self.detailsAttributedString?.append(substring)
                
                guard let detailsAttributedString = self.detailsAttributedString else {
                    return
                }
                
                self.detailsTextView?.attributedText = self.transform(attributedString: detailsAttributedString)
                
                self.detailsTextView?.scrollRangeToVisible(NSRange(location: detailsAttributedString.string.count - 1, length: 1))
            }
        }, completionCallback: { status, finish, refresh in
            NSLog("SileoLog: apt completionCallback \(status) \(finish) \(refresh)")
            if status == 0 {
                installedToRecord.forEach { InstalledSourceStore.record($0) }
                removedToForget.forEach { InstalledSourceStore.remove(identifier: $0) }
            }
            PackageListManager.shared.reloadInstalled()
            DispatchQueue.main.async {
                
                DownloadManager.shared.aptRunning = false
                DownloadManager.shared.aptFinished = true
                
                NotificationCenter.default.post(name: PackageListManager.stateChange, object: nil)
                NotificationCenter.default.post(name: PackageListManager.installChange, object: nil)
                let rawUpdates = PackageListManager.shared.availableUpdates()
                let updatesNotIgnored = rawUpdates.filter({ $0.1?.wantInfo != .hold })
                UIApplication.shared.applicationIconBadgeNumber = updatesNotIgnored.count
                
                self.installExitStatus = Int32(status)
                self.isFinishedInstalling = true
                self.currentTaskStatus = nil
                self.currentOperationTitle = nil
                self.actions.forEach {
                    $0.isActive = false
                    if status == 0 { $0.transactionProgress = 1 }
                    // A nonzero transaction exit cannot confirm each item's result.
                    if let batch = restoreBatch {
                        let identifier = $0.package.package
                        $0.status = batch.results[identifier] ?? String(localizationKey:
                            batch.succeeded.contains(identifier) ? $0.operationKey + "_Completed" : "Task_Result_Unconfirmed")
                        if batch.succeeded.contains(identifier) { $0.transactionProgress = 1 }
                    } else {
                        $0.status = String(localizationKey: status == 0
                            ? $0.operationKey + "_Completed" : "Task_Result_Unconfirmed")
                    }
                    $0.progressCounter = 7
                    $0.cell?.updateStatus()
                }
                self.tableView?.reloadData()
                
                if let session = restoreBatch?.taskSession {
                    if finish.rawValue > session.accumulatedFinish.rawValue { session.accumulatedFinish = finish }
                    session.accumulatedRefresh = session.accumulatedRefresh || refresh
                    self.returnButtonAction = session.accumulatedFinish
                    self.refreshSileo = session.accumulatedRefresh
                } else {
                    self.returnButtonAction = finish
                    self.refreshSileo = refresh
                }
                self.updateCompleteButton()
                restoreBatch?.taskSession?.finish(restoreBatch?.summary ?? "")
                self.completeButton?.alpha = 1
                self.completeLaterButton?.alpha = self.shouldShow(self.returnButtonAction) ? 1 : 0
                
                self.reloadControlsOnly()
                
                TabBarController.singleton?.updatePopup()
                
                // Successful transactions respect the preference even if apt
                // emitted warnings. Failed transactions must remain inspectable.
                if restoreBatch != nil || UserDefaults.standard.bool(forKey: "AlwaysShowLog") || status != 0 {
                    self.showDetails(nil)
                } else if UserDefaults.standard.bool(forKey: "AutoComplete") {
                    self.completeButtonTapped(nil)
                }
                NotificationCenter.default.post(name: NSNotification.Name("Sileo.CompleteInstall"), object: nil)
            }
        })
    }
        
    private func updateCompleteButton() {
        switch returnButtonAction {
        case .back:
            if refreshSileo {
                completeButton?.setTitle(String(localizationKey: "After_Install_Relaunch"), for: .normal)
                completeLaterButton?.setTitle(String(localizationKey: "After_Install_Relaunch_Later"), for: .normal)
            } else {
                completeButton?.setTitle(String(localizationKey: "Done"), for: .normal)
            }
        case .uicache:
            completeButton?.setTitle(String(localizationKey: "Refresh"), for: .normal)
        case .reopen:
            completeButton?.setTitle(String(localizationKey: "After_Install_Relaunch"), for: .normal)
            completeLaterButton?.setTitle(String(localizationKey: "After_Install_Relaunch_Later"), for: .normal)
        case .reload, .restart:
            completeButton?.setTitle(String(localizationKey: "After_Install_Respring"), for: .normal)
            completeLaterButton?.setTitle(String(localizationKey: "After_Install_Respring_Later"), for: .normal)
        case .reboot, .usreboot:
            completeButton?.setTitle(String(localizationKey: "After_Install_Reboot"), for: .normal)
            completeLaterButton?.setTitle(String(localizationKey: "After_Install_Reboot_Later"), for: .normal)
        }
        
        if refreshSileo {
            UserDefaults.standard.setValue(true, forKey: "uicacheRequired")
            UserDefaults.standard.synchronize()
        }
    }
    
    private func refreshDownloadLog() {
        let downloading = isDownloading && !isInstalling && !isFinishedInstalling
        detailsTextView?.textContainerInset.bottom = 18
        guard downloading, detailsView?.superview != nil else { return }
        let manager = DownloadManager.shared
        let lines = (installations + upgrades + installdeps).map { entry -> String in
            let package = entry.package
            guard let download = manager.queuedDownload(package: package.package),
                  download.session == manager.currentDownloadSession else {
                return "\(package.name) (\(package.package))\n\(String(localizationKey: "Download_Starting"))"
            }
            let status: String
            if let failure = download.failureReason, !failure.isEmpty {
                status = failure
            } else if download.success && download.progress == 1 {
                status = String(localizationKey: "Task_Downloaded")
            } else {
                status = String(localizationKey: "Downloading_Package_Status")
            }
            let bytes = ByteCountFormatter.string(fromByteCount: max(0, download.totalBytesWritten), countStyle: .file)
            return "\(package.name) (\(package.package))\n\(status) · \(bytes)"
        }
        detailsTextView?.attributedText = transform(attributedString: NSMutableAttributedString(
            string: lines.joined(separator: "\n\n"),
            attributes: [.foregroundColor: UIColor.white]))
    }

    @IBAction private func showDetails(_ sender: Any?) {
        guard let detailsView = self.detailsView else {
            return
        }
        detailsView.alpha = 0
        detailsView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        detailsView.frame = self.view.bounds
        
        self.view.addSubview(detailsView)
        refreshDownloadLog()
        
        self.view.bringSubviewToFront(detailsView)
        taskGrabberButton.isHidden = true
        FRUIView.animate(withDuration: 0.25) {
            self.detailsView?.alpha = 1
            self.statusBarStyle = .lightContent
        }
    }
    
    @IBAction private func hideDetails(_ sender: Any?) {
        FRUIView.animate(withDuration: 0.25, animations: {
            self.detailsView?.alpha = 0
            
            self.statusBarStyle = UIDevice.current.userInterfaceIdiom == .pad ? .default : .lightContent
        }, completion: { _ in
            self.detailsView?.removeFromSuperview()
            self.taskGrabberButton.isHidden = false
            self.view.setNeedsLayout()
        })
    }

}

extension DownloadsTableViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        5
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 3 ? errors.count : taskGroups[section].count
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if tableView.numberOfRows(inSection: section) == 0 {
            return nil
        }
        switch section {
        case 0:
            return String(localizationKey: groupsShowFailures ? "Task_Attention" : "Task_Install_Update")
        case 1:
            return String(localizationKey: "Queued_Uninstall_Heading")
        case 2:
            return String(localizationKey: "Task_Downloaded")
        case 3:
            return String(localizationKey: "Download_Errors_Heading")
        case 4:
            return String(localizationKey: "Downloading_Package_Status")
        default:
            return nil
        }
    }
    
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let count = self.tableView(tableView, numberOfRowsInSection: section)
        guard count > 0, let text = self.tableView(tableView, titleForHeaderInSection: section) else { return nil }
        let header = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 38))
        header.backgroundColor = .systemGroupedBackground
        let label = UILabel(frame: CGRect(x: 28, y: 7, width: tableView.bounds.width - 56, height: 24))
        label.autoresizingMask = .flexibleWidth
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = section == 3 ? .systemOrange : .secondaryLabel
        label.text = "\(text) · \(count)"
        header.addSubview(label)
        return header
    }
    
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if self.tableView(tableView, numberOfRowsInSection: section) > 0 {
            return 36
        }
        return 0
    }
    
    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        UIView() // do not show extraneous tableview separators
    }
    
    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        8
    }
    
    private func dependencyDescription(_ error: APTBrokenPackage) -> String {
        error.conflictingPackages.map { conflict in
            let version = conflict.versionSummary.map { "(\($0))" } ?? ""
            return "\(conflict.conflict.localizedName) \(conflict.package)\(version)"
        }.joined(separator: ", ")
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if indexPath.section == 3 {
            return DownloadsTableViewCell.recommendedHeight(forError: dependencyDescription(errors[indexPath.row]), contentWidth: tableView.bounds.width, hasButton: true)
        }
        let packages = taskGroups[indexPath.section]
        if packages.indices.contains(indexPath.row),
           let failure = DownloadManager.shared.queuedDownload(package: packages[indexPath.row].package.package)?.failureReason,
           !failure.isEmpty {
            let message = String(format: String(localizationKey: "Error_Indicator", type: .error), failure)
            return DownloadsTableViewCell.recommendedHeight(forError: message, contentWidth: tableView.bounds.width, hasButton: true)
        }
        return DownloadsTableViewCell.preferredRowHeight
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cellIdentifier = "DownloadsTableViewCell"
        // swiftlint:disable force_cast
        let cell = tableView.dequeueReusableCell(withIdentifier: cellIdentifier, for: indexPath) as! DownloadsTableViewCell
        if indexPath.section == 3 {
            // Error listing
            let error = errors[indexPath.row]
            let allpackages = upgrades+installations+installdeps+uninstallations+uninstalldeps
            if let package = allpackages.first(where: { $0.package.package == error.packageID }) {
                cell.package = package.package
            } else {
                cell.package = Package(package: error.packageID, version: "-1")
            }
            cell.errorDescription = dependencyDescription(error)
            cell.searchPackageKeyword = error.conflictingPackages.first?.package
        } else {
            // Normal operation listing
            let package = taskGroups[indexPath.section][indexPath.row].package
            
            cell.package = package
            cell.isDependency = (installdeps + uninstalldeps).contains { $0.package.package == package.package }
            cell.download = DownloadManager.shared.queuedDownload(package: package.package)
            cell.action = actions.first(where: { $0.package.package == package.package })
        }
        cell.configureGroupPosition(isFirst: indexPath.row == 0,
                                    isLast: indexPath.row == self.tableView(tableView, numberOfRowsInSection: indexPath.section) - 1)
        cell.updateStatus()
        return cell
    }
}

extension DownloadsTableViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        guard indexPath.section != 3, !isInstalling, !isDownloading else { return false }
        let identifier = taskGroups[indexPath.section][indexPath.row].package.package
        return (installations + upgrades + uninstallations).contains { $0.package.package == identifier }
    }
    
    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            guard self.tableView(tableView, canEditRowAt: indexPath) else { return }
            let entry = taskGroups[indexPath.section][indexPath.row]
            let identifier = entry.package.package
            let queue: DownloadManagerQueue
            if installations.contains(where: { $0.package.package == identifier }) {
                queue = .installations
                installations.removeAll { $0.package.package == identifier }
            } else if upgrades.contains(where: { $0.package.package == identifier }) {
                queue = .upgrades
                upgrades.removeAll { $0.package.package == identifier }
            } else {
                queue = .uninstallations
                uninstallations.removeAll { $0.package.package == identifier }
            }
            rebuildTaskGroups()
            tableView.reloadData()
            let downloadManager = DownloadManager.shared
            downloadManager.remove(downloadPackage: entry, queue: queue)
            downloadManager.reloadData(recheckPackages: true)
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }
}

extension DownloadsTableViewController: UITextViewDelegate {
    override func canPerformAction(
        _ action: Selector,
        withSender sender: Any?
    ) -> Bool
    {
        if action == #selector(selectAll(_:)) {
            return true
        } else {
            return false
        }
    }
    
    override func selectAll(_ sender: Any?) {
        detailsTextView?.selectAll(sender)
    }
}

/// The log apt and dpkg print is English whatever the app's language is. Each
/// line people actually read is matched here and shown as the strings files say
/// it, with package names and versions left in place; a language without an
/// entry for a line gets the line as it came.
enum APTLogTranslator {

    static func localize(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for (pattern, key) in rules {
            let template = String(localizationKey: key)
            guard template != key, let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
        }
        return result
    }

    /// A pattern for each line and the key that holds it, English in Base and
    /// translated beside it.
    private static let rules: [(String, String)] = [
        // apt
        ("(?m)^Running dpkg(?:\\.\\.\\.)?[ \\t]*\\r?$", "Log_Running_Dpkg"),
        ("(?m)^Reading package lists\\.\\.\\.( Done)?$", "Log_Read_Lists"),
        ("(?m)^Building dependency tree\\.\\.\\.( Done)?$", "Log_Build_Tree"),
        ("(?m)^Reading state information\\.\\.\\.( Done)?$", "Log_Read_State"),
        ("(?m)^The following package was automatically installed and is no longer required:$", "Log_Auto_Installed_One"),
        ("(?m)^The following packages were automatically installed and are no longer required:$", "Log_Auto_Installed"),
        ("(?m)^Use 'apt autoremove' to remove it\\.$", "Log_Autoremove_Hint_One"),
        ("(?m)^Use 'apt autoremove' to remove them\\.$", "Log_Autoremove_Hint"),
        ("(?m)^The following NEW packages will be installed:$", "Log_Will_Install"),
        ("(?m)^The following packages will be upgraded:$", "Log_Will_Upgrade"),
        ("(?m)^The following packages will be DOWNGRADED:$", "Log_Will_Downgrade"),
        ("(?m)^The following packages will be REMOVED:$", "Log_Will_Remove"),
        ("(?m)^The following packages will be removed:$", "Log_Will_Remove"),
        ("(?m)^(\\d+) upgraded, (\\d+) newly installed, (\\d+) downgraded, (\\d+) to remove and (\\d+) not upgraded\\.$", "Log_Summary_Downgrade"),
        ("(?m)^(\\d+) upgraded, (\\d+) newly installed, (\\d+) to remove and (\\d+) not upgraded\\.$", "Log_Summary"),
        ("(?m)^After this operation, (.+) of additional disk space will be used\\.$", "Log_Disk_Used"),
        ("(?m)^After this operation, (.+) disk space will be freed\\.$", "Log_Disk_Freed"),
        ("(?m)^Need to get (.+) of (source )?archives\\.$", "Log_Need_Get_Archives"),
        ("(?m)^Need to get (.+)\\.$", "Log_Need_Get"),
        ("(?m)^Fetched (.+) in (.+) \\((.+)\\)$", "Log_Fetched"),
        ("(?m)^Do you want to continue\\? \\[Y/n\\]$", "Log_Continue"),
        ("(?m)^The following packages have unmet dependencies:$", "Log_Unmet_Deps"),
        ("(?m)^ but it is not going to be installed$", "Log_Not_Going_To_Install"),
        ("(?m)^ but it is not installable$", "Log_Not_Installable"),
        ("(?m)^WARNING: The following packages cannot be authenticated!$", "Log_Unauthenticated"),
        ("(?m)^Install these packages without verification\\? \\[y/N\\]$", "Log_Install_Unverified"),
        ("(?m)^You might want to run 'apt --fix-broken install' to correct these\\.$", "Log_Fix_Broken_Hint"),
        ("(?m)^Hit:(\\d+) (.+)$", "Log_Hit"),
        ("(?m)^Get:(\\d+) (.+)$", "Log_Get"),
        ("(?m)^Ign:(\\d+) (.+)$", "Log_Ign"),
        ("(?m)^Err:(\\d+) (.+)$", "Log_Err"),
        ("(?m)^Some index files failed to download\\. They have been ignored, or old ones used instead\\.$", "Log_Index_Failed"),
        ("(?m)^Calculating upgrade\\.\\.\\.( Done)?$", "Log_Calculating_Upgrade"),
        ("(?m)^All packages are up to date\\.$", "Log_All_Up_To_Date"),
        ("(?m)^(\\d+) package can be upgraded\\. Run 'apt list --upgradable' to see it\\.$", "Log_Upgradable_One"),
        ("(?m)^(\\d+) packages can be upgraded\\. Run 'apt list --upgradable' to see them\\.$", "Log_Upgradable"),
        ("(?m)^Package '(.+)' is not installed, so not removed\\. Did you mean '(.+)'\\?$", "Log_Not_Installed_Removed_Did"),
        ("(?m)^Package '(.+)' is not installed, so not removed$", "Log_Not_Installed_Removed"),
        ("(?m)^Note, selecting '(.+)' instead of '(.+)'$", "Log_Note_Select_Instead"),
        ("(?m)^Note, selecting '(.+)' for glob '(.+)'$", "Log_Note_Select_Glob"),
        ("(?m)^Note, selecting '(.+)' for regex '(.+)'$", "Log_Note_Select_Regex"),
        ("(?m)^Note, selecting '(.+)' for task '(.+)'$", "Log_Note_Select_Task"),
        ("(?m)^Selected version '(.+)' \\((.+)\\) for '(.+)' because of '(.+)'$", "Log_Selected_Version_Because"),
        ("(?m)^Selected version '(.+)' \\((.+)\\) for '(.+)'$", "Log_Selected_Version"),
        ("(?m)^Skipping (.+), it is already installed and upgrade is not set\\.$", "Log_Skipping_Installed"),
        ("(?m)^The following signatures couldn't be verified because the public key is not available:$", "Log_Signatures_Unverified"),
        ("(?m)^The following signatures were invalid:$", "Log_Signatures_Invalid"),
        ("(?m)^Package (.+) is a virtual package provided by:$", "Log_Virtual_Provided"),
        ("(?m)^Virtual packages like '(.+)' can't be removed$", "Log_Virtual_Cannot_Remove"),
        ("(?m)^Your '(.+)' file changed, please run 'apt-get update'\\.$", "Log_File_Changed"),
        ("(?m)^(.+) is already the newest version \\((.+)\\)\\.$", "Log_Already_Newest"),
        ("(?m)^Abort\\.$", "Log_Abort"),
        // apt's E:/W: lines whose body is its own sentence
        ("(?m)^E: Sub-process (.+) returned an error code \\((\\d+)\\)$", "Log_Subprocess_Error"),
        ("(?m)^E: Unable to locate package (.+)$", "Log_Unable_Locate_Package"),
        ("(?m)^E: Unable to correct problems, you have held broken packages\\.$", "Log_Held_Broken"),
        ("(?m)^W: Download is performed unsandboxed as root as file '(.+)' couldn't be accessed by user '(.+)'\\.$", "Log_Unsandboxed_Download"),

        // dpkg
        ("(?m)^Selecting previously unselected package (.+)\\.$", "Log_Dpkg_Select"),
        ("(?m)^\\(Reading database \\.\\.\\. (\\d+) files and directories currently installed\\.\\)$", "Log_Dpkg_Database"),
        ("(?m)^Preparing to unpack \\.\\.\\./(.+) \\.\\.\\.$", "Log_Dpkg_Prepare"),
        ("(?m)^Preparing to unpack (.+) \\.\\.\\.$", "Log_Dpkg_Prepare_Plain"),
        ("(?m)^Replacing files in old package (.+) \\((.+)\\) \\.\\.\\.$", "Log_Dpkg_Replacing_Files"),
        ("(?m)^Replaced by files in installed package (.+) \\((.+)\\) \\.\\.\\.$", "Log_Dpkg_Replaced_By"),
        ("(?m)^Installing new version of config file (.+) \\.\\.\\.$", "Log_Dpkg_New_Config"),
        ("(?m)^Preparing to configure (.+) \\((.+)\\) \\.\\.\\.$", "Log_Dpkg_Prepare_Configure"),
        ("(?m)^Configuring (.+) \\((.+)\\) \\.\\.\\.$", "Log_Dpkg_Configuring"),
        ("(?m)^Unpacking (.+) \\((.+)\\) over \\((.+)\\) \\.\\.\\.$", "Log_Dpkg_Unpack_Over"),
        ("(?m)^Unpacking (.+) \\((.+)\\) \\.\\.\\.$", "Log_Dpkg_Unpack"),
        ("(?m)^Setting up (.+) \\((.+)\\) \\.\\.\\.$", "Log_Dpkg_Setup"),
        ("(?m)^Removing (.+) \\((.+)\\), to allow installation of (.+) \\((.+)\\) \\.\\.\\.$", "Log_Dpkg_Remove_Allow_Install"),
        ("(?m)^Removing (.+) \\((.+)\\), to allow configuration of (.+) \\((.+)\\) \\.\\.\\.$", "Log_Dpkg_Remove_Allow_Config"),
        ("(?m)^De-configuring (.+) \\((.+)\\), to allow installation of (.+) \\((.+)\\) \\.\\.\\.$", "Log_Dpkg_Deconfig_Install"),
        ("(?m)^De-configuring (.+) \\((.+)\\), to allow configuration of (.+) \\((.+)\\) \\.\\.\\.$", "Log_Dpkg_Deconfig_Config"),
        ("(?m)^De-configuring (.+) \\((.+)\\), to allow removal of (.+) \\((.+)\\) \\.\\.\\.$", "Log_Dpkg_Deconfig_Remove"),
        ("(?m)^Removing obsolete conffile (.+) \\.\\.\\.$", "Log_Dpkg_Obsolete_Conffile"),
        ("(?m)^Removing (.+) \\((.+)\\) \\.\\.\\.$", "Log_Dpkg_Remove"),
        ("(?m)^Purging configuration files for (.+) \\((.+)\\) \\.\\.\\.$", "Log_Dpkg_Purge"),
        ("(?m)^Processing triggers for (.+) \\((.+)\\) \\.\\.\\.$", "Log_Dpkg_Triggers"),
        ("(?m)^dpkg: warning: downgrading (.+) from (.+) to (.+)$", "Log_Dpkg_Downgrade"),
        ("(?m)^dpkg: warning: while removing (.+), directory '(.+)' not empty so not removed$", "Log_Dpkg_Dir_Not_Empty"),
        ("(?m)^dpkg: warning: while removing (.+), unable to remove directory '(.+)': (.+) - directory may be a mount point\\?$", "Log_Dpkg_Dir_Mount"),
        ("(?m)^dpkg: warning: unable to delete old directory '(.+)': Directory not empty$", "Log_Dpkg_Old_Dir_Not_Empty"),
        ("(?m)^dpkg: warning: unable to delete old directory '(.+)': (.+)$", "Log_Dpkg_Old_Dir_Failed"),
        ("(?m)^dpkg: warning: files list file for package '(.+)' missing; assuming package has no files currently installed$", "Log_Dpkg_Missing_Files_List"),
        ("(?m)^Obsolete conffile '(.+)' has been modified by you\\.$", "Log_Dpkg_Obsolete_Conffile_Modified"),
        ("(?m)^Processing was halted because there were too many errors\\.$", "Log_Dpkg_Halted"),
        ("(?m)^installed (.+) package old pre-removal script subprocess returned error exit status (\\d+)$", "Log_Dpkg_Script_OldPreRm"),
        ("(?m)^installed (.+) package old post-removal script subprocess returned error exit status (\\d+)$", "Log_Dpkg_Script_OldPostRm"),
        ("(?m)^installed (.+) package pre-installation script subprocess returned error exit status (\\d+)$", "Log_Dpkg_Script_PreInst"),
        ("(?m)^installed (.+) package post-installation script subprocess returned error exit status (\\d+)$", "Log_Dpkg_Script_PostInst"),
        ("(?m)^installed (.+) package pre-removal script subprocess returned error exit status (\\d+)$", "Log_Dpkg_Script_PreRm"),
        ("(?m)^installed (.+) package post-removal script subprocess returned error exit status (\\d+)$", "Log_Dpkg_Script_PostRm"),
        ("(?m)^(.+) subprocess returned error exit status (\\d+)$", "Log_Dpkg_Subprocess_Failed"),
        ("(?m)^(.+) subprocess was killed by signal \\((.+)\\)(.*)$", "Log_Dpkg_Subprocess_Signal"),
        ("(?m)^(.+) subprocess was interrupted$", "Log_Dpkg_Subprocess_Interrupted"),
        ("(?m)^dpkg: warning: ", "Log_Dpkg_Warning"),
        ("(?m)^dpkg: error: ", "Log_Dpkg_Error_Prefix"),
        ("(?m)^dpkg: error processing archive (.+) \\(--(\\w+)\\):$", "Log_Dpkg_Error_Archive"),
        ("(?m)^dpkg: error processing package (.+) \\(--(\\w+)\\):$", "Log_Dpkg_Error"),
        ("(?m)^dpkg: unrecoverable fatal error, aborting:$", "Log_Dpkg_Fatal"),
        ("(?m)^dpkg: dependency problems prevent configuration of (.+):$", "Log_Dpkg_Dep_Config"),
        ("(?m)^ dependency problems - leaving unconfigured$", "Log_Dpkg_Dep_Unconfigured"),
        ("(?m)^Errors were encountered while processing:$", "Log_Dpkg_Errors"),
        ("(?m)^ (.+) depends on (.+); however:$", "Log_Depends_However"),
        ("(?m)^  Package (.+) is not installed\\.?$", "Log_Not_Installed"),
        ("(?m)^  Package (.+) is not configured yet\\.$", "Log_Not_Configured"),

        // the first word of an apt error or warning line
        ("(?m)^E: ", "Log_E"),
        ("(?m)^W: ", "Log_W"),
        ("(?m)^Error: ", "Log_Error_Prefix")
    ]
}
