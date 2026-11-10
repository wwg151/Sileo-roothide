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
        return nil
    }
}

// MARK: - Snapshot from DownloadManager

extension DownloadManager {

    /// Every entry of the queue, with the state the new UI shows.
    func queueSnapshot() -> [QueueItem] {
        var items: [QueueItem] = []
        let downloads = vars.queuedDownloads.raw
        let aptActive = aptRunning && !aptFinished

        func add(_ set: [DownloadPackage], removal: Bool) {
            for entry in set {
                let package = entry.package
                let identifier = package.package
                let state: QueueItemState
                if let download = downloads[identifier] {
                    if download.completed && download.failureReason != nil {
                        state = .failed(download.failureReason)
                    } else if download.message != nil && !download.completed {
                        // the roothide conversion runs inside the download's slot
                        state = .converting
                    } else if download.started && !download.completed {
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
                                       state: state))
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
            if download.completed && download.failureReason != nil {
                state = .failed(download.failureReason)
            } else if download.message != nil && !download.completed {
                state = .converting
            } else if download.started && !download.completed {
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
        return items.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0.identifier < $1.identifier }
    }
}

// MARK: - Center

final class QueueCenter {
    static let shared = QueueCenter()
    static let queueChangedNotification = Notification.Name("QueueCenterQueueChanged")

    private var capsule: QueueCapsuleView?
    private var timer: Timer?
    private var doneShownAt: Date?
    private var installFailed = false
    private(set) var sheetVisible = false
    private var lastItems: [QueueItem] = []

    private init() {}

    // MARK: wiring

    /// The capsule rides above the floating tab bar of the root controller.
    func attach(to view: UIView, tabBar: UIView) {
        guard capsule == nil else { return }
        let capsuleView = QueueCapsuleView(frame: .zero)
        capsuleView.onTap = { [weak self] in self?.presentSheet() }
        capsuleView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(capsuleView)
        NSLayoutConstraint.activate([
            capsuleView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            // the floating pill sits 12pt above the safe area and is 64pt tall;
            // the capsule keeps 8pt of air above its top edge
            capsuleView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -84),
            capsuleView.heightAnchor.constraint(equalToConstant: 44)
        ])
        capsule = capsuleView
        view.bringSubviewToFront(capsuleView)
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
            if ok {
                self.doneShownAt = Date()
            } else {
                self.installFailed = true
            }
            self.syncNow()
        }
    }

    /// A new apt run began: the previous result no longer applies.
    func installStarted() {
        DispatchQueue.main.async {
            self.installFailed = false
            self.doneShownAt = nil
            self.syncNow()
        }
    }

    func state(for identifier: String) -> QueueItemState? {
        lastItems.first { $0.identifier == identifier }?.state
    }

    private func syncNow() {
        var items = DownloadManager.shared.queueSnapshot()
        for item in items where origins[item.identifier] == nil {
            origins[item.identifier] = QueueCenter.currentPageIdentifier()
        }
        let hasFailure = installFailed || items.contains { $0.isFailed }

        if !items.isEmpty {
            // a new run supersedes the previous result
            doneShownAt = nil
            installFailed = false
        } else if let done = doneShownAt, Date().timeIntervalSince(done) >= 2 {
            doneShownAt = nil
        }

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
    private var origins: [String: ObjectIdentifier] = [:]

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
        let busy = capsule?.isHidden == false || sheetVisible
        if busy, timer == nil {
            let timer = Timer(timeInterval: 0.7, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !busy, let timer = self.timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    @objc private func tick() {
        syncNow()
    }

    // MARK: capsule

    private func updateCapsule(visible: Bool, items: [QueueItem], failure: Bool, done: Bool) {
        guard let capsule = capsule else { return }
        if visible {
            capsule.configure(items: items, failure: failure, done: done)
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
            })
        }
        restartTimer()
    }

    // MARK: sheet

    func presentSheet() {
        guard !sheetVisible else { return }
        guard let host = TabBarController.singleton else { return }
        let sheet = QueueSheetController()
        sheet.modalPresentationStyle = .pageSheet
        if let presentation = sheet.sheetPresentationController {
            presentation.detents = [.medium(), .large()]
            presentation.prefersGrabberVisible = true
        }
        sheetVisible = true
        host.present(sheet, animated: true) {
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

// MARK: - Capsule view

final class QueueCapsuleView: UIView {

    var onTap: (() -> Void)?

    private let ringLayer = CAShapeLayer()
    private let trackLayer = CAShapeLayer()
    private let titleLabel = UILabel()
    private let percentLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .systemBackground
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 18
        layer.shadowOffset = CGSize(width: 0, height: 6)
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.separator.withAlphaComponent(0.4).cgColor

        trackLayer.fillColor = UIColor.clear.cgColor
        trackLayer.strokeColor = UIColor.tertiaryLabel.withAlphaComponent(0.35).cgColor
        trackLayer.lineWidth = 3
        trackLayer.lineCap = .round
        layer.addSublayer(trackLayer)

        ringLayer.fillColor = UIColor.clear.cgColor
        ringLayer.strokeColor = UIColor.tintColor.cgColor
        ringLayer.lineWidth = 3
        ringLayer.lineCap = .round
        layer.addSublayer(ringLayer)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 1
        addSubview(titleLabel)

        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        percentLabel.font = .systemFont(ofSize: 13)
        percentLabel.textColor = .secondaryLabel
        addSubview(percentLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 42),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            percentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            percentLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

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

    override func layoutSubviews() {
        super.layoutSubviews()
        let center = CGPoint(x: 26, y: bounds.height / 2)
        let path = UIBezierPath(arcCenter: center, radius: 9.5, startAngle: -.pi / 2,
                                endAngle: .pi * 3 / 2, clockwise: true)
        trackLayer.frame = bounds
        ringLayer.frame = bounds
        trackLayer.path = path.cgPath
        ringLayer.path = path.cgPath
    }

    func configure(items: [QueueItem], failure: Bool, done: Bool) {
        let ringColor: UIColor
        if done {
            titleLabel.text = String(localizationKey: "Queue_Done")
            percentLabel.text = "✓"
            percentLabel.textColor = .systemGreen
            ringColor = .systemGreen
            setRing(1, ringColor)
        } else if failure || items.contains(where: { $0.isFailed }) {
            let failed = max(1, items.filter { $0.isFailed }.count)
            titleLabel.text = String(format: String(localizationKey: "Queue_Failed_N"), failed)
            percentLabel.text = "!"
            percentLabel.textColor = .systemRed
            ringColor = .systemRed
            setRing(1, ringColor)
        } else {
            let downloading = items.filter {
                if case .downloading = $0.state { return true }
                return false
            }
            let progress = downloading.map { $0.progress ?? 0 }.reduce(0, +) / CGFloat(max(downloading.count, 1))
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
            percentLabel.text = downloading.isEmpty ? nil : String(format: "%.0f%%", progress * 100)
            percentLabel.textColor = .secondaryLabel
            ringColor = .tintColor
            setRing(downloading.isEmpty ? 1 : progress, ringColor)
        }
    }

    private func setRing(_ fraction: CGFloat, _ color: UIColor) {
        ringLayer.strokeColor = color.cgColor
        ringLayer.strokeEnd = fraction
    }
}

// MARK: - In-place ring overlay

final class QueueRingOverlay: UIView {

    private let ringLayer = CAShapeLayer()
    private let textLayer = CATextLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        ringLayer.fillColor = UIColor.clear.cgColor
        ringLayer.strokeColor = UIColor.tintColor.cgColor
        ringLayer.lineWidth = 3
        ringLayer.lineCap = .round
        layer.addSublayer(ringLayer)
        textLayer.string = ""
        textLayer.fontSize = 12
        textLayer.alignmentMode = .center
        textLayer.contentsScale = UIScreen.main.scale
        textLayer.foregroundColor = UIColor.label.cgColor
        layer.addSublayer(textLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var fraction: CGFloat = 0

    func configure(text: String, fraction: CGFloat?, failed: Bool) {
        let color: UIColor = failed ? .systemRed : .tintColor
        ringLayer.strokeColor = color.cgColor
        self.fraction = fraction ?? 1
        textLayer.string = text
        textLayer.foregroundColor = (failed ? UIColor.systemRed : UIColor.label).cgColor
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height) - 10
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        ringLayer.frame = bounds
        ringLayer.path = UIBezierPath(arcCenter: center, radius: side / 2,
                                      startAngle: -.pi / 2, endAngle: .pi * 3 / 2,
                                      clockwise: true).cgPath
        ringLayer.strokeEnd = fraction
        textLayer.frame = CGRect(x: 0, y: center.y - 9, width: bounds.width, height: 18)
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
        table.register(QueueCardCell.self, forCellReuseIdentifier: "QueueCard")
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
        items = DownloadManager.shared.queueSnapshot()
        let failed = items.filter { $0.isFailed }.count
        titleLabel.text = String(localizationKey: "Queue_Title")
        if failed > 0 {
            subtitleLabel.text = String(format: String(localizationKey: "Queue_Failed_N"), failed)
            subtitleLabel.textColor = .systemRed
        } else {
            subtitleLabel.text = String(format: String(localizationKey: "Queue_Items"), items.count)
            subtitleLabel.textColor = .secondaryLabel
        }
        if items.isEmpty {
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
            DownloadManager.shared.removeAllItems()
        }.present(from: self)
    }

    private func openLog() {
        let controller = DownloadManager.shared.viewController
        controller.modalPresentationStyle = .pageSheet
        if let presentation = controller.sheetPresentationController {
            presentation.detents = [.large()]
            presentation.prefersGrabberVisible = true
        }
        present(controller, animated: true)
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
