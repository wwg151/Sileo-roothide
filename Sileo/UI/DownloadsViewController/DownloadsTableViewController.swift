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
    private var hasErrored = false
    private var detailsAttributedString: NSMutableAttributedString?

    private let taskHeader = UIView()
    private let taskCard = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let taskTitle = UILabel()
    private let collapseTaskButton = UIButton(type: .system)
    private let taskPrimaryButton = UIButton(type: .system)
    private let cancelFromLogButton = UIButton(type: .system)
    private let taskStage = UILabel()
    private let taskHeadline = UILabel()
    private let taskDetail = UILabel()
    private let taskProgress = UIProgressView(progressViewStyle: .bar)
    private let stageActivity = UIActivityIndicatorView(style: .medium)
    private let footerMaterial = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private var installExitStatus: Int32?
    private var currentTaskStatus: String?

    public var presentationHasFailed: Bool {
        !errors.isEmpty || (isFinishedInstalling && installExitStatus != 0)
    }

    private func configureTaskPresentation() {
        view.backgroundColor = .systemGroupedBackground
        tableView?.backgroundColor = .clear
        tableView?.contentInset = .zero
        tableView?.sectionHeaderTopPadding = 0
        taskHeader.addSubview(taskTitle)
        taskHeader.addSubview(collapseTaskButton)
        collapseTaskButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        collapseTaskButton.accessibilityLabel = String(localizationKey: "Hide_Install_Details")
        collapseTaskButton.addTarget(self, action: #selector(collapseTask), for: .touchUpInside)
        taskPrimaryButton.layer.cornerRadius = 25
        taskPrimaryButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        taskPrimaryButton.addTarget(self, action: #selector(retryFailedTasks), for: .touchUpInside)
        taskHeader.addSubview(taskCard)
        taskCard.layer.cornerRadius = 25
        taskCard.clipsToBounds = true
        taskCard.layer.borderWidth = 0.5
        [taskStage, taskHeadline, taskDetail, taskProgress, stageActivity].forEach { taskCard.contentView.addSubview($0) }
        taskTitle.font = .systemFont(ofSize: 29, weight: .bold)
        taskTitle.textColor = .label
        taskTitle.text = String(localizationKey: "Task_Title")
        taskStage.font = .systemFont(ofSize: 13, weight: .semibold)
        taskHeadline.font = .systemFont(ofSize: 25, weight: .bold)
        taskHeadline.adjustsFontSizeToFitWidth = true
        taskHeadline.minimumScaleFactor = 0.7
        taskHeadline.textColor = .label
        taskDetail.font = .systemFont(ofSize: 13)
        taskDetail.textColor = .secondaryLabel
        taskDetail.numberOfLines = 2
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
        cancelFromLogButton.setTitle(cancelDownload?.title(for: .normal), for: .normal)
        cancelFromLogButton.addTarget(self, action: #selector(cancelFromDownloadLog), for: .touchUpInside)
        cancelFromLogButton.isHidden = true
        if let details = detailsView, let textView = detailsTextView {
            cancelFromLogButton.translatesAutoresizingMaskIntoConstraints = false
            details.addSubview(cancelFromLogButton)
            NSLayoutConstraint.activate([
                cancelFromLogButton.trailingAnchor.constraint(equalTo: textView.trailingAnchor, constant: -12),
                cancelFromLogButton.bottomAnchor.constraint(equalTo: textView.bottomAnchor, constant: -8),
                cancelFromLogButton.heightAnchor.constraint(equalToConstant: 44)
            ])
        }
    }

    private func layoutTaskPresentation() {
        guard let table = tableView else { return }
        let width = table.bounds.width
        if taskHeader.frame.width != width || taskHeader.frame.height != 268 {
            taskHeader.frame = CGRect(x: 0, y: 0, width: width, height: 268)
            table.tableHeaderView = taskHeader
        }
        taskTitle.frame = CGRect(x: 24, y: 46, width: max(0, width - 94), height: 38)
        collapseTaskButton.frame = CGRect(x: width - 64, y: 43, width: 44, height: 44)
        taskCard.frame = CGRect(x: 20, y: 108, width: width - 40, height: 146)
        let inner = taskCard.bounds.width - 40
        taskStage.frame = CGRect(x: 20, y: 17, width: inner - 28, height: 20)
        stageActivity.frame = CGRect(x: inner + 1, y: 17, width: 20, height: 20)
        taskHeadline.frame = CGRect(x: 20, y: 44, width: inner, height: 34)
        taskDetail.frame = CGRect(x: 20, y: 81, width: inner, height: 36)
        taskProgress.frame = CGRect(x: 20, y: 128, width: inner, height: 4)
        taskCard.layer.borderColor = UIColor.separator.withAlphaComponent(0.12).cgColor
        guard let footer = footerView else { return }
        footerMaterial.frame = footer.bounds
        let w = footer.bounds.width
        let side = min(122, w * 0.34)
        let main = CGRect(x: side + 24, y: 14, width: max(0, w - side - 44), height: 50)
        let secondary = CGRect(x: 16, y: 14, width: side, height: 50)
        confirmButton?.frame = main
        clearButton?.frame = secondary
        completeButton?.frame = main
        showDetailsButton?.frame = secondary
        taskPrimaryButton.frame = main
        cancelDownload?.frame = secondary
        completeLaterButton?.frame = CGRect(x: 24, y: 72, width: w - 48, height: 40)
    }

    private func refreshTaskPresentation() {
        guard isViewLoaded else { return }
        let manager = DownloadManager.shared
        let downloads = Array(manager.vars.queuedDownloads.raw.values).filter { $0.session == manager.currentDownloadSession }
        let failed = downloads.filter { !($0.failureReason ?? "").isEmpty }
        let finished = downloads.filter { $0.success && $0.progress == 1 && ($0.failureReason ?? "").isEmpty }.count
        let blocked = !errors.isEmpty || !failed.isEmpty || (isFinishedInstalling && installExitStatus != 0)
        let color: UIColor = blocked ? .systemOrange : (UINavigationBar.appearance().tintColor ?? .systemTeal)
        taskStage.textColor = color
        taskProgress.progressTintColor = color
        stageActivity.color = color
        let active = (isInstalling && !isFinishedInstalling) || (isDownloading && failed.isEmpty)
        if active { stageActivity.startAnimating() } else { stageActivity.stopAnimating() }
        taskProgress.isHidden = !isDownloading || !failed.isEmpty || isFinishedInstalling || isInstalling
        if isFinishedInstalling {
            taskStage.text = String(localizationKey: blocked ? "Task_Attention" : "Done")
            taskHeadline.text = String(localizationKey: blocked ? "Task_Install_Issue" : "Task_Completed")
            taskDetail.text = String(localizationKey: blocked ? "Task_Check_Log" : "Task_Finish_Hint")
        } else if isInstalling {
            taskStage.text = String(localizationKey: "Installing_Package_Status")
            taskHeadline.text = String(localizationKey: "Task_Installing")
            taskDetail.text = currentTaskStatus ?? String(localizationKey: "Task_Keep_Open")
        } else if !errors.isEmpty {
            taskStage.text = String(localizationKey: "Task_Attention")
            taskHeadline.text = String(format: String(localizationKey: "Task_Issue_Count"), errors.count)
            taskDetail.text = String(localizationKey: "Task_Resolve_Dependencies")
        } else if !failed.isEmpty {
            taskStage.text = String(localizationKey: "Task_Download_Issue")
            taskHeadline.text = String(format: String(localizationKey: "Task_Issue_Count"), failed.count)
            taskDetail.text = String(format: String(localizationKey: "Task_Download_Failure_Summary"), finished)
        } else if isDownloading {
            taskStage.text = String(localizationKey: "Downloading_Package_Status")
            taskHeadline.text = String(format: String(localizationKey: "Task_Download_Count"), finished, manager.installingPackages())
            let written = downloads.reduce(Int64(0)) { $0 + max(0, $1.totalBytesWritten) }
            let expected = downloads.reduce(Int64(0)) { $0 + max(0, $1.totalBytesExpectedToWrite) }
            let knownSize = downloads.count == manager.installingPackages() && downloads.allSatisfy { $0.totalBytesExpectedToWrite > 0 }
            if knownSize && expected > 0 {
                taskDetail.text = String(format: String(localizationKey: "Download_Progress"), ByteCountFormatter.string(fromByteCount: written, countStyle: .file), ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))
                taskProgress.setProgress(Float(min(1, Double(written) / Double(expected))), animated: false)
            } else {
                taskDetail.text = written > 0 ? ByteCountFormatter.string(fromByteCount: written, countStyle: .file) + " …" : String(localizationKey: "Download_Starting")
                taskProgress.isHidden = true
            }
        } else {
            taskStage.text = String(localizationKey: "Queued_Package_Status")
            taskHeadline.text = String(localizationKey: "Task_Ready")
            taskDetail.text = String(format: String(localizationKey: "Task_Summary"), manager.installingPackages(), manager.uninstallingPackages())
        }
        let downloadStage = isDownloading && !isInstalling && !isFinishedInstalling
        taskPrimaryButton.isHidden = !downloadStage
        taskPrimaryButton.isEnabled = downloadStage && !failed.isEmpty
        taskPrimaryButton.setTitle(String(localizationKey: failed.isEmpty ? "Downloading_Package_Status" : "Task_Retry_Failed"), for: .normal)
        taskPrimaryButton.backgroundColor = failed.isEmpty ? .tertiarySystemFill : color
        taskPrimaryButton.setTitleColor(failed.isEmpty ? .secondaryLabel : .white, for: .normal)
        collapseTaskButton.tintColor = .secondaryLabel
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
        
        var package: Package
        var type: ActionType
        var progressCounter: CGFloat = 0.0
        var status: String?
        weak var cell: DownloadsTableViewCell?
        
        public var progress: CGFloat {
            let progress = progressCounter / (type == .install ? 6.0 : 3.0)
            if progress > 1.0 {
                return 1.0
            } else {
                return progress
            }
        }
        
        init(package: Package, type: ActionType) {
            self.package = package
            self.type = type
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
        
        clearButton.tintColor = confirmButton.tintColor
        clearButton.isHighlighted = confirmButton.isHighlighted
        confirmButton.tintColor = UINavigationBar.appearance().tintColor
        confirmButton.isHighlighted = confirmButton.isHighlighted
        completeButton?.tintColor = UINavigationBar.appearance().tintColor
        completeButton?.isHighlighted = completeButton?.isHighlighted ?? false
        cancelDownload?.tintColor = UINavigationBar.appearance().tintColor
        cancelDownload?.isHighlighted = completeButton?.isHighlighted ?? false
        completeLaterButton?.tintColor = .clear
        completeLaterButton?.isHighlighted = completeLaterButton?.isHighlighted ?? false
        completeLaterButton?.setTitleColor(UINavigationBar.appearance().tintColor, for: .normal)
 
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
        cancelDownload?.isHidden = true
        completeButton?.isHidden = !isFinishedInstalling
        completeLaterButton?.isHidden = !isFinishedInstalling || completeLaterButton?.alpha == 0
        showDetailsButton?.isHidden = !isDownloading && !isInstalling && !isFinishedInstalling
        confirmButton?.isEnabled = manager.vars.errors.isEmpty
        confirmButton?.alpha = manager.vars.errors.isEmpty ? 1 : 0.5
        let visible = manager.operationCount() > 0 || !errors.isEmpty || isDownloading || isInstalling || isFinishedInstalling
        footerViewHeight?.constant = visible ? (isFinishedInstalling && completeLaterButton?.isHidden == false ? 126 : 80) : 0
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
        
        if let sender = sender as? UIButton, sender.isHidden {
            return //UIKit bug: https://stackoverflow.com/questions/37916952/ios-why-does-hidden-button-still-receive-tap-events/37918283#37918283
        }
        
        isInstalling = false
        isDownloading = false
        isFinishedInstalling = false
        returnButtonAction = .back
        refreshSileo = false
        hasErrored = false
        installExitStatus = nil
        currentTaskStatus = nil
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
        hasErrored = false
        installExitStatus = nil
        currentTaskStatus = nil
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
        
        isDownloading = true
        installExitStatus = nil
        currentTaskStatus = nil
        
        DownloadManager.shared.aptRunning = false
        DownloadManager.shared.aptFinished = false
        DownloadManager.shared.queueRunning = true
        DownloadManager.shared.currentDownloads = 0
        NotificationCenter.default.post(name: DownloadManager.lockStateChangeNotification, object: nil)
        
        NSLog("SileoLog: startMoreDownloads (confirmQueued)")
        DownloadManager.shared.startDownloads()
        TabBarController.singleton?.updatePopup()
        self.reloadData()
        self.checkReady()
        
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
        self.actions += installs.map { Action(package: $0.package, type: .install) }
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
        if !earlyBreak {
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
        guard let action = actions.first(where: { $0.package.package == package }) else { return }
        action.progressCounter += 1
        let shown = APTLogTranslator.localize(status)
        let ending = "(\(DPKGArchitecture.Architecture.roothide.rawValue))"
        if action.package.tags.contains(.roothide) && shown.hasSuffix(ending) {
            if var origArch = action.package.origArchitecture {
                action.status = shown.replacingOccurrences(of: ending, with: "(\(origArch))")
            } else {
                action.status = shown.replacingOccurrences(of: ending, with: "")
            }
        } else {
            action.status = shown
        }
        NSLog("SileoLog: action=\(action) cell=\(action.cell)")
        action.cell?.updateStatus()
        currentTaskStatus = action.status
        refreshTaskPresentation()
    }
    
    private func queueCompleted() {
        isInstalling = false
        isFinishedInstalling = false
        returnButtonAction = .back
        refreshSileo = false
        hasErrored = false
        installExitStatus = nil
        currentTaskStatus = nil
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
        
        isFired = true
        setNeedsStatusBarAppearanceUpdate()
        
        let window = UIApplication.shared.keyWindow

        let animator = UIViewPropertyAnimator(duration: 0.3, dampingRatio: 1) {
            window?.alpha = 0
            window?.transform = .init(scaleX: 0.9, y: 0.9)
        }

        // When the animation has finished, fire the dumb respring code
        animator.addCompletion { _ in
            
            //1: at least since iOS16, "uicache -p sileo.app" will kill the sileo process (when only the bundle mtime changed)
            //2: rebooting userspace immediately after executing uicache may cause jailbreak apps to disappear
            
            switch self.returnButtonAction {
                case .uicache:
                    spawnAsRoot(args:[jbroot("/usr/bin/uicache"), "-a"])
                
                case .reload, .restart:
                    spawnAsRoot(args:[jbroot("/usr/bin/sbreload")])
                
                case .reboot, .usreboot:
                    spawnAsRoot(args:[jbroot("/usr/bin/sync")])
                    spawnAsRoot(args:[jbroot("/usr/bin/launchctl"), "reboot", "userspace"])
                
                case .reopen:
                    if self.refreshSileo {
                        UserDefaults.standard.setValue(false, forKey: "uicacheRequired")
                        UserDefaults.standard.synchronize()
                        spawnAsRoot(args:[jbroot("/usr/bin/uicache"), "-p", rootfs(Bundle.main.bundlePath)])
                    }
                    exit(0)
                
                default:
                    if self.refreshSileo {
                        UserDefaults.standard.setValue(false, forKey: "uicacheRequired")
                        UserDefaults.standard.synchronize()
                        spawnAsRoot(args:[jbroot("/usr/bin/uicache"), "-p", rootfs(Bundle.main.bundlePath)])
                        exit(0)
                    }
            }
        }
        // Fire the animation
        animator.startAnimation()
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
        NSLog("SileoLog: startAction")
        func shouldShow(_ finish: APTWrapper.FINISH) -> Bool {
            finish == .reload || finish == .restart || finish == .reboot || finish == .usreboot
        }
        
        if let detailsAttributedString = self.detailsAttributedString {
            detailsTextView?.attributedText = self.transform(attributedString: detailsAttributedString)
        }
        
        DownloadManager.shared.aptRunning = true
        DownloadManager.shared.aptFinished = false
        
        TabBarController.singleton?.updatePopup()

        let installedToRecord = (installations + upgrades + installdeps).map { $0.package }
        let removedToForget = (uninstallations + uninstalldeps).map { $0.package.package }
        APTWrapper.performOperations(installs: installations + upgrades, removals: uninstallations + uninstalldeps, installDeps: installdeps, progressCallback: { _, statusValid, statusReadable, package in
            NSLog("SileoLog: progressCallback \(statusValid) \(package) \(statusReadable)")
            if statusValid {
                self.statusWork(package: package, status: statusReadable)
            }
        }, outputCallback: { output, pipe in
            NSLog("SileoLog: apt outputCallback \(pipe):\(output)")
            var textColor = Dusk.foregroundColor
            if pipe == STDERR_FILENO {
                textColor = Dusk.errorColor
                self.hasErrored = true
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
                
                _ = self.actions.map { $0.progressCounter = 7 }
                self.tableView?.reloadData()
                
                self.returnButtonAction = finish
                self.refreshSileo = refresh
                self.updateCompleteButton()
                self.completeButton?.alpha = 1
                self.showDetailsButton?.isHidden = false
                self.completeLaterButton?.alpha = shouldShow(finish) ? 1 : 0
                
                self.installExitStatus = Int32(status)
                self.isFinishedInstalling = true
                self.reloadControlsOnly()
                
                TabBarController.singleton?.updatePopup()
                
                if UserDefaults.standard.bool(forKey: "AlwaysShowLog") || self.hasErrored {
                    self.showDetails(nil)
                }
                else
                if (UserDefaults.standard.bool(forKey: "AutoComplete") && !self.hasErrored) // || !(TabBarController.singleton?.popupIsPresented ?? false)
                {
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
    
    @objc private func cancelFromDownloadLog() {
        guard isDownloading && !isInstalling && !isFinishedInstalling else { return }
        hideDetails(nil)
        cancelDownload(nil)
    }

    private func refreshDownloadLog() {
        let downloading = isDownloading && !isInstalling && !isFinishedInstalling
        cancelFromLogButton.isHidden = !downloading
        detailsTextView?.textContainerInset.bottom = downloading ? 60 : 18
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
        FRUIView.animate(withDuration: 0.25) {
            self.detailsView?.alpha = 1
        
            self.statusBarStyle = .lightContent
            
            TabBarController.singleton?.popupContentView.popupCloseButton.isHidden = true
        }
    }
    
    @IBAction private func hideDetails(_ sender: Any?) {
        FRUIView.animate(withDuration: 0.25, animations: {
            self.detailsView?.alpha = 0
            
            self.statusBarStyle = UIDevice.current.userInterfaceIdiom == .pad ? .default : .lightContent
            
            TabBarController.singleton?.popupContentView.popupCloseButton.isHidden = false
        }, completion: { _ in
            self.detailsView?.removeFromSuperview()
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
        ("(?m)^Reading package lists\\.\\.\\.( Done)?$", "Log_Read_Lists"),
        ("(?m)^Building dependency tree\\.\\.\\.( Done)?$", "Log_Build_Tree"),
        ("(?m)^Reading state information\\.\\.\\.( Done)?$", "Log_Read_State"),
        ("(?m)^The following packages were automatically installed and are no longer required:$", "Log_Auto_Installed"),
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

        // dpkg
        ("(?m)^Selecting previously unselected package (.+)\\.$", "Log_Dpkg_Select"),
        ("(?m)^\\(Reading database \\.\\.\\. (\\d+) files and directories currently installed\\.\\)$", "Log_Dpkg_Database"),
        ("(?m)^Preparing to unpack \\.\\.\\./(.+) \\.\\.\\.$", "Log_Dpkg_Prepare"),
        ("(?m)^Preparing to configure (.+) \\((.+)\\) \\.\\.\\.$", "Log_Dpkg_Prepare_Configure"),
        ("(?m)^Configuring (.+) \\((.+)\\) \\.\\.\\.$", "Log_Dpkg_Configuring"),
        ("(?m)^Unpacking (.+) \\((.+)\\) over \\((.+)\\) \\.\\.\\.$", "Log_Dpkg_Unpack_Over"),
        ("(?m)^Unpacking (.+) \\((.+)\\) \\.\\.\\.$", "Log_Dpkg_Unpack"),
        ("(?m)^Setting up (.+) \\((.+)\\) \\.\\.\\.$", "Log_Dpkg_Setup"),
        ("(?m)^Removing (.+) \\((.+)\\) \\.\\.\\.$", "Log_Dpkg_Remove"),
        ("(?m)^Purging configuration files for (.+) \\((.+)\\) \\.\\.\\.$", "Log_Dpkg_Purge"),
        ("(?m)^Processing triggers for (.+) \\((.+)\\) \\.\\.\\.$", "Log_Dpkg_Triggers"),
        ("(?m)^dpkg: warning: downgrading (.+) from (.+) to (.+)$", "Log_Dpkg_Downgrade"),
        ("(?m)^dpkg: warning: ", "Log_Dpkg_Warning"),
        ("(?m)^dpkg: error: ", "Log_Dpkg_Error_Prefix"),
        ("(?m)^dpkg: error processing package (.+) \\(--(\\w+)\\):$", "Log_Dpkg_Error"),
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
